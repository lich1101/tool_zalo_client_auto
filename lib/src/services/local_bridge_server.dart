import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'logging_service.dart';

/// A tiny loopback HTTP server the desktop app runs so the Campaio web UI / the
/// Chrome extension can detect whether the app is running and ask it to come to
/// the foreground ("Mở app" button).
///
/// Design:
///   - Binds 127.0.0.1 only (never exposed off-machine).
///   - Tries a small fixed port range so the browser side can probe
///     deterministically without service discovery.
///   - CORS is limited to trusted Campaio/extension/local origins. `/health`
///     can include local account display names, so arbitrary websites must not
///     be allowed to read it through the browser.
///
/// Endpoints:
///   GET  /health    → { ok, app, version, port, accounts: [...] }
///   POST /activate  → invokes [onActivate] (best-effort focus), { ok }
///   GET  /ping      → { ok: true }
///
/// Wake-up when the app is NOT running is handled separately by the OS custom
/// URL scheme (campaio-zalo://) registered in the platform runner; this server
/// only answers while the process is alive.
typedef HealthSnapshotProvider = Map<String, Object?> Function();
typedef ActivateHandler = FutureOr<void> Function();
typedef DiagnosticsProvider = Future<List<Map<String, Object?>>> Function();
// Debug-only: evaluate JS in a given profile's session and return the result.
typedef EvalHandler = Future<String?> Function(String profileId, String script);

class LocalBridgeServer {
  LocalBridgeServer(this._logger);

  final LoggingService _logger;
  HttpServer? _server;
  HealthSnapshotProvider? _healthProvider;
  ActivateHandler? _onActivate;
  DiagnosticsProvider? _diagnosticsProvider;
  EvalHandler? _evalHandler;

  /// Candidate loopback ports, probed in order. Keep this in sync with the
  /// extension/web probe list (campaio-bridge-extension + frontend).
  static const List<int> candidatePorts = <int>[8770, 8771, 8772, 8773];
  static const String appName = 'zalo-workspace';
  static const String appVersion = '0.2.0';

  int? get port => _server?.port;
  bool get isRunning => _server != null;

  Future<void> start({
    HealthSnapshotProvider? healthProvider,
    ActivateHandler? onActivate,
    DiagnosticsProvider? diagnosticsProvider,
    EvalHandler? evalHandler,
  }) async {
    _healthProvider = healthProvider;
    _onActivate = onActivate;
    _diagnosticsProvider = diagnosticsProvider;
    _evalHandler = evalHandler;
    if (_server != null) return;

    for (final candidate in candidatePorts) {
      try {
        final server = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          candidate,
          shared: false,
        );
        _server = server;
        _logger.info('[LocalBridge] listening on 127.0.0.1:$candidate');
        unawaited(_serve(server));
        return;
      } on SocketException {
        // Port busy (another app instance, or a stale bind). Try the next.
        continue;
      } catch (error) {
        _logger.warning('[LocalBridge] bind on $candidate failed: $error');
      }
    }
    _logger.warning(
      '[LocalBridge] could not bind any candidate port; open-app health endpoint disabled.',
    );
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    if (server != null) {
      await server.close(force: true);
      _logger.info('[LocalBridge] stopped.');
    }
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      try {
        await _handle(request);
      } catch (error) {
        _logger.warning('[LocalBridge] request error: $error');
        try {
          request.response.statusCode = 500;
          await request.response.close();
        } catch (_) {
          /* ignore */
        }
      }
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final trustedOrigin = _isTrustedOrigin(request);
    _applyCors(request, response, trustedOrigin: trustedOrigin);

    if (request.method == 'OPTIONS') {
      response.statusCode = trustedOrigin ? 204 : 403;
      await response.close();
      return;
    }

    final path = request.uri.path;
    if (path == '/health' || path == '/' || path == '/ping') {
      final snapshot = <String, Object?>{
        'ok': true,
        'app': appName,
        'version': appVersion,
        'port': _server?.port,
      };
      if (path == '/health' && trustedOrigin && _healthProvider != null) {
        try {
          snapshot.addAll(_healthProvider!());
        } catch (_) {
          /* best-effort */
        }
      }
      await _writeJson(response, 200, snapshot);
      return;
    }

    if (path == '/activate') {
      try {
        await _onActivate?.call();
      } catch (error) {
        _logger.warning('[LocalBridge] activate handler failed: $error');
      }
      await _writeJson(response, 200, <String, Object?>{'ok': true});
      return;
    }

    if (path == '/debug') {
      if (_diagnosticsProvider == null) {
        await _writeJson(response, 404, <String, Object?>{
          'ok': false,
          'error': 'debug disabled',
        });
        return;
      }
      if (!trustedOrigin) {
        await _writeJson(response, 403, <String, Object?>{
          'ok': false,
          'error': 'origin not allowed',
        });
        return;
      }
      final diagnostics =
          _diagnosticsProvider == null
              ? const <Map<String, Object?>>[]
              : await _diagnosticsProvider!();
      await _writeJson(response, 200, <String, Object?>{
        'ok': true,
        'diagnostics': diagnostics,
      });
      return;
    }

    if (path == '/eval' && request.method == 'POST') {
      // Debug aid: run JS in a session and return the result. Localhost-only.
      if (_evalHandler == null) {
        await _writeJson(response, 404, <String, Object?>{
          'ok': false,
          'error': 'eval disabled',
        });
        return;
      }
      if (!trustedOrigin) {
        await _writeJson(response, 403, <String, Object?>{
          'ok': false,
          'error': 'origin not allowed',
        });
        return;
      }
      final profileId = request.uri.queryParameters['profileId'] ?? '';
      final script = await utf8.decoder.bind(request).join();
      try {
        final result = await _evalHandler!(profileId, script);
        await _writeJson(response, 200, <String, Object?>{
          'ok': true,
          'result': result,
        });
      } catch (error) {
        await _writeJson(response, 200, <String, Object?>{
          'ok': false,
          'error': '$error',
        });
      }
      return;
    }

    await _writeJson(response, 404, <String, Object?>{
      'ok': false,
      'error': 'not found',
    });
  }

  bool _isTrustedOrigin(HttpRequest request) {
    final origin = request.headers.value('origin') ?? '*';
    if (origin == '*' || origin.isEmpty) {
      return true;
    }
    if (origin.startsWith('chrome-extension://')) {
      return true;
    }
    final uri = Uri.tryParse(origin);
    if (uri == null) {
      return false;
    }
    final host = uri.host.toLowerCase();
    final scheme = uri.scheme.toLowerCase();
    if ((scheme == 'http' || scheme == 'https') &&
        (host == '127.0.0.1' || host == 'localhost')) {
      return true;
    }
    if (scheme == 'https' &&
        (host == 'chatplus.io.vn' ||
            host.endsWith('.chatplus.io.vn') ||
            host == 'campaio.site' ||
            host.endsWith('.campaio.site'))) {
      return true;
    }
    return false;
  }

  void _applyCors(
    HttpRequest request,
    HttpResponse response, {
    required bool trustedOrigin,
  }) {
    final origin = request.headers.value('origin') ?? '*';
    if (trustedOrigin) {
      response.headers.set('Access-Control-Allow-Origin', origin);
    }
    response.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    response.headers.set('Access-Control-Allow-Headers', 'Content-Type');
    response.headers.set('Vary', 'Origin');
  }

  Future<void> _writeJson(
    HttpResponse response,
    int status,
    Map<String, Object?> body,
  ) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }
}
