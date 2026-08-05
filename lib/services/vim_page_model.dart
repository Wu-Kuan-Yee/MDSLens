import 'package:flutter/foundation.dart';

/// The kind of semantic cell exposed by the Vim page model.
///
/// A page is deliberately independent from Flutter widgets.  A dialog, a
/// dropdown, a plot column, and a text field all use the same representation;
/// the widget layer only supplies the activation/enter callbacks and keeps a
/// visual anchor for scrolling.
enum VimPageCellKind {
  control,
  page,
  plot,
  text,
  menu,
}

/// A single character in a Vim page.
class VimPageCell {
  const VimPageCell({
    required this.id,
    required this.label,
    this.kind = VimPageCellKind.control,
    this.enabled = true,
    this.onActivate,
    this.onEnter,
  });

  final String id;
  final String label;
  final VimPageCellKind kind;
  final bool enabled;
  final VoidCallback? onActivate;
  final VoidCallback? onEnter;

  bool get isPage => kind == VimPageCellKind.page;
}

/// A semantic page.  Rows are logical rows, not the current pixel wrapping of
/// a responsive layout.  The caller can therefore keep the same keyboard
/// behavior while a phone or desktop changes the visual arrangement.
class VimPage {
  const VimPage({
    required this.id,
    required this.title,
    required this.rows,
    this.parentId,
  });

  final String id;
  final String title;
  final List<List<VimPageCell>> rows;
  final String? parentId;

  Iterable<VimPageCell> get cells => rows.expand((row) => row);

  VimPageCell? cellById(String id) {
    for (final cell in cells) {
      if (cell.id == id) return cell;
    }
    return null;
  }

  int rowOf(String id) {
    for (var row = 0; row < rows.length; row++) {
      if (rows[row].any((cell) => cell.id == id)) return row;
    }
    return -1;
  }
}

enum VimPageMotion {
  left,
  right,
  up,
  down,
  first,
  last,
  rowFirst,
  rowLast,
}

/// Stateful page-stack navigation shared by the whole application.
///
/// The stack is intentionally small and deterministic: entering a child page
/// pushes it, Escape pops exactly one page, and Escape at the root clears the
/// selection.  Every page remembers its last cell, while transient pages can
/// opt into first-cell entry by calling [push] with [selectFirst].
class VimPageStack extends ChangeNotifier {
  VimPageStack({VimPage? root}) : _stack = [root ?? _emptyRoot];

  static const _emptyRoot = VimPage(
    id: 'root',
    title: 'Application',
    rows: <List<VimPageCell>>[],
  );

  final List<VimPage> _stack;
  final Map<String, String?> _selectionByPage = <String, String?>{};
  final Map<String, int> _preferredColumnByPage = <String, int>{};

  List<VimPage> get stack => List.unmodifiable(_stack);
  VimPage get currentPage => _stack.last;
  String? get selectedId => _selectionByPage[currentPage.id];
  bool get atRoot => _stack.length == 1;

  /// Record a widget-backed selection before its semantic page is pushed into
  /// the stack.  Dynamic pages such as a plot column are rebuilt from the
  /// current configuration, so the registry may not have a page definition at
  /// the exact moment a focus node receives focus.
  void setExternalSelection(String pageId, String cellId) {
    if (_selectionByPage[pageId] == cellId) return;
    _selectionByPage[pageId] = cellId;
    notifyListeners();
  }

  String? selectionFor(String pageId) => _selectionByPage[pageId];

  /// Replace the current page's definition after responsive layout changes.
  /// The selection is retained only if that cell still exists.
  void replaceCurrent(VimPage page) {
    if (page.id != currentPage.id) return;
    _stack[_stack.length - 1] = page;
    final selected = _selectionByPage[page.id];
    if (selected != null && page.cellById(selected) == null) {
      _selectionByPage.remove(page.id);
    }
    notifyListeners();
  }

  void setSelection(String? id) {
    if (id != null && currentPage.cellById(id) == null) return;
    if (_selectionByPage[currentPage.id] == id) return;
    _selectionByPage[currentPage.id] = id;
    notifyListeners();
  }

  /// Enter a child page.  Transient pages should use selectFirst=true so a
  /// menu/dropdown always starts at its first option.
  bool push(VimPage page, {bool selectFirst = true}) {
    if (page.parentId != null && page.parentId != currentPage.id) {
      return false;
    }
    _stack.add(page);
    if (selectFirst) {
      _selectionByPage[page.id] = _firstEnabled(page)?.id;
      _preferredColumnByPage[page.id] = 0;
    }
    notifyListeners();
    return true;
  }

  bool pop() {
    if (atRoot) {
      final hadSelection = _selectionByPage.remove(currentPage.id) != null;
      if (hadSelection) notifyListeners();
      return hadSelection;
    }
    _stack.removeLast();
    notifyListeners();
    return true;
  }

  bool activate() {
    final cell = currentPage.cellById(selectedId ?? '');
    if (cell == null || !cell.enabled) return false;
    cell.onActivate?.call();
    return true;
  }

  bool enter() {
    final cell = currentPage.cellById(selectedId ?? '');
    if (cell == null || !cell.enabled) return false;
    cell.onEnter?.call();
    return true;
  }

  bool move(VimPageMotion motion) {
    final page = currentPage;
    if (page.rows.isEmpty) return false;
    final selected = selectedId;
    final current = selected == null ? null : page.cellById(selected);
    final first = _firstEnabled(page);
    if (current == null) {
      if (first == null) return false;
      final initial = motion == VimPageMotion.last ? _lastEnabled(page) : first;
      if (initial == null) return false;
      setSelection(initial.id);
      return true;
    }

    final rowIndex = page.rowOf(current.id);
    if (rowIndex < 0) return false;
    final row = page.rows[rowIndex].where((cell) => cell.enabled).toList();
    if (row.isEmpty) return false;
    final columnIndex = row.indexWhere((cell) => cell.id == current.id);
    VimPageCell? target;
    switch (motion) {
      case VimPageMotion.left:
        target = _stepHorizontal(row, columnIndex, -1);
        if (columnIndex >= 0) {
          _preferredColumnByPage[page.id] =
              (columnIndex - 1).clamp(0, row.length - 1).toInt();
        }
        break;
      case VimPageMotion.right:
        target = _stepHorizontal(row, columnIndex, 1);
        if (columnIndex >= 0) {
          _preferredColumnByPage[page.id] =
              (columnIndex + 1).clamp(0, row.length - 1).toInt();
        }
        break;
      case VimPageMotion.up:
      case VimPageMotion.down:
        final step = motion == VimPageMotion.up ? -1 : 1;
        final targetRow = _nextEnabledRow(page, rowIndex, step);
        if (targetRow >= 0) {
          final candidates =
              page.rows[targetRow].where((cell) => cell.enabled).toList();
          if (candidates.isNotEmpty) {
            final preferred = _preferredColumnByPage[page.id] ?? columnIndex;
            target =
                candidates[preferred.clamp(0, candidates.length - 1).toInt()];
          }
        }
        break;
      case VimPageMotion.first:
        target = _firstEnabled(page);
        break;
      case VimPageMotion.last:
        target = _lastEnabled(page);
        break;
      case VimPageMotion.rowFirst:
        target = row.first;
        break;
      case VimPageMotion.rowLast:
        target = row.last;
        break;
    }
    if (target == null || target.id == current.id) return false;
    setSelection(target.id);
    return true;
  }

  VimPageCell? _stepHorizontal(
    List<VimPageCell> row,
    int current,
    int step,
  ) {
    if (current < 0) return row.firstOrNull;
    final target = current + step;
    if (target < 0 || target >= row.length) return row[current];
    return row[target];
  }

  int _nextEnabledRow(VimPage page, int start, int step) {
    for (var row = start + step;
        row >= 0 && row < page.rows.length;
        row += step) {
      if (page.rows[row].any((cell) => cell.enabled)) return row;
    }
    return -1;
  }

  VimPageCell? _firstEnabled(VimPage page) {
    for (final row in page.rows) {
      for (final cell in row) {
        if (cell.enabled) return cell;
      }
    }
    return null;
  }

  VimPageCell? _lastEnabled(VimPage page) {
    for (final row in page.rows.reversed) {
      for (final cell in row.reversed) {
        if (cell.enabled) return cell;
      }
    }
    return null;
  }
}

extension on List<VimPageCell> {
  VimPageCell? get firstOrNull => isEmpty ? null : first;
}
