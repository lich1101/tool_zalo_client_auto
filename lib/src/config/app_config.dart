import 'package:flutter/foundation.dart';

class AppConfig {
  const AppConfig._();

  static const String appName = 'Zalo Tool ChatPlus';
  static const String storageFolderName = 'ZaloAccountWorkspace';
  static const String selectorConfigAsset = 'assets/zalo_selectors.json';
  // Zalo Web chat client. Scanning the QR here creates a real logged-in Zalo
  // Web session in this profile. (id.zalo.me/account only links an account to
  // the zalo.me website and does NOT establish a usable chat session.)
  static const String zaloAccountUrl = 'https://chat.zalo.me/';
  static const Duration sessionCheckDebounce = Duration(milliseconds: 900);
  static const Duration manualCheckCooldown = Duration(seconds: 5);
  static const double sidebarWidth = 280;

  static bool get debugMode => kDebugMode;
}
