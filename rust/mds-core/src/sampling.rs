// SPDX-FileCopyrightText: 2026 MdsScope Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Signal data sampling and downsampling algorithms.

use crate::types::SignalSeries;

/// Build a MinMax block index for O(1) range queries.
///
/// Divides the uniform data into blocks of `block_size` points,
/// precomputing min/max per block to accelerate view-range queries.
///
/// Ported from the C++ min-max index construction logic.
pub fn build_min_max_index(series: &mut SignalSeries, block_size: usize) {
    if !series.has_uniform_data() || block_size == 0 {
        return;
    }

    let n = series.uniform_y.len();
    let num_blocks = (n + block_size - 1) / block_size;

    series.min_y_blocks = Vec::with_capacity(num_blocks);
    series.max_y_blocks = Vec::with_capacity(num_blocks);
    series.min_max_block_size = block_size;

    for block in 0..num_blocks {
        let start = block * block_size;
        let end = (start + block_size).min(n);
        let slice = &series.uniform_y[start..end];

        let (min, max) = slice.iter().fold((f32::INFINITY, f32::NEG_INFINITY), |(min, max), &v| {
            (min.min(v), max.max(v))
        });

        series.min_y_blocks.push(min);
        series.max_y_blocks.push(max);
    }

    // Update cached overall min/max
    series.uniform_min_y = series.min_y_blocks.iter().fold(f32::INFINITY, |a, &b| a.min(b)) as f64;
    series.uniform_max_y = series.max_y_blocks.iter().fold(f32::NEG_INFINITY, |a, &b| a.max(b)) as f64;
}

/// Compute sampling step from total point count and target max points.
/// Ported from `samplingFromPointCount()`.
pub fn sampling_from_point_count(total_points: usize, max_points: usize) -> SamplingPlan {
    if total_points == 0 || max_points == 0 {
        return SamplingPlan {
            source_count: total_points,
            step: 1,
            sampled_count: 0,
        };
    }

    let step = (total_points as f64 / max_points as f64).ceil() as usize;
    let step = step.max(1);
    let sampled_count = (total_points + step - 1) / step;

    SamplingPlan {
        source_count: total_points,
        step,
        sampled_count,
    }
}

#[derive(Debug, Clone)]
pub struct SamplingPlan {
    pub source_count: usize,
    pub step: usize,
    pub sampled_count: usize,
}

/// Perform MinMax downsampling on a series to fit within a pixel budget.
///
/// Each bucket covers approximately `points_per_bucket` raw data points.
/// The min and max Y value in each bucket is kept (max 2 points per bucket),
/// ensuring that spikes and outliers remain visible even after downsampling.
///
/// Ported from `display_points_for_series()` MinMax logic.
pub fn min_max_downsample_uniform(
    series: &SignalSeries,
    start_index: usize,
    end_index: usize,
    target_points: usize,
) -> Vec<[f64; 2]> {
    let visible_count = end_index.saturating_sub(start_index).saturating_add(1);
    if visible_count == 0 {
        return Vec::new();
    }

    // If the view is zoomed in enough, return all points
    if visible_count <= target_points {
        let mut out = Vec::with_capacity(visible_count);
        for i in start_index..=end_index {
            if let Some(pt) = series.point_at(i) {
                out.push(pt);
            }
        }
        return out;
    }

    let buckets = (target_points / 2).max(1);
    let mut out = Vec::with_capacity(buckets * 2);

    for b in 0..buckets {
        let bucket_start = start_index + (b as u64 * visible_count as u64 / buckets as u64) as usize;
        let bucket_end = start_index + ((b + 1) as u64 * visible_count as u64 / buckets as u64) as usize;

        if bucket_end <= bucket_start {
            continue;
        }

        let range = bucket_start..bucket_end.min(series.point_count());

        let (min_idx, max_idx) = find_min_max_in_range(series, range);

        if min_idx == max_idx {
            if let Some(pt) = series.point_at(min_idx) {
                out.push(pt);
            }
        } else if min_idx < max_idx {
            if let Some(pt) = series.point_at(min_idx) { out.push(pt); }
            if let Some(pt) = series.point_at(max_idx) { out.push(pt); }
        } else {
            if let Some(pt) = series.point_at(max_idx) { out.push(pt); }
            if let Some(pt) = series.point_at(min_idx) { out.push(pt); }
        }
    }

    out
}

fn find_min_max_in_range(series: &SignalSeries, range: std::ops::Range<usize>) -> (usize, usize) {
    let start = range.start;
    let end = range.end;

    if start >= end {
        return (start, start);
    }

    let mut min_idx = start;
    let mut max_idx = start;
    let mut min_val = f64::INFINITY;
    let mut max_val = f64::NEG_INFINITY;

    for i in start..end.min(series.point_count()) {
        if let Some([_, y]) = series.point_at(i) {
            if y < min_val { min_val = y; min_idx = i; }
            if y > max_val { max_val = y; max_idx = i; }
        }
    }

    (min_idx, max_idx)
}
