import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../controllers/workspace_controller.dart';
import '../services/app_bootstrap.dart';

final appBootstrapProvider = Provider<AppBootstrap>((ref) {
  throw UnimplementedError('AppBootstrap override is required.');
});

final workspaceControllerProvider = Provider<WorkspaceController>((ref) {
  final bootstrap = ref.watch(appBootstrapProvider);
  final controller = WorkspaceController(
    accountRepository: bootstrap.accountRepository,
    browserProfileRepository: bootstrap.browserProfileRepository,
    settingsRepository: bootstrap.settingsRepository,
    browserEngine: bootstrap.browserEngine,
    zaloDomExtractor: bootstrap.zaloDomExtractor,
    logger: bootstrap.loggingService,
  );
  ref.onDispose(controller.dispose);
  return controller;
});
