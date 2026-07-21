import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import '../models/app_state.dart';
import 'package:file_picker/file_picker.dart';

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
  final _chartAreaKey = GlobalKey();
  final _listenerKey = GlobalKey();
  double _viewMinX = double.nan, _viewMaxX = double.nan, _viewMinY = double.nan, _viewMaxY = double.nan;
  double? _localCrosshairY;
  int _lastResetId = -1;
  bool _midPanning = false;
  Offset? _lastMidPanPos;
  bool _inRubberBand = false;
  Offset? _rubberBandStart;
  Rect? _rubberBandRect;
  double _lastScale = 1.0;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    if (app.viewResetId != _lastResetId) {
      _lastResetId = app.viewResetId;
      _resetView();
      if (app.sharedXMin != null) { _viewMinX = app.sharedXMin!; _viewMaxX = app.sharedXMax!; }
      if (app.sharedYMin != null) { _viewMinY = app.sharedYMin!; _viewMaxY = app.sharedYMax!; }
    }
    if (app.crosshairX == null && _localCrosshairY != null) {
      _localCrosshairY = null;
    }
    if (widget.plotIdx >= app.plots.length) return const SizedBox();

    final plot = app.plots[widget.plotIdx];
    final panel = _findPanel(app);
    final theme = Theme.of(context);

    // Build line bars with MinMax decimation
    final bars = <LineChartBarData>[];
    final sigSpecs = (panel['signal_specs'] as List?)?.cast<Map>() ?? [];
    double? viewMinX, viewMaxX, viewMinY, viewMaxY;
    for (var i = 0; i < plot.series.length; i++) {
      final s = plot.series[i];
      if (s?.points == null || s!.points!.isEmpty) continue;
      if (i < sigSpecs.length && sigSpecs[i]['hidden'] == true) continue;
      final decimated = _decimate(s.points!, 2000);
      final spots = decimated.map((p) => FlSpot(p[0], p[1])).toList();
      for (final sp in spots) {
        viewMinX ??= sp.x; viewMaxX ??= sp.x;
        viewMinY ??= sp.y; viewMaxY ??= sp.y;
        if (sp.x < viewMinX) viewMinX = sp.x;
        if (sp.x > viewMaxX) viewMaxX = sp.x;
        if (sp.y < viewMinY) viewMinY = sp.y;
        if (sp.y > viewMaxY) viewMaxY = sp.y;
      }
      bars.add(LineChartBarData(
        spots: spots,
        isCurved: false,
        color: _sigColor(i, sigSpecs),
        barWidth: 1,
        dotData: const FlDotData(show: false),
        belowBarData: BarAreaData(show: false),
      ));
    }

    return Stack(children: [
      GestureDetector(
        onTapDown: (details) {
          widget.onTap?.call();
        final a = context.read<AppState>();
        if (a.interactionMode == 1 && a.pointLocked) {
          a.pointLocked = false;
          // Set crosshair at tap position using full widget mapping
          if (_viewMinX.isFinite) {
            a.setCrosshair(_pxToDataX(details.localPosition.dx));
          }
        }
      },
      onScaleStart: (details) {
        _lastScale = 1.0;
      },
      onScaleUpdate: (details) {
        final mode = context.read<AppState>().interactionMode;
        if (mode != 0 || _midPanning || _inRubberBand) return;
        setState(() {
          if (_viewMinX.isNaN) _initViewToData(plot);
          if (details.scale != 1.0) {
            final deltaScale = details.scale / _lastScale;
            _lastScale = details.scale;
            final factor = 1.0 / deltaScale;
            final localF = details.localFocalPoint;
            final cx = _pxToDataX(localF.dx);
            final cy = _pxToDataY(localF.dy);
            _viewMinX = cx - (cx - _viewMinX) * factor;
            _viewMaxX = cx + (_viewMaxX - cx) * factor;
            _viewMinY = cy - (cy - _viewMinY) * factor;
            _viewMaxY = cy + (_viewMaxY - cy) * factor;
          } else {
            final lb = _listenerBox;
            final cb = _chartBox;
            if (lb != null && cb != null && cb.size.width > 50 && cb.size.height > 32) {
              final gw = cb.size.width - 50;
              final gh = cb.size.height - 32;
              final xScale = (_viewMaxX - _viewMinX) / gw;
              final yScale = (_viewMaxY - _viewMinY) / gh;
              _viewMinX -= details.focalPointDelta.dx * xScale;
              _viewMaxX -= details.focalPointDelta.dx * xScale;
              _viewMinY += details.focalPointDelta.dy * yScale;
              _viewMaxY += details.focalPointDelta.dy * yScale;
            }
          }
        });
      },
      onSecondaryTapUp: (details) => _showContextMenu(context, details.globalPosition),
      onLongPressStart: (details) => _showContextMenu(context, details.globalPosition),
      child: Listener(
        key: _listenerKey,
        onPointerSignal: _handleScrollWheel,
        onPointerDown: _handlePointerDown,
        onPointerMove: _handlePointerMove,
        onPointerUp: _handlePointerUp,
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
              Expanded(
                child: bars.isEmpty
                    ? Center(child: Text(plot.series.any((s) => s?.error != null && s!.error!.isNotEmpty) ? 'Error' : 'No data', style: TextStyle(color: Colors.grey, fontSize: 10)))
                    : Stack(key: _chartAreaKey, children: [
                        _buildChart(bars, plot, panel, theme, viewMinX, viewMaxX, viewMinY, viewMaxY),
                      ]),
              ),
            ]),
          ),
        ),
        ),
      ),
    ),
      if (_inRubberBand && _rubberBandRect != null)
        Positioned(
          left: _rubberBandRect!.left,
          top: _rubberBandRect!.top,
          width: _rubberBandRect!.width,
          height: _rubberBandRect!.height,
          child: IgnorePointer(
            child: Container(
              decoration: BoxDecoration(color: const Color(0x180000FF), border: Border.all(color: const Color(0xFF0000FF), width: 1)),
            ),
          ),
        ),
    ]);
  }

  Widget _buildChart(List<LineChartBarData> bars, PlotData plot, Map<String, dynamic> panel, ThemeData theme,
      double? autoMinX, double? autoMaxX, double? autoMinY, double? autoMaxY) {
    final textColor = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final tickColor = theme.colorScheme.onSurface.withValues(alpha: 0.4);
    final cx = context.read<AppState>().crosshairX;
    final showGrid = panel['grid'] ?? true;
    final customX = panel['custom_x_range'] == true;
    final customY = panel['custom_y_range'] == true;

    // Use view state if user has interacted; otherwise auto-scale to displayed data
    final xMin = customX ? ((panel['xmin'] as num?)?.toDouble()) : (_viewMinX.isNaN ? autoMinX : _viewMinX);
    final xMax = customX ? ((panel['xmax'] as num?)?.toDouble()) : (_viewMaxX.isNaN ? autoMaxX : _viewMaxX);
    final yMin = customY ? ((panel['ymin'] as num?)?.toDouble()) : (_viewMinY.isNaN ? autoMinY : _viewMinY);
    final yMax = customY ? ((panel['ymax'] as num?)?.toDouble()) : (_viewMaxY.isNaN ? autoMaxY : _viewMaxY);

    List<double> evenTicks(double min, double max, int count) {
      if (count < 2) return [min];
      final step = (max - min) / (count - 1);
      return List.generate(count, (i) => min + step * i);
    }

    return LayoutBuilder(
        builder: (ctx, constraints) {
          final cw = constraints.maxWidth;
          final ch = constraints.maxHeight;
          // Chart grid area — matches fl_chart internal grid exactly
          //   left = 50 (leftTitles.reservedSize)
          //   top = 0 (no top titles)
          //   right = full width (no right titles)
          //   bottom = ch - 32 (bottomTitles.reservedSize)
          final gridLeft = 50.0;
          final gridTop = 0.0;
          final gridRight = cw;
          final gridBottom = ch - 32.0;
          final gridW = gridRight - gridLeft;
          final gridH = gridBottom - gridTop;

          // Tick count based on pixel size matching C++:
          //   xTickCount = clamp(width/78 + 1, 3, 7)
          //   yTickCount = clamp(height/34 + 1, 3, 6)
          final xTickCount = xMin != null && xMax != null ? (gridW / 78.0 + 1).round().clamp(3, 7) : 0;
          final yTickCount = yMin != null && yMax != null ? (gridH / 34.0 + 1).round().clamp(3, 6) : 0;
          final xTicks = xTickCount > 1 ? evenTicks(xMin!, xMax!, xTickCount) : <double>[];
          final yTicks = yTickCount > 1 ? evenTicks(yMin!, yMax!, yTickCount) : <double>[];

          return Stack(
            children: [
              if (plot.title.isNotEmpty)
                Positioned(left: gridLeft, right: 0, top: gridTop + 2, child: Center(child: Text(plot.title, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: textColor)))),
              LineChart(
                LineChartData(
                clipData: const FlClipData.all(),
                lineBarsData: bars,
                gridData: FlGridData(show: showGrid, drawVerticalLine: showGrid, drawHorizontalLine: showGrid,
                  getDrawingHorizontalLine: (v) => FlLine(color: theme.dividerColor.withValues(alpha: 0.15), strokeWidth: 0.5),
                  getDrawingVerticalLine: (v) => FlLine(color: theme.dividerColor.withValues(alpha: 0.15), strokeWidth: 0.5),
                ),
                titlesData: FlTitlesData(
                  bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 32, getTitlesWidget: (v, m) => const SizedBox())),
                  leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 50, getTitlesWidget: (v, m) => const SizedBox())),
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                ),
                borderData: FlBorderData(show: true, border: Border.all(color: theme.dividerColor.withValues(alpha: 0.5), width: 1)),
                lineTouchData: LineTouchData(enabled: true,
                  touchCallback: (event, response) {
                    final a = context.read<AppState>();
                    if (a.interactionMode != 1) return;
                    if (a.pointLocked) return;
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
                minX: xMin, maxX: xMax, minY: yMin, maxY: yMax,
              ),
              ),
            // Y-axis tick marks — 3px horizontal lines (matching C++ render.cpp:251)
              for (int i = 0; i < yTicks.length; i++)
                Positioned(
                  left: gridLeft,
                  top: gridTop + ((yTicks.length - 1 - i) / (yTicks.length - 1)) * gridH,
                  child: Container(width: 3, height: 1, color: tickColor),
                ),
              // X-axis tick marks — 2px vertical lines below axis border (C++ render.cpp:327)
              for (int i = 0; i < xTicks.length; i++)
                Positioned(
                  left: gridLeft + (i / (xTicks.length - 1)) * gridW,
                  top: gridBottom,
                  child: Container(width: 1, height: 2, color: tickColor),
                ),
              // Y-axis tick labels at fixed fractions of grid height
              for (int i = 0; i < yTicks.length; i++)
                Positioned(
                  left: 2,
                  top: (gridTop + ((yTicks.length - 1 - i) / (yTicks.length - 1)) * gridH - 6).clamp(2.0, double.infinity),
                  child: SizedBox(width: gridLeft - 6, child: Text(_fmtAxis(yTicks[i]), style: TextStyle(fontSize: 8, color: textColor), textAlign: TextAlign.right)),
                ),
              // X-axis tick values — below tick marks (row 1 of 2 below axis)
              // First label left-aligned, last label right-aligned, others centered
              if (xTicks.isNotEmpty)
                for (int i = 0; i < xTicks.length; i++) ...[
                  if (i == 0)
                    Positioned(
                      left: gridLeft,
                      top: gridBottom + 4,
                      child: Text(_fmtAxis(xTicks[i]), style: TextStyle(fontSize: 8, color: textColor)),
                    )
                  else if (i == xTicks.length - 1)
                    Positioned(
                      right: cw - gridRight,
                      top: gridBottom + 4,
                      child: Text(_fmtAxis(xTicks[i]), style: TextStyle(fontSize: 8, color: textColor)),
                    )
                  else
                    Positioned(
                      left: gridLeft + (i / (xTicks.length - 1)) * gridW - 16,
                      top: gridBottom + 4,
                      child: Text(_fmtAxis(xTicks[i]), style: TextStyle(fontSize: 8, color: textColor)),
                    ),
                ],
              // X-axis name label — below tick values (row 2 of 2 below axis)
              Positioned(
                left: gridLeft, right: 0, top: gridBottom + 16,
                child: Center(child: Text(plot.xLabel, style: TextStyle(fontSize: 9, color: textColor))),
              ),
              Positioned(
                left: -2, top: gridTop, bottom: ch - gridBottom,
                child: Center(child: Padding(padding: const EdgeInsets.only(bottom: 2), child: RotatedBox(quarterTurns: -1, child: Text(plot.yLabel, style: TextStyle(fontSize: 9, color: textColor))))),
              ),
            ],
          );
        },
      );
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

  RenderBox? get _listenerBox => _listenerKey.currentContext?.findRenderObject() as RenderBox?;
  RenderBox? get _chartBox => _chartAreaKey.currentContext?.findRenderObject() as RenderBox?;

  Color _sigColor(int i, List<Map> sigSpecs) {
    if (i < sigSpecs.length && sigSpecs[i]['color_name'] != null) {
      final hex = sigSpecs[i]['color_name'].toString().replaceFirst('#', '');
      final c = int.tryParse(hex, radix: 16);
      if (c != null) return Color(0xFF000000 | c);
    }
    return _colors[i % _colors.length];
  }

  // Convert listener-local pixel to data coordinate using chart grid area.
  double _pxToDataX(double px) {
    final lb = _listenerBox;
    final cb = _chartBox;
    if (lb == null || cb == null || cb.size.width <= 50) return (_viewMinX + _viewMaxX) / 2;
    final chartLocal = cb.globalToLocal(lb.localToGlobal(Offset(px, 0)));
    final gx = chartLocal.dx - 50;
    final gw = cb.size.width - 50;
    return _viewMinX + (gx / gw) * (_viewMaxX - _viewMinX);
  }
  double _pxToDataY(double py) {
    final lb = _listenerBox;
    final cb = _chartBox;
    if (lb == null || cb == null || cb.size.height <= 32) return (_viewMinY + _viewMaxY) / 2;
    final chartLocal = cb.globalToLocal(lb.localToGlobal(Offset(0, py)));
    final gy = chartLocal.dy;
    final gh = cb.size.height - 32;
    return _viewMaxY - (gy / gh) * (_viewMaxY - _viewMinY);
  }

  void _handleScrollWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final app = context.read<AppState>();
    if (app.interactionMode != 0) return;
    final plot = app.plots[widget.plotIdx];
    setState(() {
      if (_viewMinX.isNaN) _initViewToData(plot);
      final pos = event.localPosition;
      final steps = event.scrollDelta.dy / 53.0;
      final factor = math.pow(1.22, -steps);
      final cx = _pxToDataX(pos.dx);
      final cy = _pxToDataY(pos.dy);
      _viewMinX = cx - (cx - _viewMinX) * factor;
      _viewMaxX = cx + (_viewMaxX - cx) * factor;
      _viewMinY = cy - (cy - _viewMinY) * factor;
      _viewMaxY = cy + (_viewMaxY - cy) * factor;
    });
  }

  void _handlePointerDown(PointerDownEvent event) {
    final app = context.read<AppState>();
    if (app.interactionMode != 0) return;
    final isMid = (event.buttons & kMiddleMouseButton) != 0;
    final isShiftLeft = app.shiftHeld && (event.buttons & kPrimaryMouseButton) != 0;
    final isMouseLeft = event.kind == PointerDeviceKind.mouse &&
        (event.buttons & kPrimaryMouseButton) != 0 && !app.shiftHeld;
    if (isMouseLeft) {
      _inRubberBand = true;
      _rubberBandStart = event.localPosition;
      _rubberBandRect = Rect.fromPoints(event.localPosition, event.localPosition);
    } else if (isMid || isShiftLeft) {
      _midPanning = true;
      _lastMidPanPos = event.localPosition;
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (_inRubberBand && _rubberBandStart != null) {
      setState(() { _rubberBandRect = Rect.fromPoints(_rubberBandStart!, event.localPosition); });
      return;
    }
    if (!_midPanning || _lastMidPanPos == null) return;
    final app = context.read<AppState>();
    final plot = app.plots[widget.plotIdx];
    final lb = _listenerBox;
    final cb = _chartBox;
    setState(() {
      if (_viewMinX.isNaN) _initViewToData(plot);
      if (lb == null || cb == null || cb.size.width <= 0 || cb.size.height <= 0) return;
      final dx = event.localPosition.dx - _lastMidPanPos!.dx;
      final dy = event.localPosition.dy - _lastMidPanPos!.dy;
      final xScale = (_viewMaxX - _viewMinX) / cb.size.width;
      final yScale = (_viewMaxY - _viewMinY) / cb.size.height;
      _viewMinX -= dx * xScale;
      _viewMaxX -= dx * xScale;
      _viewMinY += dy * yScale;
      _viewMaxY += dy * yScale;
      _lastMidPanPos = event.localPosition;
    });
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (_inRubberBand && _rubberBandRect != null &&
        ((event.buttons & kPrimaryMouseButton) == 0)) {
      final r = _rubberBandRect!;
      final app = context.read<AppState>();
      final plot = app.plots[widget.plotIdx];
      setState(() {
        _inRubberBand = false;
        _rubberBandStart = null;
        _rubberBandRect = null;
        if (r.width > 8 && r.height > 8) {
          if (_viewMinX.isNaN) _initViewToData(plot);
          final x1 = _pxToDataX(r.left);
          final y1 = _pxToDataY(r.top);
          final x2 = _pxToDataX(r.right);
          final y2 = _pxToDataY(r.bottom);
          _viewMinX = x1 < x2 ? x1 : x2;
          _viewMaxX = x1 > x2 ? x1 : x2;
          _viewMinY = y1 < y2 ? y1 : y2;
          _viewMaxY = y1 > y2 ? y1 : y2;
        }
      });
      return;
    }
    _midPanning = false;
    _lastMidPanPos = null;
  }

  List<double>? _currentRange(AppState app) {
    if (!_viewMinX.isNaN) return [_viewMinX, _viewMaxX, _viewMinY, _viewMaxY];
    final plot = app.plots[widget.plotIdx];
    double? minX, maxX, minY, maxY;
    for (final s in plot.series) {
      if (s?.points == null || s!.points!.isEmpty) continue;
      for (final p in s.points!) {
        if (minX == null || p[0] < minX) minX = p[0];
        if (maxX == null || p[0] > maxX) maxX = p[0];
        if (minY == null || p[1] < minY) minY = p[1];
        if (maxY == null || p[1] > maxY) maxY = p[1];
      }
    }
    return minX != null ? [minX, maxX!, minY!, maxY!] : null;
  }

  void _resetView() {
    _viewMinX = double.nan; _viewMaxX = double.nan;
    _viewMinY = double.nan; _viewMaxY = double.nan;
    _localCrosshairY = null;
    _inRubberBand = false;
    _rubberBandStart = null;
    _rubberBandRect = null;
  }

  void _showContextMenu(BuildContext ctx, Offset globalPosition) {
    final app = ctx.read<AppState>();
    final isMaxed = app.maximizedPlot != null;
    showMenu<String>(
      context: ctx,
      position: RelativeRect.fromLTRB(globalPosition.dx, globalPosition.dy, globalPosition.dx, globalPosition.dy),
      items: [
        if (isMaxed)
          const PopupMenuItem(value: 'showAll', child: Text('Show All Panels'))
        else
          const PopupMenuItem(value: 'max', child: Text('Max')),
        const PopupMenuItem(value: 'reset', child: Text('Reset Current Scale')),
        const PopupMenuItem(value: 'resetAll', child: Text('Reset All Panels')),
        const PopupMenuItem(value: 'sameX', child: Text('All Same X Scale')),
        const PopupMenuItem(value: 'sameY', child: Text('All Same Y Scale')),
        const PopupMenuItem(value: 'export', child: Text('Export Data')),
        const PopupMenuItem(value: 'dataSource', child: Text('Data Source Setup')),
        const PopupMenuItem(value: 'setup', child: Text('Panel Setup')),
      ],
    ).then((value) {
      if (value == null) return;
      switch (value) {
        case 'max':
          app.maximizePlot(widget.plotIdx);
          break;
        case 'showAll':
          app.showAllPanels();
          break;
        case 'reset':
          _resetView();
          app.clearCrosshair();
          break;
        case 'resetAll':
          app.sharedXMin = null; app.sharedXMax = null;
          app.sharedYMin = null; app.sharedYMax = null;
          app.resetAllViews();
          app.clearCrosshair();
          break;
        case 'sameX':
          final r = _currentRange(app);
          app.applySharedXScale(r != null ? r[0] : 0, r != null ? r[1] : 1);
          break;
        case 'sameY':
          final r = _currentRange(app);
          app.applySharedYScale(r != null ? r[2] : 0, r != null ? r[3] : 1);
          break;
        case 'export':
          _exportCsv(app);
          break;
        case 'dataSource':
          _showDataSourceSetup(ctx, app);
          break;
        case 'setup':
          _showPanelSetup(ctx, app);
          break;
      }
    });
  }

  Map<String, dynamic> _findPanel(AppState app) {
    var idx = widget.plotIdx;
    for (final col in app.columns) {
      if (idx < col.length) return col[idx];
      idx -= col.length;
    }
    return <String, dynamic>{};
  }

  void _showDataSourceSetup(BuildContext ctx, AppState app) {
    final panel = _findPanel(app);
    final sigs = List<Map<String, dynamic>>.from(
      (panel['signal_specs'] as List?)?.map((s) => Map<String, dynamic>.from(s as Map)) ?? []);
    final defaultShot = (panel['shot']?.toString() ?? app.shotText).trim();
    if (sigs.isEmpty) sigs.add({'experiment': 'pcs_east', 'server_ip': '202.127.204.12'});
    showDialog(
      context: ctx,
      builder: (ctx) => _DataSourceDialog(signals: sigs, defaultShot: defaultShot, onSave: () { panel['signal_specs'] = sigs; _rebuildPlots(app); }),
    ).then((confirmed) { if (confirmed == true) app.startRefresh(); });
  }

  void _rebuildPlots(AppState app) {
    // Preserve existing series data, update metadata without intermediate empty state
    final newPlots = <PlotData>[];
    var idx = 0;
    final curPlots = app.plots.toList();
    for (final col in app.columns) {
      for (final p in col) {
        final sc = (p['signal_specs'] as List?)?.length ?? 1;
        final oldSeries = idx < curPlots.length ? curPlots[idx].series : <SeriesData?>[];
        newPlots.add(PlotData(
          title: p['title']?.toString()??'',
          xLabel: p['x_label']?.toString()??'s',
          yLabel: p['y_label']?.toString()??'a.u.',
          series: _resizeSeries(oldSeries, sc > 0 ? sc : 1),
        ));
        idx++;
      }
    }
    // Replace in-place to avoid intermediate empty state
    app.plots.clear();
    app.plots.addAll(newPlots);
    app.rebuild();
  }

  List<SeriesData?> _resizeSeries(List<SeriesData?> old, int newCount) {
    if (old.length == newCount) return old;
    if (old.length > newCount) return old.sublist(0, newCount);
    return [...old, ...List.filled(newCount - old.length, null)];
  }

  void _showPanelSetup(BuildContext ctx, AppState app) {
    final panel = _findPanel(app);
    showDialog(
      context: ctx,
      builder: (ctx) => _PanelSetupDialog(panel: panel, onSave: () {
        _rebuildPlots(app);
      }),
    );
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

  void _initViewToData(PlotData plot, [Map<String, dynamic>? panel]) {
    final bounds = _computeDataBounds(plot, panel);
    if (bounds != null) {
      _viewMinX = bounds[0]; _viewMaxX = bounds[1];
      _viewMinY = bounds[2]; _viewMaxY = bounds[3];
    }
  }

  List<double>? _computeDataBounds(PlotData plot, [Map<String, dynamic>? panel]) {
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
    var rMinX = minX, rMaxX = maxX!, rMinY = minY!, rMaxY = maxY!;
    final customX = panel?['custom_x_range'] == true;
    final customY = panel?['custom_y_range'] == true;
    if (customX) {
      final cxmin = (panel?['xmin'] as num?)?.toDouble();
      final cxmax = (panel?['xmax'] as num?)?.toDouble();
      if (cxmin != null && cxmin.isFinite) rMinX = cxmin;
      if (cxmax != null && cxmax.isFinite) rMaxX = cxmax;
    }
    if (customY) {
      final cymin = (panel?['ymin'] as num?)?.toDouble();
      final cymax = (panel?['ymax'] as num?)?.toDouble();
      if (cymin != null && cymin.isFinite) rMinY = cymin;
      if (cymax != null && cymax.isFinite) rMaxY = cymax;
    }
    // Grid boundaries = data min/max exactly, no padding
    final xPad = 0.0;
    final yPad = 0.0;
    return [rMinX - xPad, rMaxX + xPad, rMinY - yPad, rMaxY + yPad];
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
      // Use endpoint X for first/last bucket so the curve reaches grid edges
      final x = b == 0 ? points[0][0] : (b == buckets - 1 ? points[points.length - 1][0] : (points[start][0] + points[end - 1][0]) / 2);
      if (minY == maxY) {
        out.add([x, minY]);
      } else {
        out.add([x, minY]);
        out.add([x, maxY]);
      }
    }
    return out;
  }
}

class _PanelSetupDialog extends StatefulWidget {
  final Map<String, dynamic> panel;
  final VoidCallback onSave;
  const _PanelSetupDialog({required this.panel, required this.onSave});

  @override State<_PanelSetupDialog> createState() => _PanelSetupDialogState();
}

class _PanelSetupDialogState extends State<_PanelSetupDialog> {
  late final _titleCtrl = TextEditingController(text: widget.panel['title']?.toString() ?? '');
  late final _xLabelCtrl = TextEditingController(text: widget.panel['x_label']?.toString() ?? 's');
  late final _yLabelCtrl = TextEditingController(text: widget.panel['y_label']?.toString() ?? 'a.u.');
  late final _pointsCtrl = TextEditingController(text: (widget.panel['extraction_points'] ?? 2000).toString());
  late bool _grid = widget.panel['grid'] ?? true;
  late bool _customX = widget.panel['custom_x_range'] ?? false;
  late bool _customY = widget.panel['custom_y_range'] ?? false;
  late final _xMinCtrl = TextEditingController(text: (widget.panel['xmin'] ?? '').toString());
  late final _xMaxCtrl = TextEditingController(text: (widget.panel['xmax'] ?? '').toString());
  late final _yMinCtrl = TextEditingController(text: (widget.panel['ymin'] ?? '').toString());
  late final _yMaxCtrl = TextEditingController(text: (widget.panel['ymax'] ?? '').toString());

  @override void dispose() {
    _titleCtrl.dispose(); _xLabelCtrl.dispose(); _yLabelCtrl.dispose();
    _pointsCtrl.dispose(); _xMinCtrl.dispose(); _xMaxCtrl.dispose();
    _yMinCtrl.dispose(); _yMaxCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext ctx) {
    return AlertDialog(
      title: const Text('Panel Setup'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: _titleCtrl, decoration: const InputDecoration(labelText: 'Title', isDense: true)),
          const SizedBox(height: 8),
          TextField(controller: _xLabelCtrl, decoration: const InputDecoration(labelText: 'X Label', isDense: true)),
          const SizedBox(height: 8),
          TextField(controller: _yLabelCtrl, decoration: const InputDecoration(labelText: 'Y Label', isDense: true)),
          const SizedBox(height: 8),
          TextField(controller: _pointsCtrl, decoration: const InputDecoration(labelText: 'Extraction Points', isDense: true), keyboardType: TextInputType.number),
          const SizedBox(height: 8),
          CheckboxListTile(title: const Text('Show Grid'), value: _grid, onChanged: (v) => setState(() => _grid = v ?? true), contentPadding: EdgeInsets.zero, dense: true, controlAffinity: ListTileControlAffinity.leading),
          CheckboxListTile(title: const Text('Custom X range'), value: _customX, onChanged: (v) => setState(() => _customX = v ?? false), contentPadding: EdgeInsets.zero, dense: true, controlAffinity: ListTileControlAffinity.leading),
          if (_customX) ...[
            Row(children: [
              Expanded(child: TextField(controller: _xMinCtrl, decoration: const InputDecoration(labelText: 'X min', isDense: true), keyboardType: TextInputType.number)),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: _xMaxCtrl, decoration: const InputDecoration(labelText: 'X max', isDense: true), keyboardType: TextInputType.number)),
            ]),
          ],
          CheckboxListTile(title: const Text('Custom Y range'), value: _customY, onChanged: (v) => setState(() => _customY = v ?? false), contentPadding: EdgeInsets.zero, dense: true, controlAffinity: ListTileControlAffinity.leading),
          if (_customY) ...[
            Row(children: [
              Expanded(child: TextField(controller: _yMinCtrl, decoration: const InputDecoration(labelText: 'Y min', isDense: true), keyboardType: TextInputType.number),
              ),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: _yMaxCtrl, decoration: const InputDecoration(labelText: 'Y max', isDense: true), keyboardType: TextInputType.number)),
            ]),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        TextButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }

  void _save() {
    widget.panel['title'] = _titleCtrl.text;
    widget.panel['x_label'] = _xLabelCtrl.text;
    widget.panel['y_label'] = _yLabelCtrl.text;
    widget.panel['extraction_points'] = int.tryParse(_pointsCtrl.text) ?? 2000;
    widget.panel['grid'] = _grid;
    widget.panel['custom_x_range'] = _customX;
    widget.panel['custom_y_range'] = _customY;
    if (_customX) {
      widget.panel['xmin'] = double.tryParse(_xMinCtrl.text) ?? double.nan;
      widget.panel['xmax'] = double.tryParse(_xMaxCtrl.text) ?? double.nan;
    }
    if (_customY) {
      widget.panel['ymin'] = double.tryParse(_yMinCtrl.text) ?? double.nan;
      widget.panel['ymax'] = double.tryParse(_yMaxCtrl.text) ?? double.nan;
    }
    widget.onSave();
    Navigator.pop(context);
  }
}

class _DataSourceDialog extends StatefulWidget {
  final List<Map<String, dynamic>> signals;
  final String defaultShot;
  final VoidCallback onSave;
  const _DataSourceDialog({required this.signals, required this.defaultShot, required this.onSave});

  @override State<_DataSourceDialog> createState() => _DataSourceDialogState();
}

class _DataSourceDialogState extends State<_DataSourceDialog> {
  final _rows = <_DSRow>[];
  List<String> _treeNames = [];
  Map<String, List<String>> _signalCache = {};

  static const _modes = ['Thin', 'Medium', 'Full'];
  static const _presetColors = [0xFF2364aa, 0xFFc44e52, 0xFF2f855a, 0xFF805ad5, 0xFFd97706, 0xFF0f766e, 0xFF9f1239, 0xFF4a5568, 0xFFdb2777, 0xFF16a34a, 0xFFea580c, 0xFF0891b2];

  @override void initState() {
    super.initState();
    _loadIndex();
    final count = widget.signals.isEmpty ? 1 : widget.signals.length;
    for (var i = 0; i < count; i++) {
      final s = i < widget.signals.length ? widget.signals[i] : null;
      _addRowFromSignal(s, i);
    }
  }

  Future<void> _loadIndex() async {
    try {
      final treeText = await _loadAsset('assets/source_index/trees.txt');
      _treeNames = treeText.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    } catch (_) { _treeNames = ['pcs_east']; }
    // Load initial signal options for each row
    for (final r in _rows) { _updateSignalOptions(r); }
    if (mounted) setState(() {});
  }

  Future<List<String>> _signalsForTree(String tree) async {
    final key = tree.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]+'), '_');
    if (_signalCache.containsKey(key)) return _signalCache[key]!;
    try {
      final text = await _loadAsset('assets/source_index/signals/$key.txt');
      final sigs = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
      _signalCache[key] = sigs;
      return sigs;
    } catch (_) { _signalCache[key] = []; return []; }
  }

  static InputDecoration _dsDeco() => const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8), border: OutlineInputBorder());

  static Widget _hdrCell(String text, double rightPad) {
    return Padding(
      padding: EdgeInsets.only(right: rightPad),
      child: Center(child: Text(text, style: TextStyle(fontSize: 11, color: Colors.grey.shade600))),
    );
  }

  Future<String> _loadAsset(String path) async {
    final bundle = DefaultAssetBundle.of(context);
    return await bundle.loadString(path);
  }

  void _addRowFromSignal(Map<String, dynamic>? s, int i) {
    _rows.add(_DSRow(
      shot: TextEditingController(text: s?['shot']?.toString() ?? widget.defaultShot),
      y: TextEditingController(text: s?['y_expr']?.toString() ?? ''),
      tree: TextEditingController(text: s?['experiment']?.toString() ?? 'pcs_east'),
      server: TextEditingController(text: s?['server_ip']?.toString() ?? '202.127.204.12'),
    )..hidden = s?['hidden'] == true
     ..colorIdx = i % _presetColors.length
     ..readMode = (s?['read_mode'] as int?) ?? 0);
    if (s != null && s['color_name'] != null) {
      final hex = s['color_name'].toString().replaceFirst('#', '');
      final c = int.tryParse(hex, radix: 16);
      if (c != null) {
        final full = 0xFF000000 | c;
        for (var j = 0; j < _presetColors.length; j++) { if (_presetColors[j] == full) { _rows.last.colorIdx = j; break; } }
        _rows.last.customColor = Color(full);
      }
    }
  }

  @override void dispose() { for (final r in _rows) { r.dispose(); } super.dispose(); }

  @override Widget build(BuildContext ctx) {
    final ddStyle = TextStyle(fontSize: 11, color: Theme.of(ctx).colorScheme.onSurface);
    return AlertDialog(
      title: Row(children: [
        const Text('Data Source Setup'),
        const Spacer(),
        IconButton(icon: const Icon(Icons.add, size: 18), tooltip: 'Add Curve', onPressed: _rows.length < 8 ? () {
          final last = _rows.isNotEmpty ? _rows.last : null;
          final shotCtrl = TextEditingController(text: last?.shot.text ?? widget.defaultShot);
          final treeCtrl = TextEditingController(text: last?.tree.text ?? 'pcs_east');
          final yCtrl = TextEditingController();
          final serverCtrl = TextEditingController(text: last?.server.text ?? '202.127.204.12');
          final newRow = _DSRow(shot: shotCtrl, y: yCtrl, tree: treeCtrl, server: serverCtrl)..colorIdx = _rows.length % _presetColors.length;
          setState(() { _rows.add(newRow); });
          _updateSignalOptions(newRow);
        } : null),
      ]),
      content: SizedBox(
        height: 180,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: IntrinsicWidth(
            child: SingleChildScrollView(
              child: Table(
                columnWidths: const {
                  0: FixedColumnWidth(84),
                  1: FixedColumnWidth(124),
                  2: FixedColumnWidth(184),
                  3: FixedColumnWidth(144),
                  4: FixedColumnWidth(34),
                  5: FixedColumnWidth(46),
                  6: FixedColumnWidth(114),
                  7: FixedColumnWidth(26),
                },
                defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                children: [
                  TableRow(children: [
                    _hdrCell('Shot', 4),
                    _hdrCell('Tree', 4),
                    _hdrCell('Signal', 4),
                    _hdrCell('Server IP', 4),
                    _hdrCell('Color', 4),
                    _hdrCell('Hide', 2),
                    _hdrCell('Data', 4),
                    _hdrCell('Del', 0),
                  ]),
                  for (var i = 0; i < _rows.length; i++)
                    TableRow(children: [
                      Padding(padding: const EdgeInsets.only(right: 4), child: TextField(controller: _rows[i].shot, decoration: _dsDeco(), style: const TextStyle(fontSize: 12))),
                      Padding(padding: const EdgeInsets.only(right: 4), child: _AutocompleteField(controller: _rows[i].tree, options: _treeNames, label: 'Tree', onChanged: () { _updateSignalOptions(_rows[i]); setState(() {}); })),
                      Padding(padding: const EdgeInsets.only(right: 4), child: _AutocompleteField(controller: _rows[i].y, options: _rows[i]._signalOptions, label: 'Signal', onChanged: () { _updateSignalOptions(_rows[i]); })),
                      Padding(padding: const EdgeInsets.only(right: 4), child: TextField(controller: _rows[i].server, decoration: _dsDeco(), style: const TextStyle(fontSize: 12))),
                      Padding(padding: const EdgeInsets.only(right: 4), child: Center(child: _ColorPicker(row: _rows[i], onChanged: () => setState(() {})))),
                      Padding(padding: const EdgeInsets.only(right: 2), child: Center(child: Checkbox(value: _rows[i].hidden, onChanged: (v) => setState(() => _rows[i].hidden = v ?? false)))),
                      Padding(padding: const EdgeInsets.only(right: 4), child: DropdownButtonFormField<int>(initialValue: _rows[i].readMode, decoration: _dsDeco(), style: ddStyle, dropdownColor: Theme.of(ctx).colorScheme.surface, items: List.generate(3, (j) => DropdownMenuItem(value: j, child: Text(_modes[j], style: ddStyle))), onChanged: (v) { if (v != null) setState(() => _rows[i].readMode = v); })),
                      _rows.length > 1
                          ? GestureDetector(onTap: () => setState(() { _rows[i].dispose(); _rows.removeAt(i); }), child: const Icon(Icons.close, size: 16, color: Colors.red))
                          : const SizedBox(width: 16),
                    ]),
                ],
              ),
            ),
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')), TextButton(onPressed: _save, child: const Text('OK'))],
    );
  }

  void _updateSignalOptions(_DSRow row) async {
    final sigs = await _signalsForTree(row.tree.text);
    setState(() => row._signalOptions = sigs);
  }

  void _save() {
    widget.signals.clear();
    for (final r in _rows) {
      if (r.y.text.trim().isEmpty) continue;
      final shot = r.shot.text.trim();
      final colorValue = r.customColor ?? Color(_presetColors[r.colorIdx % _presetColors.length]);
      widget.signals.add({
        'y_expr': r.y.text.trim(),
        'experiment': r.tree.text.trim(),
        'server_ip': r.server.text.trim(),
        if (shot.isNotEmpty && shot != widget.defaultShot) 'shot': shot,
        'color_name': '#${colorValue.value.toRadixString(16).padLeft(8, '0').substring(2)}',
        'hidden': r.hidden,
        'read_mode': r.readMode,
      });
    }
    widget.onSave();
    Navigator.pop(context, true);
  }
}

class _AutocompleteField extends StatefulWidget {
  final TextEditingController controller;
  final List<String> options;
  final String label;
  final VoidCallback? onChanged;
  const _AutocompleteField({required this.controller, required this.options, required this.label, this.onChanged});
  @override State<_AutocompleteField> createState() => _AutocompleteFieldState();
}

class _AutocompleteFieldState extends State<_AutocompleteField> {
  final _node = FocusNode();
  OverlayEntry? _overlay;
  final _layerLink = LayerLink();

  @override void initState() {
    super.initState();
    widget.controller.addListener(_update);
  }

  @override void dispose() {
    _removeOverlay();
    widget.controller.removeListener(_update);
    _node.dispose();
    super.dispose();
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  void _update() {
    final v = widget.controller.text.toLowerCase();
    final hints = v.isEmpty ? <String>[] : widget.options.where((o) => o.toLowerCase().contains(v)).take(20).toList();
    _removeOverlay();
    if (hints.isNotEmpty && _node.hasFocus) {
      // Don't show if there's exactly one hint that matches the current text exactly
      if (hints.length == 1 && hints[0].toLowerCase() == v) return;
      _overlay = OverlayEntry(builder: (_) => Positioned(width: 220, child: CompositedTransformFollower(link: _layerLink, showWhenUnlinked: false, offset: const Offset(0, 40), child: Material(elevation: 8, child: Container(constraints: const BoxConstraints(maxHeight: 200), decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade300)), child: ListView.builder(padding: EdgeInsets.zero, shrinkWrap: true, itemCount: hints.length, itemBuilder: (_, i) => ListTile(dense: true, title: Text(hints[i], style: const TextStyle(fontSize: 12)), onTap: () { widget.controller.text = hints[i]; widget.controller.selection = TextSelection.collapsed(offset: hints[i].length); _removeOverlay(); widget.onChanged?.call(); })))))));
      Overlay.of(context).insert(_overlay!);
    }
  }

  @override Widget build(BuildContext ctx) => CompositedTransformTarget(link: _layerLink, child: TextField(controller: widget.controller, focusNode: _node, decoration: _DataSourceDialogState._dsDeco(), style: const TextStyle(fontSize: 12), onChanged: (_) => _update()));
}

class _ColorPicker extends StatelessWidget {
  final _DSRow row;
  final VoidCallback onChanged;
  const _ColorPicker({required this.row, required this.onChanged});

  @override Widget build(BuildContext ctx) {
    final current = row.customColor ?? Color(_DataSourceDialogState._presetColors[row.colorIdx % _DataSourceDialogState._presetColors.length]);
    return GestureDetector(
      onTap: () => _showColorDialog(ctx, current),
      child: Container(width: 22, height: 22, decoration: BoxDecoration(color: current, border: Border.all(color: Colors.grey), borderRadius: BorderRadius.circular(3))),
    );
  }

  void _showColorDialog(BuildContext ctx, Color current) {
    final topColors = _DataSourceDialogState._presetColors;
    Color selected = current;
    showDialog(context: ctx, builder: (ctx) => StatefulBuilder(builder: (ctx, setSt) {
      return AlertDialog(
        title: Row(children: [const Text('Curve Color'), const SizedBox(width: 12), Container(width: 28, height: 28, decoration: BoxDecoration(color: selected, border: Border.all(color: Colors.grey), borderRadius: BorderRadius.circular(3)))]),
        content: SizedBox(width: 300, child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Wrap(spacing: 2, runSpacing: 2, children: topColors.map((c) => GestureDetector(
              onTap: () { selected = Color(c); setSt(() {}); },
              child: Container(width: 22, height: 22, decoration: BoxDecoration(color: Color(c), border: Border.all(color: selected == Color(c) ? Colors.black : Colors.grey, width: selected == Color(c) ? 2 : 1))),
            )).toList()),
            const SizedBox(height: 8),
            // Continuous HSV picker: X = hue, Y = value (brightness)
            GestureDetector(
              onPanDown: (d) => _pickColor(d.localPosition, setSt, (c) => selected = c),
              onPanUpdate: (d) => _pickColor(d.localPosition, setSt, (c) => selected = c),
              child: ClipRRect(borderRadius: BorderRadius.circular(4), child: CustomPaint(size: const Size(280, 180), painter: _HsvPainter())),
            ),
            const SizedBox(height: 8),
            Row(children: [const Text('#'), Expanded(child: TextField(decoration: const InputDecoration(isDense: true), onSubmitted: (v) { final cleaned = v.replaceFirst('#', ''); final c = int.tryParse(cleaned, radix: 16); if (c != null && cleaned.length == 6) { selected = Color(0xFF000000 | c); setSt(() {}); } }))]),
          ]),
        )),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () { row.customColor = selected; row.colorIdx = topColors.indexWhere((c) => c == selected.value); if (row.colorIdx < 0) row.colorIdx = 0; onChanged(); Navigator.pop(ctx); }, child: const Text('OK')),
        ],
      );
    }));
  }

  void _pickColor(Offset pos, StateSetter setSt, void Function(Color) setColor) {
    if (pos.dx < 0 || pos.dy < 0 || pos.dx > 280 || pos.dy > 180) return;
    final hue = (pos.dx / 280 * 360).clamp(0.0, 359.0);
    final val = (1.0 - pos.dy / 180).clamp(0.0, 1.0);
    setSt(() => setColor(HSVColor.fromAHSV(1, hue, 1, val).toColor()));
  }
}

class _HsvPainter extends CustomPainter {
  @override void paint(Canvas canvas, Size size) {
    for (var x = 0.0; x < size.width; x += 1.0) {
      final hue = (x / size.width * 360);
      final paint = Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [HSVColor.fromAHSV(1.0, hue, 1.0, 1.0).toColor(), Colors.black]).createShader(Rect.fromLTWH(x, 0, 1.0, size.height));
      canvas.drawRect(Rect.fromLTWH(x, 0, 1.0, size.height), paint);
    }
  }
  @override bool shouldRepaint(_) => false;
}

class _DSRow {
  final TextEditingController shot, y, tree, server;
  bool hidden = false;
  int readMode = 0;
  int colorIdx = 0;
  Color? customColor;
  List<String> _signalOptions = [];
  _DSRow({required this.shot, required this.y, required this.tree, required this.server});
  void dispose() { shot.dispose(); y.dispose(); tree.dispose(); server.dispose(); }
}
