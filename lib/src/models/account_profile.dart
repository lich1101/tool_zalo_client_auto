enum AccountStatus {
  active,
  needsLogin,
  checking,
  error;

  static AccountStatus fromName(String? value) {
    return AccountStatus.values.firstWhere(
      (status) => status.name == value,
      orElse: () => AccountStatus.needsLogin,
    );
  }

  String get label => switch (this) {
        AccountStatus.active => 'Đang hoạt động',
        AccountStatus.needsLogin => 'Cần đăng nhập lại',
        AccountStatus.checking => 'Đang kiểm tra',
        AccountStatus.error => 'Lỗi',
      };
}

class AccountProfile {
  const AccountProfile({
    required this.id,
    required this.profilePath,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.displayName,
    this.accountName,
    this.avatarUrl,
    this.lastCheckedAt,
    this.lastError,
  });

  static const Object _sentinel = Object();

  final String id;
  final String profilePath;
  final String? displayName;
  final String? accountName;
  final String? avatarUrl;
  final AccountStatus status;
  final DateTime? lastCheckedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? lastError;

  String get effectiveTitle {
    final overridden = displayName?.trim();
    if (overridden != null && overridden.isNotEmpty) {
      return overridden;
    }

    final extracted = accountName?.trim();
    if (extracted != null && extracted.isNotEmpty) {
      return extracted;
    }

    return 'Tài khoản mới';
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'profilePath': profilePath,
      'displayName': displayName,
      'accountName': accountName,
      'avatarUrl': avatarUrl,
      'status': status.name,
      'lastCheckedAt': lastCheckedAt?.toIso8601String(),
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'lastError': lastError,
    };
  }

  factory AccountProfile.fromJson(Map<dynamic, dynamic> json) {
    return AccountProfile(
      id: json['id'] as String,
      profilePath: json['profilePath'] as String,
      displayName: json['displayName'] as String?,
      accountName: json['accountName'] as String?,
      avatarUrl: json['avatarUrl'] as String?,
      status: AccountStatus.fromName(json['status'] as String?),
      lastCheckedAt: json['lastCheckedAt'] == null
          ? null
          : DateTime.tryParse(json['lastCheckedAt'] as String),
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      lastError: json['lastError'] as String?,
    );
  }

  AccountProfile copyWith({
    String? id,
    String? profilePath,
    AccountStatus? status,
    DateTime? createdAt,
    DateTime? updatedAt,
    Object? displayName = _sentinel,
    Object? accountName = _sentinel,
    Object? avatarUrl = _sentinel,
    Object? lastCheckedAt = _sentinel,
    Object? lastError = _sentinel,
  }) {
    return AccountProfile(
      id: id ?? this.id,
      profilePath: profilePath ?? this.profilePath,
      displayName:
          identical(displayName, _sentinel) ? this.displayName : displayName as String?,
      accountName:
          identical(accountName, _sentinel) ? this.accountName : accountName as String?,
      avatarUrl:
          identical(avatarUrl, _sentinel) ? this.avatarUrl : avatarUrl as String?,
      status: status ?? this.status,
      lastCheckedAt: identical(lastCheckedAt, _sentinel)
          ? this.lastCheckedAt
          : lastCheckedAt as DateTime?,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastError:
          identical(lastError, _sentinel) ? this.lastError : lastError as String?,
    );
  }
}
