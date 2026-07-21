// SPDX-FileCopyrightText: 2026 MdsScope Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Signal fetch strategies: Thin/Medium/Full read modes with EAST optimizations.
//!
//! Ported from `src/mds/mds_ip_signal_fetch.cpp`, `mds_ip_series.cpp`, `mds_ip_east.cpp`.

use crate::protocol::{self, Message};
use mds_core::types::{DataReadMode, PlotSpec, SignalSeries, SignalSpec};
use std::net::TcpStream;

// ── Fetch request ─────────────────────────────────────────────────────────

/// Internal fetch request with all context needed by the fetch pipeline.
#[derive(Debug, Clone)]
pub struct FetchRequest {
    /// Global index in the output buffer.
    pub loaded_index: usize,
    /// Layout column index.
    pub column: i32,
    /// Layout row index.
    pub row: i32,
    /// Signal index within the panel.
    pub signal: i32,
    /// Shot number (from panel or overridden per-signal).
    pub shot: String,
    /// Panel configuration.
    pub plot: PlotSpec,
    /// Signal configuration.
    pub sig: SignalSpec,
    /// Effective read mode.
    pub read_mode: DataReadMode,
    /// Target max points for Thin/Medium.
    pub max_points: usize,
}

/// Result of a single signal fetch.
#[derive(Debug, Clone)]
pub struct FetchResult {
    pub loaded_index: usize,
    pub series: SignalSeries,
}

// ── East timebase ─────────────────────────────────────────────────────────

/// Cached EAST timebase: uniform start and step.
#[derive(Debug, Clone)]
pub struct EastTimebase {
    pub start: f64,
    pub step: f64,
}

/// EAST thin sampling plan.
#[derive(Debug, Clone)]
pub struct EastThinPlan {
    pub sampling: SamplingPlan,
    pub timebase: EastTimebase,
}

#[derive(Debug, Clone)]
pub struct SamplingPlan {
    pub source_count: usize,
    pub step: usize,
    pub sampled_count: usize,
}

// ── Entry: fetch one signal on an open socket ─────────────────────────────

/// Fetch a single signal on an already-open socket. Dispatches by read mode.
pub fn fetch_signal(
    socket: &mut TcpStream,
    request: &FetchRequest,
) -> FetchResult {
    let mut result = FetchResult {
        loaded_index: request.loaded_index,
        series: SignalSeries {
            name: normalized_name(&request.sig.y_expr),
            ..Default::default()
        },
    };

    match request.read_mode {
        DataReadMode::Thin => fetch_thin(socket, request, &mut result),
        DataReadMode::Medium => fetch_medium(socket, request, &mut result),
        DataReadMode::Full => fetch_full(socket, request, &mut result),
    }

    result
}

// ── Thin mode ─────────────────────────────────────────────────────────────

fn fetch_thin(socket: &mut TcpStream, req: &FetchRequest, result: &mut FetchResult) {
    let is_east = is_east_signal(req);
    if is_east {
        fetch_east_thin(socket, req, result);
    } else {
        fetch_generic_thin(socket, req, result);
    }
}

/// EAST Thin: four-tier fallback strategy.
///
/// 1. Try saved signal `{y}_s`
/// 2. Try SetTimeContext envelope
/// 3. Try SetTimeContext direct
/// 4. Fallback: length-sampled `data(y)[1:*:step]`
fn fetch_east_thin(socket: &mut TcpStream, req: &FetchRequest, result: &mut FetchResult) {
    // First try to derive timebase + fetch data with proper X coords
    if let Some(tb) = try_timebase(socket, req) {
        let y_expr = format!("( _jscope_0 = ({}), fs_float(_jscope_0))", req.sig.y_expr.trim());
        if let Ok(msg) = protocol::value(socket, &y_expr) {
            result.series = series_from_msg_uniform(
                normalized_name(&req.sig.y_expr), &msg, tb.start, tb.step, req.max_points,
            );
            if result.series.has_data() { return; }
            // has_data returned false — the server returned empty data
            result.series.error = format!("noData: freq={:.0} t0={:.3} step={:.6}", 1.0/tb.step, tb.start, tb.step);
        }
    }

    // Tier 2: Try saved/compressed signal variant
    if let Some(series) = try_saved_signal(socket, &req.sig.y_expr) {
        result.series = series;
        return;
    }

    // Tier 2+3: Try SetTimeContext-based approaches
    if let Some(plan) = try_east_thin_plan(socket, req) {
        let start = plan.timebase.start;
        let end = start + plan.sampling.source_count as f64 * plan.timebase.step;
        let delta = plan.timebase.step * plan.sampling.step as f64;

        if delta > 0.0 && end > start {
            // SetTimeContext for server-side resampling
            let ctx_expr = format!(
                "SetTimeContext({},{},{})", start, end, delta
            );
            let _ = protocol::value(socket, &ctx_expr);

            let y_expr = format!("( _jscope_0 = ({}), fs_float(_jscope_0))", req.sig.y_expr.trim());
            match protocol::value(socket, &y_expr) {
                Ok(msg) => {
                    result.series = series_from_msg_uniform(
                        normalized_name(&req.sig.y_expr), &msg, start, delta, req.max_points,
                    );
                    let _ = protocol::value(socket, "SetTimeContext()"); // reset
                    if result.series.has_data() { return; }
                }
                Err(_) => {
                    let _ = protocol::value(socket, "SetTimeContext()"); // reset
                }
            }
        }
    }

    // Tier 4: Length-sampled fallback
    fetch_east_length_sampled(socket, req, result);
}

/// Try to fetch the saved signal `{y}_s`.
fn try_saved_signal(socket: &mut TcpStream, y_expr: &str) -> Option<SignalSeries> {
    let saved_expr = format!("( _jscope_0 = ({}_s), fs_float(_jscope_0))", y_expr.trim());
    match protocol::value(socket, &saved_expr) {
        Ok(msg) => {
            let values = protocol::numeric_from_message(&msg).ok()?;
            if values.is_empty() { return None; }
            // Saved signals come without timebase — make a raw series
            Some(SignalSeries {
                name: normalized_name(y_expr),
                points: values.iter().enumerate().map(|(i, &v)| [i as f64, v]).collect(),
                ..Default::default()
            })
        }
        Err(_) => None,
    }
}

/// Try to derive an EAST thin plan: freq + trigtime → timebase + sampling.
fn try_east_thin_plan(socket: &mut TcpStream, req: &FetchRequest) -> Option<EastThinPlan> {
    let y = req.sig.y_expr.trim();
    let meta_expr = format!("[size({}),{}:freq,{}:trigtime]", y, y, y);
    let meta = protocol::value(socket, &meta_expr).ok()?;
    let values = protocol::numeric_from_message(&meta).ok()?;

    if values.len() < 3 || !values[0].is_finite() || !values[1].is_finite() || !values[2].is_finite() {
        return None;
    }

    let point_count = values[0].round() as usize;
    let freq = values[1].round() as usize;
    if point_count == 0 || freq == 0 { return None; }

    let plan = sampling_from_point_count(point_count, req.max_points);
    if plan.sampled_count == 0 { return None; }

    Some(EastThinPlan {
        sampling: plan,
        timebase: EastTimebase { start: values[2], step: 1.0 / freq as f64 },
    })
}

/// Length-sampled: `data(y)[1:*:step]` with `fs_float`.
fn fetch_east_length_sampled(socket: &mut TcpStream, req: &FetchRequest, result: &mut FetchResult) {
    // Get point count first
    let size_expr = format!("size({})", req.sig.y_expr.trim());
    let total_points = match protocol::value(socket, &size_expr) {
        Ok(msg) => protocol::int_from_message(&msg).unwrap_or(0) as usize,
        Err(_) => 0,
    };

    if total_points == 0 {
        result.series.error = "empty signal".into();
        return;
    }

    let plan = sampling_from_point_count(total_points, req.max_points);
    let step = plan.step;

    let y_expr = if step > 1 {
        format!("( _jscope_0 = (data({})[1:*:{}]), fs_float(_jscope_0))", req.sig.y_expr.trim(), step)
    } else {
        format!("( _jscope_0 = ({}), fs_float(_jscope_0))", req.sig.y_expr.trim())
    };

    match protocol::value(socket, &y_expr) {
        Ok(msg) => {
            // Get X axis from dim_of(y) for proper time coords (matching C++ behavior)
            let x_expr = if step > 1 {
                format!("( _jscope_1 = (data(dim_of({}))[1:*:{}]), ft_float(_jscope_1))", req.sig.y_expr.trim(), step)
            } else {
                format!("( _jscope_1 = (dim_of({})), ft_float(_jscope_1))", req.sig.y_expr.trim())
            };
            if let Ok(x_msg) = protocol::value(socket, &x_expr) {
                if let Ok(x_vals) = protocol::numeric_from_message(&x_msg) {
                    let y_vals = protocol::numeric_from_message(&msg).unwrap_or_default();
                    let n = y_vals.len().min(x_vals.len());
                    result.series = SignalSeries {
                        name: normalized_name(&req.sig.y_expr),
                        points: (0..n).map(|i| [x_vals[i], y_vals[i]]).collect(),
                        ..Default::default()
                    };
                    return;
                }
            }
            result.series = series_from_msg(normalized_name(&req.sig.y_expr), &msg, req.max_points);
        }
        Err(e) => { result.series.error = e; }
    }
}

// ── Medium mode ───────────────────────────────────────────────────────────

fn fetch_medium(socket: &mut TcpStream, req: &FetchRequest, result: &mut FetchResult) {
    // Medium uses stride sampling at finer resolution than Thin.
    // It preserves spike amplitude without final downsample.
    if is_east_signal(req) {
        // Use length-sampled with higher point budget
        let budget = req.max_points * 4;
        fetch_east_length_sampled_with_budget(socket, req, result, budget);
    } else {
        fetch_generic_thin(socket, req, result); // same path, higher budget implicit
    }
}

fn fetch_east_length_sampled_with_budget(
    socket: &mut TcpStream, req: &FetchRequest, result: &mut FetchResult, budget: usize,
) {
    let size_expr = format!("size({})", req.sig.y_expr.trim());
    let total = match protocol::value(socket, &size_expr) {
        Ok(msg) => protocol::int_from_message(&msg).unwrap_or(0) as usize,
        Err(_) => 0,
    };
    if total == 0 { result.series.error = "empty signal".into(); return; }

    let plan = sampling_from_point_count(total, budget);
    let y_expr = if plan.step > 1 {
        format!("( _jscope_0 = (data({})[1:*:{}]), fs_float(_jscope_0))", req.sig.y_expr.trim(), plan.step)
    } else {
        format!("( _jscope_0 = ({}), fs_float(_jscope_0))", req.sig.y_expr.trim())
    };

    match protocol::value(socket, &y_expr) {
        Ok(msg) => {
            // Try to derive timebase first (EAST signal freq+trigtime)
            if let Some(tb) = try_timebase(socket, req) {
                result.series = series_from_msg_uniform(normalized_name(&req.sig.y_expr), &msg, tb.start, tb.step, req.max_points);
            } else {
                result.series = series_from_msg(normalized_name(&req.sig.y_expr), &msg, req.max_points);
            }
        }
        Err(e) => { result.series.error = e; }
    }
}

// ── Full mode ─────────────────────────────────────────────────────────────

fn fetch_full(socket: &mut TcpStream, req: &FetchRequest, result: &mut FetchResult) {
    // Full: read all raw data, no downsampling.
    // Try to derive timebase for uniform storage.
    if is_east_signal(req) {
        if let Some(tb) = try_timebase(socket, req) {
            let y_expr = format!("( _jscope_0 = ({}), fs_float(_jscope_0))", req.sig.y_expr.trim());
            match protocol::value(socket, &y_expr) {
                Ok(msg) => {
                    result.series = series_from_msg_uniform(
                        normalized_name(&req.sig.y_expr), &msg, tb.start, tb.step, usize::MAX,
                    );
                    return;
                }
                Err(e) => { result.series.error = e; return; }
            }
        }
    }

    // Generic: get both X and Y
    let y_expr = format!("( _jscope_0 = ({}), fs_float(_jscope_0))", req.sig.y_expr.trim());
    let x_expr = if !req.sig.x_expr.trim().is_empty() {
        format!("( _jscope_1 = ({}), ft_float(_jscope_1))", req.sig.x_expr.trim())
    } else {
        format!("( _jscope_1 = (dim_of({})), ft_float(_jscope_1))", req.sig.y_expr.trim())
    };

    let y_msg = match protocol::value(socket, &y_expr) { Ok(m) => m, Err(e) => { result.series.error = e; return; } };
    let x_msg = match protocol::value(socket, &x_expr) { Ok(m) => m, Err(e) => { result.series.error = e; return; } };

    let y_vals = protocol::numeric_from_message(&y_msg).unwrap_or_default();
    let x_vals = protocol::numeric_from_message(&x_msg).unwrap_or_default();
    let n = y_vals.len().min(x_vals.len());

    result.series = SignalSeries {
        name: normalized_name(&req.sig.y_expr),
        points: (0..n).map(|i| [x_vals[i], y_vals[i]]).collect(),
        ..Default::default()
    };
}

// ── Generic Thin ──────────────────────────────────────────────────────────

fn fetch_generic_thin(socket: &mut TcpStream, req: &FetchRequest, result: &mut FetchResult) {
    let size_expr = format!("size({})", req.sig.y_expr.trim());
    let total = match protocol::value(socket, &size_expr) {
        Ok(msg) => protocol::int_from_message(&msg).unwrap_or(0) as usize,
        Err(_) => 0,
    };
    if total == 0 { result.series.error = "empty signal".into(); return; }

    let plan = sampling_from_point_count(total, req.max_points);
    let y_expr = if plan.step > 1 {
        format!("( _jscope_0 = (data({})[1:*:{}]), fs_float(_jscope_0))", req.sig.y_expr.trim(), plan.step)
    } else {
        format!("( _jscope_0 = ({}), fs_float(_jscope_0))", req.sig.y_expr.trim())
    };

    match protocol::value(socket, &y_expr) {
        Ok(msg) => {
            if let Some(tb) = try_timebase(socket, req) {
                result.series = series_from_msg_uniform(normalized_name(&req.sig.y_expr), &msg, tb.start, tb.step, req.max_points);
            } else {
                result.series = series_from_msg(normalized_name(&req.sig.y_expr), &msg, req.max_points);
            }
        }
        Err(e) => { result.series.error = e; }
    }
}

// ── Timebase derivation ───────────────────────────────────────────────────

/// Derive EAST timebase from `freq` and `trigtime` (separate queries, matching C++).
fn try_timebase(socket: &mut TcpStream, req: &FetchRequest) -> Option<EastTimebase> {
    let y = req.sig.y_expr.trim();
    // Query using MDSplus attribute syntax: yExpr:freq and yExpr:trigtime
    let freq_expr = format!("{}:freq", y);
    let trig_expr = format!("{}:trigtime", y);

    match (protocol::value(socket, &freq_expr), protocol::value(socket, &trig_expr)) {
        (Ok(fm), Ok(tm)) => {
            let fv = protocol::numeric_from_message(&fm).ok()?;
            let tv = protocol::numeric_from_message(&tm).ok()?;
            if !fv.is_empty() && !tv.is_empty() && fv[0].is_finite() && tv[0].is_finite() && fv[0] > 0.0 {
                let freq = fv[0].round() as usize;
                return Some(EastTimebase { start: tv[0], step: 1.0 / freq as f64 });
            }
        }
        _ => {}
    }
    None
}

// ── Helpers ───────────────────────────────────────────────────────────────

fn is_east_signal(req: &FetchRequest) -> bool {
    !req.shot.is_empty()
        && req.sig.x_expr.trim().is_empty()
        && !req.sig.y_expr.trim().is_empty()
}

pub fn normalized_name(expr: &str) -> String {
    expr.trim().to_string()
}

/// Returns the higher-precision of global and per-signal read mode.
/// Matches C++ `effectiveSignalReadMode`: Thin < Medium < Full.
pub fn effective_read_mode(global: DataReadMode, signal_mode: Option<DataReadMode>) -> DataReadMode {
    fn rank(m: DataReadMode) -> u8 {
        match m {
            DataReadMode::Thin => 0,
            DataReadMode::Medium => 1,
            DataReadMode::Full => 2,
        }
    }
    match signal_mode {
        Some(sig) if rank(sig) >= rank(global) => sig,
        _ => global,
    }
}

pub fn sampling_from_point_count(total: usize, max_points: usize) -> SamplingPlan {
    if total == 0 || max_points == 0 {
        return SamplingPlan { source_count: total, step: 1, sampled_count: 0 };
    }
    let step = ((total as f64 / max_points as f64).ceil() as usize).max(1);
    let sampled_count = (total + step - 1) / step;
    SamplingPlan { source_count: total, step, sampled_count }
}

/// Build a SignalSeries from a numeric message (no timebase info).
fn series_from_msg(name: String, msg: &Message, max_points: usize) -> SignalSeries {
    let values = protocol::numeric_from_message(msg).unwrap_or_default();
    if values.is_empty() {
        return SignalSeries { name, error: "empty signal".into(), ..Default::default() };
    }

    // Store as points with actual index-based X. The caller should
    // replace X with proper timebase if available (via series_from_msg_uniform).
    let n = values.len();
    if n <= max_points || max_points == 0 {
        SignalSeries {
            name,
            points: values.iter().enumerate().map(|(i, &v)| [i as f64, v]).collect(),
            uniform_min_y: values.iter().fold(f64::INFINITY, |a, &v| a.min(v)),
            uniform_max_y: values.iter().fold(f64::NEG_INFINITY, |a, &v| a.max(v)),
            ..Default::default()
        }
    } else {
        let step = n / max_points;
        let mut pts = Vec::with_capacity(max_points * 2);
        for b in 0..max_points {
            let start = b * step;
            let end = ((b + 1) * step).min(n);
            if start >= end { continue; }
            let (min_val, max_val) = values[start..end].iter()
                .fold((f64::INFINITY, f64::NEG_INFINITY), |(min, max), &v| (min.min(v), max.max(v)));
            pts.push([(start + end) as f64 / 2.0, min_val]);
            pts.push([(start + end) as f64 / 2.0, max_val]);
        }
        SignalSeries { name, points: pts, ..Default::default() }
    }
}

/// Build a SignalSeries with uniform timebase.
fn series_from_msg_uniform(name: String, msg: &Message, start: f64, step: f64, _max: usize) -> SignalSeries {
    let values = protocol::numeric_from_message(msg).unwrap_or_default();
    if values.is_empty() {
        return SignalSeries { name, error: "empty signal".into(), ..Default::default() };
    }

    let mut min_y = f64::INFINITY;
    let mut max_y = f64::NEG_INFINITY;
    let uniform_y: Vec<f32> = values.iter().map(|&v| {
        if v < min_y { min_y = v; }
        if v > max_y { max_y = v; }
        v as f32
    }).collect();

    SignalSeries {
        name,
        uniform_y, uniform_start: start, uniform_step: step,
        uniform_min_y: min_y, uniform_max_y: max_y,
        ..Default::default()
    }
}
