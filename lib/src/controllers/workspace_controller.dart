import 'dart:async';

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
import '../services/logging_service.dart';
import '../services/outbox_poller.dart';
import '../services/zalo_dom_extractor.dart';

class WorkspaceController extends ChangeNotifier {
  WorkspaceController({
    required AccountRepository accountRepository,
    required BrowserProfileRepository browserProfileRepository,
    required SettingsRepository settingsRepository,
    required BrowserEngine browserEngine,
    required ZaloDomExtractor zaloDomExtractor,
    required LoggingService logger,
  })  : _accountRepository = accountRepository,
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

  List<AccountProfile> _accounts = <AccountProfile>[];
  AppSettings _appSettings = const AppSettings();
  ThemeMode _themeMode = ThemeMode.system;
  late final BridgeInjector _bridgeInjector = BridgeInjector(_logger);
  late final OutboxPoller _outboxPoller = OutboxPoller(_logger);
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

  List<AccountProfile> get accounts => List<AccountProfile>.unmodifiable(_accounts);

  BrowserSession? get activeSession => _selectedAccountId == null
      ? null
      : _sessions[_selectedAccountId!];

  bool get isCreatingAccount => _isCreatingAccount;

  /// Active in-app popup window (window.open / new tab), or null when none.
  BrowserSession? get popupSession => _popupSession;

  String? get popupTitle => _popupTitle;

  bool get isOpeningPopup => _isOpeningPopup;

  bool get isInitialized => _isInitialized;

  bool get isInitializing => _isInitializing;

  String? get lastError => _lastError;

  AccountProfile? get selectedAccount => _selectedAccountId == null
      ? null
      : _accountById(_selectedAccountId!);

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
      final profilePath =
          await _browserProfileRepository.createProfileDirectory(accountId);
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
      if (_appSettings.bridgeEnabled
          && _appSettings.tenantUrl.isNotEmpty
          && _appSettings.deviceApiKey.isNotEmpty) {
        for (final account in _accounts) {
          if (_sessions.containsKey(account.id)) continue;
          unawaited(_ensureSession(account.id));
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

  bool isSessionBooting(String accountId) => _bootingSessions.contains(accountId);

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
    await _ensureSession(accountId);
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
        unawaited(_ensureSession(account.id));
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
    if (!_appSettings.bridgeEnabled
        || _appSettings.tenantUrl.isEmpty
        || _appSettings.deviceApiKey.isEmpty) {
      _outboxPoller.stop();
      return;
    }
    _outboxPoller.start(
      settings: _appSettings,
      profileIds: _accounts.map((a) => a.id).toList(),
      resolveSession: (profileId) => _sessions[profileId],
      // Piggyback the account roster push on the same poll loop so the
      // tenant /channels page reflects login changes without the user
      // re-opening the settings dialog. Fires on first tick and every
      // ~2 minutes after.
      pushAccounts: () => _bridgeInjector.pushAccountList(
        settings: _appSettings,
        accounts: List<AccountProfile>.from(_accounts),
      ),
    );
  }

  /// Push the current account list to the tenant if the bridge is configured.
  /// No-op when bridge is disabled or creds missing. Errors are logged via
  /// the bridge injector, never thrown.
  void _maybePushAccountList() {
    if (!_appSettings.bridgeEnabled
        || _appSettings.tenantUrl.isEmpty
        || _appSettings.deviceApiKey.isEmpty) {
      return;
    }
    unawaited(_bridgeInjector.pushAccountList(
      settings: _appSettings,
      accounts: List<AccountProfile>.from(_accounts),
    ));
  }

  AccountProfile? _accountById(String id) {
    for (final account in _accounts) {
      if (account.id == id) {
        return account;
      }
    }
    return null;
  }

  Future<void> _attachSessionCallback(String accountId, BrowserSession session) async {
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
      unawaited(_bridgeInjector.maybeInject(
        session: session,
        url: url,
        settings: _appSettings,
        profileId: accountId,
      ));
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

    await _browserEngine.disposeSession(accountId);
    _sessions.remove(accountId);
  }

  Future<BrowserSession?> _ensureSession(
    String accountId, {
    bool reopen = false,
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
        _scheduleInspection(
          accountId,
          delay: const Duration(seconds: 2),
        );
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

  void _reportError(
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    _lastError = message;
    _logger.error(message, error: error, stackTrace: stackTrace);
    _notifySafely();
  }

  void _scheduleInspection(
    String accountId, {
    Duration? delay,
  }) {
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
