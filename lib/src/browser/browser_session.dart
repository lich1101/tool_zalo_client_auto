import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

typedef BrowserLoadEndCallback = FutureOr<void> Function(String url);

abstract class BrowserSession {
  String get profileId;

  String get profilePath;

  String get currentUrl;

  ValueListenable<String> get currentUrlListenable;

  Widget get view;

  void setLoadEndCallback(BrowserLoadEndCallback? callback);

  /// Called whenever the navigated URL changes. Fires both on full page loads
  /// and on SPA history changes (e.g. when Zalo Web transitions from
  /// id.zalo.me to chat.zalo.me after a QR scan).
  void setUrlChangedCallback(void Function(String url)? callback);

  /// Called when the page requests a popup / new tab (window.open,
  /// target="_blank"). The host opens [url] in a separate in-app popup window.
  void setPopupCallback(void Function(String url)? callback);

  Future<void> loadUrl(String url);

  Future<void> reload();

  Future<void> goBack();

  Future<void> goForward();

  Future<void> openDevTools();

  Future<String?> evaluateToString(String script);

  /// Commit text through the embedded browser's native IME path. This is useful
  /// for sites whose search boxes ignore synthetic DOM input events.
  Future<void> imeCommitText(String text);

  /// Tell the embedded CEF browser to release/acquire keyboard focus. On
  /// macOS, CEF NSViews capture keystrokes via the responder chain and the
  /// AlertDialog overlay can't reclaim them on its own; calling
  /// setKeyboardFocus(false) before showing a dialog frees the keyboard.
  Future<void> setKeyboardFocus(bool focus);

  Future<void> dispose();
}
