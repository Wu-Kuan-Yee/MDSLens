// SPDX-FileCopyrightText: 2026 MdsScope Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! C FFI exports for dart:ffi. All functions use JSON strings.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use crate::api as a;

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

// ── Auth ─────────────────────────────────────────────────────────────

#[no_mangle]
pub extern "C" fn mds_request_login(api_url: *const c_char, user: *const c_char, pass: *const c_char) -> *mut c_char {
    let rt = tokio::runtime::Runtime::new().unwrap();
    match rt.block_on(a::request_login(to_rust(api_url), to_rust(user), to_rust(pass))) {
        Ok(token) => ffi_string!(format!("{{\"ok\":true,\"token\":\"{}\"}}", token)),
        Err(e) => ffi_string!(format!("{{\"error\":\"{}\"}}", e)),
    }
}

#[no_mangle]
pub extern "C" fn mds_fetch_shot(api_url: *const c_char, token: *const c_char) -> *mut c_char {
    let rt = tokio::runtime::Runtime::new().unwrap();
    match rt.block_on(a::fetch_shot(to_rust(api_url), to_rust(token))) {
        Ok(info) => ffi_string!(serde_json::to_string(&info).unwrap_or_default()),
        Err(e) => ffi_string!(format!("{{\"error\":\"{}\"}}", e)),
    }
}

#[no_mangle]
pub extern "C" fn mds_ssh_test(settings_json: *const c_char) -> *mut c_char {
    let settings: a::FrbSshSettings = serde_json::from_str(&to_rust(settings_json)).unwrap_or_default();
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
pub extern "C" fn mds_prepare_url(url: *const c_char, settings_json: *const c_char) -> *mut c_char {
    let settings: a::FrbSshSettings = serde_json::from_str(&to_rust(settings_json)).unwrap_or_default();
    let mut mgr = mds_ssh::tunnel::SshTunnelManager::new();
    mgr.reload_settings(settings.into_rust());
    match mgr.prepare_url(&to_rust(url)) {
        Ok(tunneled) => ffi_string!(tunneled),
        Err(e) => ffi_string!(format!("{{\"error\":\"{}\"}}", e)),
    }
}

#[no_mangle]
pub extern "C" fn mds_free_string(ptr: *mut c_char) {
    unsafe { free_string(ptr); }
}
