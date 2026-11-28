/// Linux's system packages: the command-line tools Flutter's own Linux
/// instructions list, which App Studio checks for and never installs itself.
/// It runs no `sudo` (specs/linux_port.md, L4): setup names what is missing
/// and gives this distro's command to install it.
///
/// Free of `dart:io` — the probe reads `/etc/os-release` and hands it in.
library;

/// The commands App Studio needs on `PATH`. Flutter runs on `git`, and its
/// tool downloads and unpacks with `curl`, `unzip` and `xz`; App Studio's own
/// Flutter install unpacks a `.tar.xz` too.
const kLinuxRequiredCommands = ['git', 'curl', 'unzip', 'xz'];

/// The package managers App Studio can write an install command for.
enum LinuxPackageManager {
  apt('sudo apt install'),
  pacman('sudo pacman -S --needed'),
  dnf('sudo dnf install'),
  zypper('sudo zypper install');

  const LinuxPackageManager(this.installPrefix);

  final String installPrefix;
}

/// The package manager of the distro `/etc/os-release` describes, from its
/// `ID` and then each `ID_LIKE` entry — Omarchy is `ID=omarchy`,
/// `ID_LIKE=arch`. Null for a distro none of them is known for.
LinuxPackageManager? packageManagerFor(String osRelease) {
  final fields = parseOsRelease(osRelease);
  final ids = [
    ?fields['ID'],
    ...?fields['ID_LIKE']?.split(RegExp(r'\s+')),
  ];
  for (final id in ids) {
    final manager = switch (id) {
      'debian' || 'ubuntu' => LinuxPackageManager.apt,
      'arch' => LinuxPackageManager.pacman,
      'fedora' || 'rhel' || 'centos' => LinuxPackageManager.dnf,
      'suse' || 'opensuse' || 'sles' => LinuxPackageManager.zypper,
      _ when id.startsWith('opensuse') => LinuxPackageManager.zypper,
      _ => null,
    };
    if (manager != null) return manager;
  }
  return null;
}

/// `KEY=value` lines, with the shell quoting os-release allows stripped.
Map<String, String> parseOsRelease(String contents) {
  final fields = <String, String>{};
  for (final line in contents.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final eq = trimmed.indexOf('=');
    if (eq <= 0) continue;
    var value = trimmed.substring(eq + 1);
    if (value.length >= 2 &&
        (value.startsWith('"') && value.endsWith('"') ||
            value.startsWith("'") && value.endsWith("'"))) {
      value = value.substring(1, value.length - 1);
    }
    fields[trimmed.substring(0, eq)] = value;
  }
  return fields;
}

/// The package that provides [command]. Only Debian and Ubuntu name one
/// differently: `xz` comes in `xz-utils`.
String linuxPackageFor(String command, LinuxPackageManager? manager) =>
    command == 'xz' && manager == LinuxPackageManager.apt ? 'xz-utils' : command;

/// The command that installs [missing] with [manager], or null when the
/// distro is not one App Studio knows — the caller then lists the packages.
String? linuxInstallCommand(
  List<String> missing,
  LinuxPackageManager? manager,
) {
  if (manager == null || missing.isEmpty) return null;
  final packages = [for (final c in missing) linuxPackageFor(c, manager)];
  return '${manager.installPrefix} ${packages.join(' ')}';
}
