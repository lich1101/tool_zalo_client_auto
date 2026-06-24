import 'dart:io';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../browser/browser_engine.dart';
import '../browser/webview_cef_browser_engine.dart';
import '../config/app_config.dart';
import '../repositories/account_repository.dart';
import '../repositories/browser_profile_repository.dart';
import '../repositories/file_system_browser_profile_repository.dart';
import '../repositories/hive_account_repository.dart';
import '../repositories/hive_settings_repository.dart';
import '../repositories/settings_repository.dart';
import 'logging_service.dart';
import 'zalo_dom_extractor.dart';

class AppBootstrap {
  AppBootstrap({
    required this.appDataDirectory,
    required this.accountRepository,
    required this.browserProfileRepository,
    required this.settingsRepository,
    required this.browserEngine,
    required this.loggingService,
    required this.zaloDomExtractor,
  });

  final Directory appDataDirectory;
  final AccountRepository accountRepository;
  final BrowserProfileRepository browserProfileRepository;
  final SettingsRepository settingsRepository;
  final BrowserEngine browserEngine;
  final LoggingService loggingService;
  final ZaloDomExtractor zaloDomExtractor;

  static Future<AppBootstrap> initialize() async {
    final logger = LoggingService();
    final appDirectory = await _resolveAppDirectory();
    await appDirectory.create(recursive: true);

    final hiveDirectory = Directory(path.join(appDirectory.path, 'hive'));
    await Hive.initFlutter(hiveDirectory.path);

    final accountBox = await Hive.openBox<dynamic>('accounts');
    final settingsBox = await Hive.openBox<dynamic>('settings');

    final accountRepository = HiveAccountRepository(accountBox);
    final settingsRepository = HiveSettingsRepository(settingsBox);
    final profileRepository =
        FileSystemBrowserProfileRepository(appDirectory, logger);
    await profileRepository.ensureRoot();

    logger.info(
      'Initialized application storage.',
      metadata: <String, Object?>{'root': appDirectory.path},
    );

    return AppBootstrap(
      appDataDirectory: appDirectory,
      accountRepository: accountRepository,
      browserProfileRepository: profileRepository,
      settingsRepository: settingsRepository,
      browserEngine: WebviewCefBrowserEngine(
        logger,
        rootCachePath: path.join(appDirectory.path, 'profiles'),
      ),
      loggingService: logger,
      zaloDomExtractor: ZaloDomExtractor(),
    );
  }

  static Future<Directory> _resolveAppDirectory() async {
    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) {
        return Directory(
          path.join(home, 'Library', 'Application Support', AppConfig.storageFolderName),
        );
      }
    }

    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData != null && appData.isNotEmpty) {
        return Directory(path.join(appData, AppConfig.storageFolderName));
      }
    }

    final fallback = await getApplicationSupportDirectory();
    return Directory(path.join(fallback.path, AppConfig.storageFolderName));
  }
}
