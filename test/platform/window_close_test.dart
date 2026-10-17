import 'package:appstudio/platform/window_close.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Windows runner's lifecycle channel, driven as the runner drives it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(kWindowLifecycleChannel);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<void> call(String method) async {
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall(method)),
      (_) {},
    );
  }

  setUp(installWindowCloseHandler);
  tearDown(() => onWindowsEndSession = null);

  test('signing out runs the exit teardown, and the runner waits for it',
      () async {
    final finished = <String>[];
    onWindowsEndSession = () async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      finished.add('teardown');
    };

    await call('endSession');

    // The reply goes back only once the teardown is done: the runner holds
    // Windows off until then.
    expect(finished, ['teardown']);
  });

  test('signing out before the app is up is answered at once', () async {
    onWindowsEndSession = null;
    await call('endSession');
  });
}
