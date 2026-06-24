import 'package:flutter/material.dart';

import '../models/account_profile.dart';

class StatusBadge extends StatelessWidget {
  const StatusBadge({
    required this.status,
    super.key,
  });

  final AccountStatus status;

  @override
  Widget build(BuildContext context) {
    final palette = switch (status) {
      AccountStatus.active => const _BadgePalette(
          background: Color(0xFFDFF7E8),
          foreground: Color(0xFF166534),
        ),
      AccountStatus.needsLogin => const _BadgePalette(
          background: Color(0xFFFFF2D8),
          foreground: Color(0xFF9A6700),
        ),
      AccountStatus.checking => const _BadgePalette(
          background: Color(0xFFDDEBFF),
          foreground: Color(0xFF1D4ED8),
        ),
      AccountStatus.error => const _BadgePalette(
          background: Color(0xFFFDE2E2),
          foreground: Color(0xFFB42318),
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: palette.background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status.label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: palette.foreground,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class _BadgePalette {
  const _BadgePalette({
    required this.background,
    required this.foreground,
  });

  final Color background;
  final Color foreground;
}
