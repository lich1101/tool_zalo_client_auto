import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:zalo_account_workspace/src/repositories/file_system_browser_profile_repository.dart';
import 'package:zalo_account_workspace/src/services/logging_service.dart';

void main() {
  late Directory rootDirectory;
  late FileSystemBrowserProfileRepository repository;

  setUp(() async {
    rootDirectory = await Directory.systemTemp.createTemp('zaw-profile-test-');
    repository = FileSystemBrowserProfileRepository(
      rootDirectory,
      LoggingService(),
    );
    await repository.ensureRoot();
  });

  tearDown(() async {
    if (await rootDirectory.exists()) {
      await rootDirectory.delete(recursive: true);
    }
  });

  test('creates isolated profile folders for two accounts', () async {
    final firstPath = await repository.createProfileDirectory('account-a');
    final secondPath = await repository.createProfileDirectory('account-b');

    expect(firstPath, isNot(secondPath));
    expect(Directory(firstPath).existsSync(), isTrue);
    expect(Directory(secondPath).existsSync(), isTrue);
    expect(path.basename(firstPath), 'account-a');
    expect(path.basename(secondPath), 'account-b');
  });

  test('deleting one profile does not remove its sibling folder', () async {
    final firstPath = await repository.createProfileDirectory('account-a');
    final secondPath = await repository.createProfileDirectory('account-b');

    await repository.deleteProfile(firstPath);

    expect(Directory(firstPath).existsSync(), isFalse);
    expect(Directory(secondPath).existsSync(), isTrue);
  });

  test('recreateProfile returns an empty folder at the same path', () async {
    final profilePath = await repository.createProfileDirectory('account-a');
    await File(path.join(profilePath, 'marker.txt')).writeAsString('ok');

    await repository.recreateProfile(profilePath);

    expect(Directory(profilePath).existsSync(), isTrue);
    expect(File(path.join(profilePath, 'marker.txt')).existsSync(), isFalse);
  });

  test('rejects deleting folders outside the managed profiles root', () async {
    final unmanagedPath = path.join(rootDirectory.path, 'hive');
    await Directory(unmanagedPath).create(recursive: true);

    expect(repository.pathBelongsToRoot(unmanagedPath), isFalse);
    expect(
      () => repository.deleteProfile(unmanagedPath),
      throwsA(isA<StateError>()),
    );
    expect(Directory(unmanagedPath).existsSync(), isTrue);
  });
}
