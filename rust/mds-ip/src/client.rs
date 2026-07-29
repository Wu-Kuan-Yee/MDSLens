// SPDX-FileCopyrightText: 2026 MDSLens Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! MDSIP TCP connection management with thread-local connection caching.
//!
//! Ported from `src/mds/mds_ip_client.cpp`.

use crate::protocol;
use std::collections::HashMap;
use std::net::TcpStream;
use std::sync::{Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

const MAX_CONCURRENT_SETUPS_PER_SERVER: usize = 8;

struct ConnectionSetupPermit {
    key: String,
}

static CONNECTION_SETUPS: OnceLock<(Mutex<HashMap<String, usize>>, Condvar)> =
    OnceLock::new();

fn connection_setups() -> &'static (Mutex<HashMap<String, usize>>, Condvar) {
    CONNECTION_SETUPS.get_or_init(|| (Mutex::new(HashMap::new()), Condvar::new()))
}

impl ConnectionSetupPermit {
    fn acquire(key: String) -> Result<Self, String> {
        let (setups, changed) = connection_setups();
        let mut active = setups
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        loop {
            if protocol::current_operation_canceled() {
                return Err("operation canceled".to_string());
            }
            let count = active.entry(key.clone()).or_default();
            if *count < MAX_CONCURRENT_SETUPS_PER_SERVER {
                *count += 1;
                return Ok(Self { key });
            }
            active = changed
                .wait_timeout(active, Duration::from_millis(50))
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .0;
        }
    }
}

impl Drop for ConnectionSetupPermit {
    fn drop(&mut self) {
        let (setups, changed) = connection_setups();
        let mut active = setups
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(count) = active.get_mut(&self.key) {
            *count = count.saturating_sub(1);
            if *count == 0 {
                active.remove(&self.key);
            }
        }
        changed.notify_one();
    }
}

/// A reusable MDSplus TCP connection with cached tree/shot state.
pub struct MdsConnection {
    pub stream: TcpStream,
    pub host: String,
    pub port: u16,
    pub current_tree: String,
    pub current_shot: String,
}

impl MdsConnection {
    /// Connect to an MDSplus server and perform the MDSIP handshake.
    pub fn connect(host: &str, port: u16) -> Result<Self, String> {
        let started = Instant::now();
        // If host already contains a port (SSH tunnel rewrites IP to "127.0.0.1:PORT"),
        // use it as-is. Otherwise append the MDS port.
        let addr = if host.contains(':') { host.to_string() }
                   else { format!("{}:{}", host, port) };
        let _setup_permit = ConnectionSetupPermit::acquire(addr.clone())?;
        let stream = TcpStream::connect_timeout(
            &addr.parse().map_err(|e| format!("invalid address {}: {}", addr, e))?,
            Duration::from_millis(protocol::CONNECTION_SETUP_TIMEOUT_MS),
        )
        .map_err(|e| format!("connect to {}: {}", addr, e))?;

        stream
            .set_read_timeout(Some(Duration::from_millis(
                protocol::CONNECTION_SETUP_TIMEOUT_MS,
            )))
            .map_err(|e| format!("set_read_timeout: {}", e))?;

        let mut conn = Self {
            stream,
            host: host.to_string(),
            port,
            current_tree: String::new(),
            current_shot: String::new(),
        };

        protocol::handshake(&mut conn.stream)?;
        protocol::observe_reconnect_cost(started.elapsed());
        Ok(conn)
    }

    /// Open a tree on this connection. Skips if tree/shot unchanged.
    pub fn open_tree(&mut self, tree: &str, shot: &str) -> Result<(), String> {
        if tree.is_empty() || shot.is_empty() {
            return Ok(());
        }
        if self.current_tree == tree && self.current_shot == shot {
            return Ok(());
        }

        let expr = format!("TreeOpen(\"{}\", {})", tree, shot);
        match protocol::value_for_setup(&mut self.stream, &expr) {
            Ok(_) => {}
            Err(_e) => {
                // Fallback: try JavaOpen for EAST servers
                let fallback = format!("JavaOpen(\"{}\", {})", tree, shot);
                protocol::value_for_setup(&mut self.stream, &fallback)?;
            }
        }
        self.current_tree = tree.to_string();
        self.current_shot = shot.to_string();
        Ok(())
    }

    pub fn key(&self) -> String {
        format!("{}:{}", self.host, self.port)
    }
}

/// Thread-local connection pool.
///
/// Each worker thread caches up to 8 connections keyed by `host:port`.
pub struct ConnectionPool {
    connections: HashMap<String, MdsConnection>,
    max_connections: usize,
}

impl ConnectionPool {
    pub fn new() -> Self {
        Self { connections: HashMap::new(), max_connections: 8 }
    }

    /// Get or create a connection to `host:port`. Opens the given tree.
    pub fn get_or_connect(
        &mut self,
        host: &str,
        port: u16,
        tree: &str,
        shot: &str,
    ) -> Result<&mut MdsConnection, String> {
        let key = if host.contains(':') { host.to_string() }
                  else { format!("{}:{}", host, port) };

        if !self.connections.contains_key(&key) {
            if self.connections.len() >= self.max_connections {
                let oldest_key = self.connections.keys().next().cloned();
                if let Some(k) = oldest_key {
                    self.connections.remove(&k);
                }
            }
            let conn = MdsConnection::connect(host, port)?;
            self.connections.insert(key.clone(), conn);
        }

        let conn = self.connections.get_mut(&key).unwrap();
        conn.open_tree(tree, shot)?;
        Ok(conn)
    }

    /// Evict a broken connection.
    pub fn evict(&mut self, host: &str, port: u16) {
        let key = format!("{}:{}", host, port);
        self.connections.remove(&key);
    }
}

/// Access the thread-local connection pool.
pub fn with_thread_local_pool<F, R>(f: F) -> R
where
    F: FnOnce(&mut ConnectionPool) -> R,
{
    thread_local! {
        static POOL: std::cell::RefCell<ConnectionPool> =
            std::cell::RefCell::new(ConnectionPool::new());
    }
    POOL.with(|p| f(&mut p.borrow_mut()))
}

// Keep one socket for every global fetch worker. Large layouts regularly use
// all 16 workers; discarding half of those connections made every refresh pay
// another round of MDSIP handshakes and TreeOpen calls.
const MAX_IDLE_CONNECTIONS_PER_SERVER: usize = 16;
static SHARED_CONNECTIONS: OnceLock<Mutex<HashMap<String, Vec<MdsConnection>>>> =
    OnceLock::new();

fn shared_connections() -> &'static Mutex<HashMap<String, Vec<MdsConnection>>> {
    SHARED_CONNECTIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn connection_key(host: &str, port: u16) -> String {
    if host.contains(':') { host.to_string() } else { format!("{}:{}", host, port) }
}

/// Borrow a reusable connection without holding the pool lock during network
/// I/O. Worker threads return healthy sockets to the process-wide pool so a
/// rapid shot change can reuse them even after the original worker exits.
pub fn with_reusable_connection<F, R>(
    host: &str,
    port: u16,
    tree: &str,
    shot: &str,
    operation: F,
) -> Result<R, String>
where
    F: FnOnce(&mut MdsConnection) -> (R, bool),
{
    let key = connection_key(host, port);
    let mut connection = shared_connections()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .get_mut(&key)
        .and_then(Vec::pop)
        .map_or_else(|| MdsConnection::connect(host, port), Ok)?;

    if connection.open_tree(tree, shot).is_err() {
        connection = MdsConnection::connect(host, port)?;
        connection.open_tree(tree, shot)?;
    }

    let (result, reusable) = operation(&mut connection);
    if reusable {
        let mut pool = shared_connections()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let idle = pool.entry(key).or_default();
        if idle.len() < MAX_IDLE_CONNECTIONS_PER_SERVER {
            idle.push(connection);
        }
    }
    Ok(result)
}

/// Establish one process-wide reusable socket without opening a tree.
pub fn warm_reusable_connection(host: &str, port: u16) -> Result<(), String> {
    with_reusable_connection(host, port, "", "", |_| ((), true))
}

/// Number of currently idle process-wide sockets for a server.
pub fn reusable_connection_count(host: &str, port: u16) -> usize {
    let key = connection_key(host, port);
    shared_connections()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .get(&key)
        .map_or(0, Vec::len)
}

/// Grow the reusable pool without borrowing an existing connection.
pub fn ensure_reusable_connections(host: &str, port: u16, target: usize) {
    let target = target.min(MAX_IDLE_CONNECTIONS_PER_SERVER);
    let missing = target.saturating_sub(reusable_connection_count(host, port));
    let mut handles = Vec::with_capacity(missing);
    for _ in 0..missing {
        let host = host.to_string();
        handles.push(std::thread::spawn(move || {
            MdsConnection::connect(&host, port).ok()
        }));
    }
    for handle in handles {
        let Ok(Some(connection)) = handle.join() else { continue };
        let key = connection_key(host, port);
        let mut pool = shared_connections()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let idle = pool.entry(key).or_default();
        if idle.len() < target {
            idle.push(connection);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    #[test]
    fn connection_setup_limit_is_enforced_per_server() {
        let key = "test-setup-limit:8000".to_string();
        let mut permits = Vec::new();
        for _ in 0..MAX_CONCURRENT_SETUPS_PER_SERVER {
            permits.push(ConnectionSetupPermit::acquire(key.clone()).unwrap());
        }

        let (acquired_tx, acquired_rx) = mpsc::channel();
        let waiter = std::thread::spawn(move || {
            let permit = ConnectionSetupPermit::acquire(key).unwrap();
            acquired_tx.send(()).unwrap();
            permit
        });

        assert!(acquired_rx.recv_timeout(Duration::from_millis(75)).is_err());
        permits.pop();
        acquired_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        drop(permits);
        drop(waiter.join().unwrap());
    }

    #[test]
    fn canceled_setup_does_not_enter_the_queue() {
        let cancel = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true));
        protocol::with_cancel_context(cancel, false, || {
            assert_eq!(
                ConnectionSetupPermit::acquire("test-canceled-setup:8000".to_string())
                    .err()
                    .as_deref(),
                Some("operation canceled")
            );
        });
    }
}
