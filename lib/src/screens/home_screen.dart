import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../browser/browser_session.dart';
import '../config/app_config.dart';
import '../controllers/workspace_controller.dart';
import '../models/account_profile.dart';
import '../providers/app_providers.dart';
import '../widgets/account_sidebar.dart';
import '../widgets/empty_workspace.dart';
import '../widgets/integration_settings_dialog.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(workspaceControllerProvider);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.isInitializing && !controller.isInitialized) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            final sidebarWidth =
                constraints.maxWidth < 980 ? 230.0 : AppConfig.sidebarWidth;
            final selectedAccount = controller.selectedAccount;
            final activeSession = controller.activeSession;

            return Scaffold(
              backgroundColor: const Color(0xFFF1F5F9),
              body: Stack(
                children: <Widget>[
                  SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Row(
                        children: <Widget>[
                          SizedBox(
                            width: sidebarWidth,
                            child: AccountSidebar(
                              accounts: controller.accounts,
                              selectedAccountId: controller.selectedAccountId,
                              isCreatingAccount: controller.isCreatingAccount,
                              themeMode: controller.themeMode,
                              onAddAccount: () => controller.addAccount(),
                              onToggleTheme: () => controller.toggleThemeMode(),
                              onSelectAccount: (accountId) =>
                                  controller.selectAccount(accountId),
                              onMenuAction: (account, action) =>
                                  _handleAccountAction(
                                context,
                                controller,
                                account,
                                action,
                              ),
                              onOpenIntegrationSettings: () => _openIntegrationSettings(context, controller),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: selectedAccount == null
                                ? EmptyWorkspace(
                                    onAddAccount: () => controller.addAccount(),
                                  )
                                : _BrowserStage(
                                    session: activeSession,
                                    isBooting: controller
                                        .isSessionBooting(selectedAccount.id),
                                    lastError: controller.lastError,
                                    onDismissError: controller.clearError,
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (controller.popupSession != null)
                    _PopupWindow(
                      session: controller.popupSession!,
                      title: controller.popupTitle,
                      onClose: () => controller.closePopup(),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _handleAccountAction(
    BuildContext context,
    WorkspaceController controller,
    AccountProfile account,
    AccountMenuAction action,
  ) async {
    switch (action) {
      case AccountMenuAction.rename:
        final renamed = await _showRenameDialog(context, account);
        if (renamed != null) {
          await controller.renameAccount(account.id, renamed);
        }
        break;
      case AccountMenuAction.checkSession:
        await controller.checkSession(account.id, reloadFirst: true);
        break;
      case AccountMenuAction.reload:
        await controller.reloadSession(account.id);
        break;
      case AccountMenuAction.resetSession:
        final confirmed = await _confirm(
          context,
          title: 'Đăng xuất tài khoản?',
          message:
              'Phiên đăng nhập cục bộ sẽ bị xóa. Tên và avatar đã lưu vẫn được giữ. Bạn sẽ cần quét lại QR.',
          confirmLabel: 'Đăng xuất',
        );
        if (confirmed) {
          await controller.resetSession(account.id);
        }
        break;
      case AccountMenuAction.deleteProfile:
        final confirmed = await _confirm(
          context,
          title: 'Xóa tài khoản này?',
          message:
              'Toàn bộ dữ liệu profile (cookies, lịch sử, tên & avatar đã lưu) sẽ bị xóa vĩnh viễn.',
          confirmLabel: 'Xóa',
          destructive: true,
        );
        if (confirmed) {
          await controller.deleteAccount(account.id);
        }
        break;
    }
  }

  Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String message,
    required String confirmLabel,
    bool destructive = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          title: Text(title),
          content: Text(message),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Hủy'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor:
                    destructive ? const Color(0xFFB42318) : null,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );

    return result ?? false;
  }

  Future<void> _openIntegrationSettings(BuildContext context, WorkspaceController controller) async {
    // Tell every embedded CEF browser to drop keyboard focus first; without
    // this the AlertDialog's TextFields look frozen because Chromium NSViews
    // keep eating the keystrokes via the macOS responder chain.
    await controller.setBrowsersKeyboardFocus(false);
    if (!context.mounted) return;
    try {
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          return IntegrationSettingsDialog(
            initial: controller.appSettings,
            onSave: ({required String tenantUrl, required String deviceApiKey, required bool bridgeEnabled}) async {
              await controller.updateIntegrationSettings(
                tenantUrl: tenantUrl,
                deviceApiKey: deviceApiKey,
                bridgeEnabled: bridgeEnabled,
              );
            },
          );
        },
      );
    } finally {
      // Give keyboard focus back to whichever browser the user was viewing
      // so chat input keeps working as before.
      await controller.setBrowsersKeyboardFocus(true);
    }
  }

  Future<String?> _showRenameDialog(
    BuildContext context,
    AccountProfile account,
  ) async {
    final textController = TextEditingController(
      text: account.displayName ?? account.accountName ?? account.effectiveTitle,
    );

    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          title: const Text('Đổi tên hiển thị'),
          content: TextField(
            controller: textController,
            decoration: const InputDecoration(
              labelText: 'Tên hiển thị',
              hintText: 'Nhập tên bạn muốn hiển thị trong sidebar',
            ),
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Hủy'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () => Navigator.of(context).pop(textController.text),
              child: const Text('Lưu'),
            ),
          ],
        );
      },
    );

    textController.dispose();
    return result;
  }
}

class _PopupWindow extends StatelessWidget {
  const _PopupWindow({
    required this.session,
    required this.title,
    required this.onClose,
  });

  final BrowserSession session;
  final String? title;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.45),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000, maxHeight: 760),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Material(
                elevation: 12,
                borderRadius: BorderRadius.circular(10),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: <Widget>[
                    Container(
                      color: theme.colorScheme.surfaceContainerHighest,
                      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
                      child: Row(
                        children: <Widget>[
                          const Icon(Icons.open_in_new_rounded, size: 16),
                          const SizedBox(width: 10),
                          Expanded(
                            child: ValueListenableBuilder<String>(
                              valueListenable: session.currentUrlListenable,
                              builder: (context, url, _) {
                                return Text(
                                  url.isEmpty ? (title ?? 'Cửa sổ mới') : url,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall,
                                );
                              },
                            ),
                          ),
                          IconButton(
                            tooltip: 'Đóng',
                            iconSize: 18,
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.close_rounded),
                            onPressed: onClose,
                          ),
                        ],
                      ),
                    ),
                    Expanded(child: session.view),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BrowserStage extends StatelessWidget {
  const _BrowserStage({
    required this.session,
    required this.isBooting,
    required this.lastError,
    required this.onDismissError,
  });

  final BrowserSession? session;
  final bool isBooting;
  final String? lastError;
  final VoidCallback onDismissError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: <Widget>[
        if (lastError != null) ...<Widget>[
          Material(
            color: const Color(0xFFFEE4E2),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: <Widget>[
                  const Icon(
                    Icons.error_outline_rounded,
                    color: Color(0xFFB42318),
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      lastError!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF7A271A),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: onDismissError,
                    child: const Text('Ẩn'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        Expanded(
          child: Material(
            borderRadius: BorderRadius.circular(10),
            clipBehavior: Clip.antiAlias,
            color: theme.colorScheme.surface,
            child: session == null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        if (isBooting)
                          const CircularProgressIndicator()
                        else
                          const Icon(
                            Icons.web_asset_off_outlined,
                            size: 40,
                            color: Color(0xFF94A3B8),
                          ),
                        const SizedBox(height: 12),
                        Text(
                          isBooting
                              ? 'Đang khởi tạo phiên...'
                              : 'Chưa có phiên nào.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  )
                : session!.view,
          ),
        ),
      ],
    );
  }
}
