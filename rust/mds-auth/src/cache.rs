// SPDX-FileCopyrightText: 2026 MdsScope Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Encrypted authentication cache.
//!
//! Ported from the XOR stream cipher in `src/core/api_auth.cpp`.
//! Uses SHA-256 key derivation with machine-specific entropy + random salt.

use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
use mds_core::types::CachedAuth;
use ring::rand::{SecureRandom, SystemRandom};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// Get a stable machine identifier for auth key derivation.
/// Ported from C++ `localAuthKey()`:
/// - Windows: COMPUTERNAME | USERNAME
/// - macOS: machineUniqueId | hostname | USER
/// - Linux: /etc/machine-id | USER
/// All platforms append: | <homeDir> | "MdsScope EAST auth cache"
fn machine_id() -> String {
    #[cfg(target_os = "windows")]
    {
        let computer = std::env::var("COMPUTERNAME").unwrap_or_default();
        let user = std::env::var("USERNAME").unwrap_or_default();
        format!("{}|{}", computer, user)
    }
    #[cfg(target_os = "macos")]
    {
        let host = hostname_cmd();
        let user = std::env::var("USER").unwrap_or_default();
        format!("{}|{}|{}", host, host, user)
    }
    #[cfg(target_os = "linux")]
    {
        let machine = std::fs::read_to_string("/etc/machine-id")
            .unwrap_or_default()
            .trim()
            .to_string();
        let user = std::env::var("USER").unwrap_or_default();
        format!("{}|{}", machine, user)
    }
    #[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "linux")))]
    {
        let user = std::env::var("USER").unwrap_or_default();
        format!("unknown|{}", user)
    }
}

fn hostname_cmd() -> String {
    std::process::Command::new("hostname")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "unknown".into())
}

fn home_dir() -> String {
    #[cfg(target_os = "windows")]
    { std::env::var("USERPROFILE").unwrap_or_else(|_| "C:\\Users\\Default".into()) }
    #[cfg(not(target_os = "windows"))]
    { std::env::var("HOME").unwrap_or_else(|_| "/tmp".into()) }
}

/// Auth cache file format (JSON wrapper).
#[derive(Debug, Serialize, Deserialize)]
struct CacheFile {
    version: u32,
    salt: String,
    payload: String,
}

/// Decrypted payload content.
#[derive(Debug, Serialize, Deserialize)]
struct AuthPayload {
    #[serde(rename = "userName", default)]
    user_name: String,
    #[serde(default)]
    password: String,
    #[serde(default)]
    token: String,
    #[serde(default)]
    ssh: SshPayload,
}

#[derive(Debug, Serialize, Deserialize, Default)]
struct SshPayload {
    #[serde(default)]
    mode: String,
    #[serde(default)]
    host: String,
    #[serde(default)]
    port: u16,
    #[serde(default)]
    user: String,
    #[serde(default)]
    password: String,
    #[serde(default)]
    #[serde(rename = "identityFile")]
    identity_file: String,
}

/// Derive a machine-specific encryption key using SHA-256.
/// Matches the C++ `localAuthKey()` derivation.
fn local_auth_key() -> Vec<u8> {
    let entropy = format!(
        "{}|{}|MdsScope EAST auth cache",
        machine_id(),
        home_dir(),
    );
    let mut hasher = Sha256::new();
    hasher.update(entropy.as_bytes());
    hasher.finalize().to_vec()
}

/// XOR encrypt/decrypt payload using keystream derived from key + salt.
fn crypt_auth_payload(data: &[u8], salt: &[u8], key: &[u8]) -> Vec<u8> {
    let mut result = Vec::with_capacity(data.len());
    let mut counter: u64 = 0;

    while result.len() < data.len() {
        let mut hasher = Sha256::new();
        hasher.update(key);
        hasher.update(salt);
        hasher.update(counter.to_le_bytes());
        let keystream = hasher.finalize();

        let remaining = data.len() - result.len();
        let chunk_size = remaining.min(32);
        for i in 0..chunk_size {
            result.push(data[result.len()] ^ keystream[i]);
        }
        counter += 1;
    }

    result
}

/// Load cached authentication from disk.
pub fn load_cached_auth(cache_path: &str) -> Option<CachedAuth> {
    let content = std::fs::read_to_string(cache_path).ok()?;
    let cache_file: CacheFile = serde_json::from_str(&content).ok()?;

    if cache_file.version != 1 {
        return None;
    }

    let salt = BASE64.decode(&cache_file.salt).ok()?;
    let encrypted = BASE64.decode(&cache_file.payload).ok()?;
    let key = local_auth_key();
    let decrypted = crypt_auth_payload(&encrypted, &salt, &key);

    let payload: AuthPayload = serde_json::from_slice(&decrypted).ok()?;

    Some(CachedAuth {
        user_name: payload.user_name,
        password: payload.password,
        token: payload.token,
        ssh: mds_core::types::SshSettings {
            mode: match payload.ssh.mode.as_str() {
                "Always" => mds_core::types::SshMode::Always,
                "Auto" => mds_core::types::SshMode::Auto,
                _ => mds_core::types::SshMode::Disabled,
            },
            host: payload.ssh.host,
            port: if payload.ssh.port == 0 { 22 } else { payload.ssh.port },
            user: payload.ssh.user,
            password: payload.ssh.password,
            identity_file: payload.ssh.identity_file,
        },
    })
}

/// Save authentication data to disk (encrypted).
pub fn save_cached_auth(cache_path: &str, auth: &CachedAuth) -> Result<(), String> {
    let payload = AuthPayload {
        user_name: auth.user_name.clone(),
        password: auth.password.clone(),
        token: auth.token.clone(),
        ssh: SshPayload {
            mode: match auth.ssh.mode {
                mds_core::types::SshMode::Always => "Always".into(),
                mds_core::types::SshMode::Auto => "Auto".into(),
                mds_core::types::SshMode::Disabled => "Disabled".into(),
            },
            host: auth.ssh.host.clone(),
            port: auth.ssh.port,
            user: auth.ssh.user.clone(),
            password: auth.ssh.password.clone(),
            identity_file: auth.ssh.identity_file.clone(),
        },
    };

    let payload_json = serde_json::to_vec(&payload).map_err(|e| e.to_string())?;

    let rng = SystemRandom::new();
    let mut salt = vec![0u8; 16];
    rng.fill(&mut salt).map_err(|e| e.to_string())?;

    let key = local_auth_key();
    let encrypted = crypt_auth_payload(&payload_json, &salt, &key);

    let cache_file = CacheFile {
        version: 1,
        salt: BASE64.encode(&salt),
        payload: BASE64.encode(&encrypted),
    };

    let content = serde_json::to_string_pretty(&cache_file).map_err(|e| e.to_string())?;
    std::fs::write(cache_path, &content).map_err(|e| e.to_string())?;

    // Set file permissions to owner-only (0600)
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(cache_path, std::fs::Permissions::from_mode(0o600)).ok();
    }

    Ok(())
}

/// Check if a JWT token expires soon (within 5 minutes).
pub fn token_expires_soon(token: &str) -> bool {
    let parts: Vec<&str> = token.split('.').collect();
    if parts.len() < 3 {
        return true;
    }

    // Decode JWT payload (second segment)
    let payload_b64 = parts[1]
        .replace('-', "+")
        .replace('_', "/");

    let payload_json = BASE64.decode(payload_b64.as_bytes()).ok();
    let Some(payload_json) = payload_json else {
        return true;
    };

    let payload: serde_json::Value = match serde_json::from_slice(&payload_json) {
        Ok(v) => v,
        Err(_) => return true,
    };

    // Check exp claim
    let exp = payload.get("exp").and_then(|v| v.as_i64()).unwrap_or(0);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;

    // Expires within 300 seconds (5 minutes)
    (exp - now) < 300
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn test_crypt_roundtrip() {
        let key = local_auth_key();
        let data = b"Hello, this is test auth data!";
        let salt = b"0123456789abcdef";

        let encrypted = crypt_auth_payload(data, salt, &key);
        assert_ne!(&encrypted, data);
        assert_eq!(encrypted.len(), data.len());

        let decrypted = crypt_auth_payload(&encrypted, salt, &key);
        assert_eq!(&decrypted, data);
    }

    #[test]
    fn test_crypt_empty() {
        let key = local_auth_key();
        let encrypted = crypt_auth_payload(b"", b"", &key);
        assert!(encrypted.is_empty());
    }

    #[test]
    fn test_crypt_large_payload() {
        let key = local_auth_key();
        let data = vec![0xAAu8; 1024]; // 1KB, spans multiple SHA-256 blocks
        let salt = b"0123456789abcdef";

        let encrypted = crypt_auth_payload(&data, salt, &key);
        let decrypted = crypt_auth_payload(&encrypted, salt, &key);
        assert_eq!(decrypted, data);
    }

    #[test]
    fn test_crypt_different_salts() {
        let key = local_auth_key();
        let data = b"secret";

        let e1 = crypt_auth_payload(data, b"salt1", &key);
        let e2 = crypt_auth_payload(data, b"salt2", &key);
        assert_ne!(e1, e2); // Different salts → different ciphertexts
    }

    #[test]
    fn test_save_load_roundtrip() {
        let tmp = std::env::temp_dir().join("mdsscope_test_auth.cache");

        let auth = CachedAuth {
            user_name: "testuser".into(),
            password: "testpass".into(),
            token: "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjk5OTk5OTk5OTl9.signature".into(),
            ssh: mds_core::types::SshSettings {
                mode: mds_core::types::SshMode::Auto,
                host: "ssh.example.com".into(),
                port: 22,
                user: "sshuser".into(),
                ..Default::default()
            },
        };

        save_cached_auth(tmp.to_str().unwrap(), &auth).unwrap();

        // Verify file exists and has correct structure
        let content = std::fs::read_to_string(&tmp).unwrap();
        let file: CacheFile = serde_json::from_str(&content).unwrap();
        assert_eq!(file.version, 1);
        assert!(!file.salt.is_empty());
        assert!(!file.payload.is_empty());

        // Load back
        let loaded = load_cached_auth(tmp.to_str().unwrap()).unwrap();
        assert_eq!(loaded.user_name, "testuser");
        assert_eq!(loaded.password, "testpass");
        assert_eq!(loaded.token, auth.token);
        assert_eq!(loaded.ssh.host, "ssh.example.com");
        assert!(matches!(loaded.ssh.mode, mds_core::types::SshMode::Auto));

        std::fs::remove_file(&tmp).ok();
    }

    #[test]
    fn test_load_nonexistent() {
        assert!(load_cached_auth("/tmp/mdsscope_nonexistent_cache.json").is_none());
    }

    #[test]
    fn test_token_expires_soon_no_exp() {
        assert!(token_expires_soon("invalid.token.here"));
        assert!(token_expires_soon("a.b.c"));
    }

    #[test]
    fn test_token_expires_soon_already_expired() {
        // JWT with exp in the past (2020)
        let payload = r#"{"exp":1577836800}"#;
        let payload_b64 = BASE64.encode(payload);
        let token = format!("header.{}.sig", payload_b64);
        assert!(token_expires_soon(&token));
    }

    #[test]
    fn test_token_expires_soon_far_future() {
        // JWT with exp far in the future
        let far_future = 9999999999i64;
        let payload = format!(r#"{{"exp":{}}}"#, far_future);
        let payload_b64 = BASE64.encode(payload);
        let token = format!("header.{}.sig", payload_b64);
        assert!(!token_expires_soon(&token));
    }

    #[test]
    fn test_token_expires_soon_within_5min() {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        // Expires in 4 minutes → should be "soon"
        let payload = format!(r#"{{"exp":{}}}"#, now + 240);
        let payload_b64 = BASE64.encode(payload);
        let token = format!("h.{}.s", payload_b64);
        assert!(token_expires_soon(&token));
    }

    #[test]
    fn test_key_is_stable() {
        let k1 = local_auth_key();
        let k2 = local_auth_key();
        assert_eq!(k1, k2); // Key should be deterministic for the same machine
    }

    #[test]
    fn test_crypt_deterministic_decrypt() {
        // Encrypting the same data with the same key and salt should give the same result
        let key = local_auth_key();
        let data = b"test data";
        let salt = b"0123456789abcdef";

        let e1 = crypt_auth_payload(data, salt, &key);
        let e2 = crypt_auth_payload(data, salt, &key);
        assert_eq!(e1, e2);
    }
}
