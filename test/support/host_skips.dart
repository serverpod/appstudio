import 'dart:io';

/// True on a Windows host, for tests of behaviour that is still macOS-only
/// until a later phase of the Windows port gives it a Windows counterpart
/// (`specs/windows_port.md`). Each call site names the phase.
bool get macOSOnlyForNow => Platform.isWindows;
