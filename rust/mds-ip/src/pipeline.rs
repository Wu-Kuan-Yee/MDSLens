// SPDX-FileCopyrightText: 2026 MdsScope Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Concurrent fetch pipeline: grouping, wave-based dispatch, streaming callbacks, cancellation.
//!
//! Ported from `src/mds/mds_ip_client.cpp`.

use crate::client::{with_reusable_connection, with_thread_local_pool};
use crate::fetch::{self, effective_read_mode, FetchRequest, FetchResult};
use crate::protocol;
use mds_core::types::{DataReadMode, LayoutConfig, LoadedSignal, PlotSpec, SignalSpec};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

/// Maximum concurrent chunks per wave.
const MAX_GLOBAL_SOCKETS: usize = 16;

pub type SignalCallback = Box<dyn Fn(LoadedSignal) + Send + Sync>;

// ── Public API ────────────────────────────────────────────────────────────

/// Fetch all non-hidden signals in a layout config.
///
/// Groups by `server|tree|shot`, dispatches in waves of ≤16 parallel chunks,
/// streams results via callback as each signal completes.
pub fn fetch_all(
    config: &LayoutConfig,
    read_mode: DataReadMode,
    callback: &SignalCallback,
    cancel: &Arc<AtomicBool>,
) -> Vec<LoadedSignal> {
    let requests = build_requests(config, read_mode);
    if requests.is_empty() {
        return Vec::new();
    }

    let n = requests.len();
    let results: Arc<Mutex<Vec<Option<FetchResult>>>> =
        Arc::new(Mutex::new(vec![None; n]));
    let groups = group_requests(&requests);
    let chunks = build_chunks(&requests, &groups);

    // Wave dispatch
    let mut next = 0usize;
    while next < chunks.len() && !cancel.load(Ordering::Relaxed) {
        let end = (next + MAX_GLOBAL_SOCKETS).min(chunks.len());
        let wave = &chunks[next..end];
        next = end;

        let mut handles = Vec::new();
        for chunk in wave {
            let reqs: Vec<FetchRequest> = chunk.iter()
                .map(|&i| requests[i].clone()).collect();
            let cancel = cancel.clone();
            handles.push(std::thread::spawn(move || {
                if cancel.load(Ordering::Relaxed) { return Vec::new(); }
                fetch_chunk_serial(&reqs, &cancel)
            }));
        }

        for handle in handles {
            if let Ok(chunk_results) = handle.join() {
                for fr in chunk_results {
                    let idx = fr.loaded_index;
                    let loaded = fetch_result_to_loaded(&requests, &fr);
                    callback(loaded);
                    if let Ok(mut res) = results.lock() {
                        if idx < res.len() { res[idx] = Some(fr); }
                    }
                }
            }
        }
    }

    // Retry transient failures
    if !cancel.load(Ordering::Relaxed) {
        retry_transient(&requests, &results, callback, cancel);
    }

    // Build final output
    let guard = results.lock().unwrap();
    guard.iter()
        .filter_map(|r| r.as_ref().map(|fr| fetch_result_to_loaded(&requests, fr)))
        .collect()
}

/// Pre-connect to all unique servers in the layout.
pub fn warm_connections(config: &LayoutConfig, cancel: &Arc<AtomicBool>) {
    let mut servers: Vec<&str> = config.columns.iter()
        .flat_map(|c| c.iter())
        .flat_map(|p| p.signal_specs.iter())
        .filter(|s| !s.server_ip.is_empty() && !s.is_hidden())
        .map(|s| s.server_ip.as_str())
        .collect();
    servers.sort();
    servers.dedup();

    for server in &servers {
        if cancel.load(Ordering::Relaxed) { break; }
        with_thread_local_pool(|pool| {
            let _ = pool.get_or_connect(server, protocol::MDS_PORT, "", "");
        });
    }
}

// ── Internal: chunk fetch ─────────────────────────────────────────────────

fn fetch_chunk_serial(
    requests: &[FetchRequest],
    cancel: &Arc<AtomicBool>,
) -> Vec<FetchResult> {
    if requests.is_empty() { return Vec::new(); }

    let first = &requests[0];
    let host = &first.sig.server_ip;
    let tree = &first.sig.experiment;
    let shot = effective_shot(&first.plot, &first.sig);

    let preserve_connection = requests.iter()
        .all(|request| request.read_mode != DataReadMode::Full);
    protocol::with_cancel_context(cancel.clone(), preserve_connection, || {
        let fetched = with_reusable_connection(
            host,
            protocol::MDS_PORT,
            tree,
            &shot,
            |connection| {
                let mut results = Vec::with_capacity(requests.len());
                for req in requests {
                    if cancel.load(Ordering::Relaxed) { break; }
                    results.push(fetch::fetch_signal(&mut connection.stream, req));
                }
                let canceled = cancel.load(Ordering::Acquire);
                let transport_failed = results.iter().any(|result| {
                    let error = result.series.error.to_ascii_lowercase();
                    error.contains("read error")
                        || error.contains("write error")
                        || error.contains("connection closed")
                        || error.contains("timed out")
                });
                let reusable = !transport_failed && (!canceled || preserve_connection);
                (results, reusable)
            },
        );
        match fetched {
            Ok(results) => results,
            Err(e) => {
                requests.iter().map(|req| FetchResult {
                    loaded_index: req.loaded_index,
                    series: mds_core::types::SignalSeries {
                        name: fetch::normalized_name(&req.sig.y_expr),
                        error: e.clone(),
                        ..Default::default()
                    },
                }).collect()
            }
        }
    })
}

// ── Internal: retry ───────────────────────────────────────────────────────

fn retry_transient(
    requests: &[FetchRequest],
    results: &Arc<Mutex<Vec<Option<FetchResult>>>>,
    callback: &SignalCallback,
    cancel: &Arc<AtomicBool>,
) {
    let to_retry = retry_indices(requests, &results.lock().unwrap());

    if to_retry.is_empty() { return; }

    // The first wave deliberately opens several connections for speed, but
    // mobile SSH relays and some MDS servers can temporarily reject that
    // burst. Retry every no-data result serially with its own server/tree/shot.
    for index in to_retry {
        if cancel.load(Ordering::Relaxed) { break; }
        let Some(request) = requests.get(index) else { continue };
        for fr in fetch_chunk_serial(std::slice::from_ref(request), cancel) {
            let idx = fr.loaded_index;
            let loaded = fetch_result_to_loaded(requests, &fr);
            callback(loaded);
            if let Ok(mut res) = results.lock() {
                if idx < res.len() { res[idx] = Some(fr); }
            }
        }
    }
}

fn retry_indices(
    requests: &[FetchRequest],
    results: &[Option<FetchResult>],
) -> Vec<usize> {
    requests.iter()
        .filter_map(|request| {
            let needs_retry = results.get(request.loaded_index)
                .and_then(|result| result.as_ref())
                .is_none_or(|result| !result.series.has_data());
            needs_retry.then_some(request.loaded_index)
        })
        .collect()
}

// ── Internal: request building ────────────────────────────────────────────

fn build_requests(config: &LayoutConfig, read_mode: DataReadMode) -> Vec<FetchRequest> {
    let mut requests = Vec::new();
    let mut index = 0usize;

    for (col, column) in config.columns.iter().enumerate() {
        for (row, plot) in column.iter().enumerate() {
            for (sig_idx, sig) in plot.signal_specs.iter().enumerate() {
                if sig.is_hidden() { continue; }
                let mode = effective_read_mode(read_mode, sig.read_mode);
                let max_pts = match mode {
                    DataReadMode::Thin => plot.extraction_points.max(1) as usize,
                    DataReadMode::Medium => (plot.extraction_points * 2).max(1) as usize,
                    DataReadMode::Full => usize::MAX,
                };

                requests.push(FetchRequest {
                    loaded_index: index,
                    column: col as i32, row: row as i32, signal: sig_idx as i32,
                    shot: effective_shot(plot, sig),
                    plot: plot.clone(), sig: sig.clone(),
                    read_mode: mode, max_points: max_pts,
                });
                index += 1;
            }
        }
    }
    requests
}

fn group_requests(requests: &[FetchRequest]) -> HashMap<String, Vec<usize>> {
    let mut groups: HashMap<String, Vec<usize>> = HashMap::new();
    for (i, req) in requests.iter().enumerate() {
        let key = format!("{}|{}|{}", req.sig.server_ip, req.sig.experiment, req.shot);
        groups.entry(key).or_default().push(i);
    }
    groups
}

fn build_chunks(requests: &[FetchRequest], groups: &HashMap<String, Vec<usize>>) -> Vec<Vec<usize>> {
    let mut chunks: Vec<Vec<usize>> = Vec::new();
    for indices in groups.values() {
        let first = &requests[indices[0]];
        let is_east = !first.shot.is_empty() && first.sig.x_expr.trim().is_empty();
        // Split groups for parallelism: each chunk uses 1 connection serially
        // More chunks = more parallel connections = faster fetch
        if indices.len() >= 2 && is_east {
            let n = ((indices.len() + 1) / 2).min(8); // 1-2 signals per chunk, max 8 chunks
            let size = (indices.len() + n - 1) / n;
            for bucket in indices.chunks(size) {
                chunks.push(bucket.to_vec());
            }
        } else {
            chunks.push(indices.clone());
        }
    }
    chunks.sort_by_key(|c| -(c.len() as isize)); // largest first
    chunks
}

// ── Helpers ───────────────────────────────────────────────────────────────

fn effective_shot(plot: &PlotSpec, sig: &SignalSpec) -> String {
    if !sig.shot.trim().is_empty() { sig.shot.clone() }
    else { plot.shot.clone() }
}

fn fetch_result_to_loaded(requests: &[FetchRequest], fr: &FetchResult) -> LoadedSignal {
    let req = &requests[fr.loaded_index];
    LoadedSignal {
        column: req.column, row: req.row, signal: req.signal,
        shot: req.shot.clone(), series: fr.series.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_test_config() -> LayoutConfig {
        let plot = PlotSpec {
            title: "Test".into(),
            extraction_points: 2000, grid: true,
            signal_specs: vec![SignalSpec {
                y_expr: "\\test".into(), experiment: "t".into(),
                server_ip: "127.0.0.1".into(), ..Default::default()
            }],
            ..Default::default()
        };
        LayoutConfig { columns: vec![vec![plot]], ..Default::default() }
    }

    #[test]
    fn test_build_requests_basic() {
        let config = make_test_config();
        let requests = build_requests(&config, DataReadMode::Thin);
        assert_eq!(requests.len(), 1);
        assert_eq!(requests[0].read_mode, DataReadMode::Thin);
        assert_eq!(requests[0].max_points, 2000);
    }

    #[test]
    fn test_build_requests_hidden_skipped() {
        let mut config = make_test_config();
        config.columns[0][0].signal_specs = vec![
            SignalSpec { y_expr: "\\a".into(), experiment: "t".into(), server_ip: "1.1.1.1".into(), hidden: true, ..Default::default() },
            SignalSpec { y_expr: "\\b".into(), experiment: "t".into(), server_ip: "1.1.1.1".into(), ..Default::default() },
        ];
        assert_eq!(build_requests(&config, DataReadMode::Thin).len(), 1);
    }

    #[test]
    fn test_group_and_chunk() {
        let mut config = make_test_config();
        config.columns[0][0].signal_specs = vec![
            SignalSpec { y_expr: "\\a".into(), experiment: "t1".into(), server_ip: "10.0.0.1".into(), ..Default::default() },
            SignalSpec { y_expr: "\\b".into(), experiment: "t2".into(), server_ip: "10.0.0.2".into(), ..Default::default() },
        ];
        let requests = build_requests(&config, DataReadMode::Thin);
        let groups = group_requests(&requests);
        assert_eq!(groups.len(), 2);
        let chunks = build_chunks(&requests, &groups);
        assert_eq!(chunks.len(), 2);
    }

    #[test]
    fn test_effective_read_mode() {
        // Per-signal always overrides global when set
        assert_eq!(effective_read_mode(DataReadMode::Thin, Some(DataReadMode::Full)), DataReadMode::Full);
        assert_eq!(effective_read_mode(DataReadMode::Full, Some(DataReadMode::Thin)), DataReadMode::Thin);
        assert_eq!(effective_read_mode(DataReadMode::Medium, Some(DataReadMode::Full)), DataReadMode::Full);
        // No per-signal → global default
        assert_eq!(effective_read_mode(DataReadMode::Thin, None), DataReadMode::Thin);
        assert_eq!(effective_read_mode(DataReadMode::Full, None), DataReadMode::Full);
        // Equal modes
        assert_eq!(effective_read_mode(DataReadMode::Medium, Some(DataReadMode::Medium)), DataReadMode::Medium);
    }

    #[test]
    fn retry_candidates_include_errors_and_missing_results() {
        let requests = build_requests(&make_test_config(), DataReadMode::Thin);
        let errored = vec![Some(FetchResult {
            loaded_index: 0,
            series: mds_core::types::SignalSeries {
                error: "temporary connection failure".into(),
                ..Default::default()
            },
        })];
        assert_eq!(retry_indices(&requests, &errored), vec![0]);
        assert_eq!(retry_indices(&requests, &[None]), vec![0]);

        let loaded = vec![Some(FetchResult {
            loaded_index: 0,
            series: mds_core::types::SignalSeries {
                points: vec![[0.0, 1.0]],
                ..Default::default()
            },
        })];
        assert!(retry_indices(&requests, &loaded).is_empty());
    }
}
