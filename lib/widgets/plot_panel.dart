import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
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
        setState(() {
          final sf = details.scale;
          if (sf != 1.0) {
            // Zoom
          } else if (details.focalPointDelta.dx != 0 || details.focalPointDelta.dy != 0) {
            // Pan
          }
        });
      },
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
    return LineChart(
      duration: Duration.zero,
      LineChartData(
        lineBarsData: bars,
        gridData: FlGridData(show: true, drawVerticalLine: true, drawHorizontalLine: true,
          getDrawingHorizontalLine: (v) => FlLine(color: theme.dividerColor.withValues(alpha: 0.15), strokeWidth: 0.5),
          getDrawingVerticalLine: (v) => FlLine(color: theme.dividerColor.withValues(alpha: 0.15), strokeWidth: 0.5),
        ),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 20, interval: null, getTitlesWidget: (v, _) => _axisLabel(v, textColor))),
          leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 42, interval: null, getTitlesWidget: (v, _) => _axisLabel(v, textColor))),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: true, border: Border.all(color: theme.dividerColor.withValues(alpha: 0.3), width: 0.5)),
        lineTouchData: LineTouchData(enabled: true,
          touchCallback: (event, response) {
            final a = context.read<AppState>();
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
              'x=${s.x.toStringAsFixed(6)}\ny=${s.y.toStringAsFixed(4)}',
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
    );
  }

  Widget _axisLabel(double value, Color color) {
    final abs = value.abs();
    String text;
    if (abs >= 1000 || (abs > 0 && abs < 0.001)) {
      text = value.toStringAsExponential(1);
    } else if (abs >= 100) {
      text = value.toStringAsFixed(0);
    } else if (abs >= 10) {
      text = value.toStringAsFixed(1);
    } else {
      text = value.toStringAsFixed(3);
    }
    return Padding(padding: const EdgeInsets.only(top: 2), child: Text(text, style: TextStyle(fontSize: 8, color: color)));
  }

  VerticalLineLabel? _crosshairLabel(List<LineChartBarData> bars, double? cx) {
    if (cx == null || bars.isEmpty) return null;
    final parts = <String>['x=${cx.toStringAsFixed(6)}'];
    for (final bar in bars) {
      if (bar.spots.isEmpty) continue;
      final idx = _nearest(bar.spots, cx);
      parts.add('${bar.spots[idx].y.toStringAsFixed(4)}');
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
