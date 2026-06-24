import 'package:flutter/material.dart';

class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
  });

  final ThemeMode themeMode;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'themeMode': themeMode.name,
    };
  }

  factory AppSettings.fromJson(Map<dynamic, dynamic>? json) {
    final themeName = json?['themeMode'] as String?;
    return AppSettings(
      themeMode: ThemeMode.values.firstWhere(
        (mode) => mode.name == themeName,
        orElse: () => ThemeMode.system,
      ),
    );
  }
}
