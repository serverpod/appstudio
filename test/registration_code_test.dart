import 'package:appstudio/process/registration_code.dart';
import 'package:appstudio/process/serverpod_process.dart';
import 'package:appstudio/session/project_session.dart';
import 'package:appstudio/terminal/studio_terminal.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/toolchain_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseRegistrationCode', () {
    test('reads the code the server console prints', () {
      expect(
        parseRegistrationCode(
          'Registration code for viktor@serverpod.dev: <48775957>',
        ),
        '48775957',
      );
    });

    test('tolerates a log prefix and missing angle brackets', () {
      expect(
        parseRegistrationCode(
          '2026-07-30 12:00:01 INFO Registration code for a@b.se: 4ABC-1234',
        ),
        '4ABC-1234',
      );
    });

    test('ignores unrelated lines', () {
      expect(parseRegistrationCode('Connecting to Example app VM service'), null);
      expect(parseRegistrationCode('Registration code'), null);
      expect(parseRegistrationCode(''), null);
    });
  });

  group('ServerpodProcessController', () {
    late ServerpodProcessController process;

    setUp(() async {
      process = ServerpodProcessController(
        toolchains: await emptyToolchainController(),
        session: ProjectSession(),
        terminal: StudioTerminal(),
      );
    });

    tearDown(() => process.dispose());

    test('picks up a code split across PTY chunks', () {
      expect(process.registrationCode, null);

      process.ingestOutput('Registration code for vikt');
      // Still mid-line: nothing to show yet.
      expect(process.registrationCode, null);

      process.ingestOutput('or@serverpod.dev: <48775957>\r\n');
      expect(process.registrationCode, '48775957');
    });

    test('strips ANSI colouring around the line', () {
      process.ingestOutput(
        '\x1B[32mRegistration code for a@b.se: <11223344>\x1B[0m\r\n',
      );

      expect(process.registrationCode, '11223344');
    });

    test('a newer code replaces the previous one', () {
      process.ingestOutput('Registration code for a@b.se: <11111111>\r\n');
      process.ingestOutput('Registration code for c@d.se: <22222222>\r\n');

      expect(process.registrationCode, '22222222');
    });

    test('dismissing clears it and notifies once', () {
      var notifications = 0;
      process.addListener(() => notifications++);

      process.ingestOutput('Registration code for a@b.se: <11111111>\r\n');
      expect(notifications, 1);

      process.dismissRegistrationCode();
      expect(process.registrationCode, null);
      expect(notifications, 2);

      // Already clear: no further churn.
      process.dismissRegistrationCode();
      expect(notifications, 2);
    });

    test('an unterminated line does not grow without bound', () {
      process.ingestOutput('x' * 20000);
      process.ingestOutput('Registration code for a@b.se: <33334444>\r\n');

      expect(process.registrationCode, '33334444');
    });
  });
}
