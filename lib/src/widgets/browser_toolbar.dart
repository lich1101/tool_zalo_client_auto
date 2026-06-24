import 'package:flutter/material.dart';

import '../browser/browser_session.dart';
import '../models/account_profile.dart';
import 'status_badge.dart';

class BrowserToolbar extends StatelessWidget {
  const BrowserToolbar({
    required this.account,
    required this.session,
    required this.isChecking,
    required this.onBack,
    required this.onForward,
    required this.onReload,
    required this.onHome,
    required this.onCheckSession,
    super.key,
  });

  final AccountProfile account;
  final BrowserSession? session;
  final bool isChecking;
  final VoidCallback onBack;
  final VoidCallback onForward;
  final VoidCallback onReload;
  final VoidCallback onHome;
  final VoidCallback onCheckSession;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                _AvatarPreview(avatarUrl: account.avatarUrl, title: account.effectiveTitle),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        account.effectiveTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        account.profilePath,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                StatusBadge(status: account.status),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                _ToolbarButton(
                  icon: Icons.arrow_back_rounded,
                  label: 'Back',
                  onPressed: onBack,
                ),
                _ToolbarButton(
                  icon: Icons.arrow_forward_rounded,
                  label: 'Forward',
                  onPressed: onForward,
                ),
                _ToolbarButton(
                  icon: Icons.refresh_rounded,
                  label: 'Reload',
                  onPressed: onReload,
                ),
                _ToolbarButton(
                  icon: Icons.home_rounded,
                  label: 'Home',
                  onPressed: onHome,
                ),
                FilledButton.icon(
                  onPressed: onCheckSession,
                  icon: isChecking
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.verified_user_outlined),
                  label: const Text('Check session'),
                ),
                SizedBox(
                  width: 420,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: theme.dividerColor),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            Icons.link_rounded,
                            size: 18,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: session == null
                                ? Text(
                                    'Đang khởi tạo browser profile...',
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  )
                                : ValueListenableBuilder<String>(
                                    valueListenable: session!.currentUrlListenable,
                                    builder: (context, url, _) {
                                      final text = url.isEmpty
                                          ? 'https://id.zalo.me/account'
                                          : url;
                                      return Text(
                                        text,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodyMedium,
                                      );
                                    },
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AvatarPreview extends StatelessWidget {
  const _AvatarPreview({
    required this.avatarUrl,
    required this.title,
  });

  final String? avatarUrl;
  final String title;

  @override
  Widget build(BuildContext context) {
    final trimmed = title.trim();
    final initials = trimmed.isEmpty ? 'Z' : trimmed.substring(0, 1).toUpperCase();
    return CircleAvatar(
      radius: 24,
      backgroundColor: const Color(0xFFDBEAFE),
      backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl!) : null,
      child: avatarUrl == null
          ? Text(
              initials,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: const Color(0xFF1D4ED8),
                    fontWeight: FontWeight.w800,
                  ),
            )
          : null,
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
    );
  }
}
