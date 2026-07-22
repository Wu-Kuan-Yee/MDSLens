import 'dart:collection';

import 'package:fl_chart/fl_chart.dart';

import '../models/app_state.dart';

/// Immutable geometry derived from one waveform series for chart rendering.
class PlotSeriesRenderData {
  final List<FlSpot> spots;
  final double minX;
  final double maxX;
  final double minY;
  final double maxY;

  const PlotSeriesRenderData({
    required this.spots,
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
  });
}

class _CacheEntry {
  final List<List<double>> points;
  final int pointCount;
  final int maxPoints;
  final PlotSeriesRenderData renderData;

  const _CacheEntry({
    required this.points,
    required this.pointCount,
    required this.maxPoints,
    required this.renderData,
  });
}

/// Retains expensive MinMax decimation results while a series is unchanged.
///
/// Crosshair and theme notifications rebuild every visible plot. Waveforms are
/// replaced, rather than mutated, when a fetch completes, so identity plus the
/// point count is a cheap cache key for normal application use.
class PlotRenderCache {
  final Map<SeriesData, _CacheEntry> _entries =
      HashMap<SeriesData, _CacheEntry>.identity();

  PlotSeriesRenderData render(SeriesData series, {int maxPoints = 2000}) {
    final points = series.points;
    if (points == null || points.isEmpty) {
      throw ArgumentError.value(points, 'series.points', 'must not be empty');
    }

    final existing = _entries[series];
    if (existing != null &&
        identical(existing.points, points) &&
        existing.pointCount == points.length &&
        existing.maxPoints == maxPoints) {
      return existing.renderData;
    }

    final spots = _decimate(points, maxPoints);
    var minX = spots.first.x;
    var maxX = spots.first.x;
    var minY = spots.first.y;
    var maxY = spots.first.y;
    for (var i = 1; i < spots.length; i++) {
      final spot = spots[i];
      if (spot.x < minX) minX = spot.x;
      if (spot.x > maxX) maxX = spot.x;
      if (spot.y < minY) minY = spot.y;
      if (spot.y > maxY) maxY = spot.y;
    }

    final renderData = PlotSeriesRenderData(
      spots: spots,
      minX: minX,
      maxX: maxX,
      minY: minY,
      maxY: maxY,
    );
    _entries[series] = _CacheEntry(
      points: points,
      pointCount: points.length,
      maxPoints: maxPoints,
      renderData: renderData,
    );
    return renderData;
  }

  void retain(Iterable<SeriesData> activeSeries) {
    final active = HashSet<SeriesData>.identity()..addAll(activeSeries);
    _entries.removeWhere((series, _) => !active.contains(series));
  }

  List<FlSpot> _decimate(List<List<double>> points, int maxPoints) {
    if (points.length <= maxPoints) {
      return List<FlSpot>.unmodifiable(
        points.map((point) => FlSpot(point[0], point[1])),
      );
    }

    final buckets = (maxPoints / 2).ceil().clamp(1, points.length);
    final spots = <FlSpot>[];
    for (var bucket = 0; bucket < buckets; bucket++) {
      final start = bucket * points.length ~/ buckets;
      final end =
          ((bucket + 1) * points.length ~/ buckets).clamp(0, points.length);
      if (start >= end) continue;

      var minY = double.infinity;
      var maxY = double.negativeInfinity;
      for (var i = start; i < end; i++) {
        if (points[i][1] < minY) minY = points[i][1];
        if (points[i][1] > maxY) maxY = points[i][1];
      }
      final x = bucket == 0
          ? points.first[0]
          : bucket == buckets - 1
              ? points.last[0]
              : (points[start][0] + points[end - 1][0]) / 2;
      spots.add(FlSpot(x, minY));
      if (minY != maxY) spots.add(FlSpot(x, maxY));
    }
    return List<FlSpot>.unmodifiable(spots);
  }
}
