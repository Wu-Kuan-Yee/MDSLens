import 'dart:math' as math;

const double compactPlotLayoutBreakpoint = 600;
const double minimumPlotColumnWidth = 280;

typedef ResponsivePlotCell = ({
  int sourceColumn,
  int sourceRow,
  int plotIndex,
});

bool usesScrollablePlotList(double availableWidth) {
  return availableWidth < compactPlotLayoutBreakpoint;
}

List<List<ResponsivePlotCell>> buildResponsivePlotColumns(
  List<int> sourceColumnSizes,
  double availableWidth,
) {
  final sourceColumns = <List<ResponsivePlotCell>>[];
  final flattened = <ResponsivePlotCell>[];
  var plotIndex = 0;
  for (var column = 0; column < sourceColumnSizes.length; column++) {
    final cells = <ResponsivePlotCell>[];
    for (var row = 0; row < math.max(0, sourceColumnSizes[column]); row++) {
      final cell = (
        sourceColumn: column,
        sourceRow: row,
        plotIndex: plotIndex++,
      );
      cells.add(cell);
      flattened.add(cell);
    }
    if (cells.isNotEmpty) sourceColumns.add(cells);
  }
  if (flattened.isEmpty) return const [];

  final availableColumnCount = usesScrollablePlotList(availableWidth)
      ? 1
      : math.max(1, (availableWidth / minimumPlotColumnWidth).floor());
  final displayColumnCount = math.min(
    sourceColumns.length,
    availableColumnCount,
  );
  if (displayColumnCount == sourceColumns.length) return sourceColumns;

  final baseSize = flattened.length ~/ displayColumnCount;
  final columnsWithExtraCell = flattened.length % displayColumnCount;
  final result = <List<ResponsivePlotCell>>[];
  var offset = 0;
  for (var column = 0; column < displayColumnCount; column++) {
    final size = baseSize + (column < columnsWithExtraCell ? 1 : 0);
    result.add(flattened.sublist(offset, offset + size));
    offset += size;
  }
  return result;
}
