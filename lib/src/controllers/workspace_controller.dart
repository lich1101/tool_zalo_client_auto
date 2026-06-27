import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../browser/browser_engine.dart';
import '../browser/browser_session.dart';
import '../config/app_config.dart';
import '../models/account_profile.dart';
import '../models/app_settings.dart';
import '../repositories/account_repository.dart';
import '../repositories/browser_profile_repository.dart';
import '../repositories/settings_repository.dart';
import '../services/bridge_injector.dart';
import '../services/local_bridge_server.dart';
import '../services/logging_service.dart';
import '../services/outbox_poller.dart';
import '../services/task_poller.dart';
import '../services/window_activation_service.dart';
import '../services/zalo_dom_extractor.dart';

class WorkspaceController extends ChangeNotifier {
  WorkspaceController({
    required AccountRepository accountRepository,
    required BrowserProfileRepository browserProfileRepository,
    required SettingsRepository settingsRepository,
    required BrowserEngine browserEngine,
    required ZaloDomExtractor zaloDomExtractor,
    required LoggingService logger,
  }) : _accountRepository = accountRepository,
       _browserProfileRepository = browserProfileRepository,
       _settingsRepository = settingsRepository,
       _browserEngine = browserEngine,
       _zaloDomExtractor = zaloDomExtractor,
       _logger = logger;

  final AccountRepository _accountRepository;
  final BrowserProfileRepository _browserProfileRepository;
  final SettingsRepository _settingsRepository;
  final BrowserEngine _browserEngine;
  final ZaloDomExtractor _zaloDomExtractor;
  final LoggingService _logger;
  final Uuid _uuid = const Uuid();
  final Map<String, BrowserSession> _sessions = <String, BrowserSession>{};
  final Map<String, Timer> _scheduledInspections = <String, Timer>{};
  final Set<String> _bootingSessions = <String>{};
  final Set<String> _inspectingSessions = <String>{};
  final Set<String> _backgroundWarmSessions = <String>{};

  List<AccountProfile> _accounts = <AccountProfile>[];
  AppSettings _appSettings = const AppSettings();
  ThemeMode _themeMode = ThemeMode.system;
  late final BridgeInjector _bridgeInjector = BridgeInjector(_logger);
  late final OutboxPoller _outboxPoller = OutboxPoller(_logger);
  late final TaskPoller _taskPoller = TaskPoller(_logger);
  late final LocalBridgeServer _localBridgeServer = LocalBridgeServer(_logger);
  final WindowActivationService _windowActivation = WindowActivationService();
  String? _selectedAccountId;
  BrowserSession? _popupSession;
  String? _popupSessionKey;
  String? _popupTitle;
  bool _isOpeningPopup = false;
  String? _lastError;
  bool _isInitializing = false;
  bool _isInitialized = false;
  bool _isCreatingAccount = false;
  bool _disposed = false;

  List<AccountProfile> get accounts =>
      List<AccountProfile>.unmodifiable(_accounts);

  BrowserSession? get activeSession =>
      _selectedAccountId == null ? null : _sessions[_selectedAccountId!];

  bool get isCreatingAccount => _isCreatingAccount;

  /// Active in-app popup window (window.open / new tab), or null when none.
  BrowserSession? get popupSession => _popupSession;

  String? get popupTitle => _popupTitle;

  bool get isOpeningPopup => _isOpeningPopup;

  bool get isInitialized => _isInitialized;

  bool get isInitializing => _isInitializing;

  String? get lastError => _lastError;

  AccountProfile? get selectedAccount =>
      _selectedAccountId == null ? null : _accountById(_selectedAccountId!);

  String? get selectedAccountId => _selectedAccountId;

  ThemeMode get themeMode => _themeMode;

  void clearError() {
    _lastError = null;
    _notifySafely();
  }

  Future<void> addAccount() async {
    if (_isCreatingAccount) {
      return;
    }

    _isCreatingAccount = true;
    _notifySafely();

    try {
      final accountId = _uuid.v4();
      final profilePath = await _browserProfileRepository
          .createProfileDirectory(accountId);
      final now = DateTime.now();
      final profile = AccountProfile(
        id: accountId,
        profilePath: profilePath,
        status: AccountStatus.checking,
        createdAt: now,
        updatedAt: now,
      );

      // Append: the list is sorted by createdAt (oldest first), so a new
      // account belongs at the end. Adding to the head would only get
      // re-sorted on the next status update anyway.
      _accounts = <AccountProfile>[..._accounts, profile];
      _selectedAccountId = accountId;
      await _accountRepository.put(profile);
      _notifySafely();
      _maybePushAccountList();
      _refreshOutboxPoller();

      await _ensureSession(accountId);
    } catch (error, stackTrace) {
      _reportError(
        'Không thể tạo profile mới.',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _isCreatingAccount = false;
      _notifySafely();
    }
  }

  Future<void> checkSelectedSession() async {
    final selected = selectedAccount;
    if (selected == null) {
      return;
    }

    await checkSession(selected.id, reloadFirst: true);
  }

  Future<void> checkSession(
    String accountId, {
    bool reloadFirst = true,
    bool ignoreCooldown = false,
  }) async {
    final account = _accountById(accountId);
    if (account == null) {
      return;
    }

    if (!ignoreCooldown && account.lastCheckedAt != null) {
      final elapsed = DateTime.now().difference(account.lastCheckedAt!);
      if (elapsed < AppConfig.manualCheckCooldown) {
        _scheduleInspection(
          accountId,
          delay: AppConfig.manualCheckCooldown - elapsed,
        );
        return;
      }
    }

    await _updateAccount(
      account.copyWith(
        status: AccountStatus.checking,
        updatedAt: DateTime.now(),
        lastError: null,
      ),
    );

    final session = await _ensureSession(accountId);
    if (session == null) {
      return;
    }

    if (reloadFirst) {
      try {
        await session.reload();
      } catch (error, stackTrace) {
        _reportError(
          'Không thể reload WebView hiện tại.',
          error: error,
          stackTrace: stackTrace,
        );
        await _markSessionError(accountId);
      }
      return;
    }

    _scheduleInspection(accountId, delay: const Duration(milliseconds: 100));
  }

  @override
  void dispose() {
    _disposed = true;
    _outboxPoller.stop();
    _taskPoller.stop();
    unawaited(_localBridgeServer.stop());
    for (final timer in _scheduledInspections.values) {
      timer.cancel();
    }

    for (final session in _sessions.values) {
      unawaited(session.dispose());
    }

    unawaited(_browserEngine.shutdown());
    unawaited(_accountRepository.close());
    unawaited(_settingsRepository.close());
    super.dispose();
  }

  Future<void> goBack() async {
    await activeSession?.goBack();
  }

  Future<void> goForward() async {
    await activeSession?.goForward();
  }

  Future<void> goHome() async {
    await activeSession?.loadUrl(AppConfig.zaloAccountUrl);
  }

  Future<void> initialize() async {
    if (_isInitializing || _isInitialized) {
      return;
    }

    _isInitializing = true;
    _notifySafely();

    // Start the loopback bridge so the extension / Campaio web can detect the
    // app and ask it to come to front. Independent of bridge settings — health
    // detection must work even before the user configures the tenant.
    unawaited(
      _localBridgeServer.start(
        healthProvider: _buildHealthSnapshot,
        onActivate: _activateApp,
        diagnosticsProvider: kDebugMode ? _bridgeDiagnostics : null,
        // Arbitrary JS eval is a debugging aid only — never expose it in release
        // builds (it would let any local process drive the logged-in sessions).
        evalHandler: kDebugMode ? _evalInSession : null,
      ),
    );

    // Đánh thức qua URL scheme (campaio-zalo://activate) đến từ native (macOS
    // Info.plist / Windows protocol). Cùng đổ về _activateApp như loopback bridge.
    _windowActivation.registerNativeActivationHandler(_activateApp);

    try {
      final loadedAccounts = await _accountRepository.getAll();
      // Sort by createdAt (oldest first) so the order is stable across the
      // session — sorting by updatedAt makes accounts jump up the sidebar
      // every time a status check runs, which the user perceives as flicker.
      _accounts = List<AccountProfile>.from(loadedAccounts)
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      _appSettings = await _settingsRepository.load();
      _themeMode = _appSettings.themeMode;

      if (_accounts.isNotEmpty) {
        _selectedAccountId = _accounts.first.id;
      }

      _isInitialized = true;
      _notifySafely();

      if (_selectedAccountId != null) {
        await _ensureSession(_selectedAccountId!);
      }

      // When the bridge is enabled, also boot a session for every account so
      // the Campaio Bridge JS can scrape inbound messages from every Zalo
      // account — not just the one the user happens to be viewing. Without
      // this, a customer messaging account B while the user is looking at
      // account A would be invisible to the tenant. CEF can handle many
      // sessions; the user can stop the app to free resources.
      if (_appSettings.bridgeEnabled &&
          _appSettings.tenantUrl.isNotEmpty &&
          _appSettings.deviceApiKey.isNotEmpty) {
        for (final account in _accounts) {
          if (_sessions.containsKey(account.id)) continue;
          unawaited(
            _ensureSession(
              account.id,
              backgroundWarmup: account.id != _selectedAccountId,
            ),
          );
        }
      }

      // If bridge was previously enabled, push the current account list so
      // the tenant /channels page reflects the device state even before
      // chat.zalo.me opens.
      _maybePushAccountList();
      _refreshOutboxPoller();
    } catch (error, stackTrace) {
      _reportError(
        'Không thể khởi tạo dữ liệu ứng dụng.',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _isInitializing = false;
      _notifySafely();
    }
  }

  bool isSessionBooting(String accountId) =>
      _bootingSessions.contains(accountId);

  bool isSessionChecking(String accountId) =>
      _inspectingSessions.contains(accountId) ||
      _accountById(accountId)?.status == AccountStatus.checking;

  Future<void> openDevTools(String accountId) async {
    final session = await _ensureSession(accountId);
    await session?.openDevTools();
  }

  Future<void> reloadSelectedSession() async {
    try {
      await activeSession?.reload();
    } catch (error, stackTrace) {
      _reportError(
        'Không thể reload WebView hiện tại.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> reloadSession(String accountId) async {
    final session = await _ensureSession(accountId);
    try {
      await session?.reload();
    } catch (error, stackTrace) {
      _reportError(
        'Không thể reload profile đã chọn.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> renameAccount(String accountId, String newDisplayName) async {
    final account = _accountById(accountId);
    if (account == null) {
      return;
    }

    final normalized = newDisplayName.trim();
    await _updateAccount(
      account.copyWith(
        displayName: normalized.isEmpty ? null : normalized,
        updatedAt: DateTime.now(),
      ),
    );
  }

  Future<void> resetSession(String accountId) async {
    final account = _accountById(accountId);
    if (account == null) {
      return;
    }

    try {
      await _disposeSession(accountId);
      await _browserProfileRepository.recreateProfile(account.profilePath);

      await _updateAccount(
        account.copyWith(
          status: AccountStatus.needsLogin,
          lastCheckedAt: DateTime.now(),
          lastError: null,
          updatedAt: DateTime.now(),
        ),
      );

      if (_selectedAccountId == accountId) {
        await _ensureSession(accountId, reopen: true);
      }
    } catch (error, stackTrace) {
      _reportError(
        'Không thể làm mới dữ liệu phiên cục bộ.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> selectAccount(String accountId) async {
    _selectedAccountId = accountId;
    _notifySafely();
    final account = _accountById(accountId);
    final shouldReopen =
        _backgroundWarmSessions.remove(accountId) ||
        account?.status == AccountStatus.error;
    await _ensureSession(accountId, reopen: shouldReopen);
    if (shouldReopen) {
      _scheduleInspection(accountId, delay: const Duration(seconds: 1));
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    _appSettings = _appSettings.copyWith(themeMode: mode);
    _notifySafely();
    await _settingsRepository.save(_appSettings);
  }

  AppSettings get appSettings => _appSettings;

  /// Release / restore keyboard focus on every open CEF browser session. On
  /// macOS the embedded CEF NSView captures keystrokes via the responder
  /// chain and an overlaying Flutter AlertDialog can't reclaim them. Call
  /// setBrowsersKeyboardFocus(false) right before showing a dialog and
  /// setBrowsersKeyboardFocus(true) right after it closes so the TextFields
  /// inside the dialog actually receive typing.
  Future<void> setBrowsersKeyboardFocus(bool focus) async {
    for (final session in _sessions.values) {
      try {
        await session.setKeyboardFocus(focus);
      } catch (_) {
        // Best-effort: a single session failing should not block the dialog.
      }
    }
  }

  /// Replace the integration credentials block (tenant URL, API key, bridge
  /// on/off). Re-injects the bridge into any active chat.zalo.me sessions so
  /// the new key takes effect immediately.
  Future<void> updateIntegrationSettings({
    String? tenantUrl,
    String? deviceApiKey,
    bool? bridgeEnabled,
  }) async {
    _appSettings = _appSettings.copyWith(
      tenantUrl: tenantUrl,
      deviceApiKey: deviceApiKey,
      bridgeEnabled: bridgeEnabled,
    );
    _notifySafely();
    await _settingsRepository.save(_appSettings);
    // Re-inject the bridge for every currently open session.
    for (final entry in _sessions.entries) {
      final url = entry.value.currentUrl;
      if (url.isEmpty) continue;
      await _bridgeInjector.maybeInject(
        session: entry.value,
        url: url,
        settings: _appSettings,
        profileId: entry.key,
      );
    }
    // Push account list so the /channels page can render the Zalo cá nhân
    // asset picker immediately, without waiting for chat.zalo.me to open.
    await _bridgeInjector.pushAccountList(
      settings: _appSettings,
      accounts: List<AccountProfile>.from(_accounts),
    );
    _refreshOutboxPoller();

    // If the user just enabled the bridge, boot sessions for every account
    // so background scrape covers all of them. If they just disabled it,
    // sessions stay open but the bridge no longer injects on load.
    if (_appSettings.bridgeEnabled) {
      for (final account in _accounts) {
        if (_sessions.containsKey(account.id)) continue;
        unawaited(
          _ensureSession(
            account.id,
            backgroundWarmup: account.id != _selectedAccountId,
          ),
        );
      }
    }
  }

  Future<void> toggleThemeMode() async {
    final next = switch (_themeMode) {
      ThemeMode.dark => ThemeMode.light,
      ThemeMode.light => ThemeMode.dark,
      ThemeMode.system => ThemeMode.dark,
    };

    await setThemeMode(next);
  }

  Future<void> deleteAccount(String accountId) async {
    final account = _accountById(accountId);
    if (account == null) {
      return;
    }

    try {
      // A popup may be backed by this account's profile; close it first.
      await _closePopupInternal();
      await _disposeSession(accountId);
      await _browserProfileRepository.deleteProfile(account.profilePath);
      await _accountRepository.delete(accountId);

      _accounts = _accounts.where((item) => item.id != accountId).toList();
      if (_selectedAccountId == accountId) {
        _selectedAccountId = _accounts.isEmpty ? null : _accounts.first.id;
      }
      _notifySafely();
      _maybePushAccountList();
      _refreshOutboxPoller();

      if (_selectedAccountId != null) {
        await _ensureSession(_selectedAccountId!);
      }
    } catch (error, stackTrace) {
      _reportError(
        'Không thể xóa profile đã chọn.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Start/refresh the native Dart outbox poller against the current
  /// settings + account list. Always called after settings change, after
  /// account list changes, and once at app boot.
  void _refreshOutboxPoller() {
    if (!_appSettings.bridgeEnabled ||
        _appSettings.tenantUrl.isEmpty ||
        _appSettings.deviceApiKey.isEmpty) {
      _outboxPoller.stop();
      _taskPoller.stop();
      return;
    }
    final profileIds = _accounts.map((a) => a.id).toList();
    _outboxPoller.start(
      settings: _appSettings,
      profileIds: profileIds,
      resolveSession: (profileId) => _sessions[profileId],
      prepareSession: _prepareTaskSession,
      // Piggyback the account roster push on the same poll loop so the
      // tenant /channels page reflects login changes without the user
      // re-opening the settings dialog. Fires on first tick and every
      // ~2 minutes after.
      pushAccounts:
          () => _bridgeInjector.pushAccountList(
            settings: _appSettings,
            accounts: List<AccountProfile>.from(_accounts),
          ),
    );
    // Phone-driven lookup/history/send queue runs on the same lifecycle.
    _taskPoller.start(
      settings: _appSettings,
      profileIds: profileIds,
      resolveSession: (profileId) => _sessions[profileId],
      prepareSession: _prepareTaskSession,
    );
  }

  /// Health snapshot exposed on the loopback bridge so the extension / Campaio
  /// web can show which Zalo accounts this machine has and their login state.
  Map<String, Object?> _buildHealthSnapshot() {
    return <String, Object?>{
      'bridgeEnabled': _appSettings.bridgeEnabled,
      'tenantConfigured':
          _appSettings.tenantUrl.isNotEmpty &&
          _appSettings.deviceApiKey.isNotEmpty,
      'accounts':
          _accounts
              .map(
                (a) => <String, Object?>{
                  'profileId': a.id,
                  'displayName': a.displayName ?? a.accountName,
                  'status': a.status.name,
                },
              )
              .toList(),
    };
  }

  /// Per-session bridge diagnostics, exposed on the loopback /debug endpoint so
  /// we can see (without devtools) which session has chat.zalo.me + the injected
  /// bridge. Temporary diagnostic aid for the phone-lookup flow.
  Future<List<Map<String, Object?>>> _bridgeDiagnostics() async {
    const probe = '''
JSON.stringify({
  url: location.href,
  hasConfig: !!window.__CAMPAIO__,
  hasBridge: !!window.__CAMPAIO_BRIDGE__,
  hasRunTaskAsync: !!(window.__CAMPAIO_BRIDGE__ && window.__CAMPAIO_BRIDGE__.runTaskAsync),
  module: window.__CAMPAIO_BRIDGE__ ? window.__CAMPAIO_BRIDGE__.activeModule : null,
  injectProbe: window.__CAMPAIO_INJECT_PROBE__ || 0,
  scriptLength: window.__CAMPAIO_BRIDGE_SCRIPT_LEN__ || null,
  injectResult: window.__CAMPAIO_BRIDGE_LAST_RESULT__ || null,
  lastLookupDebug: window.__CAMPAIO_LAST_LOOKUP_DEBUG__ || null,
  bridgeError: window.__CAMPAIO_BRIDGE_ERROR__ || null
})''';
    final out = <Map<String, Object?>>[];
    out.add(<String, Object?>{
      'selectedAccountId': _selectedAccountId,
      'selectedName':
          selectedAccount?.displayName ?? selectedAccount?.accountName,
      'selectedStatus': selectedAccount?.status.name,
    });
    for (final entry in _sessions.entries) {
      final account = _accountById(entry.key);
      Object? parsed;
      try {
        final raw = await entry.value.evaluateToString(probe);
        parsed = raw;
      } catch (error) {
        parsed = 'eval error: $error';
      }
      out.add(<String, Object?>{
        'profileId': entry.key,
        'name': account?.displayName ?? account?.accountName,
        'status': account?.status.name,
        'probe': parsed,
      });
    }
    return out;
  }

  /// Đánh thức app khi web/extension bấm "Mở app" (qua loopback /activate hoặc
  /// URL scheme campaio-zalo://activate). Dùng `window_manager` để raise + focus
  /// cửa sổ — chạy được trên CẢ macOS lẫn Windows (trước đây Dart thuần không
  /// raise được nên chỉ dựa vào OS, và Windows hoàn toàn không có).
  Future<void> _activateApp() async {
    _logger.info(
      '[WorkspaceController] activate requested (bring window to front).',
    );
    await _windowActivation.bringToFront();
    if (_selectedAccountId == null && _accounts.isNotEmpty) {
      await selectAccount(_accounts.first.id);
    }
  }

  /// Debug-only: evaluate [script] in [profileId]'s session (or the selected
  /// session when profileId is empty) and return the stringified result. Backs
  /// the loopback /eval endpoint used to iterate on the Zalo Web DOM.
  Future<String?> _evalInSession(String profileId, String script) async {
    final id = profileId.trim().isEmpty ? _selectedAccountId : profileId.trim();
    final session = id == null ? null : _sessions[id];
    if (session == null) return 'NO_SESSION(${id ?? '<none>'})';
    return session.evaluateToString(script);
  }

  Future<BrowserSession?> _prepareTaskSession(String profileId) async {
    final normalizedProfileId = profileId.trim();
    if (normalizedProfileId.isEmpty) {
      return null;
    }

    if (_selectedAccountId != normalizedProfileId) {
      _logger.info(
        '[WorkspaceController] task selecting profile $normalizedProfileId from ${_selectedAccountId ?? '<none>'}.',
      );
      await selectAccount(normalizedProfileId);
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    final session = await _ensureSession(normalizedProfileId);
    if (session == null) {
      return null;
    }

    if (!session.currentUrl.contains('chat.zalo.me')) {
      await session.loadUrl(AppConfig.zaloAccountUrl);
      await _waitForSessionUrl(
        session,
        (url) => url.contains('chat.zalo.me') || url.contains('id.zalo.me'),
        timeout: const Duration(seconds: 12),
      );
    }

    await _bridgeInjector.maybeInject(
      session: session,
      url:
          session.currentUrl.isEmpty
              ? AppConfig.zaloAccountUrl
              : session.currentUrl,
      settings: _appSettings,
      profileId: normalizedProfileId,
    );

    final ready = await _waitForBridgeReady(session);
    if (!ready && session.currentUrl.contains('chat.zalo.me')) {
      // Some Zalo SPA transitions do not fire a full load event. Re-inject once
      // after the DOM settles so background lookup tasks do not fail on a cold
      // session.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await _bridgeInjector.maybeInject(
        session: session,
        url: session.currentUrl,
        settings: _appSettings,
        profileId: normalizedProfileId,
      );
      await _waitForBridgeReady(session);
    }

    return session;
  }

  Future<void> _waitForSessionUrl(
    BrowserSession session,
    bool Function(String url) predicate, {
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (predicate(session.currentUrl)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  Future<bool> _waitForBridgeReady(BrowserSession session) async {
    const probe = '''
(function(){
  return !!(window.__CAMPAIO_BRIDGE__ && window.__CAMPAIO_BRIDGE__.runTaskAsync);
})();
''';
    for (var i = 0; i < 20; i += 1) {
      try {
        final raw = (await session.evaluateToString(probe))?.trim();
        if (raw == 'true' || raw == '"true"') {
          return true;
        }
      } catch (_) {
        // Best-effort probe; the caller will retry if the page is still moving.
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return false;
  }

  /// Push the current account list to the tenant if the bridge is configured.
  /// No-op when bridge is disabled or creds missing. Errors are logged via
  /// the bridge injector, never thrown.
  void _maybePushAccountList() {
    if (!_appSettings.bridgeEnabled ||
        _appSettings.tenantUrl.isEmpty ||
        _appSettings.deviceApiKey.isEmpty) {
      return;
    }
    unawaited(
      _bridgeInjector.pushAccountList(
        settings: _appSettings,
        accounts: List<AccountProfile>.from(_accounts),
      ),
    );
  }

  AccountProfile? _accountById(String id) {
    for (final account in _accounts) {
      if (account.id == id) {
        return account;
      }
    }
    return null;
  }

  Future<void> _attachSessionCallback(
    String accountId,
    BrowserSession session,
  ) async {
    session.setLoadEndCallback((url) async {
      _scheduleInspection(accountId);
      // Best-effort: inject the Campaio bridge if the user opted in and we
      // landed on chat.zalo.me. The injector self-checks bridgeEnabled.
      await _bridgeInjector.maybeInject(
        session: session,
        url: url,
        settings: _appSettings,
        profileId: accountId,
      );
    });
    // Also re-inspect on URL changes — after a QR scan Zalo Web flips
    // id.zalo.me → chat.zalo.me via redirect/SPA, and we want the sidebar to
    // pick up the new name/avatar immediately without waiting for a reload.
    session.setUrlChangedCallback((url) {
      _scheduleInspection(accountId);
      unawaited(
        _bridgeInjector.maybeInject(
          session: session,
          url: url,
          settings: _appSettings,
          profileId: accountId,
        ),
      );
    });
    session.setPopupCallback((url) {
      final account = _accountById(accountId);
      if (account != null) {
        unawaited(_openPopup(account.profilePath, url));
      }
    });
  }

  /// Opens [url] in a dedicated in-app popup window backed by the same profile
  /// directory ([profilePath]) as the opener, so the popup shares cookies/the
  /// logged-in session (e.g. OAuth / "open in new tab" flows).
  Future<void> _openPopup(String profilePath, String url) async {
    if (_disposed || _isOpeningPopup) {
      return;
    }

    _isOpeningPopup = true;
    _notifySafely();

    try {
      // Only one popup at a time: replace any existing one.
      await _closePopupInternal();

      final popupKey = 'popup-${_uuid.v4()}';
      final session = await _browserEngine.createSession(
        profileId: popupKey,
        profilePath: profilePath,
        initialUrl: url,
      );
      // Nested popups inside the popup reuse the same profile too.
      session.setPopupCallback((nestedUrl) {
        unawaited(_openPopup(profilePath, nestedUrl));
      });

      _popupSession = session;
      _popupSessionKey = popupKey;
      _popupTitle = url;
    } catch (error, stackTrace) {
      _reportError(
        'Không thể mở cửa sổ popup.',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _isOpeningPopup = false;
      _notifySafely();
    }
  }

  Future<void> closePopup() async {
    await _closePopupInternal();
    _notifySafely();
  }

  Future<void> _closePopupInternal() async {
    final key = _popupSessionKey;
    _popupSession = null;
    _popupSessionKey = null;
    _popupTitle = null;
    if (key != null) {
      await _browserEngine.disposeSession(key);
    }
  }

  Future<void> _disposeSession(String accountId) async {
    _scheduledInspections.remove(accountId)?.cancel();
    _bootingSessions.remove(accountId);
    _inspectingSessions.remove(accountId);
    _backgroundWarmSessions.remove(accountId);

    await _browserEngine.disposeSession(accountId);
    _sessions.remove(accountId);
  }

  Future<BrowserSession?> _ensureSession(
    String accountId, {
    bool reopen = false,
    bool backgroundWarmup = false,
  }) async {
    if (_disposed) {
      return null;
    }

    if (reopen) {
      await _disposeSession(accountId);
    }

    final existing = _sessions[accountId];
    if (existing != null) {
      return existing;
    }

    final account = _accountById(accountId);
    if (account == null || _bootingSessions.contains(accountId)) {
      return existing;
    }

    _bootingSessions.add(accountId);
    _notifySafely();

    try {
      final session = await _browserEngine.createSession(
        profileId: account.id,
        profilePath: account.profilePath,
        initialUrl: AppConfig.zaloAccountUrl,
      );
      _sessions[accountId] = session;
      if (backgroundWarmup) {
        _backgroundWarmSessions.add(accountId);
      } else {
        _backgroundWarmSessions.remove(accountId);
      }
      await _attachSessionCallback(accountId, session);
      return session;
    } catch (error, stackTrace) {
      _reportError(
        'Không thể khởi tạo browser profile.',
        error: error,
        stackTrace: stackTrace,
      );
      await _markSessionError(accountId);
      return null;
    } finally {
      _bootingSessions.remove(accountId);
      _notifySafely();
    }
  }

  Future<void> _inspectSession(String accountId) async {
    if (_disposed || _inspectingSessions.contains(accountId)) {
      return;
    }

    final session = _sessions[accountId];
    final account = _accountById(accountId);
    if (session == null || account == null) {
      return;
    }

    _inspectingSessions.add(accountId);
    _notifySafely();

    try {
      final result = await _zaloDomExtractor.inspect(session);
      final mergedName = result.displayName ?? account.accountName;
      final mergedAvatar = result.avatarUrl ?? account.avatarUrl;
      await _updateAccount(
        account.copyWith(
          accountName: mergedName,
          avatarUrl: mergedAvatar,
          status: result.status,
          lastCheckedAt: DateTime.now(),
          lastError: result.errorMessage,
          updatedAt: DateTime.now(),
        ),
      );

      // Right after login Zalo Web sets the URL to chat.zalo.me (active state)
      // but the profile DOM node — `#main-tab .nav__tabs__zalo` with the
      // `title="<name>"` and `.zavatar img` — is rendered a few hundred ms
      // later by the SPA. The first inspection therefore captures status=active
      // but no displayName/avatarUrl. Retry on a short backoff until both are
      // populated (or we hit a small attempt cap, so a genuinely missing-DOM
      // case doesn't loop forever).
      if (result.status == AccountStatus.active &&
          (result.displayName == null || result.avatarUrl == null)) {
        _scheduleInspection(accountId, delay: const Duration(seconds: 2));
      }
    } catch (error, stackTrace) {
      _reportError(
        'Không thể đọc thông tin tài khoản từ trang Zalo.',
        error: error,
        stackTrace: stackTrace,
      );
      await _markSessionError(accountId);
    } finally {
      _inspectingSessions.remove(accountId);
      _notifySafely();
    }
  }

  Future<void> _markSessionError(String accountId) async {
    final account = _accountById(accountId);
    if (account == null) {
      return;
    }

    await _updateAccount(
      account.copyWith(
        status: AccountStatus.error,
        lastCheckedAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
  }

  void _notifySafely() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  void _reportError(String message, {Object? error, StackTrace? stackTrace}) {
    _lastError = message;
    _logger.error(message, error: error, stackTrace: stackTrace);
    _notifySafely();
  }

  void _scheduleInspection(String accountId, {Duration? delay}) {
    _scheduledInspections.remove(accountId)?.cancel();
    _scheduledInspections[accountId] = Timer(
      delay ?? AppConfig.sessionCheckDebounce,
      () {
        unawaited(_inspectSession(accountId));
      },
    );
  }

  Future<void> _updateAccount(AccountProfile updatedAccount) async {
    final index = _accounts.indexWhere((item) => item.id == updatedAccount.id);
    if (index == -1) {
      return;
    }

    _accounts[index] = updatedAccount;
    _accounts.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    await _accountRepository.put(updatedAccount);
    _notifySafely();
    _maybePushAccountList();
    _refreshOutboxPoller();
  }
}
