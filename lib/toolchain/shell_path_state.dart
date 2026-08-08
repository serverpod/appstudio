/// Whether App Studio's `PATH` block is in the user's shell rc file.
///
/// Its own file, free of `dart:io`, because the tools UI renders this state and
/// must stay compilable for the widget preview environment — which builds for
/// web, where the rc-file editing in `shell_path_integration.dart` cannot go.
enum ShellPathState { absent, present, edited, unsupported }
