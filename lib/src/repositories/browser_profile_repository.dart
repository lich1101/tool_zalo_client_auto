import 'dart:io';

abstract class BrowserProfileRepository {
  Directory get rootDirectory;

  Future<Directory> ensureRoot();

  Future<String> createProfileDirectory(String profileId);

  Future<void> recreateProfile(String profilePath);

  Future<void> deleteProfile(String profilePath);

  bool pathBelongsToRoot(String profilePath);
}
