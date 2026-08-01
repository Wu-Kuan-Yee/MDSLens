import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'plot_render_cache.dart';
import 'polished_dropdown.dart';
import 'polished_popup_menu.dart';
import 'package:fl_chart/fl_chart.dart';
import '../models/app_state.dart';
import '../services/platform_file_dialog.dart';
import '../services/source_index.dart';
import 'dialogs/keyboard_safe_dialog.dart';
import 'dialogs/multi_panel_export.dart';

const _colors = [
  Color(0xFF2364aa),
  Color(0xFFc44e52),
  Color(0xFF2f855a),
  Color(0xFF805ad5),
  Color(0xFFd97706),
  Color(0xFF0f766e),
  Color(0xFF9f1239),
  Color(0xFF4a5568),
  Color(0xFFdb2777),
  Color(0xFF16a34a),
  Color(0xFFea580c),
  Color(0xFF0891b2),
];

String resolveDataSourceShot({
  Object? signalShot,
  Object? panelShot,
  String displayedShot = '',
  String inputShot = '',
}) {
  for (final candidate in [
    signalShot?.toString(),
    panelShot?.toString(),
    displayedShot,
    inputShot,
  ]) {
    final shot = candidate?.trim() ?? '';
    if (shot.isNotEmpty) return shot;
  }
  return '';
}

String signalLegendLabel(Map<dynamic, dynamic> signal) {
  final custom = signal['legend']?.toString().trim() ?? '';
  if (custom.isNotEmpty) return custom;
  return (signal['y_expr']?.toString().trim() ?? '').replaceFirst(
    RegExp(r'^\\+'),
    '',
  );
}

double? interpolateWaveformY(List<List<double>> points, double x) {
  if (points.isEmpty || !x.isFinite) return null;
  if (points.length == 1) return points.first[1];
  final ascending = points.first[0] <= points.last[0];
  final firstX = points.first[0];
  final lastX = points.last[0];
  if ((ascending && x <= firstX) || (!ascending && x >= firstX)) {
    return points.first[1];
  }
  if ((ascending && x >= lastX) || (!ascending && x <= lastX)) {
    return points.last[1];
  }

  var low = 0;
  var high = points.length - 1;
  while (low + 1 < high) {
    final middle = (low + high) ~/ 2;
    final middleX = points[middle][0];
    if ((ascending && middleX <= x) || (!ascending && middleX >= x)) {
      low = middle;
    } else {
      high = middle;
    }
  }
  final left = points[low];
  final right = points[high];
  final dx = right[0] - left[0];
  if (!dx.isFinite || dx == 0) {
    return (x - left[0]).abs() <= (right[0] - x).abs() ? left[1] : right[1];
  }
  final y = left[1] + (right[1] - left[1]) * (x - left[0]) / dx;
  return y.isFinite ? y : null;
}

String formatPointXForReadout(
  double value,
  List<List<double>>? points, {
  double? resolution,
}) {
  resolution ??= _localXResolution(points, value);
  if (resolution == null || !resolution.isFinite || resolution <= 0) {
    return value.toStringAsPrecision(12);
  }

  var exponent = (math.log(resolution) / math.ln10).floor();
  var mantissa = resolution / math.pow(10, exponent);
  // Collapse subtraction noise into a human-scale sampling step.
  mantissa = (mantissa * 100).roundToDouble() / 100;
  if (mantissa >= 10) {
    mantissa /= 10;
    exponent++;
  }

  var mantissaDecimals = 2;
  var scale = 1.0;
  for (var decimals = 0; decimals <= 2; decimals++) {
    if ((mantissa * scale - (mantissa * scale).round()).abs() < 1e-7) {
      mantissaDecimals = decimals;
      break;
    }
    scale *= 10;
  }
  final initialDecimals = math.max(0, -exponent + mantissaDecimals);
  const doubleEpsilon = 2.220446049250313e-16;
  final tolerance = math.max(
    resolution * 1e-3,
    value.abs() * doubleEpsilon * 4,
  );
  for (var decimals = initialDecimals; decimals <= 15; decimals++) {
    final formatted = value.toStringAsFixed(decimals);
    final rounded = double.tryParse(formatted);
    if (rounded != null && (rounded - value).abs() <= tolerance) {
      return _trimFixedNumber(formatted);
    }
  }
  return value.toStringAsPrecision(16);
}

double? _localXResolution(List<List<double>>? points, double x) {
  if (points == null || points.length < 2 || !x.isFinite) return null;
  final ascending = points.first[0] <= points.last[0];
  var low = 0;
  var high = points.length;
  while (low < high) {
    final middle = (low + high) ~/ 2;
    final middleX = points[middle][0];
    final before = ascending ? middleX < x : middleX > x;
    if (before) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  final index = low.clamp(0, points.length - 1).toInt();
  var resolution = double.infinity;
  if (index > 0) {
    final step = (points[index][0] - points[index - 1][0]).abs();
    if (step > 0) resolution = math.min(resolution, step);
  }
  if (index + 1 < points.length) {
    final step = (points[index + 1][0] - points[index][0]).abs();
    if (step > 0) resolution = math.min(resolution, step);
  }
  return resolution.isFinite ? resolution : null;
}

String _trimFixedNumber(String text) {
  if (!text.contains('.')) return text;
  var end = text.length;
  while (end > 0 && text.codeUnitAt(end - 1) == 0x30) {
    end--;
  }
  if (end > 0 && text.codeUnitAt(end - 1) == 0x2e) {
    end--;
  }
  final trimmed = text.substring(0, end);
  return trimmed == '-0' ? '0' : trimmed;
}

Future<bool> showPanelSetupEditor(
  BuildContext context,
  Map<String, dynamic> panel, {
  PanelSetupValues Function()? actualValues,
  Listenable? actualChanges,
}) async {
  var saved = false;
  await showDialog<void>(
    context: context,
    builder: (context) => _PanelSetupDialog(
      panel: panel,
      actualValues: actualValues,
      actualChanges: actualChanges,
      onSave: () => saved = true,
    ),
  );
  return saved;
}

class PanelSetupValues {
  const PanelSetupValues({
    required this.title,
    required this.xLabel,
    required this.yLabel,
    required this.extractionPoints,
  });

  final String title;
  final String xLabel;
  final String yLabel;
  final int extractionPoints;
}

Future<bool> showDataSourceSetupEditor(
  BuildContext context, {
  required List<Map<String, dynamic>> signals,
  required String defaultShot,
}) async {
  return await showDialog<bool>(
        context: context,
        builder: (context) => _DataSourceDialog(
          signals: signals,
          defaultShot: defaultShot,
          onSave: () {},
        ),
      ) ??
      false;
}

class PlotPanel extends StatefulWidget {
  final int plotIdx;
  final bool selected;
  final void Function()? onTap;
  final void Function(String action)? onContextAction;
  final PlatformSaveDialog? exportSaveDialog;
  final ValueListenable<PanelShortcutRequest?>? panelShortcutRequests;

  const PlotPanel({
    super.key,
    required this.plotIdx,
    this.onTap,
    this.onContextAction,
    this.exportSaveDialog,
    this.panelShortcutRequests,
    this.selected = false,
  });

  @override
  State<PlotPanel> createState() => _PlotPanelState();
}

class _PlotPanelState extends State<PlotPanel> {
  final _chartAreaKey = GlobalKey();
  final _listenerKey = GlobalKey();
  final _renderCache = PlotRenderCache();
  double _viewMinX = double.nan,
      _viewMaxX = double.nan,
      _viewMinY = double.nan,
      _viewMaxY = double.nan;
  int _lastResetId = -1;
  int _lastRateResetId = -1;
  bool _midPanning = false;
  Offset? _lastMidPanPos;
  bool _inRubberBand = false;
  Offset? _rubberBandStart;
  Rect? _rubberBandRect;
  final Map<int, Offset> _touchPositions = <int, Offset>{};
  bool _multiTouchActive = false;
  Offset? _lastMultiTouchFocalPoint;
  double? _lastMultiTouchSpan;
  bool _trackpadGestureActive = false;
  double _lastTrackpadScale = 1;
  int? _activeStylusPointer;
  Offset? _stylusDownLocal;
  bool _stylusDragStarted = false;
  bool _stylusLongPressTriggered = false;
  bool _stylusShouldErase = false;
  Timer? _longPressTimer;
  Offset? _longPressStartPos;
  static const double _stylusLongPressSlop = 12;
  int _lastPanelShortcutRequestId = 0;

  @override
  void initState() {
    super.initState();
    widget.panelShortcutRequests?.addListener(_handlePanelShortcutRequest);
  }

  @override
  void didUpdateWidget(covariant PlotPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.panelShortcutRequests != widget.panelShortcutRequests) {
      oldWidget.panelShortcutRequests?.removeListener(
        _handlePanelShortcutRequest,
      );
      widget.panelShortcutRequests?.addListener(_handlePanelShortcutRequest);
    }
  }

  @override
  void dispose() {
    widget.panelShortcutRequests?.removeListener(_handlePanelShortcutRequest);
    _longPressTimer?.cancel();
    super.dispose();
  }

  void _handlePanelShortcutRequest() {
    final request = widget.panelShortcutRequests?.value;
    if (request == null ||
        request.plotIndex != widget.plotIdx ||
        request.id == _lastPanelShortcutRequestId) {
      return;
    }
    _lastPanelShortcutRequestId = request.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_runPanelShortcutRequest(request.action));
    });
  }

  Future<void> _runPanelShortcutRequest(String action) async {
    final app = context.read<AppState>();
    switch (action) {
      case 'source':
        await _showDataSourceSetup(context, app);
        break;
      case 'setup':
        await _showPanelSetup(context, app);
        break;
      case 'export':
        await exportMultiplePanels(
          context,
          app,
          saveDialog: widget.exportSaveDialog,
          initialSelection: {widget.plotIdx},
          allowPanelSelection: false,
        );
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    if (widget.plotIdx >= app.plots.length) return const SizedBox();
    final plot = app.plots[widget.plotIdx];
    if (_lastResetId < 0) {
      _lastResetId = app.viewResetId;
      _lastRateResetId = app.rateViewResetId;
      _restoreView(plot, app);
    } else if (app.viewResetId != _lastResetId) {
      _lastResetId = app.viewResetId;
      _lastRateResetId = app.rateViewResetId;
      _resetView(plot);
      if (app.sharedXMin != null) {
        _viewMinX = app.sharedXMin!;
        _viewMaxX = app.sharedXMax!;
      }
      if (app.sharedYMin != null) {
        _viewMinY = app.sharedYMin!;
        _viewMaxY = app.sharedYMax!;
      }
      _storeView(plot);
    } else if (app.rateViewResetId != _lastRateResetId) {
      _lastRateResetId = app.rateViewResetId;
      _viewMinY = double.nan;
      _viewMaxY = double.nan;
      plot.viewMinY = null;
      plot.viewMaxY = null;
    }

    final panel = _findPanel(app);
    final theme = Theme.of(context);
    final isLoading = app.isPlotFetching(widget.plotIdx);

    // Build line bars with MinMax decimation
    final bars = <LineChartBarData>[];
    final activeSeries = <SeriesData>[];
    final sigSpecs = (panel['signal_specs'] as List?)?.cast<Map>() ?? [];
    final customX = panel['custom_x_range'] == true;
    final renderMinX = customX
        ? (panel['xmin'] as num?)?.toDouble()
        : (_viewMinX.isFinite ? _viewMinX : null);
    final renderMaxX = customX
        ? (panel['xmax'] as num?)?.toDouble()
        : (_viewMaxX.isFinite ? _viewMaxX : null);
    final approximatePanelWidth =
        MediaQuery.sizeOf(context).width / math.max(1, app.columns.length);
    final renderPointBudget = plotRenderPointBudget(approximatePanelWidth);
    double? viewMinX, viewMaxX, viewMinY, viewMaxY;
    for (var i = 0; i < plot.series.length; i++) {
      final s = plot.series[i];
      if (s?.hasData != true) continue;
      final series = s!;
      if (i < sigSpecs.length && signalIsHidden(sigSpecs[i])) continue;
      activeSeries.add(series);
      final rendered = _renderCache.render(
        series,
        maxPoints: renderPointBudget,
        minX: renderMinX,
        maxX: renderMaxX,
      );
      final spots = rendered.spots;
      viewMinX =
          viewMinX == null ? rendered.minX : math.min(viewMinX, rendered.minX);
      viewMaxX =
          viewMaxX == null ? rendered.maxX : math.max(viewMaxX, rendered.maxX);
      viewMinY =
          viewMinY == null ? rendered.minY : math.min(viewMinY, rendered.minY);
      viewMaxY =
          viewMaxY == null ? rendered.maxY : math.max(viewMaxY, rendered.maxY);
      bars.add(
        LineChartBarData(
          spots: spots,
          isCurved: false,
          color: _sigColor(i, sigSpecs),
          barWidth: 1,
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(show: false),
        ),
      );
    }
    _renderCache.retain(activeSeries);

    return Stack(
      children: [
        GestureDetector(
          onTapDown: (_) => widget.onTap?.call(),
          onTapUp: (details) {
            final a = context.read<AppState>();
            if (a.interactionMode != 1) return;
            if (a.pointLocked) a.pointLocked = false;
            _updatePointCrosshair(details.localPosition, chooseSeries: true);
          },
          onSecondaryTapUp: (details) {
            if (_isStylusKind(details.kind)) return;
            _showContextMenu(context, details.globalPosition);
          },
          // Long press handled manually via _longPressTimer in onPointerDown/Up for mobile compatibility
          child: Listener(
            key: _listenerKey,
            onPointerSignal: _handleScrollWheel,
            onPointerPanZoomStart: _handleTrackpadGestureStart,
            onPointerPanZoomUpdate: _handleTrackpadGestureUpdate,
            onPointerPanZoomEnd: _handleTrackpadGestureEnd,
            onPointerDown: (e) {
              _handlePointerDown(e);
              if (e.kind == PointerDeviceKind.touch &&
                  _activeStylusPointer == null &&
                  !_multiTouchActive) {
                _startLongPressTimer(e);
              }
            },
            onPointerMove: (e) {
              _handlePointerMove(e);
              _cancelLongPressIfMoved(e);
            },
            onPointerHover: _handlePointerHover,
            onPointerUp: (e) {
              _handlePointerUp(e);
              _cancelLongPressTimer();
            },
            onPointerCancel: (e) {
              _handlePointerCancel(e);
              _cancelLongPressTimer();
            },
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    border: Border.all(
                      color: widget.selected
                          ? const Color(0xFFFF00FF)
                          : theme.dividerColor.withValues(alpha: 0.3),
                      width: widget.selected ? 2 : 1,
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Column(
                    children: [
                      Expanded(
                        child: bars.isEmpty
                            ? isLoading
                                ? _buildLoadingIndicator(app, theme)
                                : Center(
                                    child: Text(
                                      _getPlaceholderText(plot),
                                      style: TextStyle(
                                        color: Colors.grey,
                                        fontFamily: app.effectiveFontFamily,
                                        fontSize: app.fontUiSize.toDouble(),
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                  )
                            : Stack(
                                key: _chartAreaKey,
                                children: [
                                  _buildChart(
                                    bars,
                                    plot,
                                    panel,
                                    theme,
                                    viewMinX,
                                    viewMaxX,
                                    viewMinY,
                                    viewMaxY,
                                  ),
                                ],
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (isLoading && bars.isNotEmpty)
          Positioned.fill(
            child: IgnorePointer(child: _buildLoadingIndicator(app, theme)),
          ),
        if (_inRubberBand && _rubberBandRect != null)
          Positioned(
            key: ValueKey('plot-rubber-band-${widget.plotIdx}'),
            left: _rubberBandRect!.left,
            top: _rubberBandRect!.top,
            width: _rubberBandRect!.width,
            height: _rubberBandRect!.height,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0x180000FF),
                  border: Border.all(color: const Color(0xFF0000FF), width: 1),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildChart(
    List<LineChartBarData> bars,
    PlotData plot,
    Map<String, dynamic> panel,
    ThemeData theme,
    double? autoMinX,
    double? autoMaxX,
    double? autoMinY,
    double? autoMaxY,
  ) {
    final textColor = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final tickColor = theme.colorScheme.onSurface.withValues(alpha: 0.4);
    final app = context.read<AppState>();
    final fontFamily = app.effectiveFontFamily;
    final legendSize = app.fontLegendSize.toDouble();
    final axisSize = app.fontAxisSize.toDouble();
    final unitSize = app.fontUnitSize.toDouble();
    final showGrid = panel['grid'] ?? true;
    final customX = panel['custom_x_range'] == true;
    final customY = panel['custom_y_range'] == true;

    // Use view state if user has interacted; otherwise auto-scale to displayed data
    final xMin = customX
        ? ((panel['xmin'] as num?)?.toDouble())
        : (_viewMinX.isNaN ? autoMinX : _viewMinX);
    final xMax = customX
        ? ((panel['xmax'] as num?)?.toDouble())
        : (_viewMaxX.isNaN ? autoMaxX : _viewMaxX);
    final yMin = customY
        ? ((panel['ymin'] as num?)?.toDouble())
        : (_viewMinY.isNaN ? autoMinY : _viewMinY);
    final yMax = customY
        ? ((panel['ymax'] as num?)?.toDouble())
        : (_viewMaxY.isNaN ? autoMaxY : _viewMaxY);

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
        // Insets grow with the configured axis/unit fonts.
        //   top = 0 (no top titles)
        //   right = full width (no right titles)
        final gridLeft = _gridLeftInset(app);
        final gridTop = 0.0;
        final gridRight = cw;
        final bottomInset = _gridBottomInset(app);
        final gridBottom = ch - bottomInset;
        final gridW = gridRight - gridLeft;
        final gridH = gridBottom - gridTop;

        // Tick count based on pixel size matching C++:
        //   xTickCount = clamp(width/78 + 1, 3, 7)
        //   yTickCount = clamp(height/34 + 1, 3, 6)
        final xTickCount = xMin != null && xMax != null
            ? (gridW / 78.0 + 1).round().clamp(3, 7)
            : 0;
        final yTickCount = yMin != null && yMax != null
            ? (gridH / 34.0 + 1).round().clamp(3, 6)
            : 0;
        final xTicks =
            xTickCount > 1 ? evenTicks(xMin!, xMax!, xTickCount) : <double>[];
        final yTicks =
            yTickCount > 1 ? evenTicks(yMin!, yMax!, yTickCount) : <double>[];

        return Stack(
          children: [
            if (plot.title.isNotEmpty)
              Positioned(
                left: gridLeft,
                right: 0,
                top: gridTop + 2,
                child: Center(
                  child: Text(
                    plot.title,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontFamily: fontFamily,
                      fontSize: legendSize,
                      color: textColor,
                    ),
                  ),
                ),
              ),
            RepaintBoundary(
              child: LineChart(
                LineChartData(
                  clipData: const FlClipData.all(),
                  lineBarsData: bars,
                  gridData: FlGridData(
                    show: showGrid,
                    drawVerticalLine: showGrid,
                    drawHorizontalLine: showGrid,
                    getDrawingHorizontalLine: (v) => FlLine(
                      color: theme.dividerColor.withValues(alpha: 0.15),
                      strokeWidth: 0.5,
                    ),
                    getDrawingVerticalLine: (v) => FlLine(
                      color: theme.dividerColor.withValues(alpha: 0.15),
                      strokeWidth: 0.5,
                    ),
                  ),
                  titlesData: FlTitlesData(
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: bottomInset,
                        getTitlesWidget: (v, m) => const SizedBox(),
                      ),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: gridLeft,
                        getTitlesWidget: (v, m) => const SizedBox(),
                      ),
                    ),
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                  ),
                  borderData: FlBorderData(
                    show: true,
                    border: Border.all(
                      color: theme.dividerColor.withValues(alpha: 0.5),
                      width: 1,
                    ),
                  ),
                  // Point interaction is handled by the panel's outer pointer
                  // layer. Keeping fl_chart's pan recognizer enabled would win
                  // the gesture arena and prevent one-finger page scrolling.
                  lineTouchData: const LineTouchData(enabled: false),
                  minX: xMin,
                  maxX: xMax,
                  minY: yMin,
                  maxY: yMax,
                ),
                duration: Duration.zero,
              ),
            ),
            // Y-axis tick marks — 3px horizontal lines (matching C++ render.cpp:251)
            for (int i = 0; i < yTicks.length; i++)
              Positioned(
                left: gridLeft,
                top: gridTop +
                    ((yTicks.length - 1 - i) / (yTicks.length - 1)) * gridH,
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
                top: (gridTop +
                        ((yTicks.length - 1 - i) / (yTicks.length - 1)) *
                            gridH -
                        6)
                    .clamp(2.0, double.infinity),
                child: SizedBox(
                  width: gridLeft - 6,
                  child: Text(
                    _fmtAxis(yTicks[i]),
                    style: TextStyle(
                      fontFamily: fontFamily,
                      fontSize: axisSize,
                      color: textColor,
                    ),
                    textAlign: TextAlign.right,
                  ),
                ),
              ),
            // X-axis tick values — below tick marks (row 1 of 2 below axis)
            // First label left-aligned, last label right-aligned, others centered
            if (xTicks.isNotEmpty)
              for (int i = 0; i < xTicks.length; i++) ...[
                if (i == 0)
                  Positioned(
                    left: gridLeft,
                    top: gridBottom + 4,
                    child: Text(
                      _fmtAxis(xTicks[i]),
                      style: TextStyle(
                        fontFamily: fontFamily,
                        fontSize: axisSize,
                        color: textColor,
                      ),
                    ),
                  )
                else if (i == xTicks.length - 1)
                  Positioned(
                    right: cw - gridRight,
                    top: gridBottom + 4,
                    child: Text(
                      _fmtAxis(xTicks[i]),
                      style: TextStyle(
                        fontFamily: fontFamily,
                        fontSize: axisSize,
                        color: textColor,
                      ),
                    ),
                  )
                else
                  Positioned(
                    left: gridLeft + (i / (xTicks.length - 1)) * gridW - 16,
                    top: gridBottom + 4,
                    child: Text(
                      _fmtAxis(xTicks[i]),
                      style: TextStyle(
                        fontFamily: fontFamily,
                        fontSize: axisSize,
                        color: textColor,
                      ),
                    ),
                  ),
              ],
            // X-axis name label — below tick values (row 2 of 2 below axis)
            Positioned(
              left: gridLeft,
              right: 0,
              top: gridBottom + 16,
              child: Center(
                child: Text(
                  _effectiveXLabel(plot, panel),
                  style: TextStyle(
                    fontFamily: fontFamily,
                    fontSize: unitSize,
                    color: textColor,
                  ),
                ),
              ),
            ),
            Positioned(
              left: -2,
              top: gridTop,
              bottom: ch - gridBottom,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: RotatedBox(
                    quarterTurns: -1,
                    child: Text(
                      _effectiveYLabel(plot, panel),
                      style: TextStyle(
                        fontFamily: fontFamily,
                        fontSize: unitSize,
                        color: textColor,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            _buildLegend(
              panel,
              theme,
              app,
              gridW,
              gridH,
              plot.title.isNotEmpty ? legendSize + 8 : 6,
            ),
            ValueListenableBuilder<CrosshairSnapshot?>(
              valueListenable: app.crosshairChanges,
              builder: (context, crosshair, child) => _buildCrosshairOverlay(
                plot: plot,
                panel: panel,
                app: app,
                theme: theme,
                crosshair: crosshair,
                gridLeft: gridLeft,
                gridTop: gridTop,
                gridWidth: gridW,
                gridHeight: gridH,
                minX: xMin,
                maxX: xMax,
                minY: yMin,
                maxY: yMax,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildLegend(
    Map<String, dynamic> panel,
    ThemeData theme,
    AppState app,
    double gridWidth,
    double gridHeight,
    double top,
  ) {
    final rawSignals = panel['signal_specs'];
    if (rawSignals is! List) return const SizedBox.shrink();
    final entries = <({int index, Map<dynamic, dynamic> signal})>[
      for (var index = 0; index < rawSignals.length; index++)
        if (rawSignals[index] is Map &&
            !signalIsHidden(rawSignals[index] as Map) &&
            signalLegendLabel(rawSignals[index] as Map).isNotEmpty)
          (index: index, signal: rawSignals[index] as Map),
    ];
    if (entries.isEmpty) return const SizedBox.shrink();

    final maxWidth = math.max(72.0, math.min(220.0, gridWidth * 0.48));
    final maxHeight = math.max(20.0, gridHeight - top - 4);
    return Positioned(
      right: 6,
      top: top,
      child: IgnorePointer(
        child: SizedBox(
          width: maxWidth,
          height: maxHeight,
          child: Align(
            alignment: Alignment.topRight,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.topRight,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface.withValues(alpha: 0.82),
                  border: Border.all(
                    color: theme.colorScheme.outlineVariant.withValues(
                      alpha: 0.7,
                    ),
                  ),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 4,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final entry in entries)
                        Padding(
                          key: ValueKey(
                            'plot-legend-${widget.plotIdx}-${entry.index}',
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: _sigColor(
                                    entry.index,
                                    rawSignals.cast<Map>(),
                                  ),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                signalLegendLabel(entry.signal),
                                style: TextStyle(
                                  color: theme.colorScheme.onSurface,
                                  fontFamily: app.effectiveFontFamily,
                                  fontSize: app.fontLegendSize.toDouble(),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _fmtAxis(double v) {
    final abs = v.abs();
    if (!abs.isFinite) return '';
    if (abs >= 1000 || (abs > 0 && abs < 0.001)) {
      return v.toStringAsExponential(1);
    }
    if (abs >= 100) return v.toStringAsFixed(0);
    if (abs >= 10) return v.toStringAsFixed(1);
    // Adaptive: 3 decimals then strip trailing zeros for natural precision
    final s = v.toStringAsFixed(3);
    return s.contains('.')
        ? s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '')
        : s;
  }

  Widget _buildLoadingIndicator(AppState app, ThemeData theme) {
    return Center(
      child: Container(
        key: ValueKey('plot-loading-${widget.plotIdx}'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.92,
          ),
          border: Border.all(color: theme.colorScheme.primary),
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: theme.colorScheme.shadow.withValues(alpha: 0.18),
              blurRadius: 8,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'Loading...',
              style: TextStyle(
                color: theme.colorScheme.onSurface,
                fontFamily: app.effectiveFontFamily,
                fontSize: app.fontUiSize.toDouble(),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _getPlaceholderText(PlotData plot) {
    for (final s in plot.series) {
      if (s?.error != null && s!.error!.isNotEmpty) {
        return s.error!;
      }
    }
    return 'No data';
  }

  double _gridLeftInset(AppState app) {
    return math.max(50, app.fontAxisSize * 3.8 + app.fontUnitSize + 6);
  }

  double _gridBottomInset(AppState app) {
    return math.max(32, app.fontAxisSize + app.fontUnitSize + 15);
  }

  ({int seriesIndex, double y})? _crosshairValue(
    PlotData plot,
    Map<String, dynamic> panel,
    double? x,
    int preferredSeries,
  ) {
    if (x == null) return null;
    final seriesIndex = _usableSeriesIndex(plot, panel, preferredSeries);
    if (seriesIndex == null) return null;
    final y = plot.series[seriesIndex]?.valueAt(x);
    return y == null ? null : (seriesIndex: seriesIndex, y: y);
  }

  Widget _buildCrosshairOverlay({
    required PlotData plot,
    required Map<String, dynamic> panel,
    required AppState app,
    required ThemeData theme,
    required CrosshairSnapshot? crosshair,
    required double gridLeft,
    required double gridTop,
    required double gridWidth,
    required double gridHeight,
    required double? minX,
    required double? maxX,
    required double? minY,
    required double? maxY,
  }) {
    if (crosshair == null ||
        minX == null ||
        maxX == null ||
        minY == null ||
        maxY == null ||
        maxX <= minX ||
        maxY <= minY) {
      return const SizedBox.shrink();
    }
    final value = _crosshairValue(
      plot,
      panel,
      crosshair.x,
      crosshair.sourceSeries,
    );
    if (value == null) return const SizedBox.shrink();

    final markerX = gridLeft + (crosshair.x - minX) / (maxX - minX) * gridWidth;
    final markerY = gridTop + (maxY - value.y) / (maxY - minY) * gridHeight;
    if (!markerX.isFinite ||
        !markerY.isFinite ||
        markerX < gridLeft ||
        markerX > gridLeft + gridWidth ||
        markerY < gridTop ||
        markerY > gridTop + gridHeight) {
      return const SizedBox.shrink();
    }

    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned(
              key: ValueKey('plot-crosshair-v-${widget.plotIdx}'),
              left: markerX - 0.5,
              top: gridTop,
              width: 1,
              height: gridHeight,
              child: const ColoredBox(color: Color(0xFFFF00FF)),
            ),
            Positioned(
              key: ValueKey('plot-crosshair-h-${widget.plotIdx}'),
              left: gridLeft,
              top: markerY - 0.5,
              width: gridWidth,
              height: 1,
              child: const ColoredBox(color: Color(0xFFFF00FF)),
            ),
            ..._buildPointReadoutOverlay(
              plot: plot,
              panel: panel,
              app: app,
              theme: theme,
              x: crosshair.x,
              y: value.y,
              seriesIndex: value.seriesIndex,
              gridLeft: gridLeft,
              gridTop: gridTop,
              gridWidth: gridWidth,
              gridHeight: gridHeight,
              minX: minX,
              maxX: maxX,
              minY: minY,
              maxY: maxY,
            ),
          ],
        ),
      ),
    );
  }

  int? _usableSeriesIndex(
    PlotData plot,
    Map<String, dynamic> panel,
    int preferred,
  ) {
    final signals = panel['signal_specs'] as List?;
    bool usable(int index) =>
        index >= 0 &&
        index < plot.series.length &&
        plot.series[index]?.hasData == true &&
        (signals == null ||
            index >= signals.length ||
            signals[index] is! Map ||
            !signalIsHidden(signals[index] as Map));
    if (usable(preferred)) return preferred;
    for (var index = 0; index < plot.series.length; index++) {
      if (usable(index)) return index;
    }
    return null;
  }

  List<Widget> _buildPointReadoutOverlay({
    required PlotData plot,
    required Map<String, dynamic> panel,
    required AppState app,
    required ThemeData theme,
    required double x,
    required double y,
    required int seriesIndex,
    required double gridLeft,
    required double gridTop,
    required double gridWidth,
    required double gridHeight,
    required double minX,
    required double maxX,
    required double minY,
    required double maxY,
  }) {
    final markerX = gridLeft + (x - minX) / (maxX - minX) * gridWidth;
    final markerY = gridTop + (maxY - y) / (maxY - minY) * gridHeight;
    if (!markerX.isFinite ||
        !markerY.isFinite ||
        markerX < gridLeft ||
        markerX > gridLeft + gridWidth ||
        markerY < gridTop ||
        markerY > gridTop + gridHeight) {
      return const [];
    }

    final signals = (panel['signal_specs'] as List?)?.cast<Map>() ?? const [];
    final color = _sigColor(seriesIndex, signals);
    final xName = _effectiveXName(plot, panel, seriesIndex);
    final sourceSeries =
        seriesIndex < plot.series.length ? plot.series[seriesIndex] : null;
    final lines = <String>[
      '$xName: ${formatPointXForReadout(
        x,
        sourceSeries?.points,
        resolution: sourceSeries?.localXResolution(x),
      )}',
    ];
    for (var index = 0; index < plot.series.length; index++) {
      final usable = _usableSeriesIndex(plot, panel, index);
      if (usable != index) continue;
      final value = plot.series[index]?.valueAt(x);
      if (value == null) continue;
      final name = index < signals.length
          ? signalLegendLabel(signals[index])
          : 'Signal ${index + 1}';
      lines.add(
        '${name.isEmpty ? "Signal ${index + 1}" : name}: '
        '${_fmtPointValue(value)}',
      );
    }

    final labelWidth = math.min(240.0, math.max(132.0, gridWidth * 0.46));
    final estimatedHeight =
        14.0 + lines.length * (app.fontLegendSize.toDouble() + 4);
    final placeRight = markerX < gridLeft + gridWidth / 2;
    final placeBelow = markerY < gridTop + gridHeight / 2;
    final labelLeft = placeRight
        ? math.min(markerX + 10, gridLeft + gridWidth - labelWidth)
        : math.max(gridLeft, markerX - labelWidth - 10);
    final labelTop = placeBelow
        ? math.min(markerY + 10, gridTop + gridHeight - estimatedHeight)
        : math.max(gridTop, markerY - estimatedHeight - 10);

    return [
      Positioned(
        key: ValueKey('plot-point-marker-${widget.plotIdx}'),
        left: markerX - 5,
        top: markerY - 5,
        child: IgnorePointer(
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: color, width: 2),
            ),
          ),
        ),
      ),
      Positioned(
        key: ValueKey('plot-point-readout-${widget.plotIdx}'),
        left: labelLeft,
        top: labelTop,
        width: labelWidth,
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.surface.withValues(alpha: 0.88),
              border: Border.all(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.8),
              ),
              borderRadius: BorderRadius.circular(7),
              boxShadow: [
                BoxShadow(
                  color: theme.colorScheme.shadow.withValues(alpha: 0.12),
                  blurRadius: 4,
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
              child: Text(
                lines.join('\n'),
                style: TextStyle(
                  color: theme.colorScheme.onSurface,
                  fontFamily: app.effectiveFontFamily,
                  fontSize: app.fontLegendSize.toDouble(),
                  height: 1.15,
                ),
              ),
            ),
          ),
        ),
      ),
    ];
  }

  String _fmtPointValue(double value) {
    final magnitude = value.abs();
    if ((magnitude >= 100000 || (magnitude > 0 && magnitude < 0.0001))) {
      return value.toStringAsExponential(5);
    }
    return value.toStringAsPrecision(7);
  }

  String _effectiveXName(
    PlotData plot,
    Map<String, dynamic> panel,
    int seriesIndex,
  ) {
    final metadataName = seriesIndex < plot.series.length
        ? plot.series[seriesIndex]?.xName.trim() ?? ''
        : '';
    if (metadataName.isNotEmpty) return metadataName;
    final signals = panel['signal_specs'] as List?;
    if (signals != null &&
        seriesIndex < signals.length &&
        signals[seriesIndex] is Map) {
      final signal = signals[seriesIndex] as Map;
      final expression = signal['x_expr']?.toString().trim() ?? '';
      if (expression.isNotEmpty) {
        return expression.replaceFirst(RegExp(r'^\\+'), '');
      }
      final yExpression = signal['y_expr']?.toString().trim() ?? '';
      if (yExpression.isNotEmpty) return 'dim_of($yExpression)';
    }
    return 'Coordinate';
  }

  String _effectiveXLabel(PlotData plot, Map<String, dynamic> panel) {
    final configured = plot.xLabel.trim();
    if (configured.isNotEmpty && configured != 's') return configured;
    for (final series in plot.series) {
      final unit = series?.xUnit.trim() ?? '';
      if (unit.isNotEmpty) return unit;
    }
    return configured.isEmpty ? 's' : configured;
  }

  String _effectiveYLabel(PlotData plot, Map<String, dynamic> panel) {
    final configured = plot.yLabel.trim();
    if (configured.isNotEmpty && configured != 'a.u.') return configured;
    final signals = panel['signal_specs'] as List?;
    for (var index = 0; index < plot.series.length; index++) {
      if (signals != null &&
          index < signals.length &&
          signals[index] is Map &&
          signalIsHidden(signals[index] as Map)) {
        continue;
      }
      final unit = plot.series[index]?.unit.trim() ?? '';
      if (unit.isNotEmpty) return unit;
    }
    return configured.isEmpty ? 'a.u.' : configured;
  }

  RenderBox? get _listenerBox =>
      _listenerKey.currentContext?.findRenderObject() as RenderBox?;
  RenderBox? get _chartBox =>
      _chartAreaKey.currentContext?.findRenderObject() as RenderBox?;

  Color _sigColor(int i, List<Map> sigSpecs) {
    if (i < sigSpecs.length && sigSpecs[i]['color_name'] != null) {
      final hex = sigSpecs[i]['color_name'].toString().replaceFirst('#', '');
      final c = int.tryParse(hex, radix: 16);
      if (c != null) {
        return Color(0xFF000000 | c);
      }
    }
    return _colors[i % _colors.length];
  }

  // Convert listener-local pixel to data coordinate using chart grid area.
  double _pxToDataX(double px) {
    final lb = _listenerBox;
    final cb = _chartBox;
    final app = context.read<AppState>();
    final gridLeft = _gridLeftInset(app);
    if (lb == null || cb == null || cb.size.width <= gridLeft) {
      return (_viewMinX + _viewMaxX) / 2;
    }
    final chartLocal = cb.globalToLocal(lb.localToGlobal(Offset(px, 0)));
    final gx = chartLocal.dx - gridLeft;
    final gw = cb.size.width - gridLeft;
    return _viewMinX + (gx / gw) * (_viewMaxX - _viewMinX);
  }

  double _pxToDataY(double py) {
    final lb = _listenerBox;
    final cb = _chartBox;
    final app = context.read<AppState>();
    final gridBottom = _gridBottomInset(app);
    if (lb == null || cb == null || cb.size.height <= gridBottom) {
      return (_viewMinY + _viewMaxY) / 2;
    }
    final chartLocal = cb.globalToLocal(lb.localToGlobal(Offset(0, py)));
    final gy = chartLocal.dy;
    final gh = cb.size.height - gridBottom;
    return _viewMaxY - (gy / gh) * (_viewMaxY - _viewMinY);
  }

  Offset? _listenerToChart(Offset localPosition) {
    final listener = _listenerBox;
    final chart = _chartBox;
    if (listener == null || chart == null) return null;
    return chart.globalToLocal(listener.localToGlobal(localPosition));
  }

  int? _pickSeriesAt(Offset localPosition, {required double maximumDistance}) {
    final app = context.read<AppState>();
    if (widget.plotIdx >= app.plots.length) return null;
    final plot = app.plots[widget.plotIdx];
    final panel = _findPanel(app);
    final chartPosition = _listenerToChart(localPosition);
    final chart = _chartBox;
    if (chartPosition == null || chart == null) return null;
    final gridLeft = _gridLeftInset(app);
    final gridBottom = _gridBottomInset(app);
    final gridWidth = chart.size.width - gridLeft;
    final gridHeight = chart.size.height - gridBottom;
    if (gridWidth <= 0 ||
        gridHeight <= 0 ||
        !_viewMinX.isFinite ||
        !_viewMinY.isFinite) {
      return null;
    }

    Offset toPixel(FlSpot spot) => Offset(
          gridLeft + (spot.x - _viewMinX) / (_viewMaxX - _viewMinX) * gridWidth,
          (_viewMaxY - spot.y) / (_viewMaxY - _viewMinY) * gridHeight,
        );

    var bestDistance = double.infinity;
    int? bestSeries;
    final signals = panel['signal_specs'] as List?;
    for (var seriesIndex = 0; seriesIndex < plot.series.length; seriesIndex++) {
      if (signals != null &&
          seriesIndex < signals.length &&
          signals[seriesIndex] is Map &&
          signalIsHidden(signals[seriesIndex] as Map)) {
        continue;
      }
      final series = plot.series[seriesIndex];
      if (series?.hasData != true) continue;
      final spots = _renderCache
          .render(
            series!,
            minX: _viewMinX.isFinite ? _viewMinX : null,
            maxX: _viewMaxX.isFinite ? _viewMaxX : null,
          )
          .spots;
      if (spots.length == 1) {
        final distance = (toPixel(spots.first) - chartPosition).distance;
        if (distance < bestDistance) {
          bestDistance = distance;
          bestSeries = seriesIndex;
        }
        continue;
      }
      for (var index = 0; index + 1 < spots.length; index++) {
        final distance = _distanceToSegment(
          chartPosition,
          toPixel(spots[index]),
          toPixel(spots[index + 1]),
        );
        if (distance < bestDistance) {
          bestDistance = distance;
          bestSeries = seriesIndex;
        }
      }
    }
    return bestDistance <= maximumDistance ? bestSeries : null;
  }

  double _distanceToSegment(Offset point, Offset start, Offset end) {
    final segment = end - start;
    final lengthSquared = segment.dx * segment.dx + segment.dy * segment.dy;
    if (lengthSquared <= 0) return (point - start).distance;
    final relative = point - start;
    final fraction =
        ((relative.dx * segment.dx + relative.dy * segment.dy) / lengthSquared)
            .clamp(0.0, 1.0);
    final closest = start + segment * fraction;
    return (point - closest).distance;
  }

  void _updatePointCrosshair(
    Offset localPosition, {
    bool chooseSeries = false,
    double pickRadius = 16,
  }) {
    final app = context.read<AppState>();
    if (app.interactionMode != 1 ||
        app.pointLocked ||
        !_ensureViewInitialized(app)) {
      return;
    }
    var seriesIndex = app.crosshairSourcePlot == widget.plotIdx
        ? app.crosshairSourceSeries
        : 0;
    if (chooseSeries) {
      seriesIndex = _pickSeriesAt(localPosition, maximumDistance: pickRadius) ??
          (_usableSeriesIndex(
                app.plots[widget.plotIdx],
                _findPanel(app),
                seriesIndex,
              ) ??
              0);
    }
    app.setCrosshair(
      _pxToDataX(localPosition.dx),
      sourcePlot: widget.plotIdx,
      sourceSeries: seriesIndex,
    );
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
      _storeView(plot);
    });
  }

  void _handleTrackpadGestureStart(PointerPanZoomStartEvent event) {
    final app = context.read<AppState>();
    _trackpadGestureActive =
        app.interactionMode == 0 && _ensureViewInitialized(app);
    _lastTrackpadScale = 1;
  }

  void _handleTrackpadGestureUpdate(PointerPanZoomUpdateEvent event) {
    if (!_trackpadGestureActive) return;
    final app = context.read<AppState>();
    if (app.interactionMode != 0 || !_ensureViewInitialized(app)) {
      _trackpadGestureActive = false;
      return;
    }
    final plot = app.plots[widget.plotIdx];
    final cb = _chartBox;
    final gridLeft = _gridLeftInset(app);
    final gridBottom = _gridBottomInset(app);
    if (cb == null ||
        cb.size.width <= gridLeft ||
        cb.size.height <= gridBottom) {
      return;
    }

    final previousScale = _lastTrackpadScale;
    _lastTrackpadScale = event.scale;
    final incrementalScale =
        previousScale > 0 ? event.scale / previousScale : 1.0;
    final canScale = incrementalScale.isFinite && incrementalScale > 0;
    final panDelta = event.localPanDelta;

    setState(() {
      final gridWidth = cb.size.width - gridLeft;
      final gridHeight = cb.size.height - gridBottom;
      final xScale = (_viewMaxX - _viewMinX) / gridWidth;
      final yScale = (_viewMaxY - _viewMinY) / gridHeight;
      _viewMinX -= panDelta.dx * xScale;
      _viewMaxX -= panDelta.dx * xScale;
      _viewMinY += panDelta.dy * yScale;
      _viewMaxY += panDelta.dy * yScale;

      if (canScale && (incrementalScale - 1).abs() >= 0.0001) {
        final factor = 1 / incrementalScale.clamp(0.2, 5.0);
        final cx = _pxToDataX(event.localPosition.dx);
        final cy = _pxToDataY(event.localPosition.dy);
        _viewMinX = cx - (cx - _viewMinX) * factor;
        _viewMaxX = cx + (_viewMaxX - cx) * factor;
        _viewMinY = cy - (cy - _viewMinY) * factor;
        _viewMaxY = cy + (_viewMaxY - cy) * factor;
      }
      _storeView(plot);
    });
  }

  void _handleTrackpadGestureEnd(PointerPanZoomEndEvent event) {
    _trackpadGestureActive = false;
    _lastTrackpadScale = 1;
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (_isStylusKind(event.kind)) {
      _activeStylusPointer = event.pointer;
      _stylusDownLocal = event.localPosition;
      _stylusDragStarted = false;
      _stylusLongPressTriggered = false;
      final app = context.read<AppState>();
      _stylusShouldErase = event.kind == PointerDeviceKind.invertedStylus ||
          app.stylusEraserMode ||
          _hasStylusButton(event.buttons);
      _startLongPressTimer(event, stylus: true);
      if (app.interactionMode == 1) {
        _updateTouchCrosshair(
          event.localPosition,
          unlock: true,
          pickRadius: 22,
        );
        return;
      }
      if (app.interactionMode != 0) return;
      return;
    }

    if (event.kind == PointerDeviceKind.touch) {
      if (_activeStylusPointer != null) return;
      _touchPositions[event.pointer] = event.localPosition;
      if (_touchPositions.length >= 2) {
        _beginMultiTouch();
        _resetMultiTouchMetrics();
      } else {
        _updateTouchCrosshair(
          event.localPosition,
          unlock: true,
          pickRadius: 22,
        );
      }
      return;
    }

    final app = context.read<AppState>();
    if (app.interactionMode != 0) return;
    final isMid = (event.buttons & kMiddleMouseButton) != 0;
    final isShiftLeft =
        app.shiftHeld && (event.buttons & kPrimaryMouseButton) != 0;
    final isMouseLeft = event.kind == PointerDeviceKind.mouse &&
        (event.buttons & kPrimaryMouseButton) != 0 &&
        !app.shiftHeld;
    if (isMouseLeft) {
      _beginRubberBand(event.localPosition);
    } else if (isMid || isShiftLeft) {
      _midPanning = true;
      _lastMidPanPos = event.localPosition;
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (_isStylusKind(event.kind) && event.pointer != _activeStylusPointer) {
      return;
    }
    if (event.kind == PointerDeviceKind.touch &&
        _touchPositions.containsKey(event.pointer)) {
      final previousPosition = _touchPositions[event.pointer]!;
      _touchPositions[event.pointer] = event.localPosition;
      if (_multiTouchActive && _touchPositions.length >= 2) {
        _applyMultiTouchTransform();
      } else {
        final app = context.read<AppState>();
        if (app.interactionMode == 0) {
          _applySingleTouchPan(previousPosition, event.localPosition);
        } else {
          _updateTouchCrosshair(event.localPosition);
        }
      }
      return;
    }
    if (event.kind == PointerDeviceKind.touch) return;

    final app = context.read<AppState>();
    if (_isStylusKind(event.kind)) {
      if (_stylusLongPressTriggered) return;
      final moved = _longPressStartPos == null
          ? double.infinity
          : (event.position - _longPressStartPos!).distance;
      if (app.interactionMode == 1) {
        if (moved > _stylusLongPressSlop) _cancelLongPressTimer();
        if (!app.pointLocked && _ensureViewInitialized(app)) {
          _updatePointCrosshair(event.localPosition);
        }
        return;
      }
      if (app.interactionMode != 0) return;
      if (!_stylusDragStarted) {
        _stylusShouldErase =
            _stylusShouldErase || _hasStylusButton(event.buttons);
        if (moved <= _stylusLongPressSlop) return;
        final dragStart = _stylusDownLocal ?? event.localPosition;
        _stylusDragStarted = true;
        _cancelLongPressTimer();
        if (_stylusShouldErase) {
          _beginRubberBand(dragStart);
        } else {
          _midPanning = true;
          _lastMidPanPos = dragStart;
        }
      }
    }

    if (app.interactionMode == 1 &&
        !app.pointLocked &&
        event.kind == PointerDeviceKind.mouse &&
        _ensureViewInitialized(app)) {
      app.setCrosshair(
        _pxToDataX(event.localPosition.dx),
        sourcePlot: widget.plotIdx,
      );
      return;
    }

    if (_inRubberBand && _rubberBandStart != null) {
      setState(() {
        _rubberBandRect = Rect.fromPoints(
          _rubberBandStart!,
          event.localPosition,
        );
      });
      return;
    }
    if (!_midPanning || _lastMidPanPos == null) return;
    final plot = app.plots[widget.plotIdx];
    final lb = _listenerBox;
    final cb = _chartBox;
    setState(() {
      if (_viewMinX.isNaN) _initViewToData(plot);
      if (lb == null ||
          cb == null ||
          cb.size.width <= 0 ||
          cb.size.height <= 0) {
        return;
      }
      final dx = event.localPosition.dx - _lastMidPanPos!.dx;
      final dy = event.localPosition.dy - _lastMidPanPos!.dy;
      final xScale = (_viewMaxX - _viewMinX) / cb.size.width;
      final yScale = (_viewMaxY - _viewMinY) / cb.size.height;
      _viewMinX -= dx * xScale;
      _viewMaxX -= dx * xScale;
      _viewMinY += dy * yScale;
      _viewMaxY += dy * yScale;
      _lastMidPanPos = event.localPosition;
      _storeView(plot);
    });
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.kind == PointerDeviceKind.touch) {
      _removeTouchPointer(event.pointer);
      return;
    }

    final wasActiveStylus = event.pointer == _activeStylusPointer;
    if (wasActiveStylus) {
      _activeStylusPointer = null;
      final completedDrag = _stylusDragStarted;
      _clearStylusGesture();
      if (!completedDrag) return;
    }

    if (_inRubberBand &&
        _rubberBandRect != null &&
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
          _storeView(plot);
        }
      });
      return;
    }
    _midPanning = false;
    _lastMidPanPos = null;
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (event.kind == PointerDeviceKind.touch) {
      _removeTouchPointer(event.pointer);
      return;
    }
    if (event.pointer == _activeStylusPointer) {
      _activeStylusPointer = null;
      _clearStylusGesture();
    }
    _midPanning = false;
    _lastMidPanPos = null;
    if (_inRubberBand && mounted) {
      setState(() {
        _inRubberBand = false;
        _rubberBandStart = null;
        _rubberBandRect = null;
      });
    }
  }

  void _handlePointerHover(PointerHoverEvent event) {
    final app = context.read<AppState>();
    if (app.interactionMode != 1 ||
        app.pointLocked ||
        !_ensureViewInitialized(app)) {
      return;
    }
    _updatePointCrosshair(event.localPosition, chooseSeries: true);
  }

  void _updateTouchCrosshair(
    Offset localPosition, {
    bool unlock = false,
    double pickRadius = 16,
  }) {
    final app = context.read<AppState>();
    if (app.interactionMode != 1) return;
    if (unlock && app.pointLocked) app.pointLocked = false;
    _updatePointCrosshair(
      localPosition,
      chooseSeries: unlock,
      pickRadius: pickRadius,
    );
  }

  bool _isStylusKind(PointerDeviceKind kind) =>
      kind == PointerDeviceKind.stylus ||
      kind == PointerDeviceKind.invertedStylus;

  bool _hasStylusButton(int buttons) =>
      (buttons & (kPrimaryStylusButton | kSecondaryStylusButton)) != 0;

  void _beginRubberBand(Offset localPosition) {
    _inRubberBand = true;
    _rubberBandStart = localPosition;
    _rubberBandRect = Rect.fromPoints(localPosition, localPosition);
  }

  void _beginMultiTouch() {
    if (_multiTouchActive) return;
    _multiTouchActive = true;
    _cancelLongPressTimer();
  }

  void _applySingleTouchPan(Offset previousPosition, Offset currentPosition) {
    final app = context.read<AppState>();
    if (app.interactionMode != 0 || !_ensureViewInitialized(app)) return;
    final plot = app.plots[widget.plotIdx];
    final cb = _chartBox;
    final gridWidth = (cb?.size.width ?? 0) - _gridLeftInset(app);
    final gridHeight = (cb?.size.height ?? 0) - _gridBottomInset(app);
    if (gridWidth <= 0 || gridHeight <= 0) return;

    final delta = currentPosition - previousPosition;
    setState(() {
      final xScale = (_viewMaxX - _viewMinX) / gridWidth;
      final yScale = (_viewMaxY - _viewMinY) / gridHeight;
      _viewMinX -= delta.dx * xScale;
      _viewMaxX -= delta.dx * xScale;
      _viewMinY += delta.dy * yScale;
      _viewMaxY += delta.dy * yScale;
      _storeView(plot);
    });
  }

  bool _ensureViewInitialized(AppState app) {
    if (_viewMinX.isFinite) return true;
    if (widget.plotIdx >= app.plots.length) return false;
    _initViewToData(app.plots[widget.plotIdx], _findPanel(app));
    return _viewMinX.isFinite;
  }

  void _removeTouchPointer(int pointer) {
    _touchPositions.remove(pointer);
    if (_multiTouchActive && _touchPositions.length < 2) {
      _multiTouchActive = false;
      _lastMultiTouchFocalPoint = null;
      _lastMultiTouchSpan = null;
    } else if (_multiTouchActive) {
      _resetMultiTouchMetrics();
    }
  }

  ({Offset focalPoint, double span})? _multiTouchMetrics() {
    if (_touchPositions.length < 2) return null;
    var focalPoint = Offset.zero;
    for (final position in _touchPositions.values) {
      focalPoint += position;
    }
    focalPoint = focalPoint / _touchPositions.length.toDouble();

    var span = 0.0;
    for (final position in _touchPositions.values) {
      span += (position - focalPoint).distance;
    }
    span /= _touchPositions.length;
    return (focalPoint: focalPoint, span: span);
  }

  void _resetMultiTouchMetrics() {
    final metrics = _multiTouchMetrics();
    _lastMultiTouchFocalPoint = metrics?.focalPoint;
    _lastMultiTouchSpan = metrics?.span;
  }

  void _applyMultiTouchTransform() {
    final metrics = _multiTouchMetrics();
    final previousFocalPoint = _lastMultiTouchFocalPoint;
    final previousSpan = _lastMultiTouchSpan;
    if (metrics == null || previousFocalPoint == null || previousSpan == null) {
      _resetMultiTouchMetrics();
      return;
    }

    _lastMultiTouchFocalPoint = metrics.focalPoint;
    _lastMultiTouchSpan = metrics.span;
    final app = context.read<AppState>();
    if (app.interactionMode != 0) return;
    final plot = app.plots[widget.plotIdx];
    final cb = _chartBox;
    final gridLeft = _gridLeftInset(app);
    final gridBottom = _gridBottomInset(app);
    if (cb == null ||
        cb.size.width <= gridLeft ||
        cb.size.height <= gridBottom) {
      return;
    }

    setState(() {
      if (_viewMinX.isNaN) _initViewToData(plot);
      final gridWidth = cb.size.width - gridLeft;
      final gridHeight = cb.size.height - gridBottom;
      final focalDelta = metrics.focalPoint - previousFocalPoint;
      final xScale = (_viewMaxX - _viewMinX) / gridWidth;
      final yScale = (_viewMaxY - _viewMinY) / gridHeight;
      _viewMinX -= focalDelta.dx * xScale;
      _viewMaxX -= focalDelta.dx * xScale;
      _viewMinY += focalDelta.dy * yScale;
      _viewMaxY += focalDelta.dy * yScale;
      _storeView(plot);

      if (previousSpan <= 0.1 || metrics.span <= 0.1) return;
      final scale = metrics.span / previousSpan;
      if ((scale - 1).abs() < 0.0001) return;
      final factor = 1.0 / scale;
      final cx = _pxToDataX(metrics.focalPoint.dx);
      final cy = _pxToDataY(metrics.focalPoint.dy);
      _viewMinX = cx - (cx - _viewMinX) * factor;
      _viewMaxX = cx + (_viewMaxX - cx) * factor;
      _viewMinY = cy - (cy - _viewMinY) * factor;
      _viewMaxY = cy + (_viewMaxY - cy) * factor;
      _storeView(plot);
    });
  }

  List<double>? _currentRange(AppState app) {
    if (!_viewMinX.isNaN) return [_viewMinX, _viewMaxX, _viewMinY, _viewMaxY];
    final plot = app.plots[widget.plotIdx];
    double? minX, maxX, minY, maxY;
    for (final s in plot.series) {
      final bounds = s?.dataBounds();
      if (bounds == null) continue;
      if (minX == null || bounds[0] < minX) minX = bounds[0];
      if (maxX == null || bounds[1] > maxX) maxX = bounds[1];
      if (minY == null || bounds[2] < minY) minY = bounds[2];
      if (maxY == null || bounds[3] > maxY) maxY = bounds[3];
    }
    return minX != null ? [minX, maxX!, minY!, maxY!] : null;
  }

  void _restoreView(PlotData plot, AppState app) {
    _viewMinX = plot.viewMinX ?? double.nan;
    _viewMaxX = plot.viewMaxX ?? double.nan;
    _viewMinY = plot.viewMinY ?? double.nan;
    _viewMaxY = plot.viewMaxY ?? double.nan;
    if (_viewMinX.isNaN && app.sharedXMin != null) {
      _viewMinX = app.sharedXMin!;
      _viewMaxX = app.sharedXMax!;
    }
    if (_viewMinY.isNaN && app.sharedYMin != null) {
      _viewMinY = app.sharedYMin!;
      _viewMaxY = app.sharedYMax!;
    }
    _storeView(plot);
  }

  void _storeView(PlotData plot) {
    plot.setViewRange(_viewMinX, _viewMaxX, _viewMinY, _viewMaxY);
  }

  void _resetView(PlotData plot) {
    _viewMinX = double.nan;
    _viewMaxX = double.nan;
    _viewMinY = double.nan;
    _viewMaxY = double.nan;
    plot.clearViewRange();
    _inRubberBand = false;
    _rubberBandStart = null;
    _rubberBandRect = null;
  }

  void _startLongPressTimer(PointerDownEvent e, {bool stylus = false}) {
    _cancelLongPressTimer();
    _longPressStartPos = e.position;
    final pointer = e.pointer;
    _longPressTimer = Timer(const Duration(milliseconds: 500), () {
      if (mounted && _longPressStartPos != null) {
        final menuPosition = _longPressStartPos!;
        if (stylus && pointer == _activeStylusPointer) {
          _stylusLongPressTriggered = true;
          _stylusDragStarted = false;
          _midPanning = false;
          _lastMidPanPos = null;
          if (_inRubberBand) {
            setState(() {
              _inRubberBand = false;
              _rubberBandStart = null;
              _rubberBandRect = null;
            });
          }
        }
        // A modal popup can consume the original pointer's up/cancel event,
        // notably for Apple Pencil on iPadOS. Release the plot's gesture state
        // before opening it so later finger gestures cannot be blocked by a
        // stale active stylus or touch pointer.
        _releasePointersForPopup();
        _showContextMenu(context, menuPosition);
      }
      _longPressTimer = null;
      _longPressStartPos = null;
    });
  }

  void _cancelLongPressTimer() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _longPressStartPos = null;
  }

  void _cancelLongPressIfMoved(PointerMoveEvent e) {
    if (_isStylusKind(e.kind)) return;
    if (_longPressStartPos != null &&
        (e.position - _longPressStartPos!).distance > 10) {
      _cancelLongPressTimer();
    }
  }

  void _clearStylusGesture() {
    _stylusDownLocal = null;
    _stylusDragStarted = false;
    _stylusLongPressTriggered = false;
    _stylusShouldErase = false;
  }

  void _releasePointersForPopup() {
    _cancelLongPressTimer();
    _activeStylusPointer = null;
    _clearStylusGesture();
    _touchPositions.clear();
    _multiTouchActive = false;
    _lastMultiTouchFocalPoint = null;
    _lastMultiTouchSpan = null;
    _midPanning = false;
    _lastMidPanPos = null;
    _trackpadGestureActive = false;
    _lastTrackpadScale = 1;
  }

  Future<void> _showContextMenu(BuildContext ctx, Offset globalPosition) async {
    final app = ctx.read<AppState>();
    final isMaxed = app.maximizedPlot != null;
    final value = await showPolishedPopupMenu<String>(
      context: ctx,
      globalPosition: globalPosition,
      id: 'plot-context-menu',
      keyboardShortcuts: app.keyboardShortcuts,
      groups: [
        PolishedPopupMenuGroup(
          label: 'View',
          options: [
            if (isMaxed)
              const PolishedPopupMenuOption(
                id: 'show-all',
                value: 'showAll',
                label: 'Show All Panels',
                icon: Icons.grid_view_rounded,
              )
            else
              const PolishedPopupMenuOption(
                id: 'maximize',
                value: 'max',
                label: 'Maximize Panel',
                icon: Icons.fullscreen_rounded,
              ),
            const PolishedPopupMenuOption(
              id: 'reset-current',
              value: 'reset',
              label: 'Reset Current Scale',
              icon: Icons.center_focus_strong_rounded,
            ),
            const PolishedPopupMenuOption(
              id: 'reset-all',
              value: 'resetAll',
              label: 'Reset All Panels',
              icon: Icons.restart_alt_rounded,
            ),
          ],
        ),
        const PolishedPopupMenuGroup(
          label: 'Scale',
          options: [
            PolishedPopupMenuOption(
              id: 'same-x',
              value: 'sameX',
              label: 'All Same X Scale',
              icon: Icons.swap_horiz_rounded,
            ),
            PolishedPopupMenuOption(
              id: 'same-y',
              value: 'sameY',
              label: 'All Same Y Scale',
              icon: Icons.swap_vert_rounded,
            ),
          ],
        ),
        const PolishedPopupMenuGroup(
          label: 'Data',
          options: [
            PolishedPopupMenuOption(
              id: 'export',
              value: 'export',
              label: 'Export Data',
              icon: Icons.file_download_outlined,
            ),
            PolishedPopupMenuOption(
              id: 'export-multiple',
              value: 'exportMultiple',
              label: 'Export Multiple Panels',
              icon: Icons.library_add_check_rounded,
            ),
          ],
        ),
        const PolishedPopupMenuGroup(
          label: 'Configure',
          options: [
            PolishedPopupMenuOption(
              id: 'data-source',
              value: 'dataSource',
              label: 'Data Source Setup',
              icon: Icons.storage_rounded,
            ),
            PolishedPopupMenuOption(
              id: 'panel-setup',
              value: 'setup',
              label: 'Panel Setup',
              icon: Icons.tune_rounded,
            ),
          ],
        ),
      ],
    );
    if (!mounted) return;
    // Also sanitize state after every close path: selecting an action, tapping
    // outside the popup, pressing Escape, or a platform-driven dismissal.
    _releasePointersForPopup();
    if (value == null) return;
    switch (value) {
      case 'max':
        app.maximizePlot(widget.plotIdx);
        break;
      case 'showAll':
        app.showAllPanels();
        break;
      case 'reset':
        _resetView(app.plots[widget.plotIdx]);
        app.clearCrosshair();
        break;
      case 'resetAll':
        app.sharedXMin = null;
        app.sharedXMax = null;
        app.sharedYMin = null;
        app.sharedYMax = null;
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
        await exportMultiplePanels(
          context,
          app,
          saveDialog: widget.exportSaveDialog,
          initialSelection: {widget.plotIdx},
          allowPanelSelection: false,
        );
        break;
      case 'exportMultiple':
        await exportMultiplePanels(
          context,
          app,
          saveDialog: widget.exportSaveDialog,
        );
        break;
      case 'dataSource':
        _showDataSourceSetup(context, app);
        break;
      case 'setup':
        _showPanelSetup(context, app);
        break;
    }
  }

  Map<String, dynamic> _findPanel(AppState app) {
    var idx = widget.plotIdx;
    for (final col in app.columns) {
      if (idx < col.length) return col[idx];
      idx -= col.length;
    }
    return <String, dynamic>{};
  }

  Future<void> _showDataSourceSetup(BuildContext ctx, AppState app) async {
    final panel = _findPanel(app);
    final sigs = List<Map<String, dynamic>>.from(
      (panel['signal_specs'] as List?)?.map(
            (s) => Map<String, dynamic>.from(s as Map),
          ) ??
          [],
    );
    final defaultShot = resolveDataSourceShot(
      panelShot: panel['shot'],
      displayedShot: app.displayedShot,
      inputShot: app.shotText,
    );
    if (sigs.isEmpty) {
      sigs.add({'experiment': 'pcs_east', 'server_ip': '202.127.204.12'});
    }
    final confirmed = await showDataSourceSetupEditor(
      ctx,
      signals: sigs,
      defaultShot: defaultShot,
    );
    if (!confirmed || !mounted) return;
    panel['signal_specs'] = sigs;
    _rebuildPlots(app);
    app.fetchSinglePanel(widget.plotIdx);
  }

  void _rebuildPlots(AppState app) {
    // Preserve existing series data, update metadata without intermediate empty state
    final newPlots = <PlotData>[];
    var idx = 0;
    final curPlots = app.plots.toList();
    for (final col in app.columns) {
      for (final p in col) {
        final sc = (p['signal_specs'] as List?)?.length ?? 1;
        final oldSeries =
            idx < curPlots.length ? curPlots[idx].series : <SeriesData?>[];
        final oldPlot = idx < curPlots.length ? curPlots[idx] : null;
        newPlots.add(
          PlotData(
            title: p['title']?.toString() ?? '',
            xLabel: p['x_label']?.toString() ?? 's',
            yLabel: p['y_label']?.toString() ?? 'a.u.',
            series: _resizeSeries(oldSeries, sc > 0 ? sc : 1),
          )..setViewRange(
              oldPlot?.viewMinX ?? double.nan,
              oldPlot?.viewMaxX ?? double.nan,
              oldPlot?.viewMinY ?? double.nan,
              oldPlot?.viewMaxY ?? double.nan,
            ),
        );
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

  Future<void> _showPanelSetup(BuildContext ctx, AppState app) async {
    final panel = _findPanel(app);
    final previousExtractionPoints =
        int.tryParse(panel['extraction_points']?.toString() ?? '') ?? 2000;
    final confirmed = await showPanelSetupEditor(
      ctx,
      panel,
      actualChanges: app,
      actualValues: () {
        final plot = app.plots[widget.plotIdx];
        final rawPoints = panel['extraction_points'];
        final parsedPoints = rawPoints is num
            ? rawPoints.toInt()
            : int.tryParse(rawPoints?.toString() ?? '');
        return PanelSetupValues(
          title: plot.title,
          xLabel: _effectiveXLabel(plot, panel),
          yLabel: _effectiveYLabel(plot, panel),
          extractionPoints:
              parsedPoints != null && parsedPoints >= 2 ? parsedPoints : 2000,
        );
      },
    );
    if (!confirmed || !mounted) return;
    _rebuildPlots(app);
    final extractionPoints =
        int.tryParse(panel['extraction_points']?.toString() ?? '') ?? 2000;
    if (extractionPoints != previousExtractionPoints && app.hasActiveSession) {
      await app.fetchSinglePanel(widget.plotIdx);
    }
  }

  void _initViewToData(PlotData plot, [Map<String, dynamic>? panel]) {
    final bounds = _computeDataBounds(plot, panel);
    if (bounds != null) {
      _viewMinX = bounds[0];
      _viewMaxX = bounds[1];
      _viewMinY = bounds[2];
      _viewMaxY = bounds[3];
    }
  }

  List<double>? _computeDataBounds(
    PlotData plot, [
    Map<String, dynamic>? panel,
  ]) {
    double? minX, maxX, minY, maxY;
    for (final s in plot.series) {
      final bounds = s?.dataBounds();
      if (bounds == null) continue;
      if (minX == null || bounds[0] < minX) minX = bounds[0];
      if (maxX == null || bounds[1] > maxX) maxX = bounds[1];
      if (minY == null || bounds[2] < minY) minY = bounds[2];
      if (maxY == null || bounds[3] > maxY) maxY = bounds[3];
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
}

class _PanelSetupDialog extends StatefulWidget {
  final Map<String, dynamic> panel;
  final PanelSetupValues Function()? actualValues;
  final Listenable? actualChanges;
  final VoidCallback onSave;
  const _PanelSetupDialog({
    required this.panel,
    required this.onSave,
    this.actualValues,
    this.actualChanges,
  });

  @override
  State<_PanelSetupDialog> createState() => _PanelSetupDialogState();
}

class _PanelSetupDialogState extends State<_PanelSetupDialog> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _xLabelCtrl;
  late final TextEditingController _yLabelCtrl;
  late final TextEditingController _pointsCtrl;
  bool _titleEdited = false;
  bool _xLabelEdited = false;
  bool _yLabelEdited = false;
  bool _pointsEdited = false;
  bool _syncingActualValues = false;
  late bool _grid = widget.panel['grid'] ?? true;
  late bool _customX = widget.panel['custom_x_range'] ?? false;
  late bool _customY = widget.panel['custom_y_range'] ?? false;
  late final _xMinCtrl = TextEditingController(
    text: (widget.panel['xmin'] ?? '').toString(),
  );
  late final _xMaxCtrl = TextEditingController(
    text: (widget.panel['xmax'] ?? '').toString(),
  );
  late final _yMinCtrl = TextEditingController(
    text: (widget.panel['ymin'] ?? '').toString(),
  );
  late final _yMaxCtrl = TextEditingController(
    text: (widget.panel['ymax'] ?? '').toString(),
  );

  @override
  void initState() {
    super.initState();
    final actual = widget.actualValues?.call();
    _titleCtrl = TextEditingController(
      text: actual?.title ?? widget.panel['title']?.toString() ?? '',
    );
    _xLabelCtrl = TextEditingController(
      text: actual?.xLabel ?? widget.panel['x_label']?.toString() ?? 's',
    );
    _yLabelCtrl = TextEditingController(
      text: actual?.yLabel ?? widget.panel['y_label']?.toString() ?? 'a.u.',
    );
    _pointsCtrl = TextEditingController(
      text: (actual?.extractionPoints ??
              widget.panel['extraction_points'] ??
              2000)
          .toString(),
    );
    _titleCtrl.addListener(() {
      if (!_syncingActualValues) _titleEdited = true;
    });
    _xLabelCtrl.addListener(() {
      if (!_syncingActualValues) _xLabelEdited = true;
    });
    _yLabelCtrl.addListener(() {
      if (!_syncingActualValues) _yLabelEdited = true;
    });
    _pointsCtrl.addListener(() {
      if (!_syncingActualValues) _pointsEdited = true;
    });
    widget.actualChanges?.addListener(_synchronizeActualValues);
  }

  void _synchronizeActualValues() {
    final actual = widget.actualValues?.call();
    if (actual == null || !mounted) return;
    _syncingActualValues = true;
    if (!_titleEdited && _titleCtrl.text != actual.title) {
      _titleCtrl.text = actual.title;
    }
    if (!_xLabelEdited && _xLabelCtrl.text != actual.xLabel) {
      _xLabelCtrl.text = actual.xLabel;
    }
    if (!_yLabelEdited && _yLabelCtrl.text != actual.yLabel) {
      _yLabelCtrl.text = actual.yLabel;
    }
    final extractionPoints = actual.extractionPoints.toString();
    if (!_pointsEdited && _pointsCtrl.text != extractionPoints) {
      _pointsCtrl.text = extractionPoints;
    }
    _syncingActualValues = false;
  }

  @override
  void dispose() {
    widget.actualChanges?.removeListener(_synchronizeActualValues);
    _titleCtrl.dispose();
    _xLabelCtrl.dispose();
    _yLabelCtrl.dispose();
    _pointsCtrl.dispose();
    _xMinCtrl.dispose();
    _xMaxCtrl.dispose();
    _yMinCtrl.dispose();
    _yMaxCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext ctx) {
    return KeyboardSafeDialog(
      title: const Text('Panel Setup'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('panel-setup-title'),
              controller: _titleCtrl,
              decoration: const InputDecoration(
                labelText: 'Title',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('panel-setup-x-label'),
              controller: _xLabelCtrl,
              decoration: const InputDecoration(
                labelText: 'X Label',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('panel-setup-y-label'),
              controller: _yLabelCtrl,
              decoration: const InputDecoration(
                labelText: 'Y Label',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('panel-setup-extraction-points'),
              controller: _pointsCtrl,
              decoration: const InputDecoration(
                labelText: 'Extraction Points',
                isDense: true,
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              title: const Text('Show Grid'),
              value: _grid,
              onChanged: (v) => setState(() => _grid = v ?? true),
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
            ),
            CheckboxListTile(
              title: const Text('Custom X range'),
              value: _customX,
              onChanged: (v) => setState(() => _customX = v ?? false),
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
            ),
            if (_customX) ...[
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _xMinCtrl,
                      decoration: const InputDecoration(
                        labelText: 'X min',
                        isDense: true,
                      ),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _xMaxCtrl,
                      decoration: const InputDecoration(
                        labelText: 'X max',
                        isDense: true,
                      ),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
            ],
            CheckboxListTile(
              title: const Text('Custom Y range'),
              value: _customY,
              onChanged: (v) => setState(() => _customY = v ?? false),
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
            ),
            if (_customY) ...[
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _yMinCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Y min',
                        isDense: true,
                      ),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _yMaxCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Y max',
                        isDense: true,
                      ),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        TextButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }

  void _save() {
    if (_titleEdited || widget.actualValues == null) {
      widget.panel['title'] = _titleCtrl.text;
    }
    if (_xLabelEdited || widget.actualValues == null) {
      widget.panel['x_label'] = _xLabelCtrl.text;
    }
    if (_yLabelEdited || widget.actualValues == null) {
      widget.panel['y_label'] = _yLabelCtrl.text;
    }
    if (_pointsEdited || widget.actualValues == null) {
      final extractionPoints = int.tryParse(_pointsCtrl.text);
      widget.panel['extraction_points'] =
          extractionPoints != null && extractionPoints >= 2
              ? extractionPoints
              : 2000;
    }
    widget.panel['grid'] = _grid;
    widget.panel['custom_x_range'] = _customX;
    widget.panel['custom_y_range'] = _customY;
    if (_customX) {
      final min = double.tryParse(_xMinCtrl.text);
      final max = double.tryParse(_xMaxCtrl.text);
      if (min != null && max != null && min.isFinite && max.isFinite) {
        widget.panel['xmin'] = min;
        widget.panel['xmax'] = max;
      } else {
        widget.panel['custom_x_range'] = false;
        widget.panel.remove('xmin');
        widget.panel.remove('xmax');
      }
    } else {
      widget.panel.remove('xmin');
      widget.panel.remove('xmax');
    }
    if (_customY) {
      final min = double.tryParse(_yMinCtrl.text);
      final max = double.tryParse(_yMaxCtrl.text);
      if (min != null && max != null && min.isFinite && max.isFinite) {
        widget.panel['ymin'] = min;
        widget.panel['ymax'] = max;
      } else {
        widget.panel['custom_y_range'] = false;
        widget.panel.remove('ymin');
        widget.panel.remove('ymax');
      }
    } else {
      widget.panel.remove('ymin');
      widget.panel.remove('ymax');
    }
    widget.onSave();
    Navigator.pop(context);
  }
}

class _InteractiveHorizontalScrollView extends StatefulWidget {
  const _InteractiveHorizontalScrollView({
    required this.scrollbarKey,
    required this.scrollViewKey,
    required this.child,
    required this.thickness,
    required this.revision,
    this.padding = EdgeInsets.zero,
  });

  final Key scrollbarKey;
  final Key scrollViewKey;
  final Widget child;
  final double thickness;
  final Object revision;
  final EdgeInsetsGeometry padding;

  @override
  State<_InteractiveHorizontalScrollView> createState() =>
      _InteractiveHorizontalScrollViewState();
}

class _InteractiveHorizontalScrollViewState
    extends State<_InteractiveHorizontalScrollView> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: widget.scrollbarKey,
      child: Scrollbar(
        key: ValueKey(widget.revision),
        controller: _controller,
        thumbVisibility: true,
        trackVisibility: true,
        interactive: true,
        thickness: widget.thickness,
        radius: const Radius.circular(4),
        scrollbarOrientation: ScrollbarOrientation.bottom,
        notificationPredicate: (notification) =>
            notification.metrics.axis == Axis.horizontal,
        child: Padding(
          padding: widget.padding,
          child: SingleChildScrollView(
            key: widget.scrollViewKey,
            controller: _controller,
            scrollDirection: Axis.horizontal,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _DataSourceDialog extends StatefulWidget {
  final List<Map<String, dynamic>> signals;
  final String defaultShot;
  final VoidCallback onSave;
  const _DataSourceDialog({
    required this.signals,
    required this.defaultShot,
    required this.onSave,
  });

  @override
  State<_DataSourceDialog> createState() => _DataSourceDialogState();
}

class _DataSourceDialogState extends State<_DataSourceDialog> {
  final _rows = <_DSRow>[];
  List<String> _treeNames = [];
  final Map<String, List<String>> _signalCache = {};
  final Map<String, Set<String>> _treesBySignal = {};
  SourceIndexMemory get _sourceIndexMemory =>
      context.read<AppState>().sourceIndexMemory;

  static const _presetColors = [
    0xFF2364aa,
    0xFFc44e52,
    0xFF2f855a,
    0xFF805ad5,
    0xFFd97706,
    0xFF0f766e,
    0xFF9f1239,
    0xFF4a5568,
    0xFFdb2777,
    0xFF16a34a,
    0xFFea580c,
    0xFF0891b2,
  ];

  @override
  void initState() {
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
      _treeNames = treeText
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
    } catch (_) {
      _treeNames = ['pcs_east'];
    }
    for (final rememberedTree in _sourceIndexMemory.trees) {
      if (!_treeNames.any(
        (tree) => tree.toLowerCase() == rememberedTree.toLowerCase(),
      )) {
        _treeNames.add(rememberedTree);
      }
    }
    _treeNames.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    _signalCache.remove('__all__');
    await _signalsForTree('');
    if (!mounted) return;
    // Load initial signal options for each row
    for (final r in _rows) {
      _updateSignalOptions(r);
    }
    if (mounted) setState(() {});
  }

  Future<List<String>> _signalsForTree(String tree) async {
    final key = tree.trim().toLowerCase().replaceAll(
          RegExp(r'[^a-z0-9_-]+'),
          '_',
        );
    if (key.isEmpty) {
      const allKey = '__all__';
      if (_signalCache.containsKey(allKey)) return _signalCache[allKey]!;
      final signalLists = await Future.wait(_treeNames.map(_signalsForTree));
      final allSignals = signalLists
          .expand((signals) => signals)
          .toSet()
          .toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      _signalCache[allKey] = allSignals;
      return allSignals;
    }
    if (_signalCache.containsKey(key)) return _signalCache[key]!;
    try {
      final text = await _loadAsset('assets/source_index/signals/$key.txt');
      final sigs = text
          .split('\n')
          .expand(sourceIndexSignalNames)
          .followedBy(_sourceIndexMemory.signalsForTree(tree))
          .toSet()
          .toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      _signalCache[key] = sigs;
      _indexTreeSignals(tree, sigs);
      return sigs;
    } catch (_) {
      final remembered = _sourceIndexMemory.signalsForTree(tree).toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      _signalCache[key] = remembered;
      _indexTreeSignals(tree, remembered);
      return remembered;
    }
  }

  void _indexTreeSignals(String tree, Iterable<String> signals) {
    final normalizedTree = tree.trim();
    if (normalizedTree.isEmpty) return;
    for (final signal in signals) {
      final key = sourceIndexSignalKey(signal);
      if (key.isEmpty) continue;
      _treesBySignal.putIfAbsent(key, () => <String>{}).add(normalizedTree);
    }
  }

  List<String> _treeOptionsFor(_DSRow row) {
    if (row.tree.text.trim().isNotEmpty) return _treeNames;
    final key = sourceIndexSignalKey(row.y.text);
    final matches = _treesBySignal[key]?.toList();
    if (matches == null || matches.isEmpty) return _treeNames;
    matches.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return matches;
  }

  static InputDecoration _dsDeco() => InputDecoration(
        isDense: true,
        filled: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      );

  static Widget _hdrCell(String text, double rightPad) {
    return Padding(
      padding: EdgeInsets.only(right: rightPad),
      child: Center(
        child: Text(
          text,
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
        ),
      ),
    );
  }

  Future<String> _loadAsset(String path) async {
    final bundle = DefaultAssetBundle.of(context);
    return await bundle.loadString(path);
  }

  void _addRowFromSignal(Map<String, dynamic>? s, int i) {
    final defaultRate = context.read<AppState>().dataMode;
    _rows.add(
      _DSRow(
        shot: TextEditingController(
          text: resolveDataSourceShot(
            signalShot: s?['shot'],
            inputShot: widget.defaultShot,
          ),
        ),
        y: TextEditingController(text: s?['y_expr']?.toString() ?? ''),
        legend: TextEditingController(text: s?['legend']?.toString() ?? ''),
        tree: TextEditingController(
          text: s?['experiment']?.toString() ?? 'pcs_east',
        ),
        server: TextEditingController(
          text: s?['server_ip']?.toString() ?? '202.127.204.12',
        ),
        xExpr: s?['x_expr']?.toString() ?? '',
      )
        ..hideMode = s == null ? signalHideModeVisible : signalHideModeOf(s)
        ..colorIdx = i % _presetColors.length
        ..readMode = (s?['read_mode'] as int?) ?? defaultRate,
    );
    if (s != null && s['color_name'] != null) {
      final hex = s['color_name'].toString().replaceFirst('#', '');
      final c = int.tryParse(hex, radix: 16);
      if (c != null) {
        final full = 0xFF000000 | c;
        for (var j = 0; j < _presetColors.length; j++) {
          if (_presetColors[j] == full) {
            _rows.last.colorIdx = j;
            break;
          }
        }
        _rows.last.customColor = Color(full);
      }
    }
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext ctx) {
    return GestureDetector(
      key: const ValueKey('data-source-dialog-surface'),
      behavior: HitTestBehavior.translucent,
      onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
      child: KeyboardSafeDialog(
        maxWidth: 960,
        title: Row(
          children: [
            const Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text('Data Source Setup'),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.add, size: 18),
              tooltip: 'Add Curve',
              onPressed: _rows.length < 8
                  ? () {
                      FocusManager.instance.primaryFocus?.unfocus();
                      final last = _rows.isNotEmpty ? _rows.last : null;
                      final shotCtrl = TextEditingController(
                        text: last?.shot.text ?? widget.defaultShot,
                      );
                      final treeCtrl = TextEditingController(
                        text: last?.tree.text ?? 'pcs_east',
                      );
                      final yCtrl = TextEditingController();
                      final legendCtrl = TextEditingController();
                      final serverCtrl = TextEditingController(
                        text: last?.server.text ?? '202.127.204.12',
                      );
                      final defaultRate = context.read<AppState>().dataMode;
                      final newRow = _DSRow(
                        shot: shotCtrl,
                        y: yCtrl,
                        legend: legendCtrl,
                        tree: treeCtrl,
                        server: serverCtrl,
                        xExpr: '',
                      )
                        ..colorIdx = _rows.length % _presetColors.length
                        ..readMode = defaultRate;
                      setState(() {
                        _rows.add(newRow);
                      });
                      _updateSignalOptions(newRow);
                    }
                  : null,
            ),
          ],
        ),
        content: SizedBox(
          height: 180,
          child: _InteractiveHorizontalScrollView(
            scrollbarKey: const ValueKey('data-source-horizontal-scrollbar'),
            scrollViewKey: const ValueKey('data-source-horizontal-scroll'),
            thickness: 5,
            revision: _rows.length,
            padding: const EdgeInsets.only(bottom: 9),
            child: IntrinsicWidth(
              child: SingleChildScrollView(
                child: Table(
                  columnWidths: const {
                    0: FixedColumnWidth(84),
                    1: FixedColumnWidth(124),
                    2: FixedColumnWidth(184),
                    3: FixedColumnWidth(130),
                    4: FixedColumnWidth(144),
                    5: FixedColumnWidth(34),
                    6: FixedColumnWidth(150),
                    7: FixedColumnWidth(136),
                    8: FixedColumnWidth(26),
                  },
                  defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                  children: [
                    TableRow(
                      children: [
                        _hdrCell('Shot', 4),
                        _hdrCell('Tree', 4),
                        _hdrCell('Signal', 4),
                        _hdrCell('Legend', 4),
                        _hdrCell('Server IP', 4),
                        _hdrCell('Color', 4),
                        _hdrCell('Visibility', 4),
                        _hdrCell('Data', 4),
                        _hdrCell('Del', 0),
                      ],
                    ),
                    for (var i = 0; i < _rows.length; i++)
                      TableRow(
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: TextField(
                              key: ValueKey('data-shot-$i'),
                              controller: _rows[i].shot,
                              decoration: _dsDeco(),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: KeyedSubtree(
                              key: ValueKey('data-tree-$i'),
                              child: _AutocompleteField(
                                key: _rows[i].treeAutocompleteKey,
                                controller: _rows[i].tree,
                                options: _treeOptionsFor(_rows[i]),
                                label: 'Tree',
                                onChanged: () {
                                  _updateSignalOptions(_rows[i]);
                                  setState(() {});
                                },
                                onSelected: (_) => _rows[i]
                                    .signalAutocompleteKey
                                    .currentState
                                    ?.requestFocus(),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: KeyedSubtree(
                              key: ValueKey('data-signal-$i'),
                              child: _AutocompleteField(
                                key: _rows[i].signalAutocompleteKey,
                                controller: _rows[i].y,
                                options: _rows[i]._signalOptions,
                                label: 'Signal',
                                onChanged: () => setState(() {}),
                                onSelected: (_) =>
                                    _showReverseTreeSuggestions(_rows[i]),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: TextField(
                              key: ValueKey('data-legend-$i'),
                              controller: _rows[i].legend,
                              decoration: _dsDeco().copyWith(
                                hintText: signalLegendLabel({
                                  'y_expr': _rows[i].y.text,
                                }),
                              ),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: TextField(
                              controller: _rows[i].server,
                              decoration: _dsDeco(),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Center(
                              child: _ColorPicker(
                                row: _rows[i],
                                onChanged: () => setState(() {}),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: PolishedDropdown<int>(
                              key: ValueKey('data-hide-mode-dropdown-$i'),
                              id: 'data-hide-mode-$i',
                              value: _rows[i].hideMode,
                              height: 42,
                              fontSize: 11,
                              leadingIcon: Icons.visibility_rounded,
                              minimumMenuWidth: 220,
                              options: const [
                                PolishedDropdownOption(
                                  value: signalHideModeVisible,
                                  label: 'Not hidden',
                                  icon: Icons.visibility_rounded,
                                ),
                                PolishedDropdownOption(
                                  value: signalHideModeTemporary,
                                  label: 'Hide this shot',
                                  icon: Icons.visibility_off_outlined,
                                ),
                                PolishedDropdownOption(
                                  value: signalHideModePersistent,
                                  label: 'Always hide',
                                  icon: Icons.lock_outline_rounded,
                                ),
                              ],
                              onChanged: (value) =>
                                  setState(() => _rows[i].hideMode = value),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: PolishedDropdown<int>(
                              key: ValueKey('data-mode-dropdown-$i'),
                              id: 'data-mode-$i',
                              value: _rows[i].readMode,
                              height: 42,
                              fontSize: 11,
                              leadingIcon: Icons.data_usage_rounded,
                              minimumMenuWidth: 190,
                              options: const [
                                PolishedDropdownOption(
                                  value: 0,
                                  label: 'Thin',
                                  icon: Icons.compress_rounded,
                                ),
                                PolishedDropdownOption(
                                  value: 1,
                                  label: 'Medium',
                                  icon: Icons.format_line_spacing_rounded,
                                ),
                                PolishedDropdownOption(
                                  value: 2,
                                  label: 'Full',
                                  icon: Icons.stacked_line_chart_rounded,
                                ),
                              ],
                              onChanged: (value) =>
                                  setState(() => _rows[i].readMode = value),
                            ),
                          ),
                          _rows.length > 1
                              ? GestureDetector(
                                  onTap: () => setState(() {
                                    _rows[i].dispose();
                                    _rows.removeAt(i);
                                  }),
                                  child: const Icon(
                                    Icons.close,
                                    size: 16,
                                    color: Colors.red,
                                  ),
                                )
                              : const SizedBox(width: 16),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(onPressed: _save, child: const Text('OK')),
        ],
      ),
    );
  }

  void _updateSignalOptions(_DSRow row) async {
    final requestedTree = row.tree.text.trim().toLowerCase();
    final sigs = await _signalsForTree(requestedTree);
    if (!mounted || requestedTree != row.tree.text.trim().toLowerCase()) return;
    setState(() => row._signalOptions = sigs);
  }

  void _showReverseTreeSuggestions(_DSRow row) {
    if (row.tree.text.trim().isNotEmpty ||
        _treeOptionsFor(row).isEmpty ||
        !mounted) {
      return;
    }
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || row.tree.text.trim().isNotEmpty) return;
      row.treeAutocompleteKey.currentState?.showSuggestions();
    });
  }

  void _save() {
    widget.signals.clear();
    for (final r in _rows) {
      if (r.y.text.trim().isEmpty) continue;
      final shot = r.shot.text.trim();
      final colorValue = r.customColor ??
          Color(_presetColors[r.colorIdx % _presetColors.length]);
      widget.signals.add({
        'shot': shot.isNotEmpty ? shot : widget.defaultShot,
        'y_expr': r.y.text.trim(),
        'x_expr': r.xExpr,
        'legend': r.legend.text.trim(),
        'experiment': r.tree.text.trim(),
        'server_ip': r.server.text.trim(),
        'color_name':
            '#${colorValue.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}',
        'manual_color': true,
        'hide_mode': r.hideMode,
        'hidden': r.hideMode != signalHideModeVisible,
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
  final ValueChanged<String>? onSelected;
  const _AutocompleteField({
    super.key,
    required this.controller,
    required this.options,
    required this.label,
    this.onChanged,
    this.onSelected,
  });
  @override
  State<_AutocompleteField> createState() => _AutocompleteFieldState();
}

class _AutocompleteFieldState extends State<_AutocompleteField> {
  final _node = FocusNode();
  final _scrollController = ScrollController();
  final _tapRegionGroup = Object();
  OverlayEntry? _overlay;
  final _layerLink = LayerLink();
  List<String> _hints = const [];

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_update);
    _node.addListener(_handleFocusChange);
  }

  @override
  void didUpdateWidget(covariant _AutocompleteField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.options, widget.options) && _node.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _update();
      });
    }
  }

  @override
  void dispose() {
    _removeOverlay();
    widget.controller.removeListener(_update);
    _node.removeListener(_handleFocusChange);
    _node.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  void _handleFocusChange() {
    if (_node.hasFocus) {
      _update();
    } else {
      _removeOverlay();
    }
  }

  void _selectHint(String hint) {
    widget.controller.value = TextEditingValue(
      text: hint,
      selection: TextSelection.collapsed(offset: hint.length),
    );
    _removeOverlay();
    widget.onChanged?.call();
    widget.onSelected?.call(hint);
  }

  void _update() {
    final v = widget.controller.text.toLowerCase();
    final matchingHints = v.isEmpty
        ? widget.options
        : widget.options.where((o) => o.toLowerCase().contains(v)).toList();
    final hints = v.isNotEmpty && matchingHints.length > 128
        ? matchingHints.sublist(0, 128)
        : matchingHints;
    final exactOnly = hints.length == 1 && hints[0].toLowerCase() == v;
    if (hints.isEmpty || !_node.hasFocus || exactOnly) {
      _hints = const [];
      _removeOverlay();
      return;
    }
    _hints = hints;
    if (_overlay == null) {
      _overlay = OverlayEntry(
        builder: (overlayContext) {
          final theme = Theme.of(overlayContext);
          final visibleHints = _hints;
          return Positioned(
            width: 220,
            child: CompositedTransformFollower(
              link: _layerLink,
              showWhenUnlinked: false,
              offset: const Offset(0, 42),
              child: TapRegion(
                groupId: _tapRegionGroup,
                child: Material(
                  color: theme.colorScheme.surfaceContainerHigh,
                  elevation: 8,
                  shadowColor: theme.colorScheme.shadow.withValues(alpha: 0.22),
                  shape: RoundedRectangleBorder(
                    side: BorderSide(color: theme.colorScheme.outlineVariant),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: ConstrainedBox(
                    key: ValueKey(
                      'autocomplete-${widget.label.toLowerCase()}-menu',
                    ),
                    constraints: const BoxConstraints(maxHeight: 240),
                    child: Scrollbar(
                      controller: _scrollController,
                      thumbVisibility: true,
                      interactive: true,
                      child: ListView.separated(
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        shrinkWrap: true,
                        itemCount: visibleHints.length,
                        separatorBuilder: (_, __) => Divider(
                          height: 1,
                          color: theme.dividerColor.withValues(alpha: 0.55),
                        ),
                        itemBuilder: (_, i) => Listener(
                          key: ValueKey(
                            'autocomplete-${widget.label.toLowerCase()}-option-$i',
                          ),
                          behavior: HitTestBehavior.opaque,
                          onPointerDown: (event) {
                            if (event.kind == PointerDeviceKind.mouse ||
                                event.kind == PointerDeviceKind.trackpad ||
                                event.kind == PointerDeviceKind.stylus ||
                                event.kind ==
                                    PointerDeviceKind.invertedStylus) {
                              _selectHint(visibleHints[i]);
                            }
                          },
                          child: ListTile(
                            dense: true,
                            minTileHeight: 42,
                            leading: Icon(
                              Icons.search_rounded,
                              size: 18,
                              color: theme.colorScheme.primary,
                            ),
                            title: Text(
                              visibleHints[i],
                              style: const TextStyle(fontSize: 12),
                            ),
                            onTap: () => _selectHint(visibleHints[i]),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
      Overlay.of(context).insert(_overlay!);
    } else {
      _overlay!.markNeedsBuild();
    }
  }

  void requestFocus() => _node.requestFocus();

  void showSuggestions() {
    _node.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _update();
    });
  }

  @override
  Widget build(BuildContext ctx) => CompositedTransformTarget(
        link: _layerLink,
        child: TextField(
          groupId: _tapRegionGroup,
          controller: widget.controller,
          focusNode: _node,
          decoration: _DataSourceDialogState._dsDeco(),
          style: const TextStyle(fontSize: 12),
          onTap: _update,
          onChanged: (_) => widget.onChanged?.call(),
        ),
      );
}

class _ColorPicker extends StatelessWidget {
  final _DSRow row;
  final VoidCallback onChanged;
  const _ColorPicker({required this.row, required this.onChanged});

  @override
  Widget build(BuildContext ctx) {
    final current = row.customColor ??
        Color(
          _DataSourceDialogState._presetColors[
              row.colorIdx % _DataSourceDialogState._presetColors.length],
        );
    return GestureDetector(
      onTap: () => _showColorDialog(ctx, current),
      child: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: current,
          border: Border.all(color: Colors.grey),
          borderRadius: BorderRadius.circular(3),
        ),
      ),
    );
  }

  void _showColorDialog(BuildContext ctx, Color current) {
    final topColors = _DataSourceDialogState._presetColors;
    Color selected = current;
    showDialog(
      context: ctx,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) {
          return KeyboardSafeDialog(
            title: Row(
              children: [
                const Text('Curve Color'),
                const SizedBox(width: 12),
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: selected,
                    border: Border.all(color: Colors.grey),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 300,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Wrap(
                      spacing: 2,
                      runSpacing: 2,
                      children: topColors
                          .map(
                            (c) => GestureDetector(
                              onTap: () {
                                selected = Color(c);
                                setSt(() {});
                              },
                              child: Container(
                                width: 22,
                                height: 22,
                                decoration: BoxDecoration(
                                  color: Color(c),
                                  border: Border.all(
                                    color: selected == Color(c)
                                        ? Colors.black
                                        : Colors.grey,
                                    width: selected == Color(c) ? 2 : 1,
                                  ),
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 8),
                    // Continuous HSV picker: X = hue, Y = value (brightness)
                    GestureDetector(
                      onPanDown: (d) => _pickColor(
                        d.localPosition,
                        setSt,
                        (c) => selected = c,
                      ),
                      onPanUpdate: (d) => _pickColor(
                        d.localPosition,
                        setSt,
                        (c) => selected = c,
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: CustomPaint(
                          size: const Size(280, 180),
                          painter: _HsvPainter(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Text('#'),
                        Expanded(
                          child: TextField(
                            decoration: const InputDecoration(isDense: true),
                            onSubmitted: (v) {
                              final cleaned = v.replaceFirst('#', '');
                              final c = int.tryParse(cleaned, radix: 16);
                              if (c != null && cleaned.length == 6) {
                                selected = Color(0xFF000000 | c);
                                setSt(() {});
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () {
                  row.customColor = selected;
                  row.colorIdx = topColors.indexWhere(
                    (c) => c == selected.toARGB32(),
                  );
                  if (row.colorIdx < 0) row.colorIdx = 0;
                  onChanged();
                  Navigator.pop(ctx);
                },
                child: const Text('OK'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _pickColor(
    Offset pos,
    StateSetter setSt,
    void Function(Color) setColor,
  ) {
    if (pos.dx < 0 || pos.dy < 0 || pos.dx > 280 || pos.dy > 180) return;
    final hue = (pos.dx / 280 * 360).clamp(0.0, 359.0);
    final val = (1.0 - pos.dy / 180).clamp(0.0, 1.0);
    setSt(() => setColor(HSVColor.fromAHSV(1, hue, 1, val).toColor()));
  }
}

class _HsvPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    for (var x = 0.0; x < size.width; x += 1.0) {
      final hue = (x / size.width * 360);
      final paint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            HSVColor.fromAHSV(1.0, hue, 1.0, 1.0).toColor(),
            Colors.black,
          ],
        ).createShader(Rect.fromLTWH(x, 0, 1.0, size.height));
      canvas.drawRect(Rect.fromLTWH(x, 0, 1.0, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_) => false;
}

class _DSRow {
  final TextEditingController shot, y, legend, tree, server;
  final treeAutocompleteKey = GlobalKey<_AutocompleteFieldState>();
  final signalAutocompleteKey = GlobalKey<_AutocompleteFieldState>();
  final String xExpr;
  int hideMode = signalHideModeVisible;
  int readMode = 0;
  int colorIdx = 0;
  Color? customColor;
  List<String> _signalOptions = [];
  _DSRow({
    required this.shot,
    required this.y,
    required this.legend,
    required this.tree,
    required this.server,
    required this.xExpr,
  });
  void dispose() {
    shot.dispose();
    y.dispose();
    legend.dispose();
    tree.dispose();
    server.dispose();
  }
}
