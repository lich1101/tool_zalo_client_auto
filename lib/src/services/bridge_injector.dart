import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../browser/browser_session.dart';
import '../models/account_profile.dart';
import '../models/app_settings.dart';
import 'logging_service.dart';

/// Injects the Campaio integration bridge JS into chat.zalo.me sessions and
/// also pushes the desktop app's account list to the tenant over HTTP.
///
/// The injection (executeJavaScript) handles scraping conversations + messages
/// + writing messages back to compose. The HTTP push of accounts is a separate
/// concern because the account list lives in Hive on the Dart side and is not
/// reachable from inside chat.zalo.me.
class BridgeInjector {
  BridgeInjector(this._logger);

  final LoggingService _logger;
  String? _cachedScript;

  Future<String> _loadScript() async {
    final cached = _cachedScript;
    if (cached != null) return cached;
    final raw = await rootBundle.loadString('assets/integration_bridge.js');
    _cachedScript = raw;
    return raw;
  }

  bool _shouldInject(String url) {
    return url.contains('chat.zalo.me');
  }

  /// Inject the bridge into [session] for [url] if conditions are met.
  Future<void> maybeInject({
    required BrowserSession session,
    required String url,
    required AppSettings settings,
    String? profileId,
  }) async {
    if (!settings.bridgeEnabled) return;
    if (settings.tenantUrl.isEmpty || settings.deviceApiKey.isEmpty) {
      _logger.info(
        '[BridgeInjector] skip injection — bridgeEnabled=true but tenantUrl/'
        'deviceApiKey not configured.',
      );
      return;
    }
    if (!_shouldInject(url)) return;

    try {
      final script = await _loadScript();
      final bridgeConfig = jsonEncode(<String, Object?>{
        'tenantUrl': settings.tenantUrl,
        'apiKey': settings.deviceApiKey,
        if (profileId != null && profileId.trim().isNotEmpty)
          'profileId': profileId.trim(),
      });
      final prologue = 'window.__CAMPAIO__ = $bridgeConfig;';
      await session.evaluateToString(prologue);
      final scriptLiteral = jsonEncode(script);
      final result = await session.evaluateToString('''
(function(){
  try {
    window.__CAMPAIO_INJECT_PROBE__ = (window.__CAMPAIO_INJECT_PROBE__ || 0) + 1;
    window.__CAMPAIO_BRIDGE_SCRIPT_LEN__ = ${script.length};
    window.__CAMPAIO_BRIDGE_ERROR__ = null;
    (0, eval)($scriptLiteral);
    window.__CAMPAIO_BRIDGE_LAST_RESULT__ = window.__CAMPAIO_BRIDGE__ ? "ok" : "no_bridge";
    return window.__CAMPAIO_BRIDGE_LAST_RESULT__;
  } catch (error) {
    var message = String((error && error.stack) || (error && error.message) || error);
    window.__CAMPAIO_BRIDGE_ERROR__ = message;
    window.__CAMPAIO_BRIDGE_LAST_RESULT__ = "error";
    console.error('[campaio-bridge] bootstrap failed', error);
    return "error: " + message;
  }
})();
''');
      _logger.info('[BridgeInjector] injected for $url result=$result');
    } catch (error) {
      _logger.warning('[BridgeInjector] injection failed: $error');
    }
  }

  /// Push the current list of AccountProfile entries to the tenant so the
  /// /channels page can render them as Zalo cá nhân assets — similar to
  /// fanpages on facebook_page.
  ///
  /// Called whenever:
  ///   - The user saves bridge settings (so the list appears immediately).
  ///   - The account list changes (add/remove/login state).
  ///   - On app startup if bridge already enabled (poor man's heartbeat).
  Future<void> pushAccountList({
    required AppSettings settings,
    required List<AccountProfile> accounts,
  }) async {
    if (!settings.bridgeEnabled) return;
    if (settings.tenantUrl.isEmpty || settings.deviceApiKey.isEmpty) return;

    final body = jsonEncode({
      'accounts': accounts
          .map((a) => {
                'profileId': a.id,
                'displayName': a.displayName ?? a.accountName ?? a.effectiveTitle,
                'accountName': a.accountName ?? a.effectiveTitle,
                'avatarUrl': a.avatarUrl,
                'status': _mapStatus(a.status),
                'lastCheckedAt': a.lastCheckedAt?.toIso8601String(),
                'lastError': a.lastError,
              })
          .toList(),
      'deviceInfo': {
        'os': Platform.operatingSystem,
        'appVersion': '0.2.0',
      }
    });

    final url = Uri.parse('${settings.tenantUrl.replaceAll(RegExp(r'/+$'), '')}/api/integrations/zalo-personal/accounts');
    final client = HttpClient();
    try {
      final request = await client.postUrl(url);
      final bodyBytes = utf8.encode(body);
      request.headers.set('Content-Type', 'application/json; charset=utf-8');
      request.headers.set('Accept', 'application/json');
      request.headers.set('Content-Length', bodyBytes.length.toString());
      request.headers.set('X-Zalo-Personal-Device-Key', settings.deviceApiKey);
      request.add(bodyBytes);
      final response = await request.close();
      if (response.statusCode >= 200 && response.statusCode < 300) {
        _logger.info('[BridgeInjector] pushed ${accounts.length} accounts to tenant.');
      } else {
        final responseBody = await response.transform(utf8.decoder).join();
        _logger.warning('[BridgeInjector] push accounts failed: HTTP ${response.statusCode} ${responseBody.length > 200 ? responseBody.substring(0, 200) : responseBody}');
      }
    } catch (error) {
      _logger.warning('[BridgeInjector] push accounts errored: $error');
    } finally {
      client.close(force: false);
    }
  }

  String _mapStatus(AccountStatus status) {
    switch (status) {
      case AccountStatus.active:
        return 'active';
      case AccountStatus.needsLogin:
        return 'needs_login';
      case AccountStatus.checking:
        return 'checking';
      case AccountStatus.error:
        return 'error';
    }
  }
}
