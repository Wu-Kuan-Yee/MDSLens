import 'dart:convert';
import 'dart:typed_data';

/// Browser-local configuration encoder.
///
/// Static hosts such as GitHub Pages cannot answer the Rust gateway's POST
/// routes. Encoding is deterministic and does not require MDSplus, SSH, or
/// credentials, so keep it in the browser.
class WebConfigurationEncoder {
  WebConfigurationEncoder._();

  static Uint8List encode(String configJson, String format) {
    final decoded = jsonDecode(configJson);
    if (decoded is! Map) {
      throw const FormatException('Configuration must be a JSON object.');
    }
    final config = Map<String, dynamic>.from(decoded);
    final text = switch (format) {
      'toml' => _toml(config),
      'webscp' => _webscp(config),
      _ => throw const FormatException('Unsupported configuration format.'),
    };
    return Uint8List.fromList(utf8.encode(text));
  }

  static List<List<Map<String, dynamic>>> _columns(
    Map<String, dynamic> config,
  ) {
    return [
      for (final rawColumn in (config['columns'] as List?) ?? const [])
        [
          for (final rawPanel in (rawColumn as List?) ?? const [])
            if (rawPanel is Map) Map<String, dynamic>.from(rawPanel),
        ],
    ];
  }

  static List<Map<String, dynamic>> _signals(Map<String, dynamic> panel) => [
        for (final raw in (panel['signal_specs'] as List?) ?? const [])
          if (raw is Map) Map<String, dynamic>.from(raw),
      ];

  static String _text(Object? value) => value?.toString() ?? '';
  static bool _bool(Object? value, [bool fallback = false]) =>
      value is bool ? value : fallback;
  static int _int(Object? value, [int fallback = 0]) =>
      value is num ? value.toInt() : int.tryParse(_text(value)) ?? fallback;
  static num? _finiteNumber(Object? value) =>
      value is num && value.isFinite ? value : null;
  static String _lineValue(Object? value) =>
      _text(value).replaceAll(RegExp(r'[\r\n]'), ' ');
  static String _tomlString(Object? value) => jsonEncode(_text(value));

  static String _hideMode(Map<String, dynamic> signal) {
    return switch (_int(signal['hide_mode'])) {
      1 => 'temporary',
      2 => 'persistent',
      _ when _bool(signal['hidden']) => 'persistent',
      _ => 'visible',
    };
  }

  static String _readMode(Map<String, dynamic> signal) {
    return switch (_int(signal['read_mode'])) {
      2 => 'full',
      1 => 'medium',
      _ => 'thin',
    };
  }

  static String _defaultShot(
    Map<String, dynamic> config,
    List<List<Map<String, dynamic>>> columns,
  ) {
    final configured = _text(config['shot']).trim();
    if (configured.isNotEmpty) return configured;
    for (final column in columns) {
      for (final panel in column) {
        final shot = _text(panel['shot']).trim();
        if (shot.isNotEmpty) return shot;
      }
    }
    return '';
  }

  static String _toml(Map<String, dynamic> config) {
    final columns = _columns(config);
    final defaultShot = _defaultShot(config, columns);
    final out = StringBuffer('version = 1\n\n');
    if (defaultShot.isNotEmpty) {
      out.writeln('shot = ${_tomlString(defaultShot)}\n');
    }
    for (var columnIndex = 0; columnIndex < columns.length; columnIndex++) {
      final column = columns[columnIndex];
      for (var rowIndex = 0; rowIndex < column.length; rowIndex++) {
        final panel = column[rowIndex];
        out
          ..writeln('[[panels]]')
          ..writeln('column = ${columnIndex + 1}')
          ..writeln('row = ${rowIndex + 1}');
        for (final entry in const [
          ('title', 'title'),
          ('x_label', 'x_label'),
          ('y_label', 'y_label'),
        ]) {
          final value = _text(panel[entry.$1]);
          if (value.isNotEmpty) {
            out.writeln('${entry.$2} = ${_tomlString(value)}');
          }
        }
        final extraction = _int(panel['extraction_points'], 2000);
        if (extraction != 2000) out.writeln('extraction_points = $extraction');
        if (!_bool(panel['grid'], true)) out.writeln('grid = false');
        final customX = _bool(panel['custom_x_range']);
        final customY = _bool(panel['custom_y_range']);
        if (customX) out.writeln('custom_x_range = true');
        if (customY) out.writeln('custom_y_range = true');
        if (customX) {
          final min = _finiteNumber(panel['xmin']);
          final max = _finiteNumber(panel['xmax']);
          if (min != null) out.writeln('xmin = $min');
          if (max != null) out.writeln('xmax = $max');
        }
        if (customY) {
          final min = _finiteNumber(panel['ymin']);
          final max = _finiteNumber(panel['ymax']);
          if (min != null) out.writeln('ymin = $min');
          if (max != null) out.writeln('ymax = $max');
        }
        out.writeln();

        final panelShot = _text(panel['shot']).trim();
        final signals = _signals(panel);
        for (var signalIndex = 0; signalIndex < signals.length; signalIndex++) {
          final signal = signals[signalIndex];
          final signalShot = _text(signal['shot']).trim();
          final resolvedShot = signalShot.isNotEmpty
              ? signalShot
              : panelShot.isNotEmpty
                  ? panelShot
                  : defaultShot;
          out
            ..writeln('[[panels.signals]]')
            ..writeln('shot = ${_tomlString(resolvedShot)}')
            ..writeln('tree = ${_tomlString(signal['experiment'])}')
            ..writeln('server = ${_tomlString(signal['server_ip'])}')
            ..writeln('y = ${_tomlString(signal['y_expr'])}')
            ..writeln('x = ${_tomlString(signal['x_expr'])}')
            ..writeln('legend = ${_tomlString(signal['legend'])}')
            ..writeln('color = ${_tomlString(signal['color_name'])}')
            ..writeln('manual_color = ${_bool(signal['manual_color'])}')
            ..writeln('hidden = ${_hideMode(signal) != 'visible'}')
            ..writeln('hide_mode = ${_tomlString(_hideMode(signal))}')
            ..writeln('read_mode = ${_tomlString(_readMode(signal))}')
            ..writeln();
        }
      }
    }
    return out.toString();
  }

  static String _webscp(Map<String, dynamic> config) {
    final columns = _columns(config);
    final defaultShot = _defaultShot(config, columns);
    final out = StringBuffer()
      ..writeln(
        'Title_Font: java.awt.Font[family=Times New Roman,name=Times New Roman,style=plain,size=16]',
      )
      ..writeln(
        'Measurement_Units: java.awt.Font[family=Times New Roman,name=Times New Roman,style=plain,size=14]',
      )
      ..writeln(
        'Coordinate_Axis: java.awt.Font[family=Times New Roman,name=Times New Roman,style=plain,size=12]',
      )
      ..write('Grid_Mode:1\nX_Lines:5\nY_Lines:5\nExtraction_points:2000\n')
      ..write('Vertical_offset:0\nHorizontal_offset:0\n')
      ..writeln('shot_txt:${_lineValue(defaultShot)}')
      ..writeln('cols:${columns.isEmpty ? 1 : columns.length}');

    for (var c = 0; c < columns.length; c++) {
      final column = columns[c];
      out.writeln('${c + 1}.rows:${column.length}');
      for (var r = 0; r < column.length; r++) {
        final panel = column[r];
        final prefix = '${c + 1}_${r + 1}.';
        final panelShot = _text(panel['shot']).trim().isEmpty
            ? defaultShot
            : _text(panel['shot']).trim();
        final signals = _signals(panel);
        final customX = _bool(panel['custom_x_range']);
        final customY = _bool(panel['custom_y_range']);
        String range(String key, bool enabled) =>
            enabled && _finiteNumber(panel[key]) != null
                ? '${_finiteNumber(panel[key])}'
                : '';
        out
          ..writeln('${prefix}shot_txt:${_lineValue(panelShot)}')
          ..writeln('${prefix}num_shot:1')
          ..writeln('${prefix}num_sig:${signals.length}')
          ..writeln('${prefix}title_position:0')
          ..writeln('${prefix}y_log:0')
          ..writeln('${prefix}legend:1')
          ..writeln('${prefix}legend_position:')
          ..writeln('${prefix}xseting_mode:${customX ? 0 : 1}')
          ..writeln('${prefix}yseting_mode:${customY ? 0 : 1}')
          ..writeln('${prefix}x_line_num:5')
          ..writeln('${prefix}y_line_num:5')
          ..writeln(
            '${prefix}extraction_points:${_int(panel['extraction_points'], 2000).clamp(2, 1 << 31)}',
          )
          ..writeln('${prefix}vertical_offset:0')
          ..writeln('${prefix}horizontal_offset:0')
          ..writeln('${prefix}grid_mode:${_bool(panel['grid'], true) ? 1 : 0}')
          ..writeln('${prefix}xmin_custom:${range('xmin', customX)}')
          ..writeln('${prefix}xmax_custom:${range('xmax', customX)}')
          ..writeln('${prefix}ymin_custom:${range('ymin', customY)}')
          ..writeln('${prefix}ymax_custom:${range('ymax', customY)}')
          ..writeln('${prefix}title:${_lineValue(panel['title'])}')
          ..writeln('${prefix}xlabel:${_lineValue(panel['x_label'])}')
          ..writeln('${prefix}ylabel:${_lineValue(panel['y_label'])}');
        for (var s = 0; s < signals.length; s++) {
          final signal = signals[s];
          final number = s + 1;
          final shot = _text(signal['shot']).trim().isEmpty
              ? panelShot
              : _text(signal['shot']).trim();
          final hideMode = _hideMode(signal);
          out
            ..writeln('${prefix}shot_$number:${_lineValue(shot)}')
            ..writeln('${prefix}color_${r + 1}_$number:${s % 16}')
            ..writeln('${prefix}markers_${r + 1}_$number:0')
            ..writeln('${prefix}interpolate_${r + 1}_$number:1')
            ..writeln(
              '${prefix}y_expr_$number:${_lineValue(signal['y_expr'])}',
            )
            ..writeln(
              '${prefix}x_expr_$number:${_lineValue(signal['x_expr'])}',
            )
            ..writeln(
              '${prefix}experiment_$number:${_lineValue(signal['experiment'])}',
            )
            ..writeln(
              '${prefix}server_ip_$number:${_lineValue(signal['server_ip'])}',
            )
            ..writeln(
              '${prefix}legend_name_$number:${_lineValue(signal['legend'])}',
            )
            ..writeln(
              '${prefix}color_name_$number:${_lineValue(signal['color_name'])}',
            )
            ..writeln(
              '${prefix}color_manual_$number:${_bool(signal['manual_color']) ? 1 : 0}',
            )
            ..writeln(
                '${prefix}hidden_$number:${hideMode == 'visible' ? 0 : 1}')
            ..writeln('${prefix}hide_mode_$number:$hideMode')
            ..writeln('${prefix}read_mode_$number:${_readMode(signal)}');
        }
      }
    }
    return out.toString();
  }
}
