import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_cef/webview_cef.dart';

import 'browser_engine.dart';
import 'browser_session.dart';
import '../services/logging_service.dart';

class WebviewCefBrowserEngine implements BrowserEngine {
  WebviewCefBrowserEngine(this._logger, {required String rootCachePath})
      : _rootCachePath = rootCachePath;

  final LoggingService _logger;

  /// Parent directory that every per-profile cache lives under. The CEF Chrome
  /// runtime requires each browser's cache_path to be a child of
  /// CefSettings.root_cache_path, otherwise profile creation fails with
  /// "Cannot create profile at path".
  final String _rootCachePath;
  final Map<String, WebviewCefBrowserSession> _sessions =
      <String, WebviewCefBrowserSession>{};
  bool _initialized = false;

  @override
  Future<BrowserSession> createSession({
    required String profileId,
    required String profilePath,
    required String initialUrl,
  }) async {
    await initialize();

    final existing = _sessions[profileId];
    if (existing != null) {
      return existing;
    }

    final controller = WebviewManager().createWebView(
      loading: const ColoredBox(
        color: Color(0xFFF4F7FB),
        child: Center(child: CircularProgressIndicator()),
      ),
    );

    final session = WebviewCefBrowserSession(
      profileId: profileId,
      profilePath: profilePath,
      controller: controller,
    );

    await session.initialize(initialUrl);
    _sessions[profileId] = session;

    return session;
  }

  @override
  Future<void> disposeSession(String profileId) async {
    final session = _sessions.remove(profileId);
    if (session != null) {
      await session.dispose();
    }
  }

  @override
  Future<void> initialize() async {
    if (_initialized) {
      return;
    }

    // Do NOT set a custom user-agent product: that string is appended to the
    // default Chromium UA and Zalo treats any UA containing app-like tokens as
    // "Zalo PC desktop" — which forces a redirect to zalo.me/pc (and an
    // infinite login ↔ /pc loop after QR scan) instead of the real chat.zalo.me
    // web client. Keeping the stock UA makes Zalo route us through the same
    // path as desktop Chrome.
    await WebviewManager().initialize(rootCachePath: _rootCachePath);
    _initialized = true;
    _logger.info('Initialized webview_cef browser engine.');
  }

  @override
  Future<void> shutdown() async {
    final keys = _sessions.keys.toList(growable: false);
    for (final key in keys) {
      await disposeSession(key);
    }

    if (_initialized) {
      await WebviewManager().quit();
      _initialized = false;
    }
  }
}

class WebviewCefBrowserSession implements BrowserSession {
  WebviewCefBrowserSession({
    required this.profileId,
    required this.profilePath,
    required WebViewController controller,
  }) : _controller = controller;

  final WebViewController _controller;
  final ValueNotifier<String> _currentUrl = ValueNotifier<String>('');
  BrowserLoadEndCallback? _loadEndCallback;
  String? _pendingLoadEndUrl;
  void Function(String url)? _popupCallback;
  void Function(String url)? _urlChangedCallback;
  bool _disposed = false;

  @override
  final String profileId;

  @override
  final String profilePath;

  Future<void> initialize(String initialUrl) async {
    _currentUrl.value = initialUrl;
    _controller.setWebviewListener(
      WebviewEventsListener(
        onUrlChanged: (url) {
          _currentUrl.value = url;
          _urlChangedCallback?.call(url);
        },
        onLoadEnd: (_, url) {
          _currentUrl.value = url;
          final callback = _loadEndCallback;
          if (callback == null) {
            _pendingLoadEndUrl = url;
            return;
          }

          unawaited(
            Future<void>.sync(() async {
              await callback(url);
            }),
          );
        },
        onPopupRequest: (url) {
          _popupCallback?.call(url);
        },
      ),
    );

    await _controller.initialize(initialUrl, cachePath: profilePath);
  }

  @override
  String get currentUrl => _currentUrl.value;

  @override
  ValueListenable<String> get currentUrlListenable => _currentUrl;

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }

    _disposed = true;
    _currentUrl.dispose();
    await _controller.dispose();
  }

  @override
  Future<String?> evaluateToString(String script) async {
    final result = await _controller.evaluateJavascript(script);
    return result?.toString();
  }

  @override
  Future<void> imeCommitText(String text) async {
    if (_disposed) return;
    await _controller.imeCommitText(text);
  }

  @override
  Future<void> setKeyboardFocus(bool focus) async {
    if (_disposed) return;
    try {
      await _controller.setClientFocus(focus);
    } catch (_) {
      // Best-effort: setClientFocus asserts the controller is alive; we'd
      // rather silently noop than crash the UI when timing races with
      // disposal happen.
    }
  }

  @override
  Future<void> goBack() => _controller.goBack();

  @override
  Future<void> goForward() => _controller.goForward();

  @override
  Future<void> loadUrl(String url) => _controller.loadUrl(url);

  @override
  Future<void> openDevTools() => _controller.openDevTools();

  @override
  Future<void> reload() => _controller.reload();

  @override
  void setPopupCallback(void Function(String url)? callback) {
    _popupCallback = callback;
  }

  @override
  void setUrlChangedCallback(void Function(String url)? callback) {
    _urlChangedCallback = callback;
  }

  @override
  void setLoadEndCallback(BrowserLoadEndCallback? callback) {
    _loadEndCallback = callback;
    if (callback == null) {
      return;
    }

    final pendingLoadEndUrl = _pendingLoadEndUrl;
    if (pendingLoadEndUrl == null) {
      return;
    }

    _pendingLoadEndUrl = null;
    unawaited(
      Future<void>.sync(() async {
        await callback(pendingLoadEndUrl);
      }),
    );
  }

  @override
  Widget get view {
    return ValueListenableBuilder<bool>(
      valueListenable: _controller,
      builder: (context, ready, _) {
        if (!ready) {
          return _controller.loadingWidget;
        }

        return DecoratedBox(
          decoration: const BoxDecoration(color: Colors.white),
          child: _controller.webviewWidget,
        );
      },
    );
  }
}
