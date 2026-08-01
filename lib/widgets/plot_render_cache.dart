import 'dart:collection';

import 'package:fl_chart/fl_chart.dart';

import '../models/app_state.dart';

int plotRenderPointBudget(double logicalWidth) {
  if (!logicalWidth.isFinite || logicalWidth <= 0) return 256;
  return (logicalWidth * 2).round().clamp(256, 2000);
}

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
  final Object source;
  final int pointCount;
  final int maxPoints;
  final double? minX;
  final double? maxX;
  final PlotSeriesRenderData renderData;

  const _CacheEntry({
    required this.source,
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
    final interleaved = series.interleavedPoints;
    final uniform = series.uniformY;
    final source = points?.isNotEmpty == true
        ? points!
        : interleaved?.isNotEmpty == true
            ? interleaved!
            : uniform;
    if (source == null || series.pointCount == 0) {
      throw ArgumentError.value(source, 'series', 'must not be empty');
    }

    final existing = _entries[series];
    if (existing != null &&
        identical(existing.source, source) &&
        existing.pointCount == series.pointCount &&
        existing.maxPoints == maxPoints &&
        existing.minX == minX &&
        existing.maxX == maxX) {
      return existing.renderData;
    }

    final (int, int) visible;
    final List<FlSpot> spots;
    if (points?.isNotEmpty == true) {
      visible = _visibleRange(points!, minX, maxX);
      spots = _decimate(points, maxPoints, visible.$1, visible.$2);
    } else if (interleaved?.isNotEmpty == true) {
      visible = _visibleInterleavedRange(series, minX, maxX);
      spots = _decimateInterleaved(
        series,
        maxPoints,
        visible.$1,
        visible.$2,
      );
    } else {
      visible = _visibleUniformRange(series, minX, maxX);
      spots = _decimateUniform(series, maxPoints, visible.$1, visible.$2);
    }
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
      source: source,
      pointCount: series.pointCount,
      maxPoints: maxPoints,
      minX: minX,
      maxX: maxX,
      renderData: renderData,
    );
    return renderData;
  }

  (int, int) _visibleInterleavedRange(
    SeriesData series,
    double? minX,
    double? maxX,
  ) {
    final count = series.pointCount;
    if (minX == null ||
        maxX == null ||
        !minX.isFinite ||
        !maxX.isFinite ||
        minX >= maxX ||
        count < 2) {
      return (0, count);
    }
    final ascending = series.pointXAt(0) <= series.pointXAt(count - 1);
    bool before(double value) => ascending ? value < minX : value > maxX;
    bool through(double value) => ascending ? value <= maxX : value >= minX;

    var low = 0;
    var high = count;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (before(series.pointXAt(middle))) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    final start = (low - 1).clamp(0, count - 1);
    low = start;
    high = count;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (through(series.pointXAt(middle))) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return (start, (low + 1).clamp(start + 1, count));
  }

  List<FlSpot> _decimateInterleaved(
    SeriesData series,
    int maxPoints,
    int rangeStart,
    int rangeEnd,
  ) {
    final count = rangeEnd - rangeStart;
    if (count <= maxPoints) {
      return List<FlSpot>.unmodifiable(
        List<FlSpot>.generate(count, (offset) {
          final index = rangeStart + offset;
          return FlSpot(series.pointXAt(index), series.pointYAt(index));
        }, growable: false),
      );
    }

    final buckets = (maxPoints / 2).ceil().clamp(1, count);
    final spots = <FlSpot>[];
    for (var bucket = 0; bucket < buckets; bucket++) {
      final start = rangeStart + bucket * count ~/ buckets;
      final end = (rangeStart + (bucket + 1) * count ~/ buckets).clamp(
        rangeStart,
        rangeEnd,
      );
      if (start >= end) continue;
      var minY = double.infinity;
      var maxY = double.negativeInfinity;
      for (var index = start; index < end; index++) {
        final y = series.pointYAt(index);
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
      final x = bucket == 0
          ? series.pointXAt(rangeStart)
          : bucket == buckets - 1
              ? series.pointXAt(rangeEnd - 1)
              : (series.pointXAt(start) + series.pointXAt(end - 1)) / 2;
      spots.add(FlSpot(x, minY));
      if (minY != maxY) spots.add(FlSpot(x, maxY));
    }
    return List<FlSpot>.unmodifiable(spots);
  }

  (int, int) _visibleUniformRange(
    SeriesData series,
    double? minX,
    double? maxX,
  ) {
    final count = series.uniformY!.length;
    if (minX == null ||
        maxX == null ||
        !minX.isFinite ||
        !maxX.isFinite ||
        minX >= maxX ||
        count < 2) {
      return (0, count);
    }
    final step = series.uniformStep;
    final first = ((minX - series.uniformStart) / step).floor();
    final last = ((maxX - series.uniformStart) / step).ceil();
    if (step > 0) {
      return (
        (first - 1).clamp(0, count - 1),
        (last + 2).clamp(1, count),
      );
    }
    return (
      (last - 1).clamp(0, count - 1),
      (first + 2).clamp(1, count),
    );
  }

  List<FlSpot> _decimateUniform(
    SeriesData series,
    int maxPoints,
    int rangeStart,
    int rangeEnd,
  ) {
    final values = series.uniformY!;
    final count = rangeEnd - rangeStart;
    double xAt(int index) => series.uniformStart + index * series.uniformStep;
    if (count <= maxPoints) {
      return List<FlSpot>.unmodifiable(
        List<FlSpot>.generate(
          count,
          (offset) {
            final index = rangeStart + offset;
            return FlSpot(xAt(index), values[index]);
          },
          growable: false,
        ),
      );
    }

    final buckets = (maxPoints / 2).ceil().clamp(1, count);
    final spots = <FlSpot>[];
    for (var bucket = 0; bucket < buckets; bucket++) {
      final start = rangeStart + bucket * count ~/ buckets;
      final end = (rangeStart + (bucket + 1) * count ~/ buckets).clamp(
        rangeStart,
        rangeEnd,
      );
      if (start >= end) continue;
      var minY = double.infinity;
      var maxY = double.negativeInfinity;

      void consider(double value) {
        if (!value.isFinite) return;
        if (value < minY) minY = value;
        if (value > maxY) maxY = value;
      }

      final indexedMin = series.minYBlocks;
      final indexedMax = series.maxYBlocks;
      final blockSize = series.minMaxBlockSize;
      var index = start;
      if (indexedMin != null &&
          indexedMax != null &&
          indexedMin.length == indexedMax.length &&
          blockSize > 0) {
        // Scan only the two partial edge blocks and use the precomputed
        // extrema for complete blocks. This keeps the first Full render from
        // walking millions of samples on Flutter's UI isolate.
        while (index < end && index % blockSize != 0) {
          consider(values[index].toDouble());
          index++;
        }
        while (index + blockSize <= end) {
          final block = index ~/ blockSize;
          if (block >= indexedMin.length) {
            for (var offset = 0; offset < blockSize; offset++) {
              consider(values[index + offset].toDouble());
            }
          } else {
            consider(indexedMin[block].toDouble());
            consider(indexedMax[block].toDouble());
          }
          index += blockSize;
        }
      }
      while (index < end) {
        consider(values[index].toDouble());
        index++;
      }
      final x = bucket == 0
          ? xAt(rangeStart)
          : bucket == buckets - 1
              ? xAt(rangeEnd - 1)
              : (xAt(start) + xAt(end - 1)) / 2;
      spots.add(FlSpot(x, minY));
      if (minY != maxY) spots.add(FlSpot(x, maxY));
    }
    return List<FlSpot>.unmodifiable(spots);
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
      final end = (rangeStart + (bucket + 1) * count ~/ buckets).clamp(
        rangeStart,
        rangeEnd,
      );
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
