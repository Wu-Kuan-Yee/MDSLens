// SPDX-FileCopyrightText: 2026 MdsScope Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! C FFI exports for dart:ffi. All functions use JSON strings.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::{Mutex, OnceLock};

use crate::api as a;

static API_TUNNEL_MANAGER: OnceLock<Mutex<mds_ssh::tunnel::SshTunnelManager>> = OnceLock::new();
const MDS_BRIDGE_ABI_VERSION: u32 = 2;

macro_rules! ffi_string {
    ($s:expr) => { CString::new($s).unwrap_or_default().into_raw() };
}

fn to_rust(ptr: *const c_char) -> String {
    unsafe { CStr::from_ptr(ptr).to_string_lossy().into_owned() }
}

unsafe fn free_string(ptr: *mut c_char) {
    if !ptr.is_null() { let _ = CString::from_raw(ptr); }
}

// ── Environment I/O ──────────────────────────────────────────────────

/// Increment whenever Dart and the native bridge make an incompatible ABI
/// change. The Flutter loader rejects stale libraries before resolving the
/// individual function table.
#[no_mangle]
pub extern "C" fn mds_bridge_abi_version() -> u32 {
    MDS_BRIDGE_ABI_VERSION
}

#[no_mangle]
pub extern "C" fn mds_git_version() -> *mut c_char {
    ffi_string!(env!("MDS_SCOPE_GIT_VERSION"))
}

#[no_mangle]
pub extern "C" fn mds_parse_environment(path: *const c_char) -> *mut c_char {
    let path = to_rust(path);
    let config = a::parse_environment(path);
    ffi_string!(serde_json::to_string(&config).unwrap_or_default())
}

#[no_mangle]
pub extern "C" fn mds_write_environment(config_json: *const c_char, path: *const c_char) -> *mut c_char {
    let config: a::FrbLayoutConfig = serde_json::from_str(&to_rust(config_json)).unwrap_or_default();
    match a::write_environment(config, to_rust(path)) {
        Ok(()) => ffi_string!("{\"ok\":true}"),
        Err(e) => ffi_string!(format!("{{\"error\":\"{}\"}}", e)),
    }
}

#[no_mangle]
pub extern "C" fn mds_encode_environment(config_json: *const c_char) -> *mut c_char {
    let config: a::FrbLayoutConfig = serde_json::from_str(&to_rust(config_json)).unwrap_or_default();
    ffi_string!(a::encode_environment(config))
}

// ── Auth ─────────────────────────────────────────────────────────────

#[no_mangle]
pub extern "C" fn mds_request_login(api_url: *const c_char, user: *const c_char, pass: *const c_char) -> *mut c_char {
    match a::request_login(to_rust(api_url), to_rust(user), to_rust(pass)) {
        Ok(token) => ffi_string!(serde_json::json!({"ok": true, "token": token}).to_string()),
        Err(e) => ffi_string!(serde_json::json!({"error": e}).to_string()),
    }
}

#[no_mangle]
pub extern "C" fn mds_fetch_shot(api_url: *const c_char, token: *const c_char) -> *mut c_char {
    match a::fetch_shot(to_rust(api_url), to_rust(token)) {
        Ok(info) => ffi_string!(serde_json::to_string(&info).unwrap_or_default()),
        Err(e) => ffi_string!(serde_json::json!({"error": e}).to_string()),
    }
}

#[no_mangle]
pub extern "C" fn mds_fetch_shot_info(api_url: *const c_char, token: *const c_char, shot: *const c_char) -> *mut c_char {
    match a::fetch_shot_info(to_rust(api_url), to_rust(token), to_rust(shot)) {
        Ok(info) => ffi_string!(serde_json::to_string(&info).unwrap_or_default()),
        Err(e) => ffi_string!(format!("{{\"error\":\"{}\"}}", e)),
    }
}

#[no_mangle]
pub extern "C" fn mds_ssh_test(settings_json: *const c_char) -> *mut c_char {
    let settings: a::FrbSshSettings = match serde_json::from_str(&to_rust(settings_json)) {
        Ok(s) => s,
        Err(e) => return ffi_string!(format!("{{\"error\":\"JSON: {}\"}}", e)),
    };
    match a::ssh_test(settings) {
        Ok(()) => ffi_string!("{\"ok\":true}"),
        Err(e) => ffi_string!(format!("{{\"error\":\"{}\"}}", e)),
    }
}

#[no_mangle]
pub extern "C" fn mds_fetch_signals(config_json: *const c_char, mode_json: *const c_char) -> *mut c_char {
    let mode: i32 = to_rust(mode_json).parse().unwrap_or(0);
    let results = a::fetch_signals(to_rust(config_json), mode);
    ffi_string!(serde_json::to_string(&results).unwrap_or_default())
}

#[no_mangle]
pub extern "C" fn mds_fetch_signals_ssh(config_json: *const c_char, mode_json: *const c_char, ssh_settings_json: *const c_char) -> *mut c_char {
    let mode: i32 = to_rust(mode_json).parse().unwrap_or(0);
    let results = a::fetch_signals_ssh(to_rust(config_json), mode, to_rust(ssh_settings_json));
    ffi_string!(serde_json::to_string(&results).unwrap_or_default())
}

#[no_mangle]
pub extern "C" fn mds_cancel_fetch(request_id: u64) -> u8 {
    u8::from(a::cancel_fetch(request_id))
}

#[no_mangle]
pub extern "C" fn mds_prepare_url(url: *const c_char, settings_json: *const c_char) -> *mut c_char {
    let settings_json = to_rust(settings_json);
    let settings: a::FrbSshSettings = match serde_json::from_str(&settings_json) {
        Ok(s) => s,
        Err(e) => return ffi_string!(format!("{{\"error\":\"JSON parse: {} — {}\"}}", e, settings_json)),
    };
    if settings.host.is_empty() {
        return ffi_string!("{\"error\":\"SSH host is empty\"}");
    }
    let manager = API_TUNNEL_MANAGER.get_or_init(|| {
        Mutex::new(mds_ssh::tunnel::SshTunnelManager::new())
    });
    let mut manager = manager.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    manager.reload_settings(settings.into_rust());
    let result = match manager.prepare_url(&to_rust(url)) {
        Ok(tunneled) => tunneled,
        Err(e) => format!("{{\"error\":\"{}\"}}", e),
    };
    ffi_string!(result)
}

#[no_mangle]
pub extern "C" fn mds_free_string(ptr: *mut c_char) {
    unsafe { free_string(ptr); }
}
