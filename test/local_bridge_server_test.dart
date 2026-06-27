import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zalo_account_workspace/src/services/local_bridge_server.dart';
import 'package:zalo_account_workspace/src/services/logging_service.dart';

Future<(int, Map<String, dynamic>, HttpHeaders)> _getJson(
  Uri uri, {
  String? origin,
}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    if (origin != null) {
      request.headers.set('Origin', origin);
    }
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    final decoded = body.isEmpty ? <String, dynamic>{} : jsonDecode(body);
    return (
      response.statusCode,
      decoded is Map<String, dynamic> ? decoded : <String, dynamic>{},
      response.headers,
    );
  } finally {
    client.close(force: true);
  }
}

void main() {
  test('health only exposes account list to trusted origins', () async {
    final server = LocalBridgeServer(LoggingService());
    await server.start(
      healthProvider:
          () => <String, Object?>{
            'accounts': <Map<String, Object?>>[
              <String, Object?>{'profileId': 'p1', 'displayName': 'Account A'},
            ],
          },
    );
    addTearDown(server.stop);

    final port = server.port!;
    final trusted = await _getJson(
      Uri.parse('http://127.0.0.1:$port/health'),
      origin: 'https://giaidoan1.chatplus.io.vn',
    );
    expect(trusted.$1, 200);
    expect(trusted.$2['accounts'], isA<List<dynamic>>());
    expect(
      trusted.$3.value('access-control-allow-origin'),
      'https://giaidoan1.chatplus.io.vn',
    );

    final untrusted = await _getJson(
      Uri.parse('http://127.0.0.1:$port/health'),
      origin: 'https://evil.example',
    );
    expect(untrusted.$1, 200);
    expect(untrusted.$2.containsKey('accounts'), isFalse);
    expect(untrusted.$3.value('access-control-allow-origin'), isNull);
  });

  test(
    'activate endpoint calls handler, debug endpoint stays disabled by default',
    () async {
      var activated = false;
      final server = LocalBridgeServer(LoggingService());
      await server.start(
        onActivate: () {
          activated = true;
        },
      );
      addTearDown(server.stop);

      final client = HttpClient();
      try {
        final activateRequest = await client.postUrl(
          Uri.parse('http://127.0.0.1:${server.port}/activate'),
        );
        final activateResponse = await activateRequest.close();
        expect(activateResponse.statusCode, 200);
        expect(activated, isTrue);
      } finally {
        client.close(force: true);
      }

      final debug = await _getJson(
        Uri.parse('http://127.0.0.1:${server.port}/debug'),
        origin: 'https://giaidoan1.chatplus.io.vn',
      );
      expect(debug.$1, 404);
      expect(debug.$2['error'], 'debug disabled');
    },
  );

  test(
    'eval endpoint rejects untrusted origins even when debug handler exists',
    () async {
      final server = LocalBridgeServer(LoggingService());
      await server.start(evalHandler: (_, __) async => 'should-not-run');
      addTearDown(server.stop);

      final client = HttpClient();
      try {
        final request = await client.postUrl(
          Uri.parse('http://127.0.0.1:${server.port}/eval'),
        );
        request.headers.set('Origin', 'https://evil.example');
        request.write('1 + 1');
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        final decoded = jsonDecode(body) as Map<String, dynamic>;
        expect(response.statusCode, 403);
        expect(decoded['error'], 'origin not allowed');
      } finally {
        client.close(force: true);
      }
    },
  );
}
