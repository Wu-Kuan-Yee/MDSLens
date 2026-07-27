// SPDX-FileCopyrightText: 2026 MDSLens Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;

pub struct ShotInfo {
    pub shot: i32,
    pub ip: String, pub pulse: String, pub it: String, pub time: String,
}

pub fn request_api_token(api_url: &str, user_name: &str, password: &str) -> Result<String, String> {
    let url = format!("{}/login", api_url.trim_end_matches('/'));
    let body = serde_json::json!({ "userName": user_name, "password": password }).to_string();
    let resp = http_post_json(&url, &body, None)?;
    if resp_ok(&resp) {
        resp.get("data").and_then(|d| d.get("token")).and_then(|t| t.as_str())
            .filter(|t| !t.is_empty()).map(|t| t.to_string()).ok_or_else(|| "no token".into())
    } else {
        Err(resp.get("msg").and_then(|m| m.as_str()).unwrap_or("unknown").into())
    }
}

pub fn fetch_latest_shot(api_url: &str, token: &str) -> Result<ShotInfo, String> {
    let url = format!("{}/treeShot", api_url.trim_end_matches('/'));
    let resp = http_post_json(&url, "{}", Some(token))?;
    if !resp_ok(&resp) { return Err(resp.get("msg").and_then(|m| m.as_str()).unwrap_or("unknown").into()); }
    let data = resp.get("data").ok_or("no data")?;
    let shot = data.get("shot").and_then(|s| s.as_i64())
        .or_else(|| find_shot(data)).ok_or("no shot")? as i32;
    Ok(ShotInfo {
        shot,
        ip: data.get("ip").and_then(|v| v.as_str()).unwrap_or("").into(),
        pulse: data.get("pulseLength").and_then(|v| v.as_f64()).map(|v| format!("{:.3}s", v)).unwrap_or_default(),
        it: data.get("it").and_then(|v| v.as_f64()).map(|v| format!("{:.0}kA", v)).unwrap_or_default(),
        time: data.get("currentTime").and_then(|v| v.as_str()).unwrap_or("").into(),
    })
}

/// Fetch shot summary info (Ip, Pulse, It, Time) for a specific shot.
/// Calls /pcsEastTree with {shot: shot} — matching C++ scheduleTopInfoUpdate.
pub fn fetch_shot_info(api_url: &str, token: &str, shot: &str) -> Result<ShotInfo, String> {
    let url = format!("{}/pcsEastTree", api_url.trim_end_matches('/'));
    let body = format!(r#"{{"treeshot":{}}}"#, shot);
    let resp = http_post_json(&url, &body, Some(token))?;
    if !resp_ok(&resp) { return Err(resp.get("msg").and_then(|m| m.as_str()).unwrap_or("unknown").into()); }
    let data = resp.get("data").ok_or("no data")?;
    Ok(ShotInfo {
        shot: shot.parse().unwrap_or(0),
        ip: data.get("pcrl01").and_then(|v| v.as_f64().map(|n| n.to_string()).or_else(|| v.as_str().map(|s| s.to_string()))).unwrap_or_default(),
        pulse: data.get("shot_len").and_then(|v| v.as_f64()).map(|v| format!("{:.3}", v)).unwrap_or_default(),
        it: data.get("iv").and_then(|v| v.as_f64()).map(|v| format!("{:.0}", v)).unwrap_or_default(),
        time: data.get("curr_time").and_then(|v| v.as_str()).unwrap_or("").into(),
    })
}

fn find_shot(v: &serde_json::Value) -> Option<i64> {
    match v {
        serde_json::Value::Number(n) => n.as_i64().filter(|&x| x >= 1000 && x <= 99999999),
        serde_json::Value::String(s) => s.parse().ok().filter(|&x: &i64| x >= 1000 && x <= 99999999),
        serde_json::Value::Array(a) => a.iter().find_map(find_shot),
        serde_json::Value::Object(o) => {
            for k in &["shot","shotNo","treeShot"] { if let Some(s) = o.get(*k).and_then(find_shot) { return Some(s); } }
            o.values().find_map(find_shot)
        }
        _ => None,
    }
}

// ── HTTP helpers ─────────────────────────────────────────────────────

fn resp_ok(r: &serde_json::Value) -> bool {
    r.get("code").map_or(false, |c| c.as_str() == Some("20000") || c.as_i64() == Some(20000))
}

fn http_post_json(url: &str, body: &str, token: Option<&str>) -> Result<serde_json::Value, String> {
    let (host, port, path) = parse_http_url(url)?;
    // Use original host:port as Host header (not localhost if tunneled)
    let host_header = if host == "127.0.0.1" {
        // For tunneled connections, we don't know the original host. Use the tunneled one.
        format!("{}:{}", host, port)
    } else {
        format!("{}", host)
    };
    let auth = token.map_or(String::new(), |t| format!("Authorization: Bearer {}\r\n", t));
    let req = format!("POST {} HTTP/1.1\r\nHost: {}\r\nContent-Type: application/json\r\n{}Content-Length: {}\r\nConnection: close\r\n\r\n{}",
        path, host_header, auth, body.len(), body);
    let raw = http_send(&host, port, &req)?;
    let body = decode_chunked(&raw).unwrap_or(raw);
    serde_json::from_str(&body).map_err(|e| format!("json: {e} — {}", &body[..200.min(body.len())]))
}

fn http_send(host: &str, port: u16, req: &str) -> Result<String, String> {
    // Guard against host already containing a port (double-port bug)
    let host = host.rsplit_once(':').map(|(h, _)| h).unwrap_or(host);
    let addr = format!("{host}:{port}");
    let sa: std::net::SocketAddr = addr.parse().map_err(|e| format!("addr '{addr}': {e}"))?;
    let mut s = TcpStream::connect_timeout(&sa, Duration::from_secs(10)).map_err(|e| format!("connect {addr}: {e}"))?;
    s.set_read_timeout(Some(Duration::from_secs(10))).ok();
    s.write_all(req.as_bytes()).map_err(|e| format!("write: {e}"))?;
    let mut r = String::new(); s.read_to_string(&mut r).map_err(|e| format!("read: {e}"))?;
    let body = r.split("\r\n\r\n").nth(1).or_else(|| r.split("\n\n").nth(1)).unwrap_or(&r);
    Ok(body.to_string())
}

fn parse_http_url(url: &str) -> Result<(String, u16, String), String> {
    let s = url.trim().strip_prefix("http://").or_else(|| url.strip_prefix("https://")).unwrap_or(url).trim_start_matches('/');
    let slash = s.find('/').unwrap_or(s.len());
    let (hp, path) = (s[..slash].trim().to_string(), if slash < s.len() { s[slash..].into() } else { "/".into() });
    if let Some(ci) = hp.rfind(':') {
        let after = hp[ci+1..].to_string();
        if let Some((d, r)) = split_digits(&after) {
            if !d.is_empty() && !r.is_empty() {
                return Ok((format!("{}:{}", &hp[..ci], d), d.parse().unwrap(), format!("/{}{}", r, path)));
            }
        }
    }
    let (h, p) = hp.rsplit_once(':').map_or((hp.as_str(), "80"), |(h, p)| (h, p.trim()));
    Ok((h.into(), p.parse().map_err(|_| "bad port")?, path))
}

fn split_digits(s: &str) -> Option<(&str, &str)> {
    let end = s.find(|c: char| !c.is_ascii_digit()).unwrap_or(s.len());
    if end == 0 { None } else { Some((&s[..end], &s[end..])) }
}

fn decode_chunked(raw: &str) -> Option<String> {
    // Strip leading hex chunk size line, extract body up to "0\n"
    // Format: "<hex>\n<json>\n0\n\n" or "<hex>\r\n<json>\r\n0\r\n\r\n"
    let after_hex = raw.split_once('\n')?.1;
    // Find the end: "\n0\n" or "\r\n0\r\n"
    let end = after_hex.rfind("\n0").or_else(|| after_hex.rfind("\r\n0"))?;
    let body = &after_hex[..end];
    if body.is_empty() { None } else { Some(body.to_string()) }
}
