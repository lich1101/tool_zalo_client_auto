import '../models/account_profile.dart';

abstract class AccountRepository {
  Future<List<AccountProfile>> getAll();

  Future<void> put(AccountProfile profile);

  Future<void> delete(String id);

  Future<void> close();
}
