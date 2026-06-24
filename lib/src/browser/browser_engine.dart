import 'browser_session.dart';

abstract class BrowserEngine {
  Future<void> initialize();

  Future<BrowserSession> createSession({
    required String profileId,
    required String profilePath,
    required String initialUrl,
  });

  Future<void> disposeSession(String profileId);

  Future<void> shutdown();
}
