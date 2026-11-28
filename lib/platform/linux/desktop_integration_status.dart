/// Where App Studio stands in the app menu on Linux.
///
/// In a file of its own, free of `dart:io`, so the menu strip can switch on
/// it without importing what reads the disk.
enum DesktopIntegrationStatus {
  /// Not running as an AppImage: a development build, a package, or another
  /// OS. There is nothing to add.
  unavailable,

  /// Already in the app menu through another tool — Gear Lever,
  /// AppImageLauncher, appimaged — or a package. Theirs to manage.
  managedByOther,

  /// App Studio added it: Remove from Applications undoes that.
  addedByAppStudio,

  /// Nobody added it yet: App Studio offers to.
  notAdded,
}
