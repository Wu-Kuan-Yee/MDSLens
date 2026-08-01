import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mdslens/services/update_health.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('health signal writes the updater nonce', () async {
    final directory = await Directory.systemTemp.createTemp(
      'mdslens-update-health-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final marker = File('${directory.path}/health');

    await acknowledgeUpdateHealth([
      '--mdslens-update-health=${marker.path}',
      '--mdslens-update-token=nonce-123',
    ]);

    expect(await marker.readAsString(), 'nonce-123\n');
  });

  test('health signal does not follow a symlink', () async {
    final directory = await Directory.systemTemp.createTemp(
      'mdslens-update-health-link-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final target = File('${directory.path}/target');
    await target.writeAsString('untouched');
    final marker = File('${directory.path}/health');
    await Link(marker.path).create(target.path);

    await acknowledgeUpdateHealth([
      '--mdslens-update-health=${marker.path}',
      '--mdslens-update-token=nonce-123',
    ]);

    expect(await target.readAsString(), 'untouched');
  });

  test('commit signal writes the updater nonce', () async {
    final directory = await Directory.systemTemp.createTemp(
      'mdslens-update-commit-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final marker = File('${directory.path}/commit');

    await acknowledgeUpdateCommit([
      '--mdslens-update-commit=${marker.path}',
      '--mdslens-update-token=nonce-456',
    ]);

    expect(await marker.readAsString(), 'nonce-456\n');
  });
}
