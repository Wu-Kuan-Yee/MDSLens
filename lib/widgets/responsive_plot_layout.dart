import 'dart:math' as math;

typedef ResponsivePlotCell = ({int sourceColumn, int sourceRow, int plotIndex});

List<List<ResponsivePlotCell>> buildResponsivePlotColumns(
  List<int> sourceColumnSizes,
  double _,
) {
  final sourceColumns = <List<ResponsivePlotCell>>[];
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
    }
    if (cells.isNotEmpty) sourceColumns.add(cells);
  }
  return sourceColumns;
}
