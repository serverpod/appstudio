import 'package:appstudio/feature_flags.dart';

/// `skip:` values for tests that only mean something in one state of
/// [kServerpodMcpEnabled].
///
/// Skipped rather than deleted, for the same reason as the agent's: the bridge
/// and everything the button does with it are still in the tree and come back
/// with the flag, so their tests have to come back too. Plain bools because
/// `testWidgets` takes `bool?` where `test` takes anything.

/// Skip a test that needs the MCP bridge switched on.
const bool skipWhenMcpOff = !kServerpodMcpEnabled;

/// Skip a test that pins how the app behaves with the MCP bridge switched off.
const bool skipWhenMcpOn = kServerpodMcpEnabled;
