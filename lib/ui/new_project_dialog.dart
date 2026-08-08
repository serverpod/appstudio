import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shad/shad.dart';

import '../process/project_creator.dart';
import '../session/project_session.dart';
import '../theme/app_theme.dart';
import '../toolchain/toolchain_controller.dart';
import '../util/pretty_path.dart';
import '../widgets/error_banner.dart';
import '../widgets/field_label.dart';

const _kDialogWidth = 460.0;

Future<void> showNewProjectDialog(
  BuildContext context, {
  required ToolchainController toolchains,
  required ProjectSession session,
}) {
  return showShadDialog<void>(
    context: context,
    builder: (context) =>
        NewProjectDialog(toolchains: toolchains, session: session),
  );
}

/// Collects a project name + location, runs `serverpod create`, then opens the
/// new project.
class NewProjectDialog extends StatefulWidget {
  const NewProjectDialog({
    super.key,
    required this.toolchains,
    required this.session,
  });

  final ToolchainController toolchains;
  final ProjectSession session;

  @override
  State<NewProjectDialog> createState() => _NewProjectDialogState();
}

class _NewProjectDialogState extends State<NewProjectDialog> {
  final _nameController = TextEditingController();
  late String _directory = widget.session.suggestedNewProjectDirectory;

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
  }

  @override
  void dispose() {
    _nameController.removeListener(_onNameChanged);
    _nameController.dispose();
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

  bool get _canCreate => !_creating && _name.isNotEmpty && _nameError == null;

  Future<void> _chooseDirectory() async {
    final path = await getDirectoryPath(
      confirmButtonText: 'Choose',
      initialDirectory: Directory(_directory).existsSync() ? _directory : null,
    );
    if (path == null || !mounted) return;
    setState(() {
      _directory = p.normalize(path);
      _error = null;
      _errorLog = null;
    });
  }

  Future<void> _create() async {
    if (!_canCreate) return;
    final name = _name;
    setState(() {
      _creating = true;
      _status = 'Starting Serverpod CLI…';
      _error = null;
      _errorLog = null;
      _createdPath = null;
    });

    try {
      final path = await ProjectCreator(toolchains: widget.toolchains).create(
        name: name,
        parentDirectory: _directory,
        onStatus: (status) {
          if (mounted) setState(() => _status = status);
        },
      );
      await widget.session.setNewProjectDirectory(_directory);
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
    widget.session.openPath(path);
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return PopScope(
      canPop: !_creating,
      child: ShadDialog(
        title: const Text('New Project'),
        description: const Text(
          'Creates a Serverpod project with the bundled CLI and opens it.',
        ),
        // No way out mid-run — the CLI keeps writing files either way.
        closeIcon: _creating ? const SizedBox.shrink() : null,
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
    return [
      ShadButton.outline(
        enabled: !_creating,
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      ShadButton(
        enabled: _canCreate,
        onPressed: _create,
        child: Text(_creating ? 'Creating…' : 'Create Project'),
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
        const SizedBox(height: 6),
        Text(
          nameError ??
              'Names the project folder and its Dart packages, e.g. my_app.',
          style: textTheme.muted.copyWith(
            fontSize: 11,
            color: nameError != null ? scheme.destructive : null,
          ),
        ),
        const SizedBox(height: 16),
        FieldLabel('Location'),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(child: _PathField(path: _directory)),
            const SizedBox(width: 8),
            ShadButton.outline(
              onPressed: _chooseDirectory,
              child: const Text('Choose…'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text.rich(
          TextSpan(
            children: [
              const TextSpan(text: 'Creates '),
              TextSpan(
                text: prettyPath(
                  p.join(_directory, _name.isEmpty ? '…' : _name),
                ),
                style: TextStyle(
                  fontFamily: kMacMonoFont,
                  color: scheme.foreground.withValues(alpha: 0.75),
                ),
              ),
            ],
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: textTheme.muted.copyWith(fontSize: 11),
        ),
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

/// Read-only folder display matching the height and chrome of [ShadInput].
class _PathField extends StatelessWidget {
  const _PathField({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: scheme.muted.withValues(alpha: 0.45),
        borderRadius: theme.radii.sm,
        border: Border.all(color: scheme.border),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.folder, size: 14, color: scheme.mutedForeground),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              prettyPath(path),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.small.copyWith(
                fontFamily: kMacMonoFont,
                fontSize: 11.5,
              ),
            ),
          ),
        ],
      ),
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
