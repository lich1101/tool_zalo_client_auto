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
import '../services/logging_service.dart';
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
  ThemeMode _themeMode = ThemeMode.system;
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
      _themeMode = (await _settingsRepository.load()).themeMode;

      if (_accounts.isNotEmpty) {
        _selectedAccountId = _accounts.first.id;
      }

      _isInitialized = true;
      _notifySafely();

      if (_selectedAccountId != null) {
        await _ensureSession(_selectedAccountId!);
      }
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
    _notifySafely();
    await _settingsRepository.save(AppSettings(themeMode: mode));
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

  AccountProfile? _accountById(String id) {
    for (final account in _accounts) {
      if (account.id == id) {
        return account;
      }
    }
    return null;
  }

  Future<void> _attachSessionCallback(String accountId, BrowserSession session) async {
    session.setLoadEndCallback((_) async {
      _scheduleInspection(accountId);
    });
    // Also re-inspect on URL changes — after a QR scan Zalo Web flips
    // id.zalo.me → chat.zalo.me via redirect/SPA, and we want the sidebar to
    // pick up the new name/avatar immediately without waiting for a reload.
    session.setUrlChangedCallback((_) {
      _scheduleInspection(accountId);
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
  }
}
