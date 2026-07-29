// SPDX-FileCopyrightText: 2026 MDSLens Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Concurrent fetch pipeline: grouping, wave-based dispatch, streaming callbacks, cancellation.
//!
//! Ported from `src/mds/mds_ip_client.cpp`.

use crate::client::{
    ensure_reusable_connections, reusable_connection_count, with_reusable_connection,
};
use crate::fetch::{self, effective_read_mode, FetchRequest, FetchResult};
use crate::protocol;
use mds_core::types::{DataReadMode, LayoutConfig, LoadedSignal, PlotSpec, SignalSpec};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};

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

        let (result_tx, result_rx) = mpsc::channel();
        let mut handles = Vec::new();
        for chunk in wave {
            let reqs: Vec<FetchRequest> = chunk.iter()
                .map(|&i| requests[i].clone()).collect();
            let cancel = cancel.clone();
            let result_tx = result_tx.clone();
            handles.push(std::thread::spawn(move || {
                if cancel.load(Ordering::Relaxed) { return Vec::new(); }
                fetch_chunk_serial_streaming(&reqs, &cancel, Some(&result_tx))
            }));
        }
        drop(result_tx);

        // Publish in completion order. A slow early chunk must not hold
        // already-finished panels behind its join.
        for fr in result_rx {
            let idx = fr.loaded_index;
            if should_stream_result(&fr) {
                callback(fetch_result_to_loaded(&requests, &fr));
            }
            if let Ok(mut res) = results.lock() {
                if idx < res.len() { res[idx] = Some(fr); }
            }
        }
        for handle in handles {
            let _ = handle.join();
        }
    }

    // Retry transient failures
    if !cancel.load(Ordering::Relaxed) {
        retry_transient(&requests, &results, callback, cancel);
    }

    // Return the current load immediately, then grow the hot pool for later
    // refreshes without delaying this result.
    let mut guard = results.lock().unwrap();
    let output = guard.iter_mut()
        .filter_map(Option::take)
        .map(|fr| fetch_result_into_loaded(&requests, fr))
        .collect();
    drop(guard);
    grow_hot_pool(&requests, &groups);
    output
}

/// Pre-connect to all unique servers in the layout.
pub fn warm_connections(config: &LayoutConfig, cancel: &Arc<AtomicBool>) {
    let mut servers: Vec<String> = config.columns.iter()
        .flat_map(|c| c.iter())
        .flat_map(|p| p.signal_specs.iter())
        .filter(|s| !s.server_ip.is_empty() && !s.is_hidden())
        .map(|s| s.server_ip.clone())
        .collect();
    servers.sort();
    servers.dedup();

    for server in servers {
        if cancel.load(Ordering::Relaxed) { break; }
        // Match the 16-worker fetch pipeline so the first large layout can
        // start on authenticated sockets instead of serializing cold setup
        // work behind its signal reads.
        ensure_reusable_connections(
            &server,
            protocol::MDS_PORT,
            MAX_GLOBAL_SOCKETS,
        );
    }
}

// ── Internal: chunk fetch ─────────────────────────────────────────────────

fn fetch_chunk_serial(
    requests: &[FetchRequest],
    cancel: &Arc<AtomicBool>,
) -> Vec<FetchResult> {
    fetch_chunk_serial_streaming(requests, cancel, None)
}

fn fetch_chunk_serial_streaming(
    requests: &[FetchRequest],
    cancel: &Arc<AtomicBool>,
    result_tx: Option<&mpsc::Sender<FetchResult>>,
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
                let mut transport_failed = false;
                for req in requests {
                    if cancel.load(Ordering::Relaxed) { break; }
                    let result = fetch::fetch_signal(&mut connection.stream, req);
                    let error = result.series.error.to_ascii_lowercase();
                    transport_failed |= error.contains("read error")
                        || error.contains("write error")
                        || error.contains("connection closed")
                        || error.contains("timed out");
                    if let Some(tx) = result_tx {
                        let _ = tx.send(result);
                    } else {
                        results.push(result);
                    }
                }
                let reusable =
                    !transport_failed && protocol::current_connection_reusable();
                (results, reusable)
            },
        );
        match fetched {
            Ok(results) => results,
            Err(e) => {
                if let Some(tx) = result_tx {
                    for req in requests {
                        let _ = tx.send(FetchResult {
                            loaded_index: req.loaded_index,
                            series: mds_core::types::SignalSeries {
                                name: fetch::normalized_name(&req.sig.y_expr),
                                error: e.clone(),
                                ..Default::default()
                            },
                        });
                    }
                    Vec::new()
                } else {
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

    // Retry genuine transient failures with bounded parallelism. Missing nodes
    // are permanent and must not delay every otherwise-complete panel.
    const MAX_RETRY_SOCKETS: usize = 8;
    for wave in to_retry.chunks(MAX_RETRY_SOCKETS) {
        if cancel.load(Ordering::Relaxed) { break; }
        let mut handles = Vec::with_capacity(wave.len());
        for &index in wave {
            let Some(request) = requests.get(index).cloned() else { continue };
            let cancel = cancel.clone();
            handles.push(std::thread::spawn(move || {
                fetch_chunk_serial(std::slice::from_ref(&request), &cancel)
            }));
        }
        for handle in handles {
            if let Ok(retried) = handle.join() {
                for fr in retried {
                    let idx = fr.loaded_index;
                    if should_stream_result(&fr) {
                        callback(fetch_result_to_loaded(requests, &fr));
                    }
                    if let Ok(mut res) = results.lock() {
                        if idx < res.len() { res[idx] = Some(fr); }
                    }
                }
            }
        }
    }
}

fn is_permanent_mds_error(error: &str) -> bool {
    let error = error.to_ascii_lowercase();
    error.contains("node not found")
        || error.contains("no data available")
        || error.contains("empty signal")
        || error.contains("missing server/tree/shot/signal")
        || error.contains("%tree-w-nnf")
        || error.contains("%tree-e-nodata")
}

fn should_stream_result(result: &FetchResult) -> bool {
    result.series.has_data()
        || (!result.series.error.is_empty()
            && is_permanent_mds_error(&result.series.error))
}

fn retry_indices(
    requests: &[FetchRequest],
    results: &[Option<FetchResult>],
) -> Vec<usize> {
    requests.iter()
        .filter_map(|request| {
            let needs_retry = results.get(request.loaded_index)
                .and_then(|result| result.as_ref())
                .is_none_or(|result| {
                    !result.series.has_data()
                        && !is_permanent_mds_error(&result.series.error)
                });
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
        let (heavy, normal): (Vec<usize>, Vec<usize>) = indices
            .iter()
            .copied()
            .partition(|&index| is_likely_heavy_signal(&requests[index].sig));
        if !heavy.is_empty() {
            let bucket_count = heavy.len().min(heavy_thin_connection_limit());
            let mut buckets = vec![Vec::new(); bucket_count];
            for (position, index) in heavy.into_iter().enumerate() {
                buckets[position % bucket_count].push(index);
            }
            chunks.extend(buckets.into_iter().filter(|bucket| !bucket.is_empty()));
        }
        if normal.is_empty() { continue; }

        let available =
            reusable_connection_count(&first.sig.server_ip, protocol::MDS_PORT).max(1);
        let desired = ((normal.len() + 1) / 2).clamp(1, 8);
        let hot_bucket_count = available.min(desired);
        let is_east = first.sig.experiment.trim().eq_ignore_ascii_case("east");

        // A cold handshake and TreeOpen cost more than saved-signal reads, so
        // a cold group starts on one socket. Reuse multiple sockets only when
        // the background pool has already made them hot.
        if hot_bucket_count > 1 {
            let mut buckets = vec![Vec::new(); hot_bucket_count];
            for (position, &index) in normal.iter().enumerate() {
                buckets[position % hot_bucket_count].push(index);
            }
            chunks.extend(buckets.into_iter().filter(|bucket| !bucket.is_empty()));
        } else if is_east && normal.len() > 16 {
            let bucket_count = if normal.len() > 48 {
                6
            } else if normal.len() > 32 {
                4
            } else {
                2
            };
            let mut buckets = vec![Vec::new(); bucket_count];
            for (position, &index) in normal.iter().enumerate() {
                buckets[position % bucket_count].push(index);
            }
            for bucket in buckets {
                if !bucket.is_empty() { chunks.push(bucket); }
            }
        } else {
            chunks.push(normal);
        }
    }
    chunks.sort_by(|a, b| {
        let a_heavy = chunk_has_likely_heavy_signal(requests, a);
        let b_heavy = chunk_has_likely_heavy_signal(requests, b);
        b_heavy.cmp(&a_heavy).then_with(|| b.len().cmp(&a.len()))
    });
    chunks
}

fn heavy_thin_connection_limit() -> usize {
    std::env::var("MDSLENS_HEAVY_THIN_CONNECTIONS")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(8)
        .clamp(1, 8)
}

fn is_likely_heavy_signal(signal: &SignalSpec) -> bool {
    signal.experiment.trim().eq_ignore_ascii_case("east")
        && fetch::normalized_name(&signal.y_expr)
            .trim_start_matches('\\')
            .to_ascii_lowercase()
            .starts_with("hrs")
}

fn chunk_has_likely_heavy_signal(requests: &[FetchRequest], chunk: &[usize]) -> bool {
    chunk.iter().any(|&index| {
        requests
            .get(index)
            .is_some_and(|request| is_likely_heavy_signal(&request.sig))
    })
}

fn grow_hot_pool(requests: &[FetchRequest], groups: &HashMap<String, Vec<usize>>) {
    let mut targets: HashMap<String, usize> = HashMap::new();
    for indices in groups.values() {
        let Some(first) = indices.first().and_then(|&index| requests.get(index)) else {
            continue;
        };
        let desired = ((indices.len() + 1) / 2).clamp(1, 8);
        targets
            .entry(first.sig.server_ip.clone())
            .and_modify(|target| *target = (*target).max(desired))
            .or_insert(desired);
    }
    for (server, target) in targets {
        if target <= reusable_connection_count(&server, protocol::MDS_PORT) {
            continue;
        }
        std::thread::spawn(move || {
            ensure_reusable_connections(&server, protocol::MDS_PORT, target);
        });
    }
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

fn fetch_result_into_loaded(requests: &[FetchRequest], fr: FetchResult) -> LoadedSignal {
    let req = &requests[fr.loaded_index];
    LoadedSignal {
        column: req.column, row: req.row, signal: req.signal,
        shot: req.shot.clone(), series: fr.series,
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
    fn heavy_east_signals_are_isolated_and_prioritized() {
        let mut config = make_test_config();
        config.columns[0][0].signal_specs = vec![
            SignalSpec { y_expr: "\\IP".into(), experiment: "east".into(), server_ip: "10.0.0.1".into(), ..Default::default() },
            SignalSpec { y_expr: "\\HRS01".into(), experiment: "east".into(), server_ip: "10.0.0.1".into(), ..Default::default() },
            SignalSpec { y_expr: "\\HRS02".into(), experiment: "east".into(), server_ip: "10.0.0.1".into(), ..Default::default() },
        ];
        let requests = build_requests(&config, DataReadMode::Thin);
        let groups = group_requests(&requests);
        let chunks = build_chunks(&requests, &groups);
        assert_eq!(chunks.len(), 3);
        assert!(chunk_has_likely_heavy_signal(&requests, &chunks[0]));
        assert!(chunk_has_likely_heavy_signal(&requests, &chunks[1]));
        assert!(!chunk_has_likely_heavy_signal(&requests, &chunks[2]));
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

    #[test]
    fn permanent_mds_errors_are_not_retried() {
        let requests = build_requests(&make_test_config(), DataReadMode::Thin);
        let missing = vec![Some(FetchResult {
            loaded_index: 0,
            series: mds_core::types::SignalSeries {
                error: "%TREE-W-NNF, Node not found".into(),
                ..Default::default()
            },
        })];
        assert!(retry_indices(&requests, &missing).is_empty());

        let empty = vec![Some(FetchResult {
            loaded_index: 0,
            series: mds_core::types::SignalSeries {
                error: "empty signal".into(),
                ..Default::default()
            },
        })];
        assert!(retry_indices(&requests, &empty).is_empty());
    }

    #[test]
    fn cold_ordinary_groups_start_on_one_connection() {
        let mut config = make_test_config();
        config.columns[0][0].signal_specs = (0..6)
            .map(|index| SignalSpec {
                y_expr: format!("\\signal_{index}"),
                experiment: "pcs_east".into(),
                server_ip: "test-cold-group.invalid".into(),
                ..Default::default()
            })
            .collect();
        let requests = build_requests(&config, DataReadMode::Thin);
        let chunks = build_chunks(&requests, &group_requests(&requests));
        assert_eq!(chunks.len(), 1);
        assert_eq!(chunks[0].len(), 6);
    }
}
