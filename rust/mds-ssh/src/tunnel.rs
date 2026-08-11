// SPDX-FileCopyrightText: 2026 MDSLens Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! SSH tunnel manager: local TCP port forwarding through SSH.
//!
//! Ported from `src/ssh/ssh_tunnel_manager.cpp`.

use crate::settings::SshSettings;
use mds_core::types::{LayoutConfig, SshMode};
use std::collections::HashMap;
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

const MDS_PORT: u16 = 8000;
const PROBE_TIMEOUT_MS: u64 = 450;
// A cold VPN/overlay peer can need a few seconds before its SSH path becomes
// reachable.  Keep the retry budget bounded and retry only transport-level
// failures; authentication and configuration errors should return promptly.
const SSH_CONNECT_TIMEOUTS_SECS: [u64; 2] = [6, 6];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TunnelState { Unconfigured, Ready, Connecting, Connected, Error }

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthMethod { PublicKey, Agent, Password, KeyboardInteractive }

struct Tunnel {
    local_port: u16,
    cancel: Arc<AtomicBool>,
    active: Arc<AtomicBool>,
}

impl Tunnel {
    fn cancel(&self) { self.cancel.store(true, Ordering::Relaxed); }

    fn is_healthy(&self) -> bool {
        !self.cancel.load(Ordering::Relaxed) && self.active.load(Ordering::Acquire)
    }
}

struct RelayActiveGuard(Arc<AtomicBool>);

impl Drop for RelayActiveGuard {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
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
        let is_configured = matches!(settings.mode, SshMode::Auto | SshMode::Always)
            && !settings.host.is_empty();
        if self.settings != settings {
            self.disconnect_all();
            self.settings = settings;
            self.state = if is_configured {
                TunnelState::Ready
            } else {
                TunnelState::Unconfigured
            };
            return;
        }
        if matches!(self.state, TunnelState::Unconfigured | TunnelState::Error) && is_configured {
            self.state = TunnelState::Ready;
        } else if !is_configured {
            self.state = TunnelState::Unconfigured;
        }
    }

    pub fn test_connection(&self, settings: &SshSettings) -> Result<(), String> {
        self.test_connection_impl(settings)
    }

    #[cfg(feature = "libssh2")]
    fn test_connection_impl(&self, settings: &SshSettings) -> Result<(), String> {
        let mut last_error = String::new();
        for timeout_secs in SSH_CONNECT_TIMEOUTS_SECS {
            match connect_ssh_session(settings, timeout_secs)
                .and_then(|session| authenticate(&session, settings).map(|_| ()))
            {
                Ok(()) => return Ok(()),
                Err(error) => {
                    last_error = error;
                    if !is_transient_ssh_error(&last_error) {
                        break;
                    }
                }
            }
        }
        Err(if last_error.is_empty() {
            "SSH connection failed".into()
        } else {
            last_error
        })
    }

    #[cfg(not(feature = "libssh2"))]
    fn test_connection_impl(&self, _: &SshSettings) -> Result<(), String> {
        Err("SSH not supported (compile with libssh2 feature)".into())
    }

    pub fn ensure_tunnel(&mut self, endpoint: &str) -> Result<String, String> {
        if let Some(t) = self.tunnels.get(endpoint) {
            if t.is_healthy() {
                return Ok(format!("127.0.0.1:{}", t.local_port));
            }
        }
        if let Some(stale) = self.tunnels.remove(endpoint) {
            stale.cancel();
            self.state = TunnelState::Ready;
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
        let mut last_error = String::new();
        for timeout_secs in SSH_CONNECT_TIMEOUTS_SECS {
            match self.create_tunnel_attempt(
                endpoint,
                _host,
                _remote_port,
                local_port,
                local_addr,
                timeout_secs,
            ) {
                Ok(()) => return Ok(()),
                Err(error) => {
                    last_error = error;
                    if !is_transient_ssh_error(&last_error) {
                        break;
                    }
                }
            }
        }
        Err(if last_error.is_empty() {
            "SSH tunnel setup failed".into()
        } else {
            last_error
        })
    }

    #[cfg(feature = "libssh2")]
    fn create_tunnel_attempt(
        &mut self,
        endpoint: &str,
        remote_host: &str,
        remote_port: u16,
        local_port: u16,
        local_addr: &str,
        timeout_secs: u64,
    ) -> Result<(), String> {
        let session = connect_ssh_session(&self.settings, timeout_secs)?;
        authenticate(&session, &self.settings)?;

        let listener = TcpListener::bind(local_addr)
            .map_err(|e| format!("bind {}: {}", local_addr, e))?;
        listener.set_nonblocking(true).ok();

        let cancel = Arc::new(AtomicBool::new(false));
        let active = Arc::new(AtomicBool::new(true));
        let rh = remote_host.to_string();
        let rp = remote_port;
        let cc = cancel.clone();
        let relay_active = active.clone();

        // Spawn relay: accept local → create fresh SSH session per connection → direct-tcpip → relay
        let ssh_host = self.settings.host.clone();
        let ssh_port = self.settings.port;
        let ssh_user = self.settings.user.clone();
        let ssh_pass = self.settings.password.clone();
        let ssh_key = self.settings.identity_file.clone();
        std::thread::spawn(move || {
            let _active_guard = RelayActiveGuard(relay_active);
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
                        // MDSIP sockets remain open for reuse. Relay each one
                        // independently so it cannot block later accepts.
                        std::thread::spawn(move || {
                            relay_via_ssh(local, &s, &rh2, rp);
                        });
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
            active,
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
fn connect_ssh_session(
    settings: &SshSettings,
    timeout_secs: u64,
) -> Result<ssh2::Session, String> {
    let addr = resolve_host(&settings.host, settings.port)?;
    let timeout = Duration::from_secs(timeout_secs);
    let tcp = TcpStream::connect_timeout(&addr, timeout)
        .map_err(|e| format!("TCP connect: {}", e))?;
    tcp.set_read_timeout(Some(timeout))
        .map_err(|e| format!("TCP read timeout: {}", e))?;
    tcp.set_write_timeout(Some(timeout))
        .map_err(|e| format!("TCP write timeout: {}", e))?;
    let mut session = ssh2::Session::new().map_err(|e| format!("ssh2: {}", e))?;
    session.set_tcp_stream(tcp);
    session.set_timeout(timeout.as_millis().min(u32::MAX as u128) as u32);
    session
        .handshake()
        .map_err(|e| format!("handshake: {}", e))?;
    Ok(session)
}

fn is_transient_ssh_error(message: &str) -> bool {
    let lower = message.to_ascii_lowercase();
    [
        "connection timed out",
        "operation timed out",
        "timed out",
        "connection refused",
        "connection reset",
        "connection closed",
        "no route to host",
        "network is unreachable",
        "temporary failure in name resolution",
        "name or service not known",
        "kex_exchange_identification",
        "banner exchange",
    ]
    .iter()
    .any(|marker| lower.contains(marker))
}

#[cfg(feature = "libssh2")]
fn authenticate(session: &ssh2::Session, settings: &SshSettings) -> Result<AuthMethod, String> {
    let identity_supplied = !settings.identity_file.trim().is_empty();
    let mut identity_error = None;
    if identity_supplied {
        match resolve_identity_file(&settings.identity_file) {
            Ok(Some(identity_file)) => {
                match session.userauth_pubkey_file(&settings.user, None, &identity_file, None) {
                    Ok(()) => return Ok(AuthMethod::PublicKey),
                    Err(e) => {
                        identity_error = Some(format!(
                            "public-key authentication failed using '{}': {}",
                            identity_file.display(),
                            e
                        ));
                    }
                }
            }
            Ok(None) => {}
            Err(e) => identity_error = Some(e),
        }
    }
    if settings.password.is_empty() && !identity_supplied {
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
                return Err(match identity_error {
                    Some(key_error) => format!("{}; password authentication failed: {}", key_error, e),
                    None => format!("password authentication failed: {}", e),
                });
            }
        }
    }
    Err(identity_error.unwrap_or_else(|| "no valid authentication method found".into()))
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

fn resolve_identity_file(input: &str) -> Result<Option<PathBuf>, String> {
    if input.trim().is_empty() {
        return Ok(None);
    }
    let home = home_directory();
    let expanded = expand_identity_path_with(input, home.as_deref(), &|name| {
        std::env::var(name).ok()
    });
    let absolute = if expanded.is_absolute() {
        expanded
    } else {
        std::env::current_dir()
            .map_err(|e| format!("cannot resolve relative identity file '{}': {}", input.trim(), e))?
            .join(expanded)
    };
    let metadata = std::fs::metadata(&absolute).map_err(|e| {
        format!(
            "identity file '{}' was not found or is inaccessible (resolved to '{}'): {}",
            input.trim(),
            absolute.display(),
            e
        )
    })?;
    if !metadata.is_file() {
        return Err(format!(
            "identity file '{}' resolves to a directory, not a file: '{}'",
            input.trim(),
            absolute.display()
        ));
    }
    Ok(Some(absolute.canonicalize().unwrap_or(absolute)))
}

fn home_directory() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("USERPROFILE")
                .filter(|value| !value.is_empty())
                .map(PathBuf::from)
        })
        .or_else(|| {
            let drive = std::env::var_os("HOMEDRIVE")?;
            let path = std::env::var_os("HOMEPATH")?;
            if drive.is_empty() || path.is_empty() {
                return None;
            }
            let mut value = drive;
            value.push(path);
            Some(PathBuf::from(value))
        })
}

fn expand_identity_path_with<F>(input: &str, home: Option<&Path>, lookup: &F) -> PathBuf
where
    F: Fn(&str) -> Option<String>,
{
    let trimmed = input.trim();
    let unquoted = if trimmed.len() >= 2
        && ((trimmed.starts_with('"') && trimmed.ends_with('"'))
            || (trimmed.starts_with('\'') && trimmed.ends_with('\'')))
    {
        &trimmed[1..trimmed.len() - 1]
    } else {
        trimmed
    };
    let expanded = expand_environment_variables_with(unquoted, lookup);
    if let Some(home) = home {
        if expanded == "~" {
            return home.to_path_buf();
        }
        if let Some(rest) = expanded
            .strip_prefix("~/")
            .or_else(|| expanded.strip_prefix("~\\"))
        {
            return home.join(rest);
        }
    }
    PathBuf::from(expanded)
}

fn expand_environment_variables_with<F>(input: &str, lookup: &F) -> String
where
    F: Fn(&str) -> Option<String>,
{
    let chars: Vec<char> = input.chars().collect();
    let mut output = String::with_capacity(input.len());
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '$' {
            if i + 1 < chars.len() && chars[i + 1] == '{' {
                if let Some(end) = (i + 2..chars.len()).find(|&j| chars[j] == '}') {
                    let name: String = chars[i + 2..end].iter().collect();
                    if let Some(value) = lookup(&name) {
                        output.push_str(&value);
                    } else {
                        output.extend(chars[i..=end].iter());
                    }
                    i = end + 1;
                    continue;
                }
            } else {
                let end = (i + 1..chars.len())
                    .find(|&j| !(chars[j].is_ascii_alphanumeric() || chars[j] == '_'))
                    .unwrap_or(chars.len());
                if end > i + 1 {
                    let name: String = chars[i + 1..end].iter().collect();
                    if let Some(value) = lookup(&name) {
                        output.push_str(&value);
                    } else {
                        output.extend(chars[i..end].iter());
                    }
                    i = end;
                    continue;
                }
            }
        } else if chars[i] == '%' {
            if let Some(end) = (i + 1..chars.len()).find(|&j| chars[j] == '%') {
                let name: String = chars[i + 1..end].iter().collect();
                if !name.is_empty() {
                    if let Some(value) = lookup(&name) {
                        output.push_str(&value);
                    } else {
                        output.extend(chars[i..=end].iter());
                    }
                    i = end + 1;
                    continue;
                }
            }
        }
        output.push(chars[i]);
        i += 1;
    }
    output
}

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

    #[test]
    fn test_manager_reconfigures_without_retaining_old_state() {
        let mut mgr = SshTunnelManager::new();
        mgr.reload_settings(SshSettings {
            mode: SshMode::Always,
            host: "first".into(),
            user: "one".into(),
            ..Default::default()
        });
        mgr.state = TunnelState::Connected;
        mgr.reload_settings(SshSettings {
            mode: SshMode::Always,
            host: "second".into(),
            user: "two".into(),
            ..Default::default()
        });
        assert_eq!(mgr.state(), TunnelState::Ready);
        assert_eq!(mgr.settings().host, "second");
    }

    #[test]
    fn stale_cached_tunnel_is_not_reused() {
        let mut mgr = SshTunnelManager::new();
        mgr.tunnels.insert(
            "internal.example:80".into(),
            Tunnel {
                local_port: 12345,
                cancel: Arc::new(AtomicBool::new(false)),
                active: Arc::new(AtomicBool::new(false)),
            },
        );

        let error = mgr.ensure_tunnel("internal.example:80").unwrap_err();
        assert_eq!(error, "SSH host not configured");
        assert!(!mgr.tunnels.contains_key("internal.example:80"));
    }

    #[test]
    fn identity_path_expands_tilde_quotes_and_environment_variables() {
        let home = Path::new("/home/test user");
        let path = expand_identity_path_with(
            r#""~/.ssh/id ed25519""#,
            Some(home),
            &|_| None,
        );
        assert_eq!(path, home.join(".ssh/id ed25519"));

        let path = expand_identity_path_with(
            "${KEY_ROOT}/id_rsa",
            None,
            &|name| (name == "KEY_ROOT").then(|| "/keys".to_string()),
        );
        assert_eq!(path, PathBuf::from("/keys/id_rsa"));

        let path = expand_identity_path_with(
            "%KEY_ROOT%/id_rsa",
            None,
            &|name| (name == "KEY_ROOT").then(|| "/portable-keys".to_string()),
        );
        assert_eq!(path, PathBuf::from("/portable-keys/id_rsa"));
    }

    #[test]
    fn invalid_identity_path_returns_the_resolved_path() {
        let error = resolve_identity_file("./definitely-missing-mdslens-key")
            .expect_err("missing identity file must be rejected");
        assert!(error.contains("not found or is inaccessible"));
        assert!(error.contains("definitely-missing-mdslens-key"));
    }

    #[test]
    fn transient_ssh_failures_are_retryable_but_auth_failures_are_not() {
        for error in [
            "TCP connect: connection timed out",
            "handshake: connection reset by peer",
            "SSH connection closed",
            "DNS resolve host — temporary failure in name resolution",
        ] {
            assert!(is_transient_ssh_error(error), "{error}");
        }
        assert!(!is_transient_ssh_error("public-key authentication failed"));
        assert!(!is_transient_ssh_error("no valid authentication method found"));
        assert_eq!(SSH_CONNECT_TIMEOUTS_SECS, [6, 6]);
    }
}
