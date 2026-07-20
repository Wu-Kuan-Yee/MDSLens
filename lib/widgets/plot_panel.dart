import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:file_picker/file_picker.dart';
import '../models/app_state.dart';

const _colors = [
  Color(0xFF2364aa), Color(0xFFc44e52), Color(0xFF2f855a),
  Color(0xFF805ad5), Color(0xFFd97706), Color(0xFF0f766e),
  Color(0xFF9f1239), Color(0xFF4a5568), Color(0xFFdb2777),
  Color(0xFF16a34a), Color(0xFFea580c), Color(0xFF0891b2),
];

class PlotPanel extends StatefulWidget {
  final int plotIdx;
  final bool selected;
  final void Function()? onTap;
  final void Function(String action)? onContextAction;

  const PlotPanel({super.key, required this.plotIdx, this.onTap, this.onContextAction, this.selected = false});

  @override
  State<PlotPanel> createState() => _PlotPanelState();
}

class _PlotPanelState extends State<PlotPanel> {
  // ignore: prefer_final_fields
  double _viewMinX = double.nan, _viewMaxX = double.nan, _viewMinY = double.nan, _viewMaxY = double.nan;
  double? _localCrosshairY;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    if (widget.plotIdx >= app.plots.length) return const SizedBox();

    final plot = app.plots[widget.plotIdx];
    final theme = Theme.of(context);

    // Build line bars with MinMax decimation
    final bars = <LineChartBarData>[];
    for (var i = 0; i < plot.series.length; i++) {
      final s = plot.series[i];
      if (s?.points == null || s!.points!.isEmpty) continue;
      final decimated = _decimate(s.points!, 2000);
      final spots = decimated.map((p) => FlSpot(p[0], p[1])).toList();
      bars.add(LineChartBarData(
        spots: spots,
        isCurved: false,
        color: _colors[i % _colors.length],
        barWidth: 1,
        dotData: const FlDotData(show: false),
        belowBarData: BarAreaData(show: false),
      ));
    }

    return GestureDetector(
      onTap: widget.onTap,
      onScaleUpdate: (details) {
        final mode = context.read<AppState>().interactionMode;
        if (mode != 0) return; // View mode only: pan + zoom combined
        setState(() {
          if (_viewMinX.isNaN) _initViewToData(plot);
          final box = context.findRenderObject() as RenderBox?;
          final w = box?.size.width ?? 0;
          final h = box?.size.height ?? 0;
          if (details.scale != 1.0 && w > 0 && h > 0) {
            // Pinch zoom around focal point
            final factor = 1.0 / details.scale;
            final cx = _viewMinX + (details.focalPoint.dx / w) * (_viewMaxX - _viewMinX);
            final cy = _viewMaxY - (details.focalPoint.dy / h) * (_viewMaxY - _viewMinY);
            _viewMinX = cx - (cx - _viewMinX) * factor;
            _viewMaxX = cx + (_viewMaxX - cx) * factor;
            _viewMinY = cy - (cy - _viewMinY) * factor;
            _viewMaxY = cy + (_viewMaxY - cy) * factor;
          } else if (w > 0 && h > 0) {
            // One-finger drag pan
            final xScale = (_viewMaxX - _viewMinX) / w;
            final yScale = (_viewMaxY - _viewMinY) / h;
            _viewMinX -= details.focalPointDelta.dx * xScale;
            _viewMaxX -= details.focalPointDelta.dx * xScale;
            _viewMinY += details.focalPointDelta.dy * yScale;
            _viewMaxY += details.focalPointDelta.dy * yScale;
          }
        });
      },
      onSecondaryTapUp: (details) => _showContextMenu(context, details.globalPosition),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              border: Border.all(
                color: widget.selected ? const Color(0xFFFF00FF) : theme.dividerColor.withValues(alpha: 0.3),
                width: widget.selected ? 2 : 1,
              ),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(children: [
              if (plot.title.isNotEmpty)
                Padding(padding: const EdgeInsets.only(top: 2), child: Text(plot.title, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: theme.colorScheme.onSurface))),
              Expanded(
                child: bars.isEmpty
                    ? Center(child: Text(plot.series.any((s) => s?.error != null && s!.error!.isNotEmpty) ? 'Error' : 'No data', style: TextStyle(color: Colors.grey, fontSize: 10)))
                    : _buildChart(bars, plot, theme),
              ),
              Padding(padding: const EdgeInsets.only(bottom: 2), child: Text(plot.xLabel, style: TextStyle(fontSize: 9, color: theme.colorScheme.onSurface.withValues(alpha: 0.7)))),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _buildChart(List<LineChartBarData> bars, PlotData plot, ThemeData theme) {
    final textColor = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final cx = context.read<AppState>().crosshairX;
    return Padding(
      padding: const EdgeInsets.only(right: 28),
      child: LineChart(
        LineChartData(
        lineBarsData: bars,
        gridData: FlGridData(show: true, drawVerticalLine: true, drawHorizontalLine: true,
          getDrawingHorizontalLine: (v) => FlLine(color: theme.dividerColor.withValues(alpha: 0.15), strokeWidth: 0.5),
          getDrawingVerticalLine: (v) => FlLine(color: theme.dividerColor.withValues(alpha: 0.15), strokeWidth: 0.5),
        ),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            axisNameWidget: Padding(padding: const EdgeInsets.only(top: 2), child: Text(plot.xLabel, style: TextStyle(fontSize: 9, color: textColor))),
            axisNameSize: 14,
            sideTitles: SideTitles(showTitles: true, reservedSize: 20, interval: null, getTitlesWidget: (v, _) => _axisLabel(v, textColor)),
          ),
          leftTitles: AxisTitles(
            axisNameWidget: Padding(padding: const EdgeInsets.only(bottom: 2), child: Text(plot.yLabel, style: TextStyle(fontSize: 9, color: textColor))),
            axisNameSize: 14,
            sideTitles: SideTitles(showTitles: true, reservedSize: 50, interval: null, getTitlesWidget: (v, _) => _axisLabel(v, textColor)),
          ),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false, reservedSize: 28)),
        ),
        borderData: FlBorderData(show: true, border: Border.all(color: theme.dividerColor.withValues(alpha: 0.3), width: 0.5)),
        lineTouchData: LineTouchData(enabled: true,
          touchCallback: (event, response) {
            final a = context.read<AppState>();
            if (a.interactionMode != 1) return; // Only in Point mode
            if (response?.lineBarSpots != null && response!.lineBarSpots!.isNotEmpty) {
              final spot = response.lineBarSpots!.first;
              a.setCrosshair(spot.x);
              setState(() { _localCrosshairY = spot.y; });
            }
          },
          handleBuiltInTouches: false,
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => theme.colorScheme.inverseSurface,
            getTooltipItems: (spots) => spots.map((s) => LineTooltipItem(
              '${s.x.toStringAsFixed(3)}, ${s.y.toStringAsFixed(4)}',
              TextStyle(fontSize: 9, color: theme.colorScheme.onInverseSurface, fontFamily: 'monospace'),
            )).toList(),
          ),
        ),
        extraLinesData: ExtraLinesData(
          verticalLines: cx != null ? [VerticalLine(x: cx, color: const Color(0xFFFF00FF), strokeWidth: 1, label: _crosshairLabel(bars, cx))] : [],
          horizontalLines: _localCrosshairY != null ? [HorizontalLine(y: _localCrosshairY!, color: const Color(0xFFFF00FF), strokeWidth: 1)] : [],
        ),
        minX: _viewMinX.isNaN ? null : _viewMinX,
        maxX: _viewMaxX.isNaN ? null : _viewMaxX,
        minY: _viewMinY.isNaN ? null : _viewMinY,
        maxY: _viewMaxY.isNaN ? null : _viewMaxY,
      ),
    ),
    );
  }

  Widget _axisLabel(double value, Color color) {
    return Padding(padding: const EdgeInsets.only(top: 2), child: Text(_fmtAxis(value), style: TextStyle(fontSize: 8, color: color)));
  }

  String _fmtAxis(double v) {
    final abs = v.abs();
    if (!abs.isFinite) return '';
    if (abs >= 1000 || (abs > 0 && abs < 0.001)) return v.toStringAsExponential(1);
    if (abs >= 100) return v.toStringAsFixed(0);
    if (abs >= 10) return v.toStringAsFixed(1);
    // Adaptive: 3 decimals then strip trailing zeros for natural precision
    final s = v.toStringAsFixed(3);
    return s.contains('.') ? s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '') : s;
  }

  VerticalLineLabel? _crosshairLabel(List<LineChartBarData> bars, double? cx) {
    if (cx == null || bars.isEmpty) return null;
    final parts = <String>[];
    for (final bar in bars) {
      if (bar.spots.isEmpty) continue;
      final idx = _nearest(bar.spots, cx);
      parts.add('${cx.toStringAsFixed(3)}, ${bar.spots[idx].y.toStringAsFixed(4)}');
    }
    if (parts.isEmpty) return null;
    return VerticalLineLabel(show: true,
      labelResolver: (_) => parts.join('\n'),
      style: const TextStyle(fontSize: 9, color: Color(0xFFFF00FF)));
  }

  int _nearest(List<FlSpot> spots, double x) {
    var lo = 0; var hi = spots.length - 1;
    while (lo < hi) { final mid = (lo + hi) ~/ 2; if (spots[mid].x < x) { lo = mid + 1; } else { hi = mid; } }
    if (lo > 0 && (lo >= spots.length || (x - spots[lo-1].x).abs() < (spots[lo].x - x).abs())) return lo - 1;
    return lo;
  }

  void _resetView() {
    _viewMinX = double.nan; _viewMaxX = double.nan;
    _viewMinY = double.nan; _viewMaxY = double.nan;
    _localCrosshairY = null;
  }

  void _showContextMenu(BuildContext ctx, Offset globalPosition) {
    final app = ctx.read<AppState>();
    showMenu<String>(
      context: ctx,
      position: RelativeRect.fromLTRB(globalPosition.dx, globalPosition.dy, globalPosition.dx, globalPosition.dy),
      items: const [
        PopupMenuItem(value: 'max', child: Text('Max')),
        PopupMenuItem(value: 'reset', child: Text('Reset View')),
        PopupMenuItem(value: 'export', child: Text('Export Data')),
        PopupMenuItem(value: 'setup', child: Text('Panel Setup')),
      ],
    ).then((value) {
      if (value == null) return;
      switch (value) {
        case 'reset':
          _resetView();
          app.clearCrosshair();
          break;
        case 'export':
          _exportCsv(app);
          break;
        // 'max', 'setup': placeholders for future
      }
    });
  }

  Future<void> _exportCsv(AppState app) async {
    final plot = app.plots[widget.plotIdx];
    final buf = StringBuffer();
    buf.writeln('# MdsScope Export — ${plot.title.isNotEmpty ? plot.title : "Panel ${widget.plotIdx + 1}"}');
    for (var i = 0; i < plot.series.length; i++) {
      final s = plot.series[i];
      if (s?.points == null || s!.points!.isEmpty) continue;
      if (plot.series.length > 1) buf.writeln('# Series $i');
      buf.writeln('x, y');
      for (final p in s.points!) {
        buf.writeln('${p[0]}, ${p[1]}');
      }
      buf.writeln();
    }
    if (buf.length == 0) return;
    try {
      final path = await FilePicker.platform.saveFile(
        fileName: '${plot.title.isNotEmpty ? plot.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_') : "export"}.csv',
        type: FileType.custom,
        allowedExtensions: ['csv'],
      );
      if (path != null) {
        await File(path).writeAsString(buf.toString());
        app.setStatus('Exported to ${path.split('/').last}');
      }
    } catch (e) { app.setStatus('Export error: $e'); }
  }

  void _initViewToData(PlotData plot) {
    final bounds = _computeDataBounds(plot);
    if (bounds != null) {
      _viewMinX = bounds[0]; _viewMaxX = bounds[1];
      _viewMinY = bounds[2]; _viewMaxY = bounds[3];
    }
  }

  List<double>? _computeDataBounds(PlotData plot) {
    double? minX, maxX, minY, maxY;
    for (final s in plot.series) {
      if (s?.points == null || s!.points!.isEmpty) continue;
      for (final p in s.points!) {
        final x = p[0], y = p[1];
        if (!x.isFinite || !y.isFinite) continue;
        if (minX == null || x < minX) minX = x;
        if (maxX == null || x > maxX) maxX = x;
        if (minY == null || y < minY) minY = y;
        if (maxY == null || y > maxY) maxY = y;
      }
    }
    if (minX == null) return null;
    final xPad = (maxX! - minX) * 0.02;
    final yPad = (maxY! - minY!) * 0.02;
    return [minX - xPad, maxX + xPad, minY - yPad, maxY + yPad];
  }

  List<List<double>> _decimate(List<List<double>> points, int maxPoints) {
    if (points.length <= maxPoints) return points;
    final buckets = (maxPoints / 2).ceil().clamp(1, points.length);
    final out = <List<double>>[];
    for (var b = 0; b < buckets; b++) {
      final start = (b * points.length ~/ buckets);
      final end = ((b + 1) * points.length ~/ buckets).clamp(0, points.length);
      if (start >= end) continue;
      double minY = double.infinity, maxY = double.negativeInfinity;
      for (var i = start; i < end; i++) {
        if (points[i][1] < minY) { minY = points[i][1]; }
        if (points[i][1] > maxY) { maxY = points[i][1]; }
      }
      final midX = (points[start][0] + points[end - 1][0]) / 2;
      if (minY == maxY) {
        out.add([midX, minY]);
      } else {
        out.add([midX, minY]);
        out.add([midX, maxY]);
      }
    }
    return out;
  }
}
