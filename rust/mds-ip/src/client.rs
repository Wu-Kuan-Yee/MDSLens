// SPDX-FileCopyrightText: 2026 MdsScope Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! MDSIP TCP connection management with thread-local connection caching.
//!
//! Ported from `src/mds/mds_ip_client.cpp`.

use crate::protocol;
use std::collections::HashMap;
use std::net::TcpStream;
use std::time::Duration;

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
        // If host already contains a port (SSH tunnel rewrites IP to "127.0.0.1:PORT"),
        // use it as-is. Otherwise append the MDS port.
        let addr = if host.contains(':') { host.to_string() }
                   else { format!("{}:{}", host, port) };
        let stream = TcpStream::connect_timeout(
            &addr.parse().map_err(|e| format!("invalid address {}: {}", addr, e))?,
            Duration::from_millis(protocol::NETWORK_TIMEOUT_MS),
        )
        .map_err(|e| format!("connect to {}: {}", addr, e))?;

        stream
            .set_read_timeout(Some(Duration::from_millis(protocol::NETWORK_TIMEOUT_MS)))
            .map_err(|e| format!("set_read_timeout: {}", e))?;

        let mut conn = Self {
            stream,
            host: host.to_string(),
            port,
            current_tree: String::new(),
            current_shot: String::new(),
        };

        protocol::handshake(&mut conn.stream)?;
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
        match protocol::value(&mut self.stream, &expr) {
            Ok(_) => {}
            Err(_e) => {
                // Fallback: try JavaOpen for EAST servers
                let fallback = format!("JavaOpen(\"{}\", {})", tree, shot);
                protocol::value(&mut self.stream, &fallback)?;
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
