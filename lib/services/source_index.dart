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
  final Map<String, Set<String>> _signalsByTree = {};

  void remember(String tree, String expression) {
    final normalizedTree = tree.trim().toLowerCase();
    if (normalizedTree.isEmpty) return;
    final nodes = sourceIndexSignalNames(expression);
    if (nodes.isEmpty) return;
    _signalsByTree.putIfAbsent(normalizedTree, () => <String>{}).addAll(nodes);
  }

  List<String> signalsForTree(String tree) => List<String>.unmodifiable(
        _signalsByTree[tree.trim().toLowerCase()] ?? const <String>{},
      );

  Set<String> get trees => Set<String>.unmodifiable(_signalsByTree.keys);
}
