import 'package:hive/hive.dart';

import '../models/account_profile.dart';
import 'account_repository.dart';

class HiveAccountRepository implements AccountRepository {
  HiveAccountRepository(this._box);

  final Box<dynamic> _box;

  @override
  Future<void> close() => _box.close();

  @override
  Future<void> delete(String id) => _box.delete(id);

  @override
  Future<List<AccountProfile>> getAll() async {
    return _box.values
        .whereType<Map>()
        .map(AccountProfile.fromJson)
        .toList(growable: false);
  }

  @override
  Future<void> put(AccountProfile profile) => _box.put(profile.id, profile.toJson());
}
