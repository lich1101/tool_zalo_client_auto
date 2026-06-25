import 'dart:async';

import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../models/account_profile.dart';
import 'app_logo.dart';
import 'status_badge.dart';

enum AccountMenuAction {
  rename,
  checkSession,
  reload,
  resetSession,
  deleteProfile,
}

class AccountSidebar extends StatelessWidget {
  const AccountSidebar({
    required this.accounts,
    required this.selectedAccountId,
    required this.isCreatingAccount,
    required this.themeMode,
    required this.onAddAccount,
    required this.onToggleTheme,
    required this.onSelectAccount,
    required this.onMenuAction,
    this.onOpenIntegrationSettings,
    super.key,
  });

  final List<AccountProfile> accounts;
  final String? selectedAccountId;
  final bool isCreatingAccount;
  final ThemeMode themeMode;
  final VoidCallback onAddAccount;
  final VoidCallback onToggleTheme;
  final ValueChanged<String> onSelectAccount;
  final Future<void> Function(AccountProfile, AccountMenuAction) onMenuAction;
  final VoidCallback? onOpenIntegrationSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(10),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 16, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const AppLogo(size: 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    AppConfig.appName,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (onOpenIntegrationSettings != null)
                  IconButton(
                    tooltip: 'Kết nối Campaio',
                    iconSize: 18,
                    visualDensity: VisualDensity.compact,
                    onPressed: onOpenIntegrationSettings,
                    icon: const Icon(Icons.link_rounded),
                  ),
                IconButton(
                  tooltip: themeMode == ThemeMode.dark
                      ? 'Chuyển sang light mode'
                      : 'Chuyển sang dark mode',
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  onPressed: onToggleTheme,
                  icon: Icon(
                    themeMode == ThemeMode.dark
                        ? Icons.light_mode_outlined
                        : Icons.dark_mode_outlined,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: isCreatingAccount ? null : onAddAccount,
                icon: isCreatingAccount
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_rounded, size: 18),
                label: const Text('Thêm tài khoản'),
              ),
            ),
            const SizedBox(height: 16),
            if (accounts.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Chưa có tài khoản nào.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.separated(
                  itemCount: accounts.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final account = accounts[index];
                    final isSelected = account.id == selectedAccountId;
                    return _AccountRow(
                      account: account,
                      isSelected: isSelected,
                      onTap: () => onSelectAccount(account.id),
                      onMenuAction: (action) {
                        unawaited(onMenuAction(account, action));
                      },
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AccountRow extends StatelessWidget {
  const _AccountRow({
    required this.account,
    required this.isSelected,
    required this.onTap,
    required this.onMenuAction,
  });

  final AccountProfile account;
  final bool isSelected;
  final VoidCallback onTap;
  final ValueChanged<AccountMenuAction> onMenuAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = account.effectiveTitle;
    final initials =
        title.isEmpty ? 'Z' : title.trim().substring(0, 1).toUpperCase();

    return Material(
      color: isSelected
          ? const Color(0xFFEFF6FF)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            border: Border.all(
              color: isSelected
                  ? const Color(0xFFBFDBFE)
                  : theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: <Widget>[
              CircleAvatar(
                radius: 16,
                backgroundColor: const Color(0xFFDBEAFE),
                backgroundImage: account.avatarUrl != null
                    ? NetworkImage(account.avatarUrl!)
                    : null,
                child: account.avatarUrl == null
                    ? Text(
                        initials,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF1D4ED8),
                          fontWeight: FontWeight.w700,
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    StatusBadge(status: account.status),
                  ],
                ),
              ),
              _MenuButton(onSelected: onMenuAction),
            ],
          ),
        ),
      ),
    );
  }
}

class _MenuButton extends StatelessWidget {
  const _MenuButton({required this.onSelected});

  final ValueChanged<AccountMenuAction> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<AccountMenuAction>(
      tooltip: 'Tùy chọn',
      iconSize: 18,
      padding: EdgeInsets.zero,
      onSelected: onSelected,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      itemBuilder: (context) {
        return const <PopupMenuEntry<AccountMenuAction>>[
          PopupMenuItem(
            value: AccountMenuAction.rename,
            child: Text('Đổi tên'),
          ),
          PopupMenuItem(
            value: AccountMenuAction.checkSession,
            child: Text('Kiểm tra phiên'),
          ),
          PopupMenuItem(
            value: AccountMenuAction.reload,
            child: Text('Tải lại'),
          ),
          PopupMenuItem(
            value: AccountMenuAction.resetSession,
            child: Text('Đăng xuất'),
          ),
          PopupMenuDivider(),
          PopupMenuItem(
            value: AccountMenuAction.deleteProfile,
            child: Text('Xóa tài khoản', style: TextStyle(color: Color(0xFFB42318))),
          ),
        ];
      },
    );
  }
}
