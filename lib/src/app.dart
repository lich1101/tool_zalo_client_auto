import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'config/app_config.dart';
import 'config/app_theme.dart';
import 'providers/app_providers.dart';
import 'screens/home_screen.dart';

class ZaloAccountWorkspaceApp extends ConsumerStatefulWidget {
  const ZaloAccountWorkspaceApp({super.key});

  @override
  ConsumerState<ZaloAccountWorkspaceApp> createState() =>
      _ZaloAccountWorkspaceAppState();
}

class _ZaloAccountWorkspaceAppState
    extends ConsumerState<ZaloAccountWorkspaceApp> {
  @override
  void initState() {
    super.initState();
    Future<void>.microtask(
      () => ref.read(workspaceControllerProvider).initialize(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(workspaceControllerProvider);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return MaterialApp(
          title: AppConfig.appName,
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: controller.themeMode,
          home: const HomeScreen(),
        );
      },
    );
  }
}
