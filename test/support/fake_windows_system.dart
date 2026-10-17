import 'package:appstudio/platform/windows/windows_system.dart';

/// An in-memory registry and a scripted UAC prompt, so no test reads or
/// writes the real registry or raises a prompt.
class FakeWindowsSystem implements WindowsSystem {
  FakeWindowsSystem({
    Map<String, Object> values = const {},
    this.onElevated,
  }) : values = {...values};

  /// `'HKLM\key\name'` / `'HKCU\key\name'` → an `int` (DWORD) or a `String`.
  final Map<String, Object> values;

  /// What the elevated program does when the user approves the prompt; null
  /// stands for the prompt being declined.
  final int? Function(FakeWindowsSystem system, String executable,
      String parameters)? onElevated;

  final elevated = <String>[];
  var broadcasts = 0;

  static String keyFor(RegistryRoot root, String key, String name) =>
      '${root == RegistryRoot.localMachine ? 'HKLM' : 'HKCU'}\\$key\\$name';

  @override
  int? readDword(RegistryRoot root, String key, String name) =>
      switch (values[keyFor(root, key, name)]) { final int v => v, _ => null };

  @override
  String? readRawString(RegistryRoot root, String key, String name) =>
      switch (values[keyFor(root, key, name)]) {
        final String v => v,
        _ => null,
      };

  /// Expands `%USERPROFILE%` only, which is all the tests write.
  @override
  String? readExpandedString(RegistryRoot root, String key, String name) =>
      readRawString(root, key, name)
          ?.replaceAll('%USERPROFILE%', r'C:\Users\alex');

  @override
  bool writeUserExpandString(String key, String name, String data) {
    values[keyFor(RegistryRoot.currentUser, key, name)] = data;
    return true;
  }

  @override
  void broadcastEnvironmentChange() => broadcasts++;

  @override
  Future<int?> runElevated(String executable, String parameters) async {
    elevated.add('$executable $parameters');
    return onElevated?.call(this, executable, parameters);
  }

  /// Developer Mode, as the elevated `reg add` would set it.
  void setDeveloperMode(bool on) => values[keyFor(
      RegistryRoot.localMachine, kAppModelUnlockKey, kDeveloperModeValue)] =
      on ? 1 : 0;
}
