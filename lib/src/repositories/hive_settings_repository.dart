import 'package:hive/hive.dart';

import '../models/app_settings.dart';
import 'settings_repository.dart';

class HiveSettingsRepository implements SettingsRepository {
  HiveSettingsRepository(this._box);

  static const String _settingsKey = 'app-settings';

  final Box<dynamic> _box;

  @override
  Future<void> close() => _box.close();

  @override
  Future<AppSettings> load() async {
    final raw = _box.get(_settingsKey);
    if (raw is Map) {
      return AppSettings.fromJson(raw);
    }

    return const AppSettings();
  }

  @override
  Future<void> save(AppSettings settings) => _box.put(_settingsKey, settings.toJson());
}
