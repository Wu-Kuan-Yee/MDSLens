import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mdsscope/services/stylus_mode_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Native stylus mode changes are delivered to Dart', () async {
    const channel = MethodChannel('mdsscope/stylus');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(StylusModeChannel.dispose);

    bool? eraser;
    StylusModeChannel.init((value) => eraser = value);
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('stylusModeChanged', true),
      ),
      (_) {},
    );

    expect(eraser, isTrue);
  });
}
