// SPDX-FileCopyrightText: 2026 MdsScope Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Concurrent fetch pipeline: grouping, wave-based dispatch, streaming callbacks, cancellation.
//!
//! Ported from `src/mds/mds_ip_client.cpp`.

use crate::client::with_thread_local_pool;
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
        .filter(|s| !s.server_ip.is_empty() && !s.hidden)
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

    with_thread_local_pool(|pool| {
        let conn = match pool.get_or_connect(host, protocol::MDS_PORT, tree, &shot) {
            Ok(c) => c,
            Err(e) => {
                return requests.iter().map(|req| FetchResult {
                    loaded_index: req.loaded_index,
                    series: mds_core::types::SignalSeries {
                        name: fetch::normalized_name(&req.sig.y_expr),
                        error: e.clone(),
                        ..Default::default()
                    },
                }).collect();
            }
        };

        let mut results = Vec::with_capacity(requests.len());
        for req in requests {
            if cancel.load(Ordering::Relaxed) { break; }
            results.push(fetch::fetch_signal(&mut conn.stream, req));
        }
        results
    })
}

// ── Internal: retry ───────────────────────────────────────────────────────

fn retry_transient(
    requests: &[FetchRequest],
    results: &Arc<Mutex<Vec<Option<FetchResult>>>>,
    callback: &SignalCallback,
    cancel: &Arc<AtomicBool>,
) {
    let to_retry: Vec<usize> = {
        let res = results.lock().unwrap();
        requests.iter()
            .filter_map(|req| {
                res.get(req.loaded_index).and_then(|r| r.as_ref()).map(|fr| {
                    if !fr.series.has_data() && fr.series.error.is_empty()
                        { Some(req.loaded_index) } else { None }
                })
            })
            .flatten()
            .collect()
    };

    if to_retry.is_empty() { return; }

    for batch in to_retry.chunks(8) {
        if cancel.load(Ordering::Relaxed) { break; }
        let reqs: Vec<FetchRequest> = batch.iter()
            .filter_map(|&i| requests.get(i).cloned())
            .collect();
        for fr in fetch_chunk_serial(&reqs, cancel) {
            let idx = fr.loaded_index;
            let loaded = fetch_result_to_loaded(requests, &fr);
            callback(loaded);
            if let Ok(mut res) = results.lock() {
                if idx < res.len() { res[idx] = Some(fr); }
            }
        }
    }
}

// ── Internal: request building ────────────────────────────────────────────

fn build_requests(config: &LayoutConfig, read_mode: DataReadMode) -> Vec<FetchRequest> {
    let mut requests = Vec::new();
    let mut index = 0usize;

    for (col, column) in config.columns.iter().enumerate() {
        for (row, plot) in column.iter().enumerate() {
            for (sig_idx, sig) in plot.signal_specs.iter().enumerate() {
                if sig.hidden { continue; }
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
}
