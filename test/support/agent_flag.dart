import 'package:appstudio/feature_flags.dart';

/// `skip:` values for tests that only mean something in one state of
/// [kOpenCodeAgentEnabled].
///
/// Skipped rather than deleted: the agent's code is still in the tree and comes
/// back with the flag, so the tests covering it have to come back too. Plain
/// bools rather than reason strings because `testWidgets` takes `bool?` where
/// `test` takes anything.

/// Skip a test that needs the agent switched on.
const bool skipWhenAgentOff = !kOpenCodeAgentEnabled;

/// Skip a test that pins how the app behaves with the agent switched off.
const bool skipWhenAgentOn = kOpenCodeAgentEnabled;
