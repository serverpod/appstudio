import 'package:appstudio/platform/afunix_settle.dart';
import 'package:flutter_test/flutter_test.dart';

/// For test files that open AF_UNIX sockets: once every test has closed its
/// own, gives Windows time to close them in the kernel before `flutter test`
/// ends the test process. A process ending with one still connected can stop
/// Windows (afunix.sys); see `lib/platform/afunix_settle.dart`.
void settleAfUnixSocketsAfterAll() => tearDownAll(
      () => settleAfUnixSockets(settle: const Duration(seconds: 1)),
    );
