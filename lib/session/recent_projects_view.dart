/// What the start page needs from the session: the recents list, the last
/// error, and the three things it can do about them.
///
/// `ProjectSession` implements this directly. The page imports only this, so
/// it can be drawn — in Widgetbook, in a test — without a folder picker or
/// preferences behind it.
abstract interface class RecentProjectsView {
  /// Most recent first.
  List<String> get recents;

  /// Why the last open failed, or null.
  String? get error;

  Future<void> openProjectPicker();
  Future<void> openPath(String path);
  Future<void> clearRecents();
}
