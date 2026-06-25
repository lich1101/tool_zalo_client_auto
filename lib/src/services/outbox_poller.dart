import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../browser/browser_session.dart';
import '../models/app_settings.dart';
import 'logging_service.dart';

/// Native Dart implementation of the Campaio outbox poller. Replaces the
/// JS-side `setInterval(pollOutbox, …)` previously running inside the
/// integration_bridge.js bundle.
///
/// Why native:
///   - The JS poller only runs while a chat.zalo.me tab is open in CEF.
///     If the user closes the tab, queued messages from the web side stay
///     stuck until they reopen Zalo.
///   - Native Dart runs as long as the desktop app is open, regardless of
///     which tab the user is viewing. The user requirement was: "đóng
///     trình duyệt hoặc đóng tabs vẫn phải gửi được" — only the app needs
///     to stay open.
///
/// Flow per tick:
///   1. For each known active profile (Zalo account in the workspace),
///      GET /api/integrations/zalo-personal/outbox?profileId=…&limit=5.
///   2. For each returned item, look up the matching BrowserSession, eval a
///      JavaScript snippet that opens the conversation + fills compose +
///      clicks send.
///   3. POST /outbox/:id/ack with status=sent or failed.
///
/// Robustness:
///   - 30s tick; backoff to 2 min on consecutive HTTP errors.
///   - At most one tick in flight (re-entrant guard).
///   - Stops cleanly on dispose.
typedef ProfileSessionResolver = BrowserSession? Function(String profileId);
typedef AccountListPusher = Future<void> Function();

class OutboxPoller {
  OutboxPoller(this._logger);

  final LoggingService _logger;
  Timer? _timer;
  bool _running = false;
  bool _inFlight = false;
  AppSettings _settings = const AppSettings();
  List<String> _profileIds = const [];
  ProfileSessionResolver? _resolveSession;
  AccountListPusher? _pushAccounts;
  int _consecutiveFailures = 0;
  // Initialised to the threshold so the very first tick triggers a push.
  int _ticksSinceAccountPush = 4;

  static const Duration _baseInterval = Duration(seconds: 30);
  static const Duration _backoffInterval = Duration(minutes: 2);
  // Re-push the account list every N ticks. With a 30s base interval that
  // means every ~2 minutes — enough that login-state changes propagate
  // promptly but not so often we hammer the tenant.
  static const int _accountPushTickInterval = 4;

  bool get isRunning => _running;

  /// Start / refresh the poller against the given settings + active profile
  /// list. Safe to call multiple times; if already running with the same
  /// config, this just updates the profile list for the next tick.
  void start({
    required AppSettings settings,
    required List<String> profileIds,
    required ProfileSessionResolver resolveSession,
    AccountListPusher? pushAccounts,
  }) {
    _settings = settings;
    _profileIds = List.unmodifiable(profileIds);
    _resolveSession = resolveSession;
    _pushAccounts = pushAccounts;

    if (!_eligible()) {
      stop();
      return;
    }

    if (_running) {
      // Already running — new config will take effect on next tick.
      return;
    }
    _running = true;
    _logger.info('[OutboxPoller] started (profiles=${_profileIds.length}).');
    _scheduleTick(_baseInterval);
    // Fire a first tick almost immediately so settings-save feedback is fast.
    Timer(const Duration(seconds: 3), () { unawaited(_tick()); });
  }

  void stop() {
    if (!_running) return;
    _timer?.cancel();
    _timer = null;
    _running = false;
    _consecutiveFailures = 0;
    _logger.info('[OutboxPoller] stopped.');
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
      // Piggyback push the account list every N ticks so the /channels page
      // reflects login-state changes even if the user never re-opens the
      // settings dialog. Run it FIRST so an outbox failure later in the
      // tick doesn't block the push.
      _ticksSinceAccountPush += 1;
      if (_pushAccounts != null && _ticksSinceAccountPush >= _accountPushTickInterval) {
        try {
          await _pushAccounts!();
          _ticksSinceAccountPush = 0;
          _logger.info('[OutboxPoller] account list pushed.');
        } catch (error) {
          _logger.warning('[OutboxPoller] account push failed: $error');
        }
      }

      // If the user has logged-in profiles, poll one queue per profile so
      // the right Zalo account sends each item. Otherwise fall back to a
      // single deviceId-only query.
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
      _logger.warning('[OutboxPoller] tick failed: $error');
      if (_consecutiveFailures >= 3) {
        _logger.warning('[OutboxPoller] backing off to ${_backoffInterval.inMinutes} minutes after $_consecutiveFailures consecutive failures.');
        _scheduleTick(_backoffInterval);
      }
    } finally {
      _inFlight = false;
    }
  }

  Future<void> _pollOnce(String? profileId) async {
    final base = _settings.tenantUrl.replaceAll(RegExp(r'/+$'), '');
    final qs = profileId != null && profileId.isNotEmpty
        ? '?limit=5&profileId=${Uri.encodeQueryComponent(profileId)}'
        : '?limit=5';
    final List<dynamic> items = await _httpGet('$base/api/integrations/zalo-personal/outbox$qs');
    if (items.isEmpty) return;

    for (final raw in items) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      final id = item['id']?.toString();
      final recipientZaloId = item['recipientZaloId']?.toString() ?? '';
      final content = item['content']?.toString() ?? '';
      final itemProfileId = item['deviceProfileId']?.toString();
      if (id == null || recipientZaloId.isEmpty || content.isEmpty) continue;

      String? resultStatus;
      String? errorMessage;

      try {
        final session = _resolveSession?.call(itemProfileId ?? profileId ?? '');
        if (session == null) {
          throw StateError('Không có session cho profile ${itemProfileId ?? profileId ?? '<none>'}.');
        }
        await _sendViaSession(session, recipientZaloId, content);
        resultStatus = 'sent';
      } catch (error) {
        if (_isTransientSendError(error)) {
          _logger.warning('[OutboxPoller] item $id postponed: $error');
          continue;
        }

        resultStatus = 'failed';
        errorMessage = error.toString();
        _logger.warning('[OutboxPoller] item $id failed: $error');
      }

      await _httpPostJson(
        '$base/api/integrations/zalo-personal/outbox/$id/ack',
        body: {
          'status': resultStatus,
          if (errorMessage != null) 'errorMessage': errorMessage,
        },
      ).catchError((e) {
        _logger.warning('[OutboxPoller] ack failed for $id: $e');
        return <String, dynamic>{};
      });

      // Throttle between sends so Zalo doesn't flag the burst.
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    }
  }

  Future<void> _sendViaSession(BrowserSession session, String recipientZaloId, String content) async {
    // Reuse the bridge's helper APIs already exposed on window.__CAMPAIO_BRIDGE__
    // when the injected script has bootstrapped. If not bootstrapped yet,
    // bootstrap it inline via the same prologue + script content.
    final js = '''
(async () => {
  try {
    const recipient = ${jsonEncode(recipientZaloId)};
    const content = ${jsonEncode(content)};
    const bridge = window.__CAMPAIO_BRIDGE__;
    if (!bridge || !bridge.activeModule) {
      return JSON.stringify({ ok: false, error: 'bridge not bootstrapped on this page' });
    }
    // The injected bridge exposes runSync + pollOutbox but not raw module —
    // walk via the SAME path: dispatchEvent open + injectMessage. Since the
    // module is closed-over, we re-derive via window.__CAMPAIO_BRIDGE__'s
    // hidden activeModule. As a fallback when the bridge object doesn't
    // expose the module, we use location.hash directly.
    if (typeof bridge.openConversation === 'function' && typeof bridge.injectMessage === 'function') {
      await bridge.openConversation(recipient);
      await bridge.injectMessage(content);
      return JSON.stringify({ ok: true });
    }
    // Fallback: best-effort DOM walk.
    if (!location.hash.includes('uid=' + recipient)) {
      location.hash = '#chat/' + recipient;
      for (let i = 0; i < 30; i += 1) {
        await new Promise((r) => setTimeout(r, 200));
        if (document.querySelector('#richInput, [contenteditable="true"][data-id="richInput"]')) break;
      }
    }
    const box = document.querySelector('#richInput, [contenteditable="true"][data-id="richInput"]');
    if (!box) return JSON.stringify({ ok: false, error: 'compose box missing' });
    box.focus();
    if (box.tagName === 'TEXTAREA' || box.tagName === 'INPUT') {
      box.value = content;
      box.dispatchEvent(new Event('input', { bubbles: true }));
    } else {
      box.textContent = content;
      box.dispatchEvent(new InputEvent('input', { bubbles: true, data: content, inputType: 'insertText' }));
    }
    await new Promise((r) => setTimeout(r, 120));
    const btn = document.querySelector('#btnSendMsg, .btn-send');
    if (btn) btn.click();
    else box.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
    return JSON.stringify({ ok: true });
  } catch (error) {
    return JSON.stringify({ ok: false, error: String(error && error.message || error) });
  }
})();
''';
    final result = await session.evaluateToString(js);
    if (result == null) return; // best-effort
    try {
      final decoded = jsonDecode(result);
      if (decoded is Map && decoded['ok'] != true) {
        throw StateError(decoded['error']?.toString() ?? 'unknown');
      }
    } on FormatException {
      // Non-JSON result — treat as success since the browser call itself did not throw.
    }
  }

  bool _isTransientSendError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('không có session')
        || text.contains('bridge not bootstrapped')
        || text.contains('compose box missing')
        || text.contains('compose box not ready')
        || text.contains('browser')
        || text.contains('webview');
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
      throw HttpException('HTTP ${res.statusCode}: ${body.length > 200 ? body.substring(0, 200) : body}', uri: Uri.parse(url));
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
      throw HttpException('HTTP ${res.statusCode}: ${responseBody.length > 200 ? responseBody.substring(0, 200) : responseBody}', uri: Uri.parse(url));
    } finally {
      client.close(force: false);
    }
  }
}
