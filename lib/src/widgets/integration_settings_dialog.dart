import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/app_settings.dart';

/// Dialog for entering / updating the Campaio tenant URL + device API key +
/// bridge toggle. Designed so the user can always see and edit the values —
/// previous version used obscureText:true on the API key field which made it
/// look read-only when a value was already present.
class IntegrationSettingsDialog extends StatefulWidget {
  const IntegrationSettingsDialog({
    super.key,
    required this.initial,
    required this.onSave,
  });

  final AppSettings initial;
  final Future<void> Function({
    required String tenantUrl,
    required String deviceApiKey,
    required bool bridgeEnabled,
  }) onSave;

  @override
  State<IntegrationSettingsDialog> createState() => _IntegrationSettingsDialogState();
}

class _IntegrationSettingsDialogState extends State<IntegrationSettingsDialog> {
  late final TextEditingController _tenantCtrl;
  late final TextEditingController _apiKeyCtrl;
  // FocusNodes are required to wrest keyboard focus away from the embedded
  // webview_cef NSView. Without them CEF keeps eating keystrokes even when
  // the AlertDialog is rendered on top, and the input fields look frozen.
  final FocusNode _tenantFocus = FocusNode(debugLabel: 'tenantUrl');
  final FocusNode _apiKeyFocus = FocusNode(debugLabel: 'apiKey');
  late bool _bridgeEnabled;
  bool _busy = false;
  bool _showKey = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tenantCtrl = TextEditingController(text: widget.initial.tenantUrl);
    _apiKeyCtrl = TextEditingController(text: widget.initial.deviceApiKey);
    _bridgeEnabled = widget.initial.bridgeEnabled;
    // Forcefully grab keyboard focus shortly after the dialog renders.
    // Multiple delayed requests in case the first one fires before the CEF
    // view fully released focus.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _grabFocus(_tenantFocus);
    });
    Future.delayed(const Duration(milliseconds: 200), () { if (mounted) _grabFocus(_tenantFocus); });
    Future.delayed(const Duration(milliseconds: 600), () { if (mounted) _grabFocus(_tenantFocus); });
  }

  void _grabFocus(FocusNode node) {
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    FocusScope.of(context).requestFocus(node);
  }

  @override
  void dispose() {
    _tenantCtrl.dispose();
    _apiKeyCtrl.dispose();
    _tenantFocus.dispose();
    _apiKeyFocus.dispose();
    super.dispose();
  }

  Future<void> _pasteKey() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final pasted = data?.text?.trim();
    if (pasted == null || pasted.isEmpty) return;
    setState(() {
      _apiKeyCtrl.text = pasted;
      // Show the key briefly so the user can verify the paste landed.
      _showKey = true;
    });
  }

  void _clearKey() {
    setState(() {
      _apiKeyCtrl.clear();
      _showKey = true;
    });
  }

  Future<void> _handleSave() async {
    final tenant = _tenantCtrl.text.trim();
    final key = _apiKeyCtrl.text.trim();
    if (_bridgeEnabled && (tenant.isEmpty || key.isEmpty)) {
      setState(() => _error = 'Bật bridge cần cả tenant URL và API key.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSave(
        tenantUrl: tenant,
        deviceApiKey: key,
        bridgeEnabled: _bridgeEnabled,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasSavedKey = widget.initial.deviceApiKey.isNotEmpty;
    final savedPrefix = hasSavedKey
        ? widget.initial.deviceApiKey.length > 8
            ? '${widget.initial.deviceApiKey.substring(0, 8)}…'
            : widget.initial.deviceApiKey
        : null;

    return AlertDialog(
      title: const Text('Kết nối Campaio'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 460, maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Đồng bộ contact/hội thoại Zalo cá nhân về tenant Campaio và nhận message từ web để gửi qua compose box. Bật tính năng này nếu bạn chấp nhận rủi ro chính sách Zalo.',
              style: TextStyle(fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _tenantCtrl,
              focusNode: _tenantFocus,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Tenant URL',
                hintText: 'https://yourtenant.chatplus.io.vn',
                border: OutlineInputBorder(),
              ),
              enabled: !_busy,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              onTap: () => _grabFocus(_tenantFocus),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _apiKeyCtrl,
              decoration: InputDecoration(
                labelText: 'Device API key',
                hintText: 'zpd_...',
                border: const OutlineInputBorder(),
                helperText: hasSavedKey
                    ? 'Đang lưu: $savedPrefix · sửa hoặc paste key mới rồi bấm Lưu.'
                    : 'Tạo tại Campaio web → Tích hợp → Zalo cá nhân (key chỉ hiện 1 lần)',
                helperMaxLines: 2,
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: _showKey ? 'Ẩn key' : 'Hiện key',
                      iconSize: 18,
                      onPressed: _busy ? null : () => setState(() => _showKey = !_showKey),
                      icon: Icon(_showKey ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                    ),
                    IconButton(
                      tooltip: 'Paste key từ clipboard',
                      iconSize: 18,
                      onPressed: _busy ? null : _pasteKey,
                      icon: const Icon(Icons.content_paste_rounded),
                    ),
                    IconButton(
                      tooltip: 'Xoá key',
                      iconSize: 18,
                      onPressed: _busy || _apiKeyCtrl.text.isEmpty ? null : _clearKey,
                      icon: const Icon(Icons.clear),
                    ),
                  ],
                ),
              ),
              enabled: !_busy,
              obscureText: !_showKey,
              autocorrect: false,
              enableSuggestions: false,
              focusNode: _apiKeyFocus,
              onChanged: (_) => setState(() {}), // refresh suffix icon enabled state
              onTap: () => _grabFocus(_apiKeyFocus),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Bật bridge'),
              subtitle: const Text(
                'Khi bật, app sẽ tự inject script đồng bộ contact + poll outbox mỗi khi mở chat.zalo.me.',
              ),
              value: _bridgeEnabled,
              onChanged: _busy ? null : (v) => setState(() => _bridgeEnabled = v),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12.5)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Huỷ'),
        ),
        FilledButton(
          onPressed: _busy ? null : _handleSave,
          child: Text(_busy ? 'Đang lưu...' : 'Lưu'),
        ),
      ],
    );
  }
}
