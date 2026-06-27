import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app.dart';
import 'src/providers/app_providers.dart';
import 'src/services/app_bootstrap.dart';

Future<void> main() async {
  // Guard the whole app: any async error that escapes the framework is logged
  // and swallowed instead of terminating the desktop process. Without this an
  // unawaited Future that throws (e.g. a transient browser-engine error) can
  // quietly take the whole app down.
  await runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // window_manager phải init trước khi raise/focus cửa sổ từ Dart (macOS+Windows).
    await windowManager.ensureInitialized();

    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      if (kDebugMode) {
        debugPrint('[ZTC][FlutterError] ${details.exceptionAsString()}');
      }
    };

    final bootstrap = await AppBootstrap.initialize();

    runApp(
      ProviderScope(
        overrides: [
          appBootstrapProvider.overrideWithValue(bootstrap),
        ],
        child: const ZaloAccountWorkspaceApp(),
      ),
    );
  }, (error, stackTrace) {
    debugPrint('[ZTC][unhandled] $error\n$stackTrace');
  });
}
