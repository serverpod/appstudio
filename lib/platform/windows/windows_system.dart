/// The few Windows facilities the toolchain needs: the registry (Developer
/// Mode, the user and machine `Path`), the environment-change broadcast, and
/// the UAC prompt.
///
/// An interface so the probe and the installer can be tested with a fake on
/// any machine — no test reads or writes the real registry or raises a UAC
/// prompt. `Win32System` (`win32_system.dart`) is the real one.
library;

enum RegistryRoot { currentUser, localMachine }

/// Where Windows keeps the user's own environment variables.
const kUserEnvironmentKey = r'Environment';

/// Where Windows keeps the machine-wide ones.
const kMachineEnvironmentKey =
    r'SYSTEM\CurrentControlSet\Control\Session Manager\Environment';

/// Developer Mode: `AllowDevelopmentWithoutDevLicense` = 1.
const kAppModelUnlockKey =
    r'SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock';
const kDeveloperModeValue = 'AllowDevelopmentWithoutDevLicense';

/// Group Policy's copy of the same switch. When set it wins over the one
/// above, and only an administrator of the policy can change it.
const kAppxPolicyKey = r'SOFTWARE\Policies\Microsoft\Windows\Appx';

abstract interface class WindowsSystem {
  /// A `REG_DWORD`, or null when the value is missing.
  int? readDword(RegistryRoot root, String key, String name);

  /// A string value as stored — a `REG_EXPAND_SZ` keeps its `%VARIABLES%`.
  String? readRawString(RegistryRoot root, String key, String name);

  /// A string value with its `%VARIABLES%` expanded, as a process sees it.
  String? readExpandedString(RegistryRoot root, String key, String name);

  /// Writes a `REG_EXPAND_SZ` under the current user. Returns false on
  /// failure. Only [RegistryRoot.currentUser] is writable without elevation.
  bool writeUserExpandString(String key, String name, String data);

  /// Tells running programs (Explorer, new terminals) that the environment
  /// changed, so a new window sees a `Path` written here.
  void broadcastEnvironmentChange();

  /// Runs [executable] with [parameters] as administrator — Windows raises its
  /// own UAC prompt — and waits for it. The exit code, or null when the prompt
  /// was declined or the program could not be started.
  Future<int?> runElevated(String executable, String parameters);

  /// Opens [target] — a URL, or a `scheme://` deep link — with whatever
  /// Windows has registered for it, as a double-click would. False when
  /// nothing could open it.
  bool shellOpen(String target);

  /// The name of the app registered for `scheme://` links, or null when none
  /// is. Covers Store (MSIX) apps, which register schemes outside the classic
  /// registry keys — on Windows an unregistered scheme raises a "choose an
  /// app" dialog, so this is the check before offering a deep link.
  String? protocolHandler(String scheme);
}

/// No registry, no prompt: every read finds nothing and every change fails.
/// What the probe and the installer use on other hosts, and in tests that do
/// not care about Windows.
class NoWindowsSystem implements WindowsSystem {
  const NoWindowsSystem();

  @override
  int? readDword(RegistryRoot root, String key, String name) => null;

  @override
  String? readRawString(RegistryRoot root, String key, String name) => null;

  @override
  String? readExpandedString(RegistryRoot root, String key, String name) =>
      null;

  @override
  bool writeUserExpandString(String key, String name, String data) => false;

  @override
  void broadcastEnvironmentChange() {}

  @override
  Future<int?> runElevated(String executable, String parameters) async => null;

  @override
  bool shellOpen(String target) => false;

  @override
  String? protocolHandler(String scheme) => null;
}

/// The `Path` a process started now would get: the machine's entries, then
/// the user's, both expanded — what Windows builds a new environment from.
///
/// The Windows counterpart of the login-shell `PATH` on macOS. A running App
/// Studio inherited Explorer's environment from whenever it started, so a tool
/// installed since — by the user, or by App Studio itself — is only visible
/// here. Null when neither value can be read.
String? registryPath(WindowsSystem windows) {
  final machine = windows.readExpandedString(
      RegistryRoot.localMachine, kMachineEnvironmentKey, 'Path');
  final user = windows.readExpandedString(
      RegistryRoot.currentUser, kUserEnvironmentKey, 'Path');
  final parts = [?machine, ?user].where((p) => p.isNotEmpty).toList();
  return parts.isEmpty ? null : parts.join(';');
}

/// Whether Developer Mode is on.
bool developerModeEnabled(WindowsSystem windows) =>
    windows.readDword(
        RegistryRoot.localMachine, kAppModelUnlockKey, kDeveloperModeValue) ==
    1;

/// Win32 long paths: `LongPathsEnabled` = 1 lifts the 260-character MAX_PATH
/// limit for programs that opt in, which Git, Dart and Flutter do.
const kFileSystemKey = r'SYSTEM\CurrentControlSet\Control\FileSystem';
const kLongPathsValue = 'LongPathsEnabled';

/// Whether long paths are on. Off is the Windows default, and deep pub cache,
/// build and CEF trees can then fail in ways that look unrelated.
bool longPathsEnabled(WindowsSystem windows) =>
    windows.readDword(RegistryRoot.localMachine, kFileSystemKey, kLongPathsValue) ==
    1;

/// Whether Group Policy has switched Developer Mode off, in which case only
/// the policy's administrator can turn it on.
bool developerModeLockedByPolicy(WindowsSystem windows) =>
    windows.readDword(
        RegistryRoot.localMachine, kAppxPolicyKey, kDeveloperModeValue) ==
    0;
