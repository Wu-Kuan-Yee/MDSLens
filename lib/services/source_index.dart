final RegExp _mdsNodePattern = RegExp(r'\\[A-Za-z][A-Za-z0-9_$:.]*');
final RegExp _bareMdsNodePattern = RegExp(r'^[A-Za-z][A-Za-z0-9_$:.]*$');

List<String> sourceIndexSignalNames(String expression) {
  final result = <String>[];
  final seen = <String>{};
  for (final match in _mdsNodePattern.allMatches(expression)) {
    var signal = match.group(0) ?? '';
    while (signal.startsWith(r'\\')) {
      signal = signal.substring(1);
    }
    if (signal.isNotEmpty && seen.add(signal.toLowerCase())) {
      result.add(signal);
    }
  }
  if (result.isEmpty) {
    final bare = expression.trim();
    if (_bareMdsNodePattern.hasMatch(bare)) result.add('\\$bare');
  }
  return result;
}

String sourceIndexSignalKey(String expression) {
  var candidate = expression.trim();
  if (candidate.startsWith('/')) candidate = '\\${candidate.substring(1)}';
  final nodes = sourceIndexSignalNames(candidate);
  var key = (nodes.isEmpty ? candidate : nodes.first).trim().toLowerCase();
  while (key.startsWith(r'\\')) {
    key = key.substring(1);
  }
  if (key.startsWith(r'\')) key = key.substring(1);
  return key;
}

class SourceIndexMemory {
  static const int maximumTrees = 256;
  static const int maximumSignalsPerTree = 2048;
  final Map<String, Set<String>> _signalsByTree = {};

  bool remember(String tree, String expression) {
    final normalizedTree = tree.trim().toLowerCase();
    if (normalizedTree.isEmpty) return false;
    final nodes = sourceIndexSignalNames(expression);
    if (nodes.isEmpty) return false;
    if (!_signalsByTree.containsKey(normalizedTree) &&
        _signalsByTree.length >= maximumTrees) {
      return false;
    }
    final signals =
        _signalsByTree.putIfAbsent(normalizedTree, () => <String>{});
    var changed = false;
    for (final node in nodes) {
      if (signals.length >= maximumSignalsPerTree) break;
      changed = signals.add(node) || changed;
    }
    return changed;
  }

  List<String> signalsForTree(String tree) => List<String>.unmodifiable(
        _signalsByTree[tree.trim().toLowerCase()] ?? const <String>{},
      );

  Set<String> get trees => Set<String>.unmodifiable(_signalsByTree.keys);

  Map<String, List<String>> toJson() {
    final result = <String, List<String>>{};
    final treeNames = _signalsByTree.keys.toList()..sort();
    for (final tree in treeNames) {
      final signals = _signalsByTree[tree]!.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      result[tree] = signals;
    }
    return result;
  }

  void restore(Object? encoded) {
    if (encoded is! Map) return;
    _signalsByTree.clear();
    for (final entry in encoded.entries) {
      if (_signalsByTree.length >= maximumTrees) break;
      final tree = entry.key.toString().trim().toLowerCase();
      if (tree.isEmpty || entry.value is! List) continue;
      for (final signal in entry.value as List) {
        remember(tree, signal.toString());
      }
    }
  }
}
