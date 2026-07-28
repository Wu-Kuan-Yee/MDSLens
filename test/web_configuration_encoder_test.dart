import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mdslens/services/web_configuration_encoder.dart';

void main() {
  final configuration = jsonEncode({
    'shot': '163701',
    'columns': [
      [
        {
          'title': 'Plasma "current"',
          'x_label': 'time',
          'y_label': 'A',
          'extraction_points': 4096,
          'grid': false,
          'custom_x_range': true,
          'xmin': -1.0,
          'xmax': 8.0,
          'signal_specs': [
            {
              'shot': '163701',
              'experiment': 'pcs_east',
              'server_ip': '202.127.204.12',
              'y_expr': r'\pcrl01',
              'x_expr': '',
              'legend': 'Ip',
              'color_name': '#2364aa',
              'manual_color': true,
              'hide_mode': 2,
              'read_mode': 1,
            },
          ],
        },
      ],
    ],
  });

  test('encodes TOML locally without a gateway', () {
    final text = utf8.decode(
      WebConfigurationEncoder.encode(configuration, 'toml'),
    );
    expect(text, contains('shot = "163701"'));
    expect(text, contains(r'title = "Plasma \"current\""'));
    expect(text, contains('[[panels.signals]]'));
    expect(text, contains(r'y = "\\pcrl01"'));
    expect(text, contains('hide_mode = "persistent"'));
    expect(text, contains('read_mode = "medium"'));
  });

  test('encodes WebSCP locally without a gateway', () {
    final text = utf8.decode(
      WebConfigurationEncoder.encode(configuration, 'webscp'),
    );
    expect(text, contains('shot_txt:163701'));
    expect(text, contains('1.rows:1'));
    expect(text, contains(r'1_1.y_expr_1:\pcrl01'));
    expect(text, contains('1_1.hide_mode_1:persistent'));
    expect(text, contains('1_1.read_mode_1:medium'));
  });
}
