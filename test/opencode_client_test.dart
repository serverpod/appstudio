import 'dart:convert';

import 'package:appstudio/agent/opencode_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late List<http.Request> requests;
  late OpenCodeClient client;

  OpenCodeClient makeClient({int status = 200, String body = 'true'}) {
    requests = [];
    final mock = MockClient((request) async {
      requests.add(request);
      return http.Response(body, status);
    });
    return OpenCodeClient(httpClient: mock)
      ..attach(Uri.parse('http://127.0.0.1:4096'));
  }

  Map<String, dynamic> bodyOf(http.Request request) =>
      jsonDecode(request.body) as Map<String, dynamic>;

  group('replyPermission', () {
    test('posts the reply enum the server accepts', () async {
      client = makeClient();
      await client.replyPermission(permissionId: 'per_1', reply: 'once');

      expect(requests, hasLength(1));
      expect(requests.single.method, 'POST');
      expect(requests.single.url.path, '/permission/per_1/reply');
      // `allow`/`deny` are rejected with HTTP 400 and leave the agent blocked.
      expect(bodyOf(requests.single), {'reply': 'once'});
    });

    test('throws when the server rejects the reply', () async {
      client = makeClient(status: 400, body: '{"name":"BadRequest"}');

      expect(
        () => client.replyPermission(permissionId: 'per_1', reply: 'always'),
        throwsStateError,
      );
    });
  });

  group('questions', () {
    test('replyQuestion sends one answer list per question', () async {
      client = makeClient();
      await client.replyQuestion(
        requestId: 'que_1',
        answers: [
          ['Use Postgres'],
          ['Dark', 'Light'],
        ],
      );

      expect(requests.single.url.path, '/question/que_1/reply');
      expect(bodyOf(requests.single), {
        'answers': [
          ['Use Postgres'],
          ['Dark', 'Light'],
        ],
      });
    });

    test('rejectQuestion posts to the reject endpoint', () async {
      client = makeClient();
      await client.rejectQuestion('que_1');

      expect(requests.single.method, 'POST');
      expect(requests.single.url.path, '/question/que_1/reject');
    });
  });
}
