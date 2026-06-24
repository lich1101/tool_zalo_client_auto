import 'dart:io';

import 'package:path/path.dart' as path;

import '../services/logging_service.dart';
import 'browser_profile_repository.dart';

class FileSystemBrowserProfileRepository implements BrowserProfileRepository {
  FileSystemBrowserProfileRepository(this.rootDirectory, this._logger);

  @override
  final Directory rootDirectory;

  final LoggingService _logger;

  String get _profilesRootPath => path.join(rootDirectory.path, 'profiles');

  @override
  Future<String> createProfileDirectory(String profileId) async {
    await ensureRoot();
    final directory = Directory(path.join(_profilesRootPath, profileId));
    await directory.create(recursive: true);
    return directory.path;
  }

  @override
  Future<void> deleteProfile(String profilePath) async {
    if (!pathBelongsToRoot(profilePath)) {
      throw StateError(
        'Refusing to delete unmanaged profile path: $profilePath',
      );
    }

    final directory = Directory(profilePath);
    if (!await directory.exists()) {
      return;
    }

    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        await directory.delete(recursive: true);
        return;
      } on FileSystemException catch (_) {
        if (attempt == 3) {
          rethrow;
        }

        _logger.warning(
          'Retrying profile deletion after file lock.',
          metadata: <String, Object?>{
            'profilePath': profilePath,
            'attempt': attempt + 1,
          },
        );
        await Future<void>.delayed(Duration(milliseconds: 200 * (attempt + 1)));
      }
    }
  }

  @override
  Future<Directory> ensureRoot() async {
    await Directory(_profilesRootPath).create(recursive: true);
    return rootDirectory;
  }

  @override
  bool pathBelongsToRoot(String profilePath) {
    final normalizedRoot = path.normalize(_profilesRootPath);
    final normalizedTarget = path.normalize(profilePath);

    return path.isWithin(normalizedRoot, normalizedTarget);
  }

  @override
  Future<void> recreateProfile(String profilePath) async {
    await deleteProfile(profilePath);
    await Directory(profilePath).create(recursive: true);
  }
}
