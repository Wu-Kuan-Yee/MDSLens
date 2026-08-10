import 'package:toml/toml.dart';

/// Decode one application-owned TOML document into ordinary Dart values.
Map<String, dynamic> decodeTomlDocument(String source) =>
    TomlDocument.parse(source).toMap();

/// Encode application-owned state as TOML.
///
/// TOML deliberately has no null value. Optional map entries are omitted and
/// null array elements are discarded, matching how MDSLens already treats
/// absent optional settings and non-finite plot bounds.
String encodeTomlDocument(Map<dynamic, dynamic> source) {
  final sanitized = _tomlValue(source);
  if (sanitized is! Map<String, dynamic>) {
    throw const FormatException('The TOML document root must be a table.');
  }
  final encoded = TomlDocument.fromMap(sanitized).toString();
  return encoded.endsWith('\n') ? encoded : '$encoded\n';
}

dynamic _tomlValue(dynamic value) {
  if (value == null) return null;
  if (value is double && !value.isFinite) return null;
  if (value is String || value is bool || value is int || value is double) {
    return value;
  }
  if (value is num) return value.toDouble();
  if (value is List) {
    return <dynamic>[
      for (final item in value)
        if (_tomlValue(item) case final converted?) converted,
    ];
  }
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries)
        if (_tomlValue(entry.value) case final converted?)
          entry.key.toString(): converted,
    };
  }
  return value.toString();
}
