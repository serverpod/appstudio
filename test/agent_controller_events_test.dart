import 'package:appstudio/agent/agent_controller.dart';
import 'package:appstudio/agent/agent_transcript.dart';
import 'package:appstudio/process/serverpod_process.dart';
import 'package:appstudio/session/project_session.dart';
import 'package:appstudio/terminal/studio_terminal.dart';
import 'package:appstudio/toolchain/toolchain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Event payloads mirror the shapes in `opencode serve`'s OpenAPI document
/// (`GET /doc`) for the bundled CLI version.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AgentController controller;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final toolchain = await Toolchain.resolve();
    final session = ProjectSession();
    final process = ServerpodProcessController(
      toolchain: toolchain,
      session: session,
      terminal: StudioTerminal(),
    );
    controller = AgentController(
      toolchain: toolchain,
      session: session,
      process: process,
    );
    // Let the initial teardown settle before injecting events.
    await pumpEventQueue();
  });

  tearDown(() => controller.dispose());

  void assistantMessage(String id) {
    controller.handleEvent({
      'type': 'message.updated',
      'properties': {
        'info': {'id': id, 'role': 'assistant', 'sessionID': 'ses_1'},
      },
    });
  }

  void toolPart({
    required String messageId,
    required String partId,
    required String callId,
    required String tool,
  }) {
    controller.handleEvent({
      'type': 'message.part.updated',
      'properties': {
        'sessionID': 'ses_1',
        'part': {
          'id': partId,
          'sessionID': 'ses_1',
          'messageID': messageId,
          'type': 'tool',
          'callID': callId,
          'tool': tool,
          'state': {'status': 'running', 'input': <String, dynamic>{}},
        },
      },
    });
  }

  List<AgentPart> partsOf(String messageId) =>
      controller.messages.firstWhere((m) => m.id == messageId).parts;

  group('permission.asked', () {
    void ask({List<String> always = const []}) {
      assistantMessage('msg_1');
      toolPart(
        messageId: 'msg_1',
        partId: 'prt_1',
        callId: 'call_1',
        tool: 'read',
      );
      controller.handleEvent({
        'type': 'permission.asked',
        'properties': {
          'id': 'per_1',
          'sessionID': 'ses_1',
          'permission': 'read',
          'patterns': ['/Users/someone/other-project/**'],
          'metadata': <String, dynamic>{},
          'always': always,
          'tool': {'messageID': 'msg_1', 'callID': 'call_1'},
        },
      });
    }

    test('adds a card next to the tool call that triggered it', () {
      ask();

      final parts = partsOf('msg_1');
      expect(parts, hasLength(2));
      expect(parts.first, isA<AgentToolPart>());

      final permission = parts.last as AgentPermissionPart;
      expect(permission.permissionId, 'per_1');
      expect(permission.title, 'Read a file outside the project');
      expect(permission.details, ['/Users/someone/other-project/**']);
      expect(permission.canRemember, isFalse);
      expect(permission.resolved, isFalse);
      expect(controller.pendingPermissions, hasLength(1));

      // The tool row stays visible — it is the context for the request.
      expect((parts.first as AgentToolPart).hidden, isFalse);
    });

    test('offers "always" only when the server saved a rule for it', () {
      ask(always: ['read:/Users/someone/other-project/**']);

      expect((partsOf('msg_1').last as AgentPermissionPart).canRemember, isTrue);
    });

    test('is ignored when the same permission is asked twice', () {
      ask();
      ask();

      expect(controller.pendingPermissions, hasLength(1));
    });

    test('permission.replied resolves the card', () {
      ask();
      controller.handleEvent({
        'type': 'permission.replied',
        'properties': {
          'sessionID': 'ses_1',
          'requestID': 'per_1',
          'reply': 'always',
        },
      });

      final permission = partsOf('msg_1').last as AgentPermissionPart;
      expect(permission.resolved, isTrue);
      expect(permission.reply, AgentPermissionReply.always);
      expect(controller.pendingPermissions, isEmpty);
    });
  });

  group('question.asked', () {
    void ask() {
      assistantMessage('msg_1');
      toolPart(
        messageId: 'msg_1',
        partId: 'prt_1',
        callId: 'call_1',
        tool: 'question',
      );
      controller.handleEvent({
        'type': 'question.asked',
        'properties': {
          'id': 'que_1',
          'sessionID': 'ses_1',
          'questions': [
            {
              'header': 'Database',
              'question': 'Which database should the project use?',
              'options': [
                {'label': 'Postgres', 'description': 'The Serverpod default'},
                {'label': 'SQLite', 'description': 'Local only'},
              ],
              'multiple': false,
              'custom': true,
            },
          ],
          'tool': {'messageID': 'msg_1', 'callID': 'call_1'},
        },
      });
    }

    test('parses the question and replaces the raw tool row', () {
      ask();

      final parts = partsOf('msg_1');
      expect(parts, hasLength(2));
      // The card carries the question, so the generic tool row is hidden.
      expect((parts.first as AgentToolPart).hidden, isTrue);

      final question = parts.last as AgentQuestionPart;
      expect(question.requestId, 'que_1');
      expect(question.questions, hasLength(1));
      expect(question.questions.single.header, 'Database');
      expect(
        question.questions.single.question,
        'Which database should the project use?',
      );
      expect(question.questions.single.custom, isTrue);
      expect(question.questions.single.multiple, isFalse);
      expect(
        question.questions.single.options.map((o) => o.label),
        ['Postgres', 'SQLite'],
      );
      expect(
        question.questions.single.options.first.description,
        'The Serverpod default',
      );
      expect(controller.pendingQuestions, hasLength(1));
    });

    test('a later tool update does not resurrect the hidden row', () {
      ask();
      toolPart(
        messageId: 'msg_1',
        partId: 'prt_1',
        callId: 'call_1',
        tool: 'question',
      );

      final tools = partsOf('msg_1').whereType<AgentToolPart>();
      expect(tools, hasLength(1));
      expect(tools.single.hidden, isTrue);
    });

    test('question.replied resolves the card', () {
      ask();
      controller.handleEvent({
        'type': 'question.replied',
        'properties': {
          'sessionID': 'ses_1',
          'requestID': 'que_1',
          'answers': [
            ['Postgres'],
          ],
        },
      });

      final question = partsOf('msg_1').last as AgentQuestionPart;
      expect(question.resolved, isTrue);
      expect(question.rejected, isFalse);
      expect(controller.pendingQuestions, isEmpty);
    });

    test('question.rejected marks the card skipped', () {
      ask();
      controller.handleEvent({
        'type': 'question.rejected',
        'properties': {'sessionID': 'ses_1', 'requestID': 'que_1'},
      });

      final question = partsOf('msg_1').last as AgentQuestionPart;
      expect(question.resolved, isTrue);
      expect(question.rejected, isTrue);
    });
  });

  group('streaming', () {
    test('message.part.delta appends to the streaming text part', () {
      assistantMessage('msg_1');
      controller.handleEvent({
        'type': 'message.part.updated',
        'properties': {
          'sessionID': 'ses_1',
          'part': {
            'id': 'prt_1',
            'sessionID': 'ses_1',
            'messageID': 'msg_1',
            'type': 'text',
            'text': 'Hello',
          },
        },
      });
      controller.handleEvent({
        'type': 'message.part.delta',
        'properties': {
          'sessionID': 'ses_1',
          'messageID': 'msg_1',
          'partID': 'prt_1',
          'field': 'text',
          'delta': ' there',
        },
      });

      expect((partsOf('msg_1').single as AgentTextPart).text, 'Hello there');
    });

    test('reasoning is kept apart from the answer text', () {
      assistantMessage('msg_1');
      controller.handleEvent({
        'type': 'message.part.updated',
        'properties': {
          'sessionID': 'ses_1',
          'part': {
            'id': 'prt_1',
            'sessionID': 'ses_1',
            'messageID': 'msg_1',
            'type': 'reasoning',
            'text': 'The user probably means…',
          },
        },
      });

      expect(partsOf('msg_1').single, isA<AgentReasoningPart>());
    });
  });
}
