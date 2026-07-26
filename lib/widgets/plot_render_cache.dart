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
  final double? minX;
  final double? maxX;
  final PlotSeriesRenderData renderData;

  const _CacheEntry({
    required this.points,
    required this.pointCount,
    required this.maxPoints,
    required this.minX,
    required this.maxX,
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

  PlotSeriesRenderData render(
    SeriesData series, {
    int maxPoints = 2000,
    double? minX,
    double? maxX,
  }) {
    final points = series.points;
    if (points == null || points.isEmpty) {
      throw ArgumentError.value(points, 'series.points', 'must not be empty');
    }

    final existing = _entries[series];
    if (existing != null &&
        identical(existing.points, points) &&
        existing.pointCount == points.length &&
        existing.maxPoints == maxPoints &&
        existing.minX == minX &&
        existing.maxX == maxX) {
      return existing.renderData;
    }

    final visible = _visibleRange(points, minX, maxX);
    final spots = _decimate(points, maxPoints, visible.$1, visible.$2);
    var renderedMinX = spots.first.x;
    var renderedMaxX = spots.first.x;
    var minY = spots.first.y;
    var maxY = spots.first.y;
    for (var i = 1; i < spots.length; i++) {
      final spot = spots[i];
      if (spot.x < renderedMinX) renderedMinX = spot.x;
      if (spot.x > renderedMaxX) renderedMaxX = spot.x;
      if (spot.y < minY) minY = spot.y;
      if (spot.y > maxY) maxY = spot.y;
    }

    final renderData = PlotSeriesRenderData(
      spots: spots,
      minX: renderedMinX,
      maxX: renderedMaxX,
      minY: minY,
      maxY: maxY,
    );
    _entries[series] = _CacheEntry(
      points: points,
      pointCount: points.length,
      maxPoints: maxPoints,
      minX: minX,
      maxX: maxX,
      renderData: renderData,
    );
    return renderData;
  }

  void retain(Iterable<SeriesData> activeSeries) {
    final active = HashSet<SeriesData>.identity()..addAll(activeSeries);
    _entries.removeWhere((series, _) => !active.contains(series));
  }

  (int, int) _visibleRange(
    List<List<double>> points,
    double? minX,
    double? maxX,
  ) {
    if (minX == null ||
        maxX == null ||
        !minX.isFinite ||
        !maxX.isFinite ||
        minX >= maxX ||
        points.length < 2) {
      return (0, points.length);
    }
    final ascending = points.first[0] <= points.last[0];
    bool before(double value) => ascending ? value < minX : value > maxX;
    bool through(double value) => ascending ? value <= maxX : value >= minX;

    var low = 0;
    var high = points.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (before(points[middle][0])) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    final start = (low - 1).clamp(0, points.length - 1);
    low = start;
    high = points.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (through(points[middle][0])) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    final end = (low + 1).clamp(start + 1, points.length);
    return (start, end);
  }

  List<FlSpot> _decimate(
    List<List<double>> points,
    int maxPoints,
    int rangeStart,
    int rangeEnd,
  ) {
    final count = rangeEnd - rangeStart;
    if (count <= maxPoints) {
      return List<FlSpot>.unmodifiable(
        points
            .getRange(rangeStart, rangeEnd)
            .map((point) => FlSpot(point[0], point[1])),
      );
    }

    final buckets = (maxPoints / 2).ceil().clamp(1, count);
    final spots = <FlSpot>[];
    for (var bucket = 0; bucket < buckets; bucket++) {
      final start = rangeStart + bucket * count ~/ buckets;
      final end = (rangeStart + (bucket + 1) * count ~/ buckets)
          .clamp(rangeStart, rangeEnd);
      if (start >= end) continue;

      var minY = double.infinity;
      var maxY = double.negativeInfinity;
      for (var i = start; i < end; i++) {
        if (points[i][1] < minY) minY = points[i][1];
        if (points[i][1] > maxY) maxY = points[i][1];
      }
      final x = bucket == 0
          ? points[rangeStart][0]
          : bucket == buckets - 1
              ? points[rangeEnd - 1][0]
              : (points[start][0] + points[end - 1][0]) / 2;
      spots.add(FlSpot(x, minY));
      if (minY != maxY) spots.add(FlSpot(x, maxY));
    }
    return List<FlSpot>.unmodifiable(spots);
  }
}
