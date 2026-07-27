// SPDX-FileCopyrightText: 2026 MDSLens Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Signal fetch strategies: Thin/Medium/Full read modes with EAST optimizations.
//!
//! Ported from `src/mds/mds_ip_signal_fetch.cpp`, `mds_ip_series.cpp`, `mds_ip_east.cpp`.

use crate::protocol::{self, Message};
use mds_core::types::{DataReadMode, PlotSpec, SignalSeries, SignalSpec};
use std::collections::HashMap;
use std::net::TcpStream;
use std::sync::{Mutex, OnceLock};

const FIXED_TIME_RESOLUTION_SECONDS: f64 = 0.0001;

#[derive(Clone)]
struct SignalMetadata {
    unit: String,
    x_name: String,
    x_unit: String,
}

static SIGNAL_METADATA_CACHE: OnceLock<Mutex<HashMap<String, SignalMetadata>>> =
    OnceLock::new();

fn signal_metadata_cache() -> &'static Mutex<HashMap<String, SignalMetadata>> {
    SIGNAL_METADATA_CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

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

    if result.series.has_data() {
        populate_series_metadata(socket, request, &mut result.series);
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
    // Saved EAST signals are prepared server-side specifically for responsive
    // previews. Keep every saved sample so Point mode and zoom retain detail.
    if let Some(series) = try_saved_signal(socket, &req.sig.y_expr) {
        result.series = series;
        return;
    }

    if let Some(series) = fetch_east_fixed_resolution(socket, req) {
        result.series = series;
        return;
    }

    // Legacy fallback when neither a saved signal nor server-side fixed
    // resolution evaluation is available.
    fetch_east_length_sampled(socket, req, result);
}

/// Try to fetch the saved signal `{y}_s`.
fn try_saved_signal(socket: &mut TcpStream, y_expr: &str) -> Option<SignalSeries> {
    let saved_node = format!("{}_s", y_expr.trim());
    let y_msg = protocol::value(
        socket,
        &format!("( _jscope_0 = ({}), fs_float(_jscope_0))", saved_node),
    ).ok()?;
    let x_msg = protocol::value(
        socket,
        &format!("( _jscope_1 = (dim_of({})), ft_float(_jscope_1))", saved_node),
    ).ok()?;
    let y_values = protocol::numeric_from_message(&y_msg).ok()?;
    let x_values = protocol::numeric_from_message(&x_msg).ok()?;
    let count = y_values.len().min(x_values.len());
    if count == 0 { return None; }
    Some(SignalSeries {
        name: normalized_name(y_expr),
        points: (0..count).map(|index| [x_values[index], y_values[index]]).collect(),
        ..Default::default()
    })
}

fn fetch_east_fixed_resolution(socket: &mut TcpStream, req: &FetchRequest) -> Option<SignalSeries> {
    let plan = try_east_thin_plan(socket, req)?;
    if plan.sampling.source_count == 0
        || !plan.timebase.start.is_finite()
        || !plan.timebase.step.is_finite()
        || plan.timebase.step <= 0.0
    {
        return None;
    }

    let mut start = plan.timebase.start;
    let mut end = start
        + (plan.sampling.source_count.saturating_sub(1) as f64) * plan.timebase.step;
    if req.plot.custom_x_range
        && req.plot.xmin.is_finite()
        && req.plot.xmax.is_finite()
        && req.plot.xmax > req.plot.xmin
    {
        start = req.plot.xmin;
        end = req.plot.xmax;
    }
    if !end.is_finite() || end <= start {
        return None;
    }

    let y_expr = format!(
        "( _jscope_0 = ({}), fs_float(_jscope_0))",
        req.sig.y_expr.trim()
    );
    if !req.plot.custom_x_range && plan.timebase.step >= FIXED_TIME_RESOLUTION_SECONDS {
        let message = protocol::value(socket, &y_expr).ok()?;
        let series = series_from_msg_uniform(
            normalized_name(&req.sig.y_expr),
            &message,
            plan.timebase.start,
            plan.timebase.step,
            usize::MAX,
        );
        return series.has_data().then_some(series);
    }

    let requested_step = fixed_resolution_step(plan.timebase.step);
    protocol::value(
        socket,
        &format!("SetTimeContext({start:.12},{end:.12},{requested_step:.12})"),
    ).ok()?;
    let response = protocol::value(socket, &y_expr);
    let cleanup_ok = protocol::value_for_cleanup(socket, "SetTimeContext()")
        .is_ok_and(|message| message.status & 1 != 0);
    if !cleanup_ok {
        protocol::mark_current_connection_unusable();
    }
    let message = response.ok()?;
    let series = series_from_msg_uniform(
        normalized_name(&req.sig.y_expr),
        &message,
        start,
        requested_step,
        usize::MAX,
    );
    series.has_data().then_some(series)
}

fn fixed_resolution_step(native_step: f64) -> f64 {
    FIXED_TIME_RESOLUTION_SECONDS.max(native_step)
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
        if let Some(series) = fetch_east_fixed_resolution(socket, req) {
            result.series = series;
            return;
        }
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

fn populate_series_metadata(socket: &mut TcpStream, request: &FetchRequest, series: &mut SignalSeries) {
    let y_expr = request.sig.y_expr.trim();
    let configured_x = request.sig.x_expr.trim();
    let cache_key = format!(
        "{}|{}|{}|{}",
        request.sig.server_ip, request.sig.experiment, y_expr, configured_x
    );
    if let Some(metadata) = signal_metadata_cache()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .get(&cache_key)
        .cloned()
    {
        series.unit = metadata.unit;
        series.x_name = metadata.x_name;
        series.x_unit = metadata.x_unit;
        return;
    }

    let raw_unit = query_text(socket, &format!("units_of({})", y_expr));
    series.unit = raw_unit
        .as_ref()
        .map(|unit| scaled_si_unit(unit, expression_numeric_scale(y_expr)))
        .unwrap_or_default();

    let x_expr = if configured_x.is_empty() {
        format!("dim_of({})", y_expr)
    } else {
        configured_x.to_string()
    };
    let raw_x_unit = query_text(socket, &format!("units_of({})", x_expr));
    series.x_unit = raw_x_unit.clone().unwrap_or_default();
    // A dimension is often an anonymous RANGE/ARRAY rather than a named tree
    // node. Prefer the name returned by MDSplus, but retain the exact source
    // expression when no name exists instead of presenting a fabricated "x".
    let raw_x_name = query_text(socket, &format!("name_of({})", x_expr));
    series.x_name = raw_x_name.clone()
        .and_then(valid_axis_name)
        .unwrap_or_else(|| axis_expression_label(&x_expr));

    if raw_unit.is_some() || raw_x_unit.is_some() || raw_x_name.is_some() {
        signal_metadata_cache()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .insert(cache_key, SignalMetadata {
                unit: series.unit.clone(),
                x_name: series.x_name.clone(),
                x_unit: series.x_unit.clone(),
            });
    }
}

fn valid_axis_name(value: String) -> Option<String> {
    let name = value.trim().trim_matches('"').trim();
    if name.is_empty()
        || name == "*"
        || name.eq_ignore_ascii_case("none")
        || name.eq_ignore_ascii_case("missing")
    {
        None
    } else {
        Some(name.trim_start_matches('\\').to_string())
    }
}

fn axis_expression_label(expression: &str) -> String {
    expression
        .split_whitespace()
        .collect::<String>()
        .trim_start_matches('\\')
        .to_string()
}

fn query_text(socket: &mut TcpStream, expr: &str) -> Option<String> {
    let message = protocol::value(socket, expr).ok()?;
    if message.status & 1 == 0 || message.dtype != 14 {
        return None;
    }
    let value = String::from_utf8_lossy(&message.body)
        .trim_matches(char::from(0))
        .trim()
        .trim_matches('"')
        .to_string();
    (!value.is_empty()).then_some(value)
}

fn expression_numeric_scale(expr: &str) -> f64 {
    let compact: String = expr.chars().filter(|c| !c.is_whitespace()).collect();
    for operator in ['/', '*'] {
        if let Some(index) = compact.rfind(operator) {
            if let Ok(value) = compact[index + 1..].trim_matches(['(', ')']).parse::<f64>() {
                if value.is_finite() && value != 0.0 {
                    return if operator == '/' { 1.0 / value } else { value };
                }
            }
        }
    }
    1.0
}

fn scaled_si_unit(unit: &str, numeric_scale: f64) -> String {
    let unit = unit.trim();
    let absolute_scale = numeric_scale.abs();
    if unit.is_empty() || !absolute_scale.is_finite() || absolute_scale == 0.0 {
        return unit.to_string();
    }
    let prefix_steps_value = -absolute_scale.log(1000.0);
    let prefix_steps = prefix_steps_value.round() as i32;
    if (prefix_steps_value - f64::from(prefix_steps)).abs() > 1e-10 || prefix_steps == 0 {
        return unit.to_string();
    }

    const PREFIXES: &[(&str, i32)] = &[
        ("Y", 8), ("Z", 7), ("E", 6), ("P", 5), ("T", 4), ("G", 3),
        ("M", 2), ("k", 1), ("m", -1), ("u", -2), ("µ", -2),
        ("μ", -2), ("n", -3), ("p", -4), ("f", -5), ("a", -6),
        ("z", -7), ("y", -8),
    ];
    const BASE_UNITS: &[&str] = &[
        "mol", "kat", "rad", "bar", "Ohm", "Bq", "Gy", "Sv", "Hz", "Pa",
        "Wb", "eV", "lm", "lx", "sr", "Ω", "W", "J", "V", "A", "s", "g",
        "m", "K", "C", "N", "F", "S", "T", "H",
    ];
    let begins_with_unit = |text: &str| {
        BASE_UNITS.iter().any(|base| {
            text.strip_prefix(base).is_some_and(|rest| {
                rest.is_empty() || rest.starts_with(['/', '*', '^', ' ', '·', '⋅'])
            })
        })
    };

    let mut current_steps = 0;
    let mut base_unit = unit;
    for (prefix, steps) in PREFIXES {
        if let Some(candidate) = unit.strip_prefix(prefix) {
            if begins_with_unit(candidate) {
                current_steps = *steps;
                base_unit = candidate;
                break;
            }
        }
    }
    if base_unit == unit && !begins_with_unit(base_unit) {
        return unit.to_string();
    }
    let target_steps = current_steps + prefix_steps;
    if target_steps == 0 {
        return base_unit.to_string();
    }
    PREFIXES
        .iter()
        .find(|(_, steps)| *steps == target_steps)
        .map_or_else(|| unit.to_string(), |(prefix, _)| format!("{prefix}{base_unit}"))
}

/// Per-signal read mode overrides global; falls back to global when not set.
pub fn effective_read_mode(global: DataReadMode, signal_mode: Option<DataReadMode>) -> DataReadMode {
    signal_mode.unwrap_or(global)
}

#[cfg(test)]
mod metadata_tests {
    use super::*;

    #[test]
    fn scales_exact_si_powers_for_simple_expressions() {
        assert_eq!(expression_numeric_scale(r"\ip / 1000"), 0.001);
        assert_eq!(scaled_si_unit("A", 0.001), "kA");
        assert_eq!(scaled_si_unit("kA", 1000.0), "A");
        assert_eq!(scaled_si_unit("V", 2.0), "V");
    }

    #[test]
    fn fixed_resolution_never_upsamples_native_data() {
        assert_eq!(fixed_resolution_step(0.00001), 0.0001);
        assert_eq!(fixed_resolution_step(0.001), 0.001);
    }

    #[test]
    fn anonymous_dimensions_keep_their_real_source_expression() {
        assert_eq!(axis_expression_label(r"dim_of(\IP)"), r"dim_of(\IP)");
        assert_eq!(axis_expression_label(r" \TIMEBASE "), "TIMEBASE");
        assert_eq!(valid_axis_name("none".into()), None);
        assert_eq!(valid_axis_name(r"\TIME".into()), Some("TIME".into()));
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
