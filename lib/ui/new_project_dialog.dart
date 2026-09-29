import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shad/shad.dart';

import '../process/new_project_view.dart';
import '../process/project_creator.dart';
import '../session/project_session.dart';
import '../theme/app_theme.dart';
import '../toolchain/toolchain_controller.dart';
import '../util/pretty_path.dart';
import '../widgets/error_banner.dart';
import '../widgets/field_label.dart';
import 'landing_scaffold.dart';

const _kDialogWidth = 460.0;

/// Pushes the Create Project screen. Completes when it is left, whether the
/// project was created or cancelled.
///
/// A route rather than a dialog: creating a project is the whole task for as
/// long as it lasts, there is nothing behind it worth reading through a
/// blurred barrier, and a stray click outside a form holding a typed name
/// should not throw it away. Cancel pops back to whatever opened it.
Future<void> showNewProjectScreen(
  BuildContext context, {
  required ToolchainController toolchains,
  required ProjectSession session,
}) {
  final actions = SessionNewProjectView(
    toolchains: toolchains,
    session: session,
  );
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      barrierDismissible: false,
      transitionDuration: const Duration(milliseconds: 150),
      reverseTransitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (context, _, _) => NewProjectScreen(actions: actions),
      transitionsBuilder: (context, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

/// The real [NewProjectView]: `serverpod create` through [ProjectCreator], and
/// the folder picker and remembered location through [ProjectSession].
class SessionNewProjectView implements NewProjectView {
  SessionNewProjectView({required this.toolchains, required this.session});

  final ToolchainController toolchains;
  final ProjectSession session;

  @override
  String get suggestedDirectory => session.suggestedNewProjectDirectory;

  @override
  Future<String?> pickDirectory(String current) => getDirectoryPath(
        confirmButtonText: 'Choose',
        initialDirectory: Directory(current).existsSync() ? current : null,
      );

  @override
  Future<String> create({
    required String name,
    required String parentDirectory,
    required Set<IdeIntegration> ides,
    void Function(String status)? onStatus,
  }) =>
      ProjectCreator(toolchains: toolchains).create(
        name: name,
        parentDirectory: parentDirectory,
        ides: ides,
        onStatus: onStatus,
      );

  @override
  Future<void> rememberDirectory(String path) =>
      session.setNewProjectDirectory(path);

  @override
  void openProject(String path) => session.openPath(path);
}

/// The Create Project form on the shared landing backdrop.
///
/// It uses [LandingScaffold] so arriving here from the start page reads as the
/// same app rather than a new one.
///
/// The form is put back on the *app's* theme, though. [LandingScaffold] gives
/// its child the landing theme, which is fixed dark because the gradient
/// behind it is — right for chrome sitting directly on that backdrop, wrong
/// for a surface with its own background, which would then be the one dark
/// panel in a light app. That is the same rule dialogs raised from the start
/// page already follow, by virtue of being routes that land outside the
/// scaffold.
class NewProjectScreen extends StatelessWidget {
  const NewProjectScreen({
    super.key,
    required this.actions,
    this.initialName = '',
    this.initialIde,
    this.createOnOpen = false,
  });

  final NewProjectView actions;

  /// Passed through to [NewProjectDialog].
  final String initialName;
  final IdeIntegration? initialIde;
  final bool createOnOpen;

  @override
  Widget build(BuildContext context) {
    // Read above the scaffold, which is where the app's theme still is.
    final appTheme = ShadTheme.of(context);

    return LandingScaffold(
      // Centre outside the scroll view, not inside it: a scroll view sized to
      // its viewport pins a short child to the top, and this one is short in
      // any window taller than the form.
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: ShadTheme(
            data: appTheme,
            child: NewProjectDialog(
              actions: actions,
              initialName: initialName,
              initialIde: initialIde,
              createOnOpen: createOnOpen,
            ),
          ),
        ),
      ),
    );
  }
}

/// Collects a project name + location, runs `serverpod create`, then opens the
/// new project.
class NewProjectDialog extends StatefulWidget {
  const NewProjectDialog({
    super.key,
    required this.actions,
    this.initialName = '',
    this.initialIde,
    this.createOnOpen = false,
  });

  final NewProjectView actions;

  /// Prefills the form. Widgetbook uses these, with [createOnOpen], to show
  /// each of the form's states on its own.
  final String initialName;
  final IdeIntegration? initialIde;

  /// Presses Create as soon as the form is up, so the progress and failure
  /// states can be looked at without anything to click. Ignored unless the
  /// prefill makes Create available.
  final bool createOnOpen;

  @override
  State<NewProjectDialog> createState() => _NewProjectDialogState();
}

class _NewProjectDialogState extends State<NewProjectDialog> {
  late final _nameController = TextEditingController(text: widget.initialName);
  late String _directory = widget.actions.suggestedDirectory;
  late final _directoryController = TextEditingController(
    text: prettyPath(_directory),
  );
  /// The one editor to configure. Picking one is mandatory, so this is null
  /// only until the user has answered — which is what holds Create disabled.
  late IdeIntegration? _ide = widget.initialIde;

  bool _creating = false;
  String? _status;
  String? _error;
  String? _errorLog;

  /// Set when the project reached disk but could not be fully configured.
  String? _createdPath;

  @override
  void initState() {
    super.initState();
    _nameController.addListener(_onNameChanged);
    if (widget.createOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _create();
      });
    }
  }

  @override
  void dispose() {
    _nameController.removeListener(_onNameChanged);
    _nameController.dispose();
    _directoryController.dispose();
    super.dispose();
  }

  void _onNameChanged() {
    if (_error != null || _createdPath != null) {
      setState(() {
        _error = null;
        _errorLog = null;
        _createdPath = null;
      });
    } else {
      setState(() {});
    }
  }

  String get _name => _nameController.text.trim();

  String? get _nameError => validateProjectName(_name);

  /// Create waits on the editor as well as the name. Picking one is mandatory,
  /// and a disabled button beside an unanswered question is a clearer way to
  /// say so than a prompt raised after the fact.
  bool get _canCreate =>
      !_creating && _name.isNotEmpty && _nameError == null && _ide != null;

  Future<void> _chooseDirectory() async {
    final path = await widget.actions.pickDirectory(_directory);
    if (path == null || !mounted) return;
    setState(() {
      _directory = p.normalize(path);
      _directoryController.text = prettyPath(_directory);
      _error = null;
      _errorLog = null;
    });
  }

  Future<void> _create() async {
    if (!_canCreate) return;
    final name = _name;
    final ide = _ide!;
    setState(() {
      _creating = true;
      _status = 'Starting Serverpod CLI…';
      _error = null;
      _errorLog = null;
      _createdPath = null;
    });

    try {
      final path = await widget.actions.create(
        name: name,
        parentDirectory: _directory,
        ides: {ide},
        onStatus: (status) {
          if (mounted) setState(() => _status = status);
        },
      );
      await widget.actions.rememberDirectory(_directory);
      _openProject(path);
    } on ProjectCreationException catch (e) {
      if (!mounted) return;
      setState(() {
        _creating = false;
        _status = null;
        _error = e.message;
        _errorLog = e.log;
        _createdPath = e.createdPath;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _creating = false;
        _status = null;
        _error = '$e';
      });
    }
  }

  void _openProject(String path) {
    if (!mounted) return;
    Navigator.of(context).pop();
    widget.actions.openProject(path);
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return PopScope(
      canPop: !_creating,
      // `alert` is the variant without a close X — Cancel is the way out, and
      // mid-run there is none, since the CLI keeps writing files either way.
      child: ShadDialog.alert(
        title: const Text('Create Project'),
        actions: _buildActions(),
        child: SizedBox(
          width: _kDialogWidth,
          child: _creating ? _buildProgress(theme) : _buildForm(theme),
        ),
      ),
    );
  }

  List<Widget> _buildActions() {
    if (_createdPath != null) {
      return [
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        ShadButton(
          onPressed: () => _openProject(_createdPath!),
          child: const Text('Open Anyway'),
        ),
      ];
    }
    // Mid-run there is nothing to press — Cancel cannot stop the CLI and
    // Create already ran — so the row disappears instead of dimming.
    if (_creating) return const [];
    return [
      ShadButton.outline(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      ShadButton(
        enabled: _canCreate,
        onPressed: _create,
        child: const Text('Create'),
      ),
    ];
  }

  Widget _buildForm(ShadThemeData theme) {
    final scheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final nameError = _name.isEmpty ? null : _nameError;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        if (_error != null) ...[
          ErrorBanner(message: _error!, log: _errorLog),
          const SizedBox(height: 16),
        ],
        FieldLabel('Project name'),
        const SizedBox(height: 6),
        ShadInput(
          controller: _nameController,
          placeholder: const Text('my_app'),
          autofocus: true,
          keyboardType: TextInputType.text,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9_]')),
            _LowerCaseFormatter(),
          ],
          onSubmitted: (_) => _create(),
        ),
        // The error takes the space rather than being given a slot of its
        // own that is empty most of the time — an always-drawn line is most
        // of the gap down to Location. The cost is that the form grows by a
        // line when a name stops being a legal Dart package name.
        if (nameError != null) ...[
          const SizedBox(height: 4),
          Text(
            nameError,
            style: textTheme.muted.copyWith(
              fontSize: 11,
              color: scheme.destructive,
            ),
          ),
          const SizedBox(height: 6),
        ] else
          const SizedBox(height: 12),
        FieldLabel('Location'),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ShadInput(
                controller: _directoryController,
                enabled: false,
                leading: Icon(
                  LucideIcons.folder,
                  size: 14,
                  color: scheme.mutedForeground,
                ),
                style: textTheme.small.copyWith(
                  fontFamily: kMacMonoFont,
                  fontSize: 11.5,
                ),
              ),
            ),
            const SizedBox(width: 8),
            ShadButton.outline(
              onPressed: _chooseDirectory,
              child: const Text('Choose…'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        FieldLabel('External AI editor'),
        const SizedBox(height: 6),
        Text(
          'Installs agent skills and MCP servers for the editor you pick.',
          style: textTheme.muted.copyWith(fontSize: 11),
        ),
        const SizedBox(height: 12),
        _IdeRadios(
          selected: _ide,
          onChanged: (ide) => setState(() => _ide = ide),
        ),
        // The dialog's own gap alone leaves the last row of options sitting on
        // top of the buttons.
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildProgress(ShadThemeData theme) {
    final textTheme = theme.textTheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Text('Creating $_name', style: textTheme.small.semibold),
        const SizedBox(height: 6),
        Text(
          _status ?? 'Working…',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: textTheme.muted.copyWith(fontSize: 11),
        ),
        const SizedBox(height: 14),
        const ShadProgress(value: null, minHeight: 3),
        const SizedBox(height: 14),
        Text(
          'Fetching dependencies and generating code can take a minute.',
          style: textTheme.muted.copyWith(fontSize: 11),
        ),
      ],
    );
  }
}

/// Editor radios, three to a row — one per line would make this section taller
/// than the two fields above it put together.
///
/// Radios rather than checkboxes because exactly one editor is configured, and
/// picking one is required. It used to be a set of opt-ins that could all be
/// left clear, which needed a prompt after the fact to ask whether that was
/// really meant; a control that cannot express the empty answer says the same
/// thing up front.
class _IdeRadios extends StatelessWidget {
  const _IdeRadios({required this.selected, required this.onChanged});

  final IdeIntegration? selected;
  final ValueChanged<IdeIntegration?> onChanged;

  @override
  Widget build(BuildContext context) {
    const columns = 3;
    const spacing = 8.0;
    final width = (_kDialogWidth - spacing * (columns - 1)) / columns;

    return ShadRadioGroup<IdeIntegration>(
      // Horizontal, so the group's own Wrap does the same job the checkboxes'
      // did; the fixed width per item is what keeps the columns lined up.
      axis: Axis.horizontal,
      spacing: spacing,
      runSpacing: spacing,
      initialValue: selected,
      onChanged: onChanged,
      items: [
        for (final ide in IdeIntegration.values)
          SizedBox(
            width: width,
            child: ShadRadio<IdeIntegration>(
              value: ide,
              label: Text(ide.label),
            ),
          ),
      ],
    );
  }
}

/// Serverpod project names are lowercase — fold as the user types instead of
/// rejecting the keystroke.
class _LowerCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final lower = newValue.text.toLowerCase();
    if (lower == newValue.text) return newValue;
    return newValue.copyWith(text: lower);
  }
}
