import 'package:flutter/foundation.dart';

class LoggingService {
  void info(String message, {Map<String, Object?>? metadata}) {
    _emit('INFO', message, metadata: metadata);
  }

  void warning(String message, {Map<String, Object?>? metadata}) {
    _emit('WARN', message, metadata: metadata);
  }

  void error(
    String message, {
    Map<String, Object?>? metadata,
    Object? error,
    StackTrace? stackTrace,
  }) {
    _emit(
      'ERROR',
      message,
      metadata: metadata,
      error: error,
      stackTrace: stackTrace,
    );
  }

  void _emit(
    String level,
    String message, {
    Map<String, Object?>? metadata,
    Object? error,
    StackTrace? stackTrace,
  }) {
    final buffer = StringBuffer('[ZAW][$level] $message');
    if (metadata != null && metadata.isNotEmpty) {
      final pairs = metadata.entries
          .map((entry) => '${entry.key}=${_sanitize(entry.value)}')
          .join(' ');
      buffer.write(' $pairs');
    }

    debugPrint(buffer.toString());

    if (error != null) {
      debugPrint('[ZAW][$level] cause=${_sanitize(error)}');
    }
    if (stackTrace != null && kDebugMode) {
      debugPrint('$stackTrace');
    }
  }

  String _sanitize(Object? value) {
    final text = '$value';
    final lower = text.toLowerCase();
    if (lower.contains('cookie') ||
        lower.contains('token') ||
        lower.contains('password') ||
        lower.contains('session=')) {
      return '<redacted>';
    }

    return text;
  }
}
