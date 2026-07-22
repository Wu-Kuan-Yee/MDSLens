// SPDX-FileCopyrightText: 2026 MdsScope Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! SSH tunnel manager: local TCP port forwarding through SSH.
//!
//! Ported from `src/ssh/ssh_tunnel_manager.cpp`.

use crate::settings::SshSettings;
use mds_core::types::{LayoutConfig, SshMode};
use std::collections::HashMap;
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

const MDS_PORT: u16 = 8000;
const PROBE_TIMEOUT_MS: u64 = 450;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TunnelState { Unconfigured, Ready, Connecting, Connected, Error }

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthMethod { PublicKey, Agent, Password, KeyboardInteractive }

struct Tunnel {
    local_port: u16,
    cancel: Arc<AtomicBool>,
}

impl Tunnel {
    fn cancel(&self) { self.cancel.store(true, Ordering::Relaxed); }
}

pub struct SshTunnelManager {
    settings: SshSettings,
    state: TunnelState,
    last_error: String,
    tunnels: HashMap<String, Tunnel>,
}

impl SshTunnelManager {
    pub fn new() -> Self {
        Self { settings: SshSettings::default(), state: TunnelState::Unconfigured, last_error: String::new(), tunnels: HashMap::new() }
    }

    pub fn state(&self) -> TunnelState { self.state }
    pub fn last_error(&self) -> &str { &self.last_error }
    pub fn settings(&self) -> &SshSettings { &self.settings }

    pub fn reload_settings(&mut self, settings: SshSettings) {
        let was_cfg = matches!(self.settings.mode, SshMode::Auto | SshMode::Always);
        let is_cfg = matches!(settings.mode, SshMode::Auto | SshMode::Always) && !settings.host.is_empty();
        self.settings = settings;
        if matches!(self.state, TunnelState::Unconfigured | TunnelState::Error) && is_cfg {
            self.state = TunnelState::Ready;
        } else if !is_cfg && was_cfg {
            self.disconnect_all();
            self.state = TunnelState::Unconfigured;
        }
    }

    pub fn test_connection(&self, settings: &SshSettings) -> Result<(), String> {
        self.test_connection_impl(settings)
    }

    #[cfg(feature = "libssh2")]
    fn test_connection_impl(&self, settings: &SshSettings) -> Result<(), String> {
        let addr = resolve_host(&settings.host, settings.port)?;
        let tcp = TcpStream::connect_timeout(&addr, Duration::from_secs(8))
            .map_err(|e| format!("TCP connect: {}", e))?;
        let mut session = ssh2::Session::new().map_err(|e| format!("ssh2: {}", e))?;
        session.set_tcp_stream(tcp);
        session.handshake().map_err(|e| format!("handshake: {}", e))?;
        authenticate(&session, settings)?;
        Ok(())
    }

    #[cfg(not(feature = "libssh2"))]
    fn test_connection_impl(&self, _: &SshSettings) -> Result<(), String> {
        Err("SSH not supported (compile with libssh2 feature)".into())
    }

    pub fn ensure_tunnel(&mut self, endpoint: &str) -> Result<String, String> {
        if let Some(t) = self.tunnels.get(endpoint) {
            return Ok(format!("127.0.0.1:{}", t.local_port));
        }
        let (host, port) = split_endpoint(endpoint);
        if matches!(self.settings.mode, SshMode::Auto) && tcp_reachable(&host, port, PROBE_TIMEOUT_MS) {
            return Ok(format!("{}:{}", host, port));
        }
        if self.settings.host.is_empty() { return Err("SSH host not configured".into()); }
        let local_port = reserve_local_port()?;
        let local_addr = format!("127.0.0.1:{}", local_port);
        self.state = TunnelState::Connecting;
        self.create_tunnel_impl(endpoint, &host, port, local_port, &local_addr)?;
        self.state = TunnelState::Connected;
        Ok(local_addr)
    }

    #[cfg(feature = "libssh2")]
    fn create_tunnel_impl(&mut self, endpoint: &str, _host: &str, _remote_port: u16, local_port: u16, local_addr: &str) -> Result<(), String> {
        let addr = resolve_host(&self.settings.host, self.settings.port)?;
        let tcp = TcpStream::connect_timeout(&addr, Duration::from_secs(8))
            .map_err(|e| format!("TCP connect: {}", e))?;
        let mut session = ssh2::Session::new().map_err(|e| format!("ssh2: {}", e))?;
        session.set_tcp_stream(tcp);
        session.handshake().map_err(|e| format!("handshake: {}", e))?;
        authenticate(&session, &self.settings)?;

        let listener = TcpListener::bind(local_addr)
            .map_err(|e| format!("bind {}: {}", local_addr, e))?;
        listener.set_nonblocking(true).ok();

        let cancel = Arc::new(AtomicBool::new(false));
        let rh = _host.to_string();
        let rp = _remote_port;
        let cc = cancel.clone();

        // Spawn relay: accept local → create fresh SSH session per connection → direct-tcpip → relay
        let ssh_host = self.settings.host.clone();
        let ssh_port = self.settings.port;
        let ssh_user = self.settings.user.clone();
        let ssh_pass = self.settings.password.clone();
        let ssh_key = self.settings.identity_file.clone();
        std::thread::spawn(move || {
            loop {
                if cc.load(Ordering::Relaxed) { break; }
                match listener.accept() {
                    Ok((local, _)) => {
                        local.set_nonblocking(false).ok();
                        let s = SshSettings {
                            mode: mds_core::types::SshMode::Always,
                            host: ssh_host.clone(), port: ssh_port,
                            user: ssh_user.clone(), password: ssh_pass.clone(),
                            identity_file: ssh_key.clone(),
                        };
                        let rh2 = rh.clone();
                        relay_via_ssh(local, &s, &rh2, rp);
                        // If relay failed, local would be dropped causing RST.
                        // This line is only reached if relay_via_ssh returned Ok.
                    }
                    Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock
                               || e.kind() == std::io::ErrorKind::Interrupted => {
                        std::thread::sleep(Duration::from_millis(100));
                    }
                    Err(e) => {
                        // Log error before dying
                        eprintln!("SSH relay accept error: {e} — restarting listener...");
                        // Don't break — retry
                        std::thread::sleep(Duration::from_millis(500));
                    }
                }
            }
        });

        self.tunnels.insert(endpoint.to_string(), Tunnel {
            local_port,
            cancel,
        });
        Ok(())
    }

    #[cfg(not(feature = "libssh2"))]
    fn create_tunnel_impl(&mut self, _: &str, _: &str, _: u16, _: u16, _: &str) -> Result<(), String> {
        Err("SSH not supported".into())
    }

    pub fn prepare_layout(&mut self, config: &mut LayoutConfig) -> Result<bool, String> {
        let mut rewrote = false;
        for col in &mut config.columns {
            for plot in col {
                for sig in &mut plot.signal_specs {
                    if sig.server_ip.is_empty() { continue; }
                    let endpoint = if sig.server_ip.contains(':') { sig.server_ip.clone() }
                                   else { format!("{}:{}", sig.server_ip, MDS_PORT) };
                    let local = self.ensure_tunnel(&endpoint)?;
                    if local.starts_with("127.0.0.1:") && local != endpoint {
                        sig.server_ip = local;
                        rewrote = true;
                    }
                }
            }
        }
        Ok(rewrote)
    }

    pub fn prepare_url(&mut self, url: &str) -> Result<String, String> { prepare_url_impl(self, url, true) }
    pub fn prepare_url_via_ssh(&mut self, url: &str) -> Result<String, String> { prepare_url_impl(self, url, false) }

    pub fn disconnect_all(&mut self) {
        for (_, t) in self.tunnels.drain() { t.cancel(); }
        self.state = match self.settings.mode {
            SshMode::Auto | SshMode::Always => TunnelState::Ready,
            _ => TunnelState::Unconfigured,
        };
    }
}

impl Drop for SshTunnelManager {
    fn drop(&mut self) { for (_, t) in self.tunnels.drain() { t.cancel(); } }
}

// ── Auth ──────────────────────────────────────────────────────────────

#[cfg(feature = "libssh2")]
fn authenticate(session: &ssh2::Session, settings: &SshSettings) -> Result<AuthMethod, String> {
    if !settings.identity_file.is_empty() {
        if session.userauth_pubkey_file(&settings.user, None, std::path::Path::new(&settings.identity_file), None).is_ok() {
            return Ok(AuthMethod::PublicKey);
        }
    }
    if settings.password.is_empty() && settings.identity_file.is_empty() {
        if let Ok(mut agent) = session.agent() {
            if agent.connect().is_ok() && agent.list_identities().is_ok() {
                if let Ok(ids) = agent.identities() {
                    for id in &ids {
                        if agent.userauth(&settings.user, id).is_ok() {
                            return Ok(AuthMethod::Agent);
                        }
                    }
                }
            }
        }
    }
    if !settings.password.is_empty() {
        match session.userauth_password(&settings.user, &settings.password) {
            Ok(()) => return Ok(AuthMethod::Password),
            Err(e) => {
                if try_keyboard_interactive(session, &settings.user, &settings.password) {
                    return Ok(AuthMethod::KeyboardInteractive);
                }
                return Err(format!("auth failed: {}", e));
            }
        }
    }
    Err("no valid authentication method found".into())
}

#[cfg(feature = "libssh2")]
fn try_keyboard_interactive(session: &ssh2::Session, user: &str, password: &str) -> bool {
    struct KbdPrompt { pw: String }
    impl ssh2::KeyboardInteractivePrompt for KbdPrompt {
        fn prompt(&mut self, _: &str, _: &str, prompts: &[ssh2::Prompt<'_>]) -> Vec<String> {
            prompts.iter().map(|_| self.pw.clone()).collect()
        }
    }
    session.userauth_keyboard_interactive(user, &mut KbdPrompt { pw: password.to_string() }).is_ok()
}

// ── Helpers ───────────────────────────────────────────────────────────

fn reserve_local_port() -> Result<u16, String> {
    let listener = TcpListener::bind("127.0.0.1:0").map_err(|e| format!("bind: {}", e))?;
    let port = listener.local_addr().map_err(|e| format!("local_addr: {}", e))?.port();
    drop(listener);
    Ok(port)
}

fn split_endpoint(endpoint: &str) -> (String, u16) {
    if endpoint.starts_with('[') {
        if let Some(idx) = endpoint.find(']') {
            let host = &endpoint[1..idx];
            let port = endpoint.get(idx + 2..).and_then(|s| s.parse().ok()).unwrap_or(MDS_PORT);
            return (host.to_string(), port);
        }
    }
    if let Some(colon) = endpoint.rfind(':') {
        (endpoint[..colon].to_string(), endpoint[colon + 1..].parse().unwrap_or(MDS_PORT))
    } else {
        (endpoint.to_string(), MDS_PORT)
    }
}

fn resolve_host(host: &str, port: u16) -> Result<std::net::SocketAddr, String> {
    use std::net::ToSocketAddrs;
    format!("{}:{}", host, port)
        .to_socket_addrs()
        .map_err(|e| format!("DNS resolve {}:{} — {}", host, port, e))?
        .next()
        .ok_or_else(|| format!("DNS resolve {}:{} — no addresses", host, port))
}

/// Create a fresh SSH session, open direct-tcpip channel, relay data.
#[cfg(feature = "libssh2")]
fn relay_via_ssh(mut local: TcpStream, settings: &SshSettings, remote_host: &str, remote_port: u16) {
    use std::io::Write;
    let addr = match resolve_host(&settings.host, settings.port) { Ok(a) => a, Err(e) => { let _ = write!(local, "HTTP/1.1 502 DNS: {e}\r\n\r\n"); return; } };
    let tcp = match TcpStream::connect_timeout(&addr, Duration::from_secs(8)) { Ok(t) => t, Err(e) => { let _ = write!(local, "HTTP/1.1 502 TCP: {e}\r\n\r\n"); return; } };
    let mut session = match ssh2::Session::new() { Ok(s) => s, Err(e) => { let _ = write!(local, "HTTP/1.1 502 SSH: {e}\r\n\r\n"); return; } };
    session.set_tcp_stream(tcp);
    if let Err(e) = session.handshake() { let _ = write!(local, "HTTP/1.1 502 Handshake: {e}\r\n\r\n"); return; }
    if let Err(e) = authenticate(&session, settings) { let _ = write!(local, "HTTP/1.1 502 Auth: {e}\r\n\r\n"); return; }
    let ch = match session.channel_direct_tcpip(remote_host, remote_port, None) { Ok(c) => c, Err(e) => { let _ = write!(local, "HTTP/1.1 502 Channel: {e}\r\n\r\n"); return; } };
    relay_bidi(local, ch);
}

#[cfg(feature = "libssh2")]
fn relay_bidi(mut local: TcpStream, mut ch: ssh2::Channel) {
    use std::io::{Read, Write};
    local.set_read_timeout(Some(Duration::from_millis(100))).ok();
    local.set_write_timeout(Some(Duration::from_secs(5))).ok();
    let mut buf = [0u8; 16384];
    loop {
        // local → SSH
        match local.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                if ch.write_all(&buf[..n]).is_err() { break; }
            }
            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(_) => break,
        }
        // SSH → local
        match ch.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                if local.write_all(&buf[..n]).is_err() { break; }
            }
            Err(ref e) if e.to_string().contains("EAGAIN") => {}
            Err(_) => break,
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn tcp_reachable(host: &str, port: u16, timeout_ms: u64) -> bool {
    resolve_host(host, port).ok().map_or(false, |addr| {
        TcpStream::connect_timeout(&addr, Duration::from_millis(timeout_ms)).is_ok()
    })
}

fn prepare_url_impl(manager: &mut SshTunnelManager, url: &str, allow_direct: bool) -> Result<String, String> {
    let (scheme, rest) = url.split_once("://").ok_or("invalid URL")?;
    let default_port: u16 = if scheme.eq_ignore_ascii_case("https") { 443 } else { 80 };
    let (host_part, path) = if let Some(idx) = rest.find('/') {
        (&rest[..idx], &rest[idx..])
    } else {
        (rest, "/")
    };
    let (host, port) = split_endpoint(host_part);
    let port = if host_part.contains(':') { port } else { default_port };
    let endpoint = format!("{}:{}", host, port);
    // Skip tunneling for localhost (already tunneled)
    if host == "127.0.0.1" || host == "localhost" {
        return Ok(format!("{}://{}{}", scheme, host_part, path));
    }
    if !allow_direct {
        manager.ensure_tunnel(&endpoint)?;
    }
    let local = manager.ensure_tunnel(&endpoint)?;
    Ok(format!("{}://{}{}", scheme, local, path))
}

// ── Tests ─────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_split_endpoint_simple() { let (h, p) = split_endpoint("x.com:8000"); assert_eq!(h, "x.com"); assert_eq!(p, 8000); }
    #[test]
    fn test_split_endpoint_default() { let (h, p) = split_endpoint("x.com"); assert_eq!(h, "x.com"); assert_eq!(p, 8000); }
    #[test]
    fn test_split_endpoint_ipv6() { let (h, p) = split_endpoint("[::1]:8000"); assert_eq!(h, "::1"); assert_eq!(p, 8000); }
    #[test]
    fn test_reserve_local_port() { assert!(reserve_local_port().unwrap() > 0); }
    #[test]
    fn test_manager_lifecycle() {
        let mut mgr = SshTunnelManager::new();
        assert_eq!(mgr.state(), TunnelState::Unconfigured);
        mgr.reload_settings(SshSettings { mode: SshMode::Auto, host: "x".into(), port: 22, user: "t".into(), ..Default::default() });
        assert_eq!(mgr.state(), TunnelState::Ready);
        mgr.reload_settings(SshSettings { mode: SshMode::Disabled, ..Default::default() });
        assert_eq!(mgr.state(), TunnelState::Unconfigured);
    }
}
