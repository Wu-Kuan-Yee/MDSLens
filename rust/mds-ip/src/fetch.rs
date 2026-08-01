// SPDX-FileCopyrightText: 2026 MDSLens Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Signal fetch strategies: Thin/Medium/Full read modes with EAST optimizations.
//!
//! Ported from `src/mds/mds_ip_signal_fetch.cpp`, `mds_ip_series.cpp`, `mds_ip_east.cpp`.

use crate::protocol::{self, Message};
use mds_core::types::{DataReadMode, PlotSpec, SignalSeries, SignalSpec};
use std::collections::HashMap;
use std::net::TcpStream;
use std::sync::{Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

const FIXED_TIME_RESOLUTION_SECONDS: f64 = 0.0001;
const DEFAULT_FULL_LARGE_SIGNAL_POINTS: usize = 8_000_000;
const DEFAULT_FULL_LARGE_DOWNLOAD_LIMIT: usize = 2;
const MIN_MAX_BLOCK_SIZE: usize = 256;
const MIN_MAX_INDEX_MIN_POINTS: usize = MIN_MAX_BLOCK_SIZE * 4;

#[derive(Clone)]
struct SignalMetadata {
    unit: String,
    x_name: String,
    x_unit: String,
}

static SIGNAL_METADATA_CACHE: OnceLock<Mutex<HashMap<String, SignalMetadata>>> = OnceLock::new();
static FULL_LARGE_DOWNLOADS: OnceLock<(Mutex<HashMap<String, usize>>, Condvar)> = OnceLock::new();

fn signal_metadata_cache() -> &'static Mutex<HashMap<String, SignalMetadata>> {
    SIGNAL_METADATA_CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn full_large_downloads() -> &'static (Mutex<HashMap<String, usize>>, Condvar) {
    FULL_LARGE_DOWNLOADS.get_or_init(|| (Mutex::new(HashMap::new()), Condvar::new()))
}

struct FullLargeDownloadPermit {
    server: String,
}

impl FullLargeDownloadPermit {
    fn acquire(server: String) -> Result<Self, String> {
        let limit = full_large_download_limit();
        let (downloads, changed) = full_large_downloads();
        let mut active = downloads
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        loop {
            if protocol::current_operation_canceled() {
                return Err("operation canceled".into());
            }
            let count = active.entry(server.clone()).or_default();
            if *count < limit {
                *count += 1;
                return Ok(Self { server });
            }
            active = changed
                .wait_timeout(active, Duration::from_millis(50))
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .0;
        }
    }
}

impl Drop for FullLargeDownloadPermit {
    fn drop(&mut self) {
        let (downloads, changed) = full_large_downloads();
        let mut active = downloads
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(count) = active.get_mut(&self.server) {
            *count = count.saturating_sub(1);
            if *count == 0 {
                active.remove(&self.server);
            }
        }
        changed.notify_one();
    }
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
pub fn fetch_signal(socket: &mut TcpStream, request: &FetchRequest) -> FetchResult {
    let started = Instant::now();
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
        if result.series.has_uniform_data()
            && result.series.uniform_y.len() >= MIN_MAX_INDEX_MIN_POINTS
        {
            mds_core::sampling::build_min_max_index(&mut result.series, MIN_MAX_BLOCK_SIZE);
        }
    }
    if trace_fetch_enabled() {
        eprintln!(
            "[mds-ip] signal_ms={} shot={} tree={} y={} points={} error={}",
            started.elapsed().as_millis(),
            request.shot,
            request.sig.experiment,
            request.sig.y_expr,
            result.series.points.len() + result.series.uniform_y.len(),
            result.series.error.replace('\n', " ")
        );
    }

    result
}

fn trace_fetch_enabled() -> bool {
    static ENABLED: OnceLock<bool> = OnceLock::new();
    *ENABLED.get_or_init(|| {
        std::env::var("MDSLENS_MDS_TRACE").is_ok_and(|value| !value.is_empty() && value != "0")
    })
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

/// EAST Thin: the same fallback order as the original client.
///
/// 1. Try saved signal `{y}_s`
/// 2. Try fixed-resolution direct/SetTimeContext data
/// 3. Try the envelope and SetTimeContext resamplers
/// 4. Fallback: length-sampled and generic `data(y)` reads
fn fetch_east_thin(socket: &mut TcpStream, req: &FetchRequest, result: &mut FetchResult) {
    let Some((base_expr, scale)) = east_signal_parts(req) else {
        fetch_generic_thin(socket, req, result);
        return;
    };

    // Saved EAST signals are prepared server-side specifically for responsive
    // previews. Keep every saved sample so Point mode and zoom retain detail.
    if let Some(mut series) = try_saved_signal(socket, &base_expr) {
        apply_series_scale(&mut series, &req.sig.y_expr, scale);
        result.series = series;
        return;
    }

    if let Some(series) = fetch_east_fixed_resolution(socket, req) {
        result.series = series;
        return;
    }

    if let Some(series) = fetch_east_envelope(socket, req, DataReadMode::Thin) {
        result.series = series;
        return;
    }

    if let Some(series) = fetch_east_time_context(socket, req) {
        result.series = series;
        return;
    }

    // Keep the native EAST length path for older servers, then use the
    // generic expression path as a final fallback.  The latter is important
    // for nodes whose metadata children are absent even though the node value
    // itself is readable.
    fetch_east_length_sampled(socket, req, result);
    if !result.series.has_data() {
        fetch_generic_thin(socket, req, result);
    }
}

/// Try to fetch the saved signal `{y}_s`.
fn try_saved_signal(socket: &mut TcpStream, y_expr: &str) -> Option<SignalSeries> {
    let saved_node = format!("{}_s", y_expr.trim());
    let y_msg = protocol::value(
        socket,
        &format!("( _jscope_0 = ({}), fs_float(_jscope_0))", saved_node),
    )
    .ok()?;
    let x_msg = protocol::value(
        socket,
        &format!(
            "( _jscope_1 = (dim_of({})), ft_float(_jscope_1))",
            saved_node
        ),
    )
    .ok()?;
    if !protocol::message_succeeded(&y_msg) {
        return None;
    }
    let y_values = protocol::numeric_from_message(&y_msg).ok()?;
    let x_values = if protocol::message_succeeded(&x_msg) {
        protocol::numeric_from_message(&x_msg).unwrap_or_default()
    } else {
        Vec::new()
    };
    let count = if x_values.is_empty() {
        y_values.len()
    } else {
        y_values.len().min(x_values.len())
    };
    if count == 0 {
        return None;
    }
    Some(SignalSeries {
        name: normalized_name(y_expr),
        points: (0..count)
            .map(|index| {
                [
                    x_values.get(index).copied().unwrap_or(index as f64),
                    y_values[index],
                ]
            })
            .collect(),
        ..Default::default()
    })
}

fn fetch_east_fixed_resolution(socket: &mut TcpStream, req: &FetchRequest) -> Option<SignalSeries> {
    let (base_expr, scale) = east_signal_parts(req)?;
    let plan = try_east_thin_plan(socket, req)?;
    if plan.sampling.source_count == 0
        || !plan.timebase.start.is_finite()
        || !plan.timebase.step.is_finite()
        || plan.timebase.step <= 0.0
    {
        return None;
    }

    let mut start = plan.timebase.start;
    let mut end =
        start + (plan.sampling.source_count.saturating_sub(1) as f64) * plan.timebase.step;
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

    let y_expr = format!("( _jscope_0 = ({}), fs_float(_jscope_0))", base_expr);
    if !req.plot.custom_x_range && plan.timebase.step >= FIXED_TIME_RESOLUTION_SECONDS {
        let message = protocol::value(socket, &y_expr).ok()?;
        let mut series = series_from_msg_uniform(
            normalized_name(&req.sig.y_expr),
            &message,
            plan.timebase.start,
            plan.timebase.step,
            usize::MAX,
        );
        if series.has_data() {
            apply_series_scale(&mut series, &req.sig.y_expr, scale);
            return Some(series);
        }
        return None;
    }

    let requested_step = fixed_resolution_step(plan.timebase.step);
    let context = protocol::value(
        socket,
        &format!("SetTimeContext({start:.12},{end:.12},{requested_step:.12})"),
    )
    .ok()?;
    if !protocol::message_succeeded(&context) {
        return None;
    }
    let response = protocol::value(socket, &y_expr);
    let cleanup_ok = protocol::value_for_cleanup(socket, "SetTimeContext()")
        .is_ok_and(|message| protocol::message_succeeded(&message));
    if !cleanup_ok {
        protocol::mark_current_connection_unusable();
    }
    let message = response.ok()?;
    let mut series = series_from_msg_uniform(
        normalized_name(&req.sig.y_expr),
        &message,
        start,
        requested_step,
        usize::MAX,
    );
    if series.has_data() {
        apply_series_scale(&mut series, &req.sig.y_expr, scale);
        Some(series)
    } else {
        None
    }
}

fn fixed_resolution_step(native_step: f64) -> f64 {
    FIXED_TIME_RESOLUTION_SECONDS.max(native_step)
}

/// Read an EAST signal through a temporary server-side time context.
///
/// SetTimeContext changes session state, so the cleanup exchange is performed
/// even when the value request fails.  A socket whose context cannot be reset
/// is marked unusable and will not be returned to the reusable connection pool.
fn fetch_east_time_context(socket: &mut TcpStream, req: &FetchRequest) -> Option<SignalSeries> {
    let (base_expr, scale) = east_signal_parts(req)?;
    let plan = try_east_thin_plan(socket, req)?;
    if plan.sampling.source_count == 0 {
        return None;
    }

    let mut start = plan.timebase.start;
    let mut end =
        start + (plan.sampling.source_count.saturating_sub(1) as f64) * plan.timebase.step;
    let mut delta = plan.timebase.step * plan.sampling.step as f64;
    if req.plot.custom_x_range
        && req.plot.xmin.is_finite()
        && req.plot.xmax.is_finite()
        && req.plot.xmax > req.plot.xmin
    {
        start = req.plot.xmin;
        end = req.plot.xmax;
        delta = (end - start) / req.max_points.max(1) as f64;
    }
    if !start.is_finite() || !end.is_finite() || !delta.is_finite() || delta <= 0.0 || end <= start
    {
        return None;
    }

    fetch_east_context_series(
        socket,
        &base_expr,
        &req.sig.y_expr,
        scale,
        start,
        end,
        delta,
        req.max_points,
    )
}

/// Preserve EAST spikes in Thin mode and provide a high-resolution stride
/// path in Medium mode, matching the original client's envelope strategy.
fn fetch_east_envelope(
    socket: &mut TcpStream,
    req: &FetchRequest,
    read_mode: DataReadMode,
) -> Option<SignalSeries> {
    let (base_expr, scale) = east_signal_parts(req)?;
    let plan = try_east_thin_plan(socket, req)?;
    if plan.sampling.source_count == 0 || plan.sampling.step <= 4 {
        return None;
    }

    let oversampled_points = req.max_points.saturating_mul(10).max(2);
    let start = plan.timebase.start;
    let end = start + (plan.sampling.source_count.saturating_sub(1) as f64) * plan.timebase.step;
    if !start.is_finite() || !end.is_finite() || end <= start {
        return None;
    }

    if read_mode == DataReadMode::Medium {
        // [1:*:step] intentionally follows the original EAST convention and
        // skips sample zero; compensate in the generated uniform X origin.
        let fine_step = (plan.sampling.source_count / oversampled_points).max(1);
        let expression = format!(
            "( _jscope_0 = (data({})[1:*:{}]), fs_float(_jscope_0))",
            base_expr, fine_step
        );
        let message = protocol::value(socket, &expression).ok()?;
        if !protocol::message_succeeded(&message) {
            return None;
        }
        let mut series = series_from_msg_uniform(
            normalized_name(&req.sig.y_expr),
            &message,
            start + plan.timebase.step,
            plan.timebase.step * fine_step as f64,
            oversampled_points,
        );
        if !series.has_data() {
            return None;
        }
        apply_series_scale(&mut series, &req.sig.y_expr, scale);
        return Some(series);
    }

    let delta = (end - start) / (oversampled_points.saturating_sub(1) as f64);
    fetch_east_context_series(
        socket,
        &base_expr,
        &req.sig.y_expr,
        scale,
        start,
        end,
        delta,
        oversampled_points,
    )
}

fn fetch_east_context_series(
    socket: &mut TcpStream,
    base_expr: &str,
    display_expr: &str,
    scale: f64,
    start: f64,
    end: f64,
    delta: f64,
    max_points: usize,
) -> Option<SignalSeries> {
    if !start.is_finite() || !end.is_finite() || !delta.is_finite() || delta <= 0.0 || end <= start
    {
        return None;
    }
    let context = protocol::value(
        socket,
        &format!("SetTimeContext({start:.12},{end:.12},{delta:.12})"),
    )
    .ok()?;
    if !protocol::message_succeeded(&context) {
        return None;
    }

    let response = protocol::value(
        socket,
        &format!("( _jscope_0 = ({}), fs_float(_jscope_0))", base_expr),
    );
    let cleanup_ok = protocol::value_for_cleanup(socket, "SetTimeContext()")
        .is_ok_and(|message| protocol::message_succeeded(&message));
    if !cleanup_ok {
        protocol::mark_current_connection_unusable();
    }

    let message = response.ok()?;
    if !protocol::message_succeeded(&message) {
        return None;
    }
    let mut series = series_from_msg_uniform(
        normalized_name(display_expr),
        &message,
        start,
        delta,
        max_points,
    );
    if !series.has_data() {
        return None;
    }
    apply_series_scale(&mut series, display_expr, scale);
    Some(series)
}

/// Try to derive an EAST thin plan: freq + trigtime → timebase + sampling.
fn try_east_thin_plan(socket: &mut TcpStream, req: &FetchRequest) -> Option<EastThinPlan> {
    let (y, _) = east_signal_parts(req)?;
    // Segmented EAST nodes can spend around a second evaluating size(). The
    // acquisition metadata gives the same count in a few milliseconds.
    let meta_expr = format!("[{}:daqtime,{}:freq,{}:trigtime]", y, y, y);
    let meta = protocol::value(socket, &meta_expr).ok()?;
    if !protocol::message_succeeded(&meta) {
        return None;
    }
    let values = protocol::numeric_from_message(&meta).ok()?;

    if values.len() < 3 || !values[1].is_finite() || !values[2].is_finite() {
        return None;
    }

    let freq = values[1].round() as usize;
    if freq == 0 {
        return None;
    }
    let daqtime = values[0];
    let point_count = if daqtime.is_finite() && daqtime > 0.0 {
        (daqtime * freq as f64).round() as usize
    } else {
        let size = protocol::value(socket, &format!("size({y})")).ok()?;
        protocol::int_from_message(&size).ok()?.max(0) as usize
    };
    if point_count == 0 {
        return None;
    }

    let plan = sampling_from_point_count(point_count, req.max_points);
    if plan.sampled_count == 0 {
        return None;
    }

    Some(EastThinPlan {
        sampling: plan,
        timebase: EastTimebase {
            start: values[2],
            step: 1.0 / freq as f64,
        },
    })
}

/// Length-sampled: `data(y)[1:*:step]` with `fs_float`.
fn fetch_east_length_sampled(socket: &mut TcpStream, req: &FetchRequest, result: &mut FetchResult) {
    let Some((base_expr, scale)) = east_signal_parts(req) else {
        fetch_generic_thin(socket, req, result);
        return;
    };
    // Get point count first
    let size_expr = format!("size({base_expr})");
    let total_points = match protocol::value(socket, &size_expr) {
        Ok(msg) => protocol::int_from_message(&msg).unwrap_or(0) as usize,
        Err(_) => 0,
    };
    let plan = sampling_from_point_count(total_points, req.max_points);
    let mut step = plan.step;

    let y_expr = if step > 1 {
        format!(
            "( _jscope_0 = (data({})[1:*:{}]), fs_float(_jscope_0))",
            base_expr, step
        )
    } else {
        format!("( _jscope_0 = ({}), fs_float(_jscope_0))", base_expr)
    };

    let (y_vals, error, used_fallback) =
        numeric_query_with_fallback(socket, &y_expr, &format!("data({base_expr})"));
    if y_vals.is_empty() {
        result.series.error = error.unwrap_or_else(|| "empty signal".into());
        return;
    }
    if used_fallback {
        // The fallback is the un-sampled data() expression. Do not pair it
        // with a stride-derived X axis or timebase.
        step = 1;
    }

    // Get X axis from dim_of(y) for proper time coordinates (matching C++).
    let x_expr = if step > 1 {
        format!(
            "( _jscope_1 = (data(dim_of({}))[1:*:{}]), ft_float(_jscope_1))",
            base_expr, step
        )
    } else {
        format!(
            "( _jscope_1 = (dim_of({})), ft_float(_jscope_1))",
            base_expr
        )
    };
    let x_vals = numeric_query(socket, &x_expr).0;
    result.series = series_from_values(normalized_name(&req.sig.y_expr), y_vals, x_vals);
    if result.series.has_data() {
        apply_series_scale(&mut result.series, &req.sig.y_expr, scale);
    }
    if !result.series.has_data() {
        result.series.error = "no numeric points".into();
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
        if let Some(series) = fetch_east_envelope(socket, req, DataReadMode::Medium) {
            result.series = series;
            return;
        }
        if let Some(series) = fetch_east_time_context(socket, req) {
            result.series = series;
            return;
        }
        // Use length-sampled with a little more budget, then the generic
        // expression path if the EAST metadata is unavailable.
        let budget = req.max_points.saturating_mul(4);
        fetch_east_length_sampled_with_budget(socket, req, result, budget);
        if !result.series.has_data() {
            fetch_generic_thin(socket, req, result);
        }
    } else {
        fetch_generic_thin(socket, req, result); // same path, higher budget implicit
    }
}

fn fetch_east_length_sampled_with_budget(
    socket: &mut TcpStream,
    req: &FetchRequest,
    result: &mut FetchResult,
    budget: usize,
) {
    let Some((base_expr, scale)) = east_signal_parts(req) else {
        fetch_generic_thin(socket, req, result);
        return;
    };
    let size_expr = format!("size({base_expr})");
    let total = match protocol::value(socket, &size_expr) {
        Ok(msg) => protocol::int_from_message(&msg).unwrap_or(0) as usize,
        Err(_) => 0,
    };
    let plan = sampling_from_point_count(total, budget);
    let mut step = plan.step;
    let y_expr = if step > 1 {
        format!(
            "( _jscope_0 = (data({})[1:*:{}]), fs_float(_jscope_0))",
            base_expr, step
        )
    } else {
        format!("( _jscope_0 = ({}), fs_float(_jscope_0))", base_expr)
    };

    let (y_vals, error, used_fallback) =
        numeric_query_with_fallback(socket, &y_expr, &format!("data({base_expr})"));
    if y_vals.is_empty() {
        result.series.error = error.unwrap_or_else(|| "empty signal".into());
        return;
    }
    if used_fallback {
        step = 1;
    }

    // Try the uniform EAST timebase only for the sampled primary expression;
    // data(y) fallback is un-sampled and must use the native X coordinates.
    if !used_fallback {
        if let Some(tb) = try_timebase(socket, req) {
            let sampled_start = if step > 1 {
                tb.start + tb.step
            } else {
                tb.start
            };
            let sampled_step = tb.step * step as f64;
            let series = series_from_values_uniform(
                normalized_name(&req.sig.y_expr),
                y_vals.clone(),
                sampled_start,
                sampled_step,
            );
            if series.has_data() {
                result.series = series;
                apply_series_scale(&mut result.series, &req.sig.y_expr, scale);
                return;
            }
        }
    }

    let x_expr = if step > 1 {
        format!(
            "( _jscope_1 = (data(dim_of({}))[1:*:{}]), ft_float(_jscope_1))",
            base_expr, step
        )
    } else {
        format!(
            "( _jscope_1 = (dim_of({})), ft_float(_jscope_1))",
            base_expr
        )
    };
    let x_vals = numeric_query(socket, &x_expr).0;
    result.series = series_from_values(normalized_name(&req.sig.y_expr), y_vals, x_vals);
    if result.series.has_data() {
        apply_series_scale(&mut result.series, &req.sig.y_expr, scale);
    }
    if !result.series.has_data() {
        result.series.error = "no numeric points".into();
    }
}

// ── Full mode ─────────────────────────────────────────────────────────────

fn fetch_full(socket: &mut TcpStream, req: &FetchRequest, result: &mut FetchResult) {
    // Full: read all raw data, no downsampling.
    // A simple scaled EAST node can still use the compact uniform-X
    // representation. Query metadata on the underlying node, then apply the
    // expression's scale locally. If any part of this optimization fails, fall
    // through to the generic MDS expression path instead of declaring a valid
    // signal empty.
    let scaled = scaled_simple_signal_expr(&req.sig.y_expr);
    let size_expression = scaled.as_ref().map_or_else(
        || req.sig.y_expr.trim(),
        |expression| expression.base_expr.as_str(),
    );
    let expected_points = full_point_count_best_effort(socket, size_expression);
    let _large_download_permit = if expected_points >= full_large_signal_point_threshold() {
        match FullLargeDownloadPermit::acquire(req.sig.server_ip.trim().to_string()) {
            Ok(permit) => Some(permit),
            Err(error) => {
                result.series.error = error;
                return;
            }
        }
    } else {
        None
    };
    if req.sig.x_expr.trim().is_empty() {
        if let Some(ref scaled_expr) = scaled {
            if is_east_timebase_candidate(req, &scaled_expr.base_expr) {
                if let Some(tb) = try_timebase_for_expr(socket, &scaled_expr.base_expr) {
                    let y_expr = format!(
                        "( _jscope_0 = ({}), fs_float(_jscope_0))",
                        scaled_expr.base_expr
                    );
                    if let Ok(msg) = protocol::value(socket, &y_expr) {
                        let mut series = series_from_msg_uniform(
                            normalized_name(&req.sig.y_expr),
                            &msg,
                            tb.start,
                            tb.step,
                            usize::MAX,
                        );
                        if series.has_data() {
                            apply_series_scale(&mut series, &req.sig.y_expr, scaled_expr.scale);
                            result.series = series;
                            return;
                        }
                    }
                }
            }
        }
    }

    let raw_y = req.sig.y_expr.trim();
    let y_expr = format!("( _jscope_0 = ({raw_y}), fs_float(_jscope_0))");
    let (y_vals, mut last_error) = numeric_query(socket, &y_expr);
    let y_vals = if y_vals.is_empty() {
        let (fallback, fallback_error) = numeric_query(socket, &format!("data({raw_y})"));
        if fallback_error.is_some() {
            last_error = fallback_error;
        }
        fallback
    } else {
        y_vals
    };
    if y_vals.is_empty() {
        result.series.error = last_error.unwrap_or_else(|| "empty signal".into());
        return;
    }

    let configured_x = req.sig.x_expr.trim();
    let mut x_vals = if configured_x.is_empty() {
        Vec::new()
    } else {
        numeric_query(
            socket,
            &format!("( _jscope_1 = ({configured_x}), ft_float(_jscope_1))"),
        )
        .0
    };
    if x_vals.is_empty() && configured_x.is_empty() {
        if let Some(tb) = try_timebase(socket, req) {
            let series = series_from_values_uniform(
                normalized_name(&req.sig.y_expr),
                y_vals.clone(),
                tb.start,
                tb.step,
            );
            if series.has_data() {
                result.series = series;
                return;
            }
        }
    }
    if x_vals.is_empty() {
        x_vals = numeric_query(
            socket,
            &format!("( _jscope_1 = (dim_of({raw_y})), ft_float(_jscope_1))"),
        )
        .0;
    }

    result.series = series_from_values(normalized_name(&req.sig.y_expr), y_vals, x_vals);
    if !result.series.has_data() {
        result.series.error = "no numeric points".into();
    }
}

// ── Generic Thin ──────────────────────────────────────────────────────────

fn fetch_generic_thin(socket: &mut TcpStream, req: &FetchRequest, result: &mut FetchResult) {
    let raw_y = req.sig.y_expr.trim();
    let size_expr = format!("size({raw_y})");
    let total = match protocol::value(socket, &size_expr) {
        Ok(msg) => protocol::int_from_message(&msg).unwrap_or(0) as usize,
        Err(_) => 0,
    };

    let plan = sampling_from_point_count(total, req.max_points);
    let y_expr = if plan.step > 1 {
        format!(
            "( _jscope_0 = (data({})[1:*:{}]), fs_float(_jscope_0))",
            raw_y, plan.step
        )
    } else {
        format!("( _jscope_0 = ({raw_y}), fs_float(_jscope_0))")
    };

    // `size(y)` is only a sampling hint. Some valid MDSplus expressions
    // (segmented data, scalar-backed expressions, and computed nodes) return
    // zero or an error for size() while `y`/`data(y)` still contains samples.
    // The original client continues with the actual value query in that case;
    // treating the hint as authoritative is what made these signals appear
    // empty in the Rust client.
    let (y_vals, error, used_fallback) =
        numeric_query_with_fallback(socket, &y_expr, &format!("data({raw_y})"));
    if y_vals.is_empty() {
        result.series.error = error.unwrap_or_else(|| "empty signal".into());
        return;
    }

    let configured_x = req.sig.x_expr.trim();
    let step = if used_fallback { 1 } else { plan.step };
    let mut x_vals = if configured_x.is_empty() {
        Vec::new()
    } else {
        let x_expr = if step > 1 {
            format!("( _jscope_1 = (data({configured_x})[1:*:{step}]), ft_float(_jscope_1))")
        } else {
            format!("( _jscope_1 = ({configured_x}), ft_float(_jscope_1))")
        };
        numeric_query(socket, &x_expr).0
    };

    if x_vals.is_empty() && configured_x.is_empty() && !used_fallback {
        if let Some(tb) = try_timebase(socket, req) {
            let sampled_start = if step > 1 {
                tb.start + tb.step
            } else {
                tb.start
            };
            let sampled_step = tb.step * step as f64;
            let series = series_from_values_uniform(
                normalized_name(&req.sig.y_expr),
                y_vals.clone(),
                sampled_start,
                sampled_step,
            );
            if series.has_data() {
                result.series = series;
                return;
            }
        }
    }

    if x_vals.is_empty() {
        let x_expr = if step > 1 {
            format!("( _jscope_1 = (data(dim_of({raw_y}))[1:*:{step}]), ft_float(_jscope_1))")
        } else {
            format!("( _jscope_1 = (dim_of({raw_y})), ft_float(_jscope_1))")
        };
        x_vals = numeric_query(socket, &x_expr).0;
    }

    result.series = series_from_values(normalized_name(&req.sig.y_expr), y_vals, x_vals);
    if !result.series.has_data() {
        result.series.error = "no numeric points".into();
    }
}

// ── Timebase derivation ───────────────────────────────────────────────────

/// Derive EAST timebase from `freq` and `trigtime` (separate queries, matching C++).
fn try_timebase(socket: &mut TcpStream, req: &FetchRequest) -> Option<EastTimebase> {
    let scaled = scaled_simple_signal_expr(&req.sig.y_expr)?;
    if !is_east_timebase_candidate(req, &scaled.base_expr) {
        return None;
    }
    try_timebase_for_expr(socket, &scaled.base_expr)
}

fn try_timebase_for_expr(socket: &mut TcpStream, y: &str) -> Option<EastTimebase> {
    // Query using MDSplus attribute syntax: yExpr:freq and yExpr:trigtime
    let freq_expr = format!("{}:freq", y);
    let trig_expr = format!("{}:trigtime", y);

    match (
        protocol::value(socket, &freq_expr),
        protocol::value(socket, &trig_expr),
    ) {
        (Ok(fm), Ok(tm)) => east_timebase_from_messages(&fm, &tm),
        _ => None,
    }
}

fn east_timebase_from_messages(
    freq_message: &Message,
    trig_message: &Message,
) -> Option<EastTimebase> {
    // `:freq` is commonly an integer scalar. Treating those four bytes as an
    // IEEE-754 float produces a tiny value, which rounds to zero and turns the
    // Full-mode time step into infinity.
    if !protocol::message_succeeded(freq_message) || !protocol::message_succeeded(trig_message) {
        return None;
    }
    let freq = protocol::int_from_message(freq_message).ok()?;
    let trig = protocol::numeric_from_message(trig_message).ok()?;
    let start = *trig.first()?;
    if freq <= 0 || !start.is_finite() {
        return None;
    }
    let step = 1.0 / f64::from(freq);
    (step.is_finite() && step > 0.0).then_some(EastTimebase { start, step })
}

// ── Helpers ───────────────────────────────────────────────────────────────

fn is_east_signal(req: &FetchRequest) -> bool {
    east_signal_parts(req).is_some()
}

/// Return the native EAST node and the local numeric scale represented by the
/// configured Y expression.  EAST metadata children belong to the native node
/// (`\IP:freq`), not to a scaled expression such as `\IP/1000`.
fn east_signal_parts(req: &FetchRequest) -> Option<(String, f64)> {
    if !req.sig.x_expr.trim().is_empty() {
        return None;
    }
    let scaled = scaled_simple_signal_expr(&req.sig.y_expr)?;
    is_east_timebase_candidate(req, &scaled.base_expr).then_some((scaled.base_expr, scaled.scale))
}

fn is_east_timebase_candidate(req: &FetchRequest, y_expr: &str) -> bool {
    let experiment = req.sig.experiment.trim();
    let shot_is_supported = experiment.eq_ignore_ascii_case("east")
        && req
            .shot
            .trim()
            .parse::<i64>()
            .is_ok_and(|shot| shot > 44326);
    (shot_is_supported || experiment.eq_ignore_ascii_case("eastpower"))
        && is_simple_mds_node(y_expr)
}

fn is_simple_mds_node(expression: &str) -> bool {
    let node = expression.trim();
    node.starts_with('\\')
        && !node
            .chars()
            .any(|character| matches!(character, '(' | ')' | '[' | ']' | ',' | ' '))
}

#[derive(Debug, Clone, PartialEq)]
struct ScaledSignalExpr {
    base_expr: String,
    scale: f64,
}

fn scaled_simple_signal_expr(expression: &str) -> Option<ScaledSignalExpr> {
    let mut compact: String = expression.chars().filter(|c| !c.is_whitespace()).collect();
    let mut sign = 1.0;
    if compact.starts_with('-') {
        sign = -1.0;
        compact.remove(0);
    } else if compact.starts_with('+') {
        compact.remove(0);
    }

    let (node_part, suffix) = if compact.starts_with('(') {
        let close = compact.find(')')?;
        (&compact[1..close], &compact[close + 1..])
    } else {
        let operator = compact.find(['*', '/']).unwrap_or(compact.len());
        (&compact[..operator], &compact[operator..])
    };
    if !is_simple_mds_node(node_part) {
        return None;
    }
    let node_name = node_part.strip_prefix('\\')?;
    let mut chars = node_name.chars();
    if !chars
        .next()
        .is_some_and(|character| character.is_ascii_alphabetic())
        || !chars.all(|character| character.is_ascii_alphanumeric() || character == '_')
    {
        return None;
    }

    let scale = if suffix.is_empty() {
        sign
    } else {
        let mut chars = suffix.chars();
        let operator = chars.next()?;
        let value = chars.as_str().parse::<f64>().ok()?;
        if !value.is_finite() || value == 0.0 {
            return None;
        }
        sign * if operator == '*' {
            value
        } else if operator == '/' {
            1.0 / value
        } else {
            return None;
        }
    };
    Some(ScaledSignalExpr {
        base_expr: node_part.to_string(),
        scale,
    })
}

fn apply_series_scale(series: &mut SignalSeries, name: &str, scale: f64) {
    series.name = normalized_name(name);
    if scale == 1.0 {
        return;
    }
    for (index, point) in series.points.iter_mut().enumerate() {
        if index & 0x3fff == 0 && protocol::current_operation_canceled() {
            return;
        }
        point[1] *= scale;
    }
    for (index, value) in series.uniform_y.iter_mut().enumerate() {
        if index & 0x3fff == 0 && protocol::current_operation_canceled() {
            return;
        }
        *value = (f64::from(*value) * scale) as f32;
    }
    if series.uniform_min_y.is_finite() && series.uniform_max_y.is_finite() {
        let first = series.uniform_min_y * scale;
        let second = series.uniform_max_y * scale;
        series.uniform_min_y = first.min(second);
        series.uniform_max_y = first.max(second);
    }
}

fn numeric_query(socket: &mut TcpStream, expression: &str) -> (Vec<f64>, Option<String>) {
    match protocol::value(socket, expression) {
        Ok(message) if !protocol::message_succeeded(&message) => {
            (Vec::new(), Some(protocol::message_error(&message)))
        }
        Ok(message) => match protocol::numeric_from_message(&message) {
            Ok(values) => (values, None),
            Err(error) => (Vec::new(), Some(error)),
        },
        Err(error) => (Vec::new(), Some(error)),
    }
}

/// Query a signal expression and retry with `data(raw_expression)` when the
/// first result is empty or rejected by the server.
///
/// `size(expr)` is not a reliable validity check for every MDSplus datatype.
/// In particular, segmented and computed expressions can have a usable value
/// even when their size expression returns zero. The fallback mirrors the
/// original client's value/data retry and returns whether the fallback was
/// needed so callers can keep the X sampling stride consistent.
fn numeric_query_with_fallback(
    socket: &mut TcpStream,
    primary_expression: &str,
    fallback_expression: &str,
) -> (Vec<f64>, Option<String>, bool) {
    let (values, primary_error) = numeric_query(socket, primary_expression);
    if !values.is_empty() {
        return (values, primary_error, false);
    }

    let (fallback, fallback_error) = numeric_query(socket, fallback_expression);
    if !fallback.is_empty() {
        return (fallback, None, true);
    }

    (
        Vec::new(),
        fallback_error
            .or(primary_error)
            .or_else(|| Some("empty signal".into())),
        true,
    )
}

fn full_point_count_best_effort(socket: &mut TcpStream, expression: &str) -> usize {
    protocol::value(socket, &format!("size({expression})"))
        .ok()
        .and_then(|message| protocol::int_from_message(&message).ok())
        .filter(|count| *count > 0)
        .map_or(0, |count| count as usize)
}

fn configured_usize(names: &[&str], default_value: usize, min: usize, max: usize) -> usize {
    names
        .iter()
        .find_map(|name| {
            std::env::var(name)
                .ok()
                .and_then(|value| value.parse::<usize>().ok())
        })
        .unwrap_or(default_value)
        .clamp(min, max)
}

fn full_large_download_limit() -> usize {
    configured_usize(
        &[
            "MDSLENS_FULL_LARGE_LIMIT",
            "MDSSCOPE_FULL_LARGE_LIMIT",
            "WEBSCOPE_FULL_LARGE_LIMIT",
        ],
        DEFAULT_FULL_LARGE_DOWNLOAD_LIMIT,
        1,
        8,
    )
}

fn full_large_signal_point_threshold() -> usize {
    configured_usize(
        &[
            "MDSLENS_FULL_LARGE_POINTS",
            "MDSSCOPE_FULL_LARGE_POINTS",
            "WEBSCOPE_FULL_LARGE_POINTS",
        ],
        DEFAULT_FULL_LARGE_SIGNAL_POINTS,
        100_000,
        100_000_000,
    )
}

pub fn normalized_name(expr: &str) -> String {
    expr.trim().to_string()
}

fn populate_series_metadata(
    socket: &mut TcpStream,
    request: &FetchRequest,
    series: &mut SignalSeries,
) {
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

    let x_expr = if configured_x.is_empty() {
        format!("dim_of({})", y_expr)
    } else {
        configured_x.to_string()
    };
    let (raw_unit, raw_x_unit, raw_x_name) = query_series_metadata(socket, y_expr, &x_expr);
    series.unit = raw_unit
        .as_ref()
        .map(|unit| scaled_si_unit(unit, expression_numeric_scale(y_expr)))
        .unwrap_or_default();

    series.x_unit = raw_x_unit.clone().unwrap_or_default();
    // A dimension is often an anonymous RANGE/ARRAY rather than a named tree
    // node. Prefer the name returned by MDSplus, but retain the exact source
    // expression when no name exists instead of presenting a fabricated "x".
    series.x_name = raw_x_name
        .clone()
        .and_then(valid_axis_name)
        .unwrap_or_else(|| axis_expression_label(&x_expr));

    if raw_unit.is_some() || raw_x_unit.is_some() || raw_x_name.is_some() {
        signal_metadata_cache()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .insert(
                cache_key,
                SignalMetadata {
                    unit: series.unit.clone(),
                    x_name: series.x_name.clone(),
                    x_unit: series.x_unit.clone(),
                },
            );
    }
}

const METADATA_SEPARATOR: &str = "__MDSLENS_METADATA_SEPARATOR__";

fn query_series_metadata(
    socket: &mut TcpStream,
    y_expr: &str,
    x_expr: &str,
) -> (Option<String>, Option<String>, Option<String>) {
    // Metadata used to cost three serial network round trips per signal.
    let expression = format!(
        "if_error(trim(adjustl(units_of({y_expr}))),\"\")//\"{METADATA_SEPARATOR}\"//\
         if_error(trim(adjustl(units_of({x_expr}))),\"\")//\"{METADATA_SEPARATOR}\"//\
         if_error(trim(adjustl(name_of({x_expr}))),\"\")"
    );
    if let Some(value) = query_text(socket, &expression) {
        let fields: Vec<_> = value.split(METADATA_SEPARATOR).collect();
        if fields.len() == 3 {
            return (
                non_empty_text(fields[0]),
                non_empty_text(fields[1]),
                non_empty_text(fields[2]),
            );
        }
    }
    (
        query_text(socket, &format!("units_of({y_expr})")),
        query_text(socket, &format!("units_of({x_expr})")),
        query_text(socket, &format!("name_of({x_expr})")),
    )
}

fn non_empty_text(value: &str) -> Option<String> {
    let value = value.trim().trim_matches('"').trim();
    (!value.is_empty()).then(|| value.to_string())
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
        ("Y", 8),
        ("Z", 7),
        ("E", 6),
        ("P", 5),
        ("T", 4),
        ("G", 3),
        ("M", 2),
        ("k", 1),
        ("m", -1),
        ("u", -2),
        ("µ", -2),
        ("μ", -2),
        ("n", -3),
        ("p", -4),
        ("f", -5),
        ("a", -6),
        ("z", -7),
        ("y", -8),
    ];
    const BASE_UNITS: &[&str] = &[
        "mol", "kat", "rad", "bar", "Ohm", "Bq", "Gy", "Sv", "Hz", "Pa", "Wb", "eV", "lm", "lx",
        "sr", "Ω", "W", "J", "V", "A", "s", "g", "m", "K", "C", "N", "F", "S", "T", "H",
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
        .map_or_else(
            || unit.to_string(),
            |(prefix, _)| format!("{prefix}{base_unit}"),
        )
}

/// Per-signal read mode overrides global; falls back to global when not set.
pub fn effective_read_mode(
    global: DataReadMode,
    signal_mode: Option<DataReadMode>,
) -> DataReadMode {
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

    #[test]
    fn east_fast_path_rejects_other_trees_and_expressions() {
        let mut request = FetchRequest {
            loaded_index: 0,
            column: 0,
            row: 0,
            signal: 0,
            shot: "162651".into(),
            plot: PlotSpec::default(),
            sig: SignalSpec {
                experiment: "east".into(),
                y_expr: r"\IP".into(),
                ..Default::default()
            },
            read_mode: DataReadMode::Thin,
            max_points: 2000,
        };
        assert!(is_east_signal(&request));
        request.sig.experiment = "analysis".into();
        assert!(!is_east_signal(&request));
        request.sig.experiment = "east".into();
        request.sig.y_expr = r"data(\IP)".into();
        assert!(!is_east_signal(&request));
        request.sig.y_expr = r"\IP".into();
        request.shot = "44326".into();
        assert!(!is_east_signal(&request));
    }

    #[test]
    fn parses_scaled_simple_east_expressions() {
        assert_eq!(
            scaled_simple_signal_expr(r" -(\IP) / 1000 "),
            Some(ScaledSignalExpr {
                base_expr: r"\IP".into(),
                scale: -0.001,
            })
        );
        assert_eq!(
            scaled_simple_signal_expr(r"\DAU5*2.5"),
            Some(ScaledSignalExpr {
                base_expr: r"\DAU5".into(),
                scale: 2.5,
            })
        );
        assert!(scaled_simple_signal_expr(r"data(\IP)").is_none());
        assert!(scaled_simple_signal_expr(r"\IP/0").is_none());
    }

    #[test]
    fn reads_integer_frequency_without_reinterpreting_its_bits_as_float() {
        let frequency = Message {
            status: 1,
            length: 4,
            dtype: 8,
            body: 500_000i32.to_be_bytes().to_vec(),
        };
        let trigger = Message {
            status: 1,
            length: 8,
            dtype: 11,
            body: (-2.0f64).to_be_bytes().to_vec(),
        };
        let timebase = east_timebase_from_messages(&frequency, &trigger).unwrap();
        assert_eq!(timebase.start, -2.0);
        assert!((timebase.step - 0.000002).abs() < f64::EPSILON);
    }

    #[test]
    fn uniform_series_rejects_non_finite_timebases() {
        let series =
            series_from_values_uniform(r"\DAU5".into(), vec![1.0, 2.0], -2.0, f64::INFINITY);
        assert!(!series.has_data());
        assert_eq!(series.error, "invalid uniform timebase");
    }
}

pub fn sampling_from_point_count(total: usize, max_points: usize) -> SamplingPlan {
    if total == 0 || max_points == 0 {
        return SamplingPlan {
            source_count: total,
            step: 1,
            sampled_count: 0,
        };
    }
    let step = ((total as f64 / max_points as f64).ceil() as usize).max(1);
    let sampled_count = (total + step - 1) / step;
    SamplingPlan {
        source_count: total,
        step,
        sampled_count,
    }
}

/// Build a SignalSeries with uniform timebase.
fn series_from_msg_uniform(
    name: String,
    msg: &Message,
    start: f64,
    step: f64,
    _max: usize,
) -> SignalSeries {
    if !protocol::message_succeeded(msg) {
        return SignalSeries {
            name,
            error: protocol::message_error(msg),
            ..Default::default()
        };
    }
    match protocol::numeric_f32_from_message(msg) {
        Ok(values) => series_from_f32_values_uniform(name, values, start, step),
        Err(error) => SignalSeries {
            name,
            error,
            ..Default::default()
        },
    }
}

fn series_from_f32_values_uniform(
    name: String,
    values: Vec<f32>,
    start: f64,
    step: f64,
) -> SignalSeries {
    if !start.is_finite() || !step.is_finite() || step == 0.0 {
        return SignalSeries {
            name,
            error: "invalid uniform timebase".into(),
            ..Default::default()
        };
    }
    if values.is_empty() {
        return SignalSeries {
            name,
            error: "empty signal".into(),
            ..Default::default()
        };
    }

    let mut min_y = f32::INFINITY;
    let mut max_y = f32::NEG_INFINITY;
    for (index, &value) in values.iter().enumerate() {
        if index & 0x3fff == 0 && protocol::current_operation_canceled() {
            return canceled_series(name);
        }
        min_y = min_y.min(value);
        max_y = max_y.max(value);
    }

    SignalSeries {
        name,
        uniform_y: values,
        uniform_start: start,
        uniform_step: step,
        uniform_min_y: min_y as f64,
        uniform_max_y: max_y as f64,
        ..Default::default()
    }
}

fn series_from_values_uniform(
    name: String,
    values: Vec<f64>,
    start: f64,
    step: f64,
) -> SignalSeries {
    if !start.is_finite() || !step.is_finite() || step == 0.0 {
        return SignalSeries {
            name,
            error: "invalid uniform timebase".into(),
            ..Default::default()
        };
    }
    if values.is_empty() {
        return SignalSeries {
            name,
            error: "empty signal".into(),
            ..Default::default()
        };
    }

    let mut min_y = f64::INFINITY;
    let mut max_y = f64::NEG_INFINITY;
    let mut uniform_y = Vec::with_capacity(values.len());
    for (index, &value) in values.iter().enumerate() {
        if index & 0x3fff == 0 && protocol::current_operation_canceled() {
            return canceled_series(name);
        }
        if value < min_y {
            min_y = value;
        }
        if value > max_y {
            max_y = value;
        }
        uniform_y.push(value as f32);
    }

    SignalSeries {
        name,
        uniform_y,
        uniform_start: start,
        uniform_step: step,
        uniform_min_y: min_y,
        uniform_max_y: max_y,
        ..Default::default()
    }
}

fn series_from_values(name: String, y_values: Vec<f64>, x_values: Vec<f64>) -> SignalSeries {
    if y_values.is_empty() {
        return SignalSeries {
            name,
            error: "empty signal".into(),
            ..Default::default()
        };
    }
    let points = if x_values.is_empty() {
        let mut points = Vec::with_capacity(y_values.len());
        for (index, y) in y_values.into_iter().enumerate() {
            if index & 0x3fff == 0 && protocol::current_operation_canceled() {
                return canceled_series(name);
            }
            points.push([index as f64, y]);
        }
        points
    } else {
        let mut points = Vec::with_capacity(x_values.len().min(y_values.len()));
        for (index, (x, y)) in x_values.into_iter().zip(y_values).enumerate() {
            if index & 0x3fff == 0 && protocol::current_operation_canceled() {
                return canceled_series(name);
            }
            if x.is_finite() && y.is_finite() {
                points.push([x, y]);
            }
        }
        points
    };
    SignalSeries {
        name,
        points,
        ..Default::default()
    }
}

fn canceled_series(name: String) -> SignalSeries {
    SignalSeries {
        name,
        error: "operation canceled".into(),
        ..Default::default()
    }
}
