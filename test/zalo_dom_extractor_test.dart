import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zalo_account_workspace/src/models/account_profile.dart';
import 'package:zalo_account_workspace/src/services/zalo_dom_extractor.dart';

void main() {
  const selectorConfig = ZaloSelectorConfig(
    displayNameSelectors: <String>['.profile-name'],
    avatarSelectors: <String>['img.avatar'],
    loggedOutUrlPatterns: <String>['/login', 'qr', 'signin'],
  );

  final extractor = ZaloDomExtractor();

  test('inspection script only reads display name text and avatar src', () {
    final script =
        extractor.buildInspectionScript(selectorConfig).toLowerCase();

    expect(script, contains('textcontent'));
    expect(script, contains("getattribute?.('src')"));
    expect(script, isNot(contains('document.cookie')));
    expect(script, isNot(contains('localstorage')));
    expect(script, isNot(contains('sessionstorage')));
    expect(script, isNot(contains('message')));
    expect(script, isNot(contains('contact')));
  });

  test('returns active when the DOM exposes account metadata', () {
    final result = extractor.parseInspectionPayload(
      rawPayload: jsonEncode(<String, Object?>{
        'currentUrl': 'https://id.zalo.me/account',
        'displayName': 'Nguyen Van A',
        'avatarUrl': 'https://avatar.zalo.me/a.png',
        'isLoggedOut': false,
        'isErrorPage': false,
      }),
      fallbackUrl: 'https://id.zalo.me/account',
    );

    expect(result.status, AccountStatus.active);
    expect(result.displayName, 'Nguyen Van A');
    expect(result.avatarUrl, 'https://avatar.zalo.me/a.png');
  });

  test('returns needsLogin for login-like URLs without account metadata', () {
    final result = extractor.parseInspectionPayload(
      rawPayload: jsonEncode(<String, Object?>{
        'currentUrl': 'https://id.zalo.me/login',
        'displayName': null,
        'avatarUrl': null,
        'isLoggedOut': true,
        'isErrorPage': false,
      }),
      fallbackUrl: 'https://id.zalo.me/account',
    );

    expect(result.status, AccountStatus.needsLogin);
    expect(result.errorMessage, isNull);
  });

  test('returns error for embedded browser load-error pages', () {
    final result = extractor.parseInspectionPayload(
      rawPayload: jsonEncode(<String, Object?>{
        'currentUrl': 'data:text/html;base64,ZXJyb3I=',
        'displayName': null,
        'avatarUrl': null,
        'isLoggedOut': false,
        'isErrorPage': true,
      }),
      fallbackUrl: 'https://id.zalo.me/account',
    );

    expect(result.status, AccountStatus.error);
    expect(result.errorMessage, isNotNull);
  });
}
