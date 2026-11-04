/// Serverpod logs a verification code to the server console instead of mailing
/// it in development, e.g.
///
/// ```
/// Registration code for viktor@serverpod.dev: <48775957>
/// Login code for viktor@serverpod.dev: <533296>
/// ```
///
/// One for each email it would have sent: signing up, a password reset, and
/// (from 4.1.0) a one-time login code. The angle brackets are optional so a
/// future log format without them still matches.
final _registrationCodeLine = RegExp(
  r'(?:registration|password\s+reset|login)\s+code\s+for\s+\S+\s*:\s*<?\s*'
  r'([A-Za-z0-9][A-Za-z0-9-]{3,})\s*>?',
  caseSensitive: false,
);

/// Returns the code from a server console [line], or null if it isn't one.
String? parseRegistrationCode(String line) {
  final match = _registrationCodeLine.firstMatch(line);
  return match?.group(1);
}
