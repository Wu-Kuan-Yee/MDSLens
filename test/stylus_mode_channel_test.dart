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
    var nativeModeRequested = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getMode');
      nativeModeRequested = true;
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    bool? eraser;
    StylusModeChannel.init((value) => eraser = value);
    await TestAsyncUtils.guard(() async {
      await Future<void>.delayed(Duration.zero);
    });
    expect(nativeModeRequested, isTrue);
    expect(eraser, isTrue);

    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('stylusModeChanged', false),
      ),
      (_) {},
    );

    expect(eraser, isFalse);
  });
}
