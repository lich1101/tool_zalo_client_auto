import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

typedef ActivationCallback = Future<void> Function();

/// Cross-platform "wake / bring-to-front" cho app desktop.
///
/// Web/extension Campaio đánh thức app theo 2 đường, CẢ macOS lẫn Windows đều
/// phải đưa đúng cửa sổ này lên trước + focus:
///   1. URL scheme `campaio-zalo://activate` (native: Info.plist trên macOS,
///      protocol registry + single-instance + WM_COPYDATA trên Windows) →
///      native gọi method `onActivate` qua [MethodChannel] này.
///   2. POST /activate trên loopback bridge (thuần Dart, đã cross-platform).
///
/// Trước đây raise cửa sổ từ Dart thuần là không thể (xem ghi chú cũ trong
/// WorkspaceController._activateApp). `window_manager` hỗ trợ cả macOS + Windows
/// nên giờ raise được chủ động ở cả hai.
class WindowActivationService {
  WindowActivationService();

  static const MethodChannel _channel =
      MethodChannel('site.campaio.zalo/activation');

  /// Đăng ký handler để native (URL scheme macOS / protocol+WM_COPYDATA Windows)
  /// yêu cầu app đang chạy nhảy lên trước.
  void registerNativeActivationHandler(ActivationCallback onActivate) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onActivate') {
        await onActivate();
      }
      return null;
    });
  }

  /// Đưa cửa sổ app lên foreground + focus. Best-effort: không bao giờ ném lỗi
  /// làm hỏng luồng đánh thức.
  Future<void> bringToFront() async {
    try {
      if (await windowManager.isMinimized()) {
        await windowManager.restore();
      }
      await windowManager.show();
      await windowManager.focus();
      // Đẩy lên trên trong khoảnh khắc rồi nhả ra để OS chắc chắn raise cửa sổ
      // mà không ghim app vĩnh viễn always-on-top.
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setAlwaysOnTop(false);
    } catch (error, stackTrace) {
      debugPrint('[WindowActivation] bringToFront failed: $error\n$stackTrace');
    }
  }
}
