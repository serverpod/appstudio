import 'package:appstudio/process/registration_code.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads each code the email provider logs in development', () {
    // As `ServerpodCloudEmailIdpConfig` logs them in 4.1.0.
    expect(
      parseRegistrationCode('Registration code for a@b.se: <48775957>'),
      '48775957',
    );
    expect(
      parseRegistrationCode('Password reset code for a@b.se: <12345678>'),
      '12345678',
    );
    expect(
      parseRegistrationCode('Login code for viktor@serverpod.dev: <533296>'),
      '533296',
    );
  });

  test('ignores other lines that mention a code', () {
    expect(
      parseRegistrationCode(
        'Failed to exchange authorization code for access token: 400',
      ),
      isNull,
    );
    expect(parseRegistrationCode('emailIdp.startOtpLogin queries=8'), isNull);
  });
}
