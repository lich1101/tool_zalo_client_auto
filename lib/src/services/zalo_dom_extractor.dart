import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../browser/browser_session.dart';
import '../config/app_config.dart';
import '../models/account_profile.dart';

class ZaloSelectorConfig {
  const ZaloSelectorConfig({
    required this.displayNameSelectors,
    required this.avatarSelectors,
    required this.loggedOutUrlPatterns,
    this.loggedInUrlPatterns = const <String>[],
  });

  final List<String> displayNameSelectors;
  final List<String> avatarSelectors;
  final List<String> loggedOutUrlPatterns;

  /// URL substrings that, when present (and no logged-out pattern matches),
  /// mean the profile holds an active session — even if the name/avatar
  /// selectors don't match. Needed for chat.zalo.me whose DOM is obfuscated:
  /// once logged in the client stays on the chat.zalo.me host, while a logged
  /// out profile is redirected to the id.zalo.me login page.
  final List<String> loggedInUrlPatterns;

  factory ZaloSelectorConfig.fromJson(Map<String, dynamic> json) {
    List<String> readList(String key) {
      return (json[key] as List<dynamic>? ?? const <dynamic>[])
          .whereType<String>()
          .toList(growable: false);
    }

    return ZaloSelectorConfig(
      displayNameSelectors: readList('displayNameSelectors'),
      avatarSelectors: readList('avatarSelectors'),
      loggedOutUrlPatterns: readList('loggedOutUrlPatterns'),
      loggedInUrlPatterns: readList('loggedInUrlPatterns'),
    );
  }
}

class ZaloDomExtractionResult {
  const ZaloDomExtractionResult({
    required this.currentUrl,
    required this.status,
    this.displayName,
    this.avatarUrl,
    this.errorMessage,
  });

  final String currentUrl;
  final String? displayName;
  final String? avatarUrl;
  final AccountStatus status;
  final String? errorMessage;
}

class ZaloDomExtractor {
  ZaloSelectorConfig? _selectorConfig;

  Future<ZaloDomExtractionResult> inspect(BrowserSession session) async {
    final config = await _loadConfig();
    final rawPayload = await session.evaluateToString(
      buildInspectionScript(config),
    );
    return parseInspectionPayload(
      rawPayload: rawPayload,
      fallbackUrl: session.currentUrl,
    );
  }

  @visibleForTesting
  String buildInspectionScript(ZaloSelectorConfig config) {
    final displaySelectors = jsonEncode(config.displayNameSelectors);
    final avatarSelectors = jsonEncode(config.avatarSelectors);
    final loggedOutPatterns = jsonEncode(config.loggedOutUrlPatterns);
    final loggedInPatterns = jsonEncode(config.loggedInUrlPatterns);

    return '''
(() => {
  const displayNameSelectors = $displaySelectors;
  const avatarSelectors = $avatarSelectors;
  const loggedOutPatterns = $loggedOutPatterns;
  const loggedInPatterns = $loggedInPatterns;
  const url = window.location.href;

  const pickText = (selectors) => {
    for (const selector of selectors) {
      const element = document.querySelector(selector);
      if (!element) continue;
      // Prefer textContent; fall back to the title / aria-label / alt attribute.
      // Zalo Web's profile element (#main-tab .nav__tabs__zalo) wraps the
      // user's name in the `title` attribute, not as text.
      const candidates = [
        element.textContent,
        element.getAttribute && element.getAttribute('title'),
        element.getAttribute && element.getAttribute('aria-label'),
        element.getAttribute && element.getAttribute('alt'),
      ];
      for (const candidate of candidates) {
        const text = candidate && candidate.trim();
        if (text) return text;
      }
    }
    return null;
  };

  const pickImage = (selectors) => {
    for (const selector of selectors) {
      const element = document.querySelector(selector);
      const src = element?.getAttribute?.('src') || element?.src;
      if (src) return src;
    }
    return null;
  };

  const lowerUrl = url.toLowerCase();
  const isLoggedOut = loggedOutPatterns.some((pattern) => lowerUrl.includes(String(pattern).toLowerCase()));
  const isLoggedInByUrl = !isLoggedOut &&
    loggedInPatterns.some((pattern) => lowerUrl.includes(String(pattern).toLowerCase()));
  const isErrorPage =
    lowerUrl.startsWith('data:text/html') ||
    lowerUrl.startsWith('chrome-error://') ||
    lowerUrl.startsWith('about:neterror');

  return JSON.stringify({
    currentUrl: url,
    displayName: pickText(displayNameSelectors),
    avatarUrl: pickImage(avatarSelectors),
    isLoggedOut,
    isLoggedInByUrl,
    isErrorPage,
  });
})();
''';
  }

  @visibleForTesting
  ZaloDomExtractionResult parseInspectionPayload({
    required String? rawPayload,
    required String fallbackUrl,
  }) {
    if (rawPayload == null || rawPayload.trim().isEmpty) {
      return ZaloDomExtractionResult(
        currentUrl: fallbackUrl,
        status: AccountStatus.error,
        errorMessage: 'No DOM payload returned by the browser engine.',
      );
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(rawPayload);
    } on FormatException {
      return ZaloDomExtractionResult(
        currentUrl: fallbackUrl,
        status: AccountStatus.error,
        errorMessage: 'Browser DOM payload is not valid JSON.',
      );
    }

    if (decoded is! Map<String, dynamic>) {
      return ZaloDomExtractionResult(
        currentUrl: fallbackUrl,
        status: AccountStatus.error,
        errorMessage: 'Unexpected DOM payload shape.',
      );
    }

    final currentUrl =
        (decoded['currentUrl'] as String?)?.trim() ?? fallbackUrl;
    final displayName = _normalize(decoded['displayName'] as String?);
    final avatarUrl = _normalize(decoded['avatarUrl'] as String?);
    final isLoggedOut = decoded['isLoggedOut'] == true;
    final isErrorPage =
        decoded['isErrorPage'] == true || _isBrowserErrorUrl(currentUrl);
    final isLoggedIn = displayName != null ||
        avatarUrl != null ||
        decoded['isLoggedInByUrl'] == true;

    final status =
        isLoggedIn
            ? AccountStatus.active
            : isErrorPage
            ? AccountStatus.error
            : isLoggedOut
            ? AccountStatus.needsLogin
            : AccountStatus.needsLogin;

    return ZaloDomExtractionResult(
      currentUrl: currentUrl,
      displayName: displayName,
      avatarUrl: avatarUrl,
      status: status,
      errorMessage:
          isLoggedIn || !isErrorPage
              ? null
              : 'The embedded browser reported a page load error.',
    );
  }

  Future<ZaloSelectorConfig> _loadConfig() async {
    if (_selectorConfig != null) {
      return _selectorConfig!;
    }

    final rawJson = await rootBundle.loadString(AppConfig.selectorConfigAsset);
    final decoded = jsonDecode(rawJson) as Map<String, dynamic>;
    _selectorConfig = ZaloSelectorConfig.fromJson(decoded);
    return _selectorConfig!;
  }

  String? _normalize(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  bool _isBrowserErrorUrl(String url) {
    final lowerUrl = url.toLowerCase();
    return lowerUrl.startsWith('data:text/html') ||
        lowerUrl.startsWith('chrome-error://') ||
        lowerUrl.startsWith('about:neterror');
  }
}
