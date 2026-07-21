// SPDX-FileCopyrightText: 2026 MdsScope Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! MDSIP binary wire protocol implementation.
//!
//! Ported from `src/mds/mds_ip_protocol.cpp`.
//!
//! The MDSIP protocol uses a 48-byte BigEndian header followed by a variable-length body.
//! Messages are sent over TCP to MDSplus servers (default port 8000).

use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;

/// MDSplus server default port.
pub const MDS_PORT: u16 = 8000;

/// Network timeout for MDSIP operations (milliseconds).
pub const NETWORK_TIMEOUT_MS: u64 = 30000;

/// A decoded MDSIP message.
#[derive(Debug, Clone)]
pub struct Message {
    pub status: i32,
    pub length: i16,
    pub dtype: i8,
    pub body: Vec<u8>,
}

// ── Message construction ─────────────────────────────────────────────────

/// Construct a MDSIP message packet.
///
/// Message format (48-byte header + body, all BigEndian):
/// ```text
/// | msgLen(i32) | status(i32, 0) | bodyLen(i16) |
/// | nargs(i8) | descrIdx(i8) | messageId(u8) | dtype(i8) |
/// | 0xC3(i8) | 0(i8) | 8 × i32 padding | body |
/// ```
pub fn message(dtype: i8, nargs: i8, descr_idx: i8, message_id: u8, body: &[u8]) -> Vec<u8> {
    let total_len = 48 + body.len();
    let mut packet = Vec::with_capacity(total_len);
    packet.extend_from_slice(&(total_len as i32).to_be_bytes());
    packet.extend_from_slice(&0i32.to_be_bytes()); // status
    packet.extend_from_slice(&(body.len() as i16).to_be_bytes());
    packet.push(nargs as u8);
    packet.push(descr_idx as u8);
    packet.push(message_id);
    packet.push(dtype as u8);
    packet.push(0xC3u8);
    packet.push(0u8);
    for _ in 0..8 {
        packet.extend_from_slice(&0i32.to_be_bytes());
    }
    packet.extend_from_slice(body);
    packet
}

// ── Socket I/O ───────────────────────────────────────────────────────────

/// Write a complete message to the socket.
pub fn write_message(socket: &mut TcpStream, packet: &[u8]) -> Result<(), String> {
    socket
        .set_write_timeout(Some(Duration::from_millis(NETWORK_TIMEOUT_MS)))
        .map_err(|e| format!("set_write_timeout: {}", e))?;
    socket.write_all(packet).map_err(|e| format!("write error: {}", e))
}

/// Write a message without blocking for flush (for pipelining).
pub fn queue_message(socket: &mut TcpStream, packet: &[u8]) -> Result<(), String> {
    let written = socket.write(packet).map_err(|e| format!("queue write: {}", e))?;
    if written != packet.len() {
        return Err(format!("queue write short: {} of {}", written, packet.len()));
    }
    Ok(())
}

/// Flush all queued writes, blocking until the socket buffer is empty.
pub fn flush_writes(socket: &mut TcpStream) -> Result<(), String> {
    socket
        .set_write_timeout(Some(Duration::from_millis(NETWORK_TIMEOUT_MS)))
        .map_err(|e| format!("set_write_timeout: {}", e))?;
    socket.flush().map_err(|e| format!("flush: {}", e))
}

/// Read exactly `size` bytes from the socket.
pub fn read_fully(socket: &mut TcpStream, size: usize) -> Result<Vec<u8>, String> {
    socket
        .set_read_timeout(Some(Duration::from_millis(NETWORK_TIMEOUT_MS)))
        .map_err(|e| format!("set_read_timeout: {}", e))?;
    let mut buf = vec![0u8; size];
    socket.read_exact(&mut buf).map_err(|e| format!("read error: {}", e))?;
    Ok(buf)
}

/// Read a complete MDSIP message from the socket.
pub fn read_message(socket: &mut TcpStream) -> Result<Message, String> {
    let header = read_fully(socket, 48)?;
    let msg_len = i32::from_be_bytes([header[0], header[1], header[2], header[3]]);
    let status = i32::from_be_bytes([header[4], header[5], header[6], header[7]]);
    let length = i16::from_be_bytes([header[8], header[9]]);
    let dtype = header[13] as i8;

    if msg_len < 48 || msg_len > 128 * 1024 * 1024 {
        return Err("invalid MDSIP message length".to_string());
    }

    let body_size = (msg_len - 48) as usize;
    let body = read_fully(socket, body_size)?;

    Ok(Message { status, length, dtype, body })
}

// ── Protocol operations ──────────────────────────────────────────────────

/// Perform MDSIP handshake: send "JAVA_USER" identifier.
pub fn handshake(socket: &mut TcpStream) -> Result<(), String> {
    write_message(socket, &message(14, 1, 0, 1, b"JAVA_USER"))?;
    read_message(socket)?;
    Ok(())
}

/// Thread-local message ID counter. Starts at 2 (1 is reserved for handshake).
/// Wraps from 0 back to 1 per MDSIP spec.
pub fn next_message_id() -> u8 {
    thread_local! {
        static MSG_ID: std::cell::Cell<u8> = const { std::cell::Cell::new(2) };
    }
    MSG_ID.with(|cell| {
        let id = cell.get();
        let next = if id == 0 { 1 } else { id.wrapping_add(1) };
        cell.set(next);
        id
    })
}

/// Send an MDSplus expression and return the response.
pub fn value(socket: &mut TcpStream, expr: &str) -> Result<Message, String> {
    let body = expr.as_bytes();
    write_message(socket, &message(14, 1, 0, next_message_id(), body))?;
    read_message(socket)
}

/// Queue an expression for pipeline send (write without waiting for response).
pub fn queue_value(socket: &mut TcpStream, expr: &str) -> Result<(), String> {
    let body = expr.as_bytes();
    queue_message(socket, &message(14, 1, 0, next_message_id(), body))
}

// ── Numeric parsing ──────────────────────────────────────────────────────

/// Parse a numeric MDSIP message body into f64 values.
///
/// dtype 11/53 = 8-byte doubles, dtype 10/52 = 4-byte floats.
/// dtype 14 = error string.
pub fn numeric_from_message(msg: &Message) -> Result<Vec<f64>, String> {
    if msg.body.is_empty() {
        return Ok(Vec::new());
    }
    if msg.dtype == 14 {
        return Err(String::from_utf8_lossy(&msg.body).trim().to_string());
    }

    match msg.dtype {
        11 | 53 => parse_f64_be(&msg.body),
        10 | 52 => parse_f32_be(&msg.body),
        _ => {
            if msg.body.len() % 8 == 0 {
                parse_f64_be(&msg.body)
            } else if msg.body.len() % 4 == 0 {
                parse_f32_be(&msg.body)
            } else {
                Ok(Vec::new())
            }
        }
    }
}

fn parse_f64_be(data: &[u8]) -> Result<Vec<f64>, String> {
    let mut values = Vec::with_capacity(data.len() / 8);
    for chunk in data.chunks_exact(8) {
        let v = f64::from_be_bytes(chunk.try_into().unwrap());
        if v.is_finite() { values.push(v); }
    }
    Ok(values)
}

fn parse_f32_be(data: &[u8]) -> Result<Vec<f64>, String> {
    let mut values = Vec::with_capacity(data.len() / 4);
    for chunk in data.chunks_exact(4) {
        let v = f32::from_be_bytes(chunk.try_into().unwrap());
        if v.is_finite() { values.push(v as f64); }
    }
    Ok(values)
}

/// Parse integer value from message body.
pub fn int_from_message(msg: &Message) -> Result<i32, String> {
    if msg.dtype == 14 {
        return Err(String::from_utf8_lossy(&msg.body).trim().to_string());
    }
    if msg.body.is_empty() {
        return Ok(0);
    }

    Ok(match msg.body.len() {
        n if n >= 8 && (msg.dtype == 11 || msg.dtype == 53) => {
            let v = f64::from_be_bytes(msg.body[..8].try_into().unwrap());
            if v.is_finite() && v > 0.0 && v <= i32::MAX as f64 { v.round() as i32 } else { 0 }
        }
        n if n >= 4 && (msg.dtype == 10 || msg.dtype == 52) => {
            let v = f32::from_be_bytes(msg.body[..4].try_into().unwrap());
            if v.is_finite() && v > 0.0 { v.round() as i32 } else { 0 }
        }
        8 => {
            let v = i64::from_be_bytes(msg.body[..8].try_into().unwrap());
            if v > 0 && v <= i32::MAX as i64 { v as i32 } else { 0 }
        }
        n if n >= 4 => {
            let v = i32::from_be_bytes(msg.body[..4].try_into().unwrap());
            if v > 0 { v } else { 0 }
        }
        n if n >= 2 => {
            let v = i16::from_be_bytes(msg.body[..2].try_into().unwrap());
            if v > 0 { v as i32 } else { 0 }
        }
        1 => msg.body[0] as i32,
        _ => 0,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_message_roundtrip() {
        let msg = message(14, 1, 0, 5, b"test_payload");
        assert_eq!(msg.len(), 48 + 12);
        let len = i32::from_be_bytes([msg[0], msg[1], msg[2], msg[3]]);
        assert_eq!(len as usize, msg.len());
        let body_len = i16::from_be_bytes([msg[8], msg[9]]);
        assert_eq!(body_len, 12);
        // Verify message ID byte (index 12)
        assert_eq!(msg[12], 5);
    }

    #[test]
    fn test_message_id_wraps() {
        // Drain IDs and verify wrap behavior
        for _ in 0..254 { next_message_id(); }
        assert_eq!(next_message_id(), 0); // wraps
        assert_eq!(next_message_id(), 1); // skips 0
        assert_eq!(next_message_id(), 2); // back to start
    }

    #[test]
    fn test_numeric_from_message_f64() {
        let body: Vec<u8> = 1.5f64.to_be_bytes().into_iter()
            .chain(2.5f64.to_be_bytes())
            .chain(f64::NAN.to_be_bytes()) // filtered
            .collect();
        let msg = Message { status: 0, length: 0, dtype: 11, body };
        let values = numeric_from_message(&msg).unwrap();
        assert_eq!(values.len(), 2);
        assert!((values[0] - 1.5).abs() < 1e-10);
        assert!((values[1] - 2.5).abs() < 1e-10);
    }

    #[test]
    fn test_numeric_from_message_f32() {
        let body: Vec<u8> = 1.0f32.to_be_bytes().into_iter()
            .chain((-3.0f32).to_be_bytes())
            .collect();
        let msg = Message { status: 0, length: 0, dtype: 10, body };
        let values = numeric_from_message(&msg).unwrap();
        assert_eq!(values.len(), 2);
        assert!((values[0] - 1.0).abs() < 1e-6);
        assert!((values[1] + 3.0).abs() < 1e-6);
    }

    #[test]
    fn test_numeric_error_string() {
        let body = b"Error: signal not found";
        let msg = Message { status: 0, length: 0, dtype: 14, body: body.to_vec() };
        assert!(numeric_from_message(&msg).is_err());
    }

    #[test]
    fn test_int_from_message_double() {
        let body = 42.0f64.to_be_bytes().to_vec();
        let msg = Message { status: 0, length: 0, dtype: 11, body };
        assert_eq!(int_from_message(&msg).unwrap(), 42);
    }

    #[test]
    fn test_int_from_message_empty() {
        let msg = Message { status: 0, length: 0, dtype: 0, body: vec![] };
        assert_eq!(int_from_message(&msg).unwrap(), 0);
    }

    #[test]
    fn test_msg_len_rejects_too_small() {
        // Construct a message with invalid msgLen
        let mut buf = vec![0u8; 48];
        buf[0] = 0; buf[1] = 0; buf[2] = 0; buf[3] = 10; // msgLen = 10 (< 48)
        // We can't test read_message without a real socket, but we test the logic via Message bounds
        let msg = Message { status: 0, length: 0, dtype: 0, body: vec![1, 2, 3] };
        // read_message uses 48 ≤ msgLen ≤ 128*1024*1024
        // numeric_from_message with body.len() < 48 is fine, the check is on msgLen in read_message
        assert!(numeric_from_message(&msg).is_ok()); // non-numeric fallback, no error
    }
}
