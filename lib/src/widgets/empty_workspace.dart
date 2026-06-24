import 'package:flutter/material.dart';

class EmptyWorkspace extends StatelessWidget {
  const EmptyWorkspace({
    required this.onAddAccount,
    super.key,
  });

  final VoidCallback onAddAccount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: <Color>[Color(0xFF2563EB), Color(0xFF38BDF8)],
                    ),
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: const Icon(
                    Icons.account_tree_outlined,
                    color: Colors.white,
                    size: 36,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Chưa có tài khoản nào',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                Text(
                  'Bấm Thêm tài khoản để tạo browser profile riêng và đăng nhập Zalo thủ công.',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: onAddAccount,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Thêm tài khoản'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
