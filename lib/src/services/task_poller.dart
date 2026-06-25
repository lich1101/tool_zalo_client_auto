import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../browser/browser_session.dart';
import '../models/app_settings.dart';
import 'logging_service.dart';

/// Native Dart poller for the Zalo Personal *task queue* (lookup_by_phone,
/// fetch_history, send_message). Sibling of [OutboxPoller]: same lifecycle and
/// HTTP plumbing, different endpoints + payload.
///
/// Why a separate poller from the outbox:
///   - The outbox only models "send text to a known recipientZaloId".
///   - Tasks are the phone-driven flows (find a user by phone, save them as a
///     customer, pull history, send by phone). They carry a taskType + result
///     object that the bridge's `runTask(task)` returns; the tenant processes
///     the result server-side on ack.
///
/// Flow per tick:
///   1. For each active profile, GET /tasks?profileId=…&limit=3.
///   2. For each task, eval `window.__CAMPAIO_BRIDGE__.runTask(task)` in the
///      matching session, capturing the JSON result.
///   3. POST /tasks/:id/ack with { status, result, errorMessage }.
typedef ProfileSessionResolver = BrowserSession? Function(String profileId);
typedef ProfileSessionPreparer = Future<BrowserSession?> Function(String profileId);

class _TransientTaskError implements Exception {
  const _TransientTaskError(this.message);

  final String message;

  @override
  String toString() => message;
}

class TaskPoller {
  TaskPoller(this._logger);

  final LoggingService _logger;
  Timer? _timer;
  bool _running = false;
  bool _inFlight = false;
  AppSettings _settings = const AppSettings();
  List<String> _profileIds = const [];
  ProfileSessionResolver? _resolveSession;
  ProfileSessionPreparer? _prepareSession;
  int _consecutiveFailures = 0;

  // Tasks are slower + heavier than outbox sends (each can drive a full
  // search → open → scrape), so poll a touch less aggressively.
  static const Duration _baseInterval = Duration(seconds: 20);
  static const Duration _backoffInterval = Duration(minutes: 2);

  bool get isRunning => _running;

  void start({
    required AppSettings settings,
    required List<String> profileIds,
    required ProfileSessionResolver resolveSession,
    ProfileSessionPreparer? prepareSession,
  }) {
    _settings = settings;
    _profileIds = List.unmodifiable(profileIds);
    _resolveSession = resolveSession;
    _prepareSession = prepareSession;

    if (!_eligible()) {
      stop();
      return;
    }
    if (_running) return;
    _running = true;
    _logger.info('[TaskPoller] started (profiles=${_profileIds.length}).');
    _scheduleTick(_baseInterval);
    Timer(const Duration(seconds: 5), () { unawaited(_tick()); });
  }

  void stop() {
    if (!_running) return;
    _timer?.cancel();
    _timer = null;
    _running = false;
    _consecutiveFailures = 0;
    _logger.info('[TaskPoller] stopped.');
  }

  bool _eligible() {
    return _settings.bridgeEnabled
        && _settings.tenantUrl.isNotEmpty
        && _settings.deviceApiKey.isNotEmpty;
  }

  void _scheduleTick(Duration delay) {
    _timer?.cancel();
    _timer = Timer.periodic(delay, (_) => unawaited(_tick()));
  }

  Future<void> _tick() async {
    if (!_running || _inFlight) return;
    if (!_eligible()) {
      stop();
      return;
    }
    _inFlight = true;
    try {
      if (_profileIds.isEmpty) {
        await _pollOnce(null);
      } else {
        for (final profileId in _profileIds) {
          await _pollOnce(profileId);
        }
      }
      if (_consecutiveFailures > 0) {
        _consecutiveFailures = 0;
        _scheduleTick(_baseInterval);
      }
    } catch (error) {
      _consecutiveFailures += 1;
      _logger.warning('[TaskPoller] tick failed: $error');
      if (_consecutiveFailures >= 3) {
        _scheduleTick(_backoffInterval);
      }
    } finally {
      _inFlight = false;
    }
  }

  Future<void> _pollOnce(String? profileId) async {
    final base = _settings.tenantUrl.replaceAll(RegExp(r'/+$'), '');
    final qs = profileId != null && profileId.isNotEmpty
        ? '?limit=3&profileId=${Uri.encodeQueryComponent(profileId)}'
        : '?limit=3';
    final items = await _httpGet('$base/api/integrations/zalo-personal/tasks$qs');
    if (items.isEmpty) return;

    for (final raw in items) {
      if (raw is! Map) continue;
      final task = Map<String, dynamic>.from(raw);
      final id = task['id']?.toString();
      if (id == null) continue;

      String status = 'completed';
      Map<String, dynamic>? result;
      String? errorMessage;

      try {
        final itemProfileId = task['deviceProfileId']?.toString();
        final effectiveProfileId = (itemProfileId != null && itemProfileId.isNotEmpty)
            ? itemProfileId
            : (profileId ?? '');
        var session = await _prepareSession?.call(effectiveProfileId);
        session ??= _resolveSession?.call(effectiveProfileId);
        if (session == null) {
          throw _TransientTaskError('Không có session cho profile ${effectiveProfileId.isEmpty ? '<none>' : effectiveProfileId}.');
        }
        final runResult = await _runTaskViaSession(session, task);
        if (runResult['ok'] == true) {
          result = runResult['result'] is Map
              ? Map<String, dynamic>.from(runResult['result'] as Map)
              : <String, dynamic>{};
          status = 'completed';
        } else {
          final errorText = runResult['error']?.toString() ?? 'unknown';
          if (_isTransientBridgeError(errorText)) {
            throw _TransientTaskError(errorText);
          }
          status = 'failed';
          errorMessage = errorText;
        }
      } catch (error) {
        if (error is _TransientTaskError || _isTransientBridgeError(error.toString())) {
          _logger.warning('[TaskPoller] task $id postponed: $error');
          continue;
        }
        status = 'failed';
        errorMessage = error.toString();
        _logger.warning('[TaskPoller] task $id failed: $error');
      }

      await _httpPostJson(
        '$base/api/integrations/zalo-personal/tasks/$id/ack',
        body: {
          'status': status,
          if (result != null) 'result': result,
          if (errorMessage != null) 'errorMessage': errorMessage,
        },
      ).catchError((e) {
        _logger.warning('[TaskPoller] ack failed for $id: $e');
        return <String, dynamic>{};
      });

      // Throttle between tasks so we don't hammer Zalo's search/lookup.
      await Future<void>.delayed(const Duration(milliseconds: 2000));
    }
  }

  // CEF's evaluateJavascript can't return a Promise (it serializes to null), so
  // we can't `await bridge.runTask(...)` inside an eval and read its value. The
  // bridge instead runs the task in the background and stashes the result in a
  // page global; we kick it off, then poll that global with a *synchronous*
  // expression until it's populated.
  Future<Map<String, dynamic>> _runTaskViaSession(BrowserSession session, Map<String, dynamic> task) async {
    final taskId = task['id']?.toString() ?? 'task';
    final taskIdJson = jsonEncode(taskId);
    final taskForBridge = Map<String, dynamic>.from(task);
    if (await _prepareNativePhoneSearch(session, taskForBridge)) {
      taskForBridge['preparedSearch'] = true;
    }

    final startJs = '''
(function(){
  try {
    var b = window.__CAMPAIO_BRIDGE__;
    if (!b || typeof b.runTaskAsync !== 'function') return 'NO_BRIDGE';
    b.runTaskAsync(${jsonEncode(taskId)}, ${jsonEncode(taskForBridge)});
    return 'STARTED';
  } catch (e) { return 'ERR:' + (e && e.message || e); }
})();
''';
    final startRaw = (await session.evaluateToString(startJs))?.trim() ?? '';
    final start = startRaw.replaceAll('"', '');
    if (start == 'NO_BRIDGE') {
      return <String, dynamic>{'ok': false, 'error': 'bridge not bootstrapped on this page'};
    }
    if (start.startsWith('ERR:')) {
      return <String, dynamic>{'ok': false, 'error': start.substring(4)};
    }

    final pollJs = '''
(function(){
  var s = window.__CAMPAIO_TASK_RESULTS__;
  var r = s && s[$taskIdJson];
  if (!r || r.status !== 'done') return '';
  try { return JSON.stringify(r); } catch (e) { return ''; }
})();
''';
    // Lookups drive a real Zalo search (network + SPA render), so allow ample
    // time before giving up.
    const maxAttempts = 60; // ~60 × 700ms ≈ 42s
    for (var i = 0; i < maxAttempts; i += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final raw = await session.evaluateToString(pollJs);
      if (raw == null) continue;
      final text = raw.trim();
      if (text.isEmpty || text == 'null' || text == '""') continue;
      // Got a result — clean up the global so it doesn't leak.
      await session.evaluateToString(
        '(function(){try{delete window.__CAMPAIO_TASK_RESULTS__[$taskIdJson];}catch(e){}return "";})();',
      );
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
        return <String, dynamic>{'ok': false, 'error': 'unexpected result: $text'};
      } on FormatException {
        return <String, dynamic>{'ok': false, 'error': 'non-JSON result: $text'};
      }
    }
    return <String, dynamic>{'ok': false, 'error': 'task timed out waiting for bridge result'};
  }

  Future<bool> _prepareNativePhoneSearch(BrowserSession session, Map<String, dynamic> task) async {
    // Do not use CEF IME commit for Zalo global search. It can put digits into
    // the visible input while Zalo's SPA state does not start a search, leaving
    // the bridge stuck with "input has digits but no results". Let the injected
    // bridge do the full fill + synthetic event sequence inside the page
    // context instead; that path also works for hidden/background sessions.
    return false;
  }

  bool _isTransientBridgeError(String value) {
    final text = value.toLowerCase();
    return text.contains('bridge not bootstrapped')
        || text.contains('không có session')
        || text.contains('no session')
        || text.contains('webview')
        || text.contains('browser')
        || text.contains('search box not found')
        || text.contains('(timeout)')
        || text.contains('task timed out waiting for bridge result');
  }

  Future<List<dynamic>> _httpGet(String url) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('X-Zalo-Personal-Device-Key', _settings.deviceApiKey);
      req.headers.set('Accept', 'application/json');
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final decoded = jsonDecode(body);
        if (decoded is Map && decoded['items'] is List) {
          return decoded['items'] as List<dynamic>;
        }
        return const [];
      }
      throw HttpException('HTTP ${res.statusCode}', uri: Uri.parse(url));
    } finally {
      client.close(force: false);
    }
  }

  Future<Map<String, dynamic>> _httpPostJson(String url, {required Map<String, dynamic> body}) async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(Uri.parse(url));
      final bytes = utf8.encode(jsonEncode(body));
      req.headers.set('X-Zalo-Personal-Device-Key', _settings.deviceApiKey);
      req.headers.set('Content-Type', 'application/json; charset=utf-8');
      req.headers.set('Accept', 'application/json');
      req.headers.set('Content-Length', bytes.length.toString());
      req.add(bytes);
      final res = await req.close();
      final responseBody = await res.transform(utf8.decoder).join();
      if (res.statusCode >= 200 && res.statusCode < 300) {
        if (responseBody.isEmpty) return <String, dynamic>{};
        final decoded = jsonDecode(responseBody);
        return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
      }
      throw HttpException('HTTP ${res.statusCode}', uri: Uri.parse(url));
    } finally {
      client.close(force: false);
    }
  }
}
