import 'package:flutter/material.dart';

class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.tenantUrl = '',
    this.deviceApiKey = '',
    this.bridgeEnabled = false,
  });

  final ThemeMode themeMode;

  /// Base URL of the Campaio tenant workspace, e.g.
  /// https://giaidoan1.chatplus.io.vn. Used by the integration bridge
  /// injection to know where to POST scraped contacts/messages and pull
  /// outbox commands.
  final String tenantUrl;

  /// Device API key generated at "Integrations → Zalo cá nhân → Thêm thiết bị"
  /// on the Campaio web UI. Stored locally only.
  final String deviceApiKey;

  /// When false, integration_bridge.js is NOT injected — the app behaves
  /// exactly like the original safety-scoped version (no scraping, no
  /// outbox polling).
  final bool bridgeEnabled;

  AppSettings copyWith({
    ThemeMode? themeMode,
    String? tenantUrl,
    String? deviceApiKey,
    bool? bridgeEnabled,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      tenantUrl: tenantUrl ?? this.tenantUrl,
      deviceApiKey: deviceApiKey ?? this.deviceApiKey,
      bridgeEnabled: bridgeEnabled ?? this.bridgeEnabled,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'themeMode': themeMode.name,
      'tenantUrl': tenantUrl,
      'deviceApiKey': deviceApiKey,
      'bridgeEnabled': bridgeEnabled,
    };
  }

  factory AppSettings.fromJson(Map<dynamic, dynamic>? json) {
    final themeName = json?['themeMode'] as String?;
    return AppSettings(
      themeMode: ThemeMode.values.firstWhere(
        (mode) => mode.name == themeName,
        orElse: () => ThemeMode.system,
      ),
      tenantUrl: (json?['tenantUrl'] as String?)?.trim() ?? '',
      deviceApiKey: (json?['deviceApiKey'] as String?)?.trim() ?? '',
      bridgeEnabled: (json?['bridgeEnabled'] as bool?) ?? false,
    );
  }
}
