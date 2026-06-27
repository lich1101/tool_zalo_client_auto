import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// Set bởi MainFlutterWindow sau khi engine sẵn sàng. Dùng để báo Dart bring
  /// cửa sổ lên trước khi app được đánh thức qua URL scheme campaio-zalo://.
  var activationChannel: FlutterMethodChannel?

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// macOS gọi hàm này khi mở URL scheme đã đăng ký (Info.plist CFBundleURLTypes
  /// = campaio-zalo). Đưa app lên trước + báo Dart để raise/focus cửa sổ.
  override func application(_ application: NSApplication, open urls: [URL]) {
    let isActivation = urls.contains { $0.scheme?.lowercased() == "campaio-zalo" }
    if isActivation {
      NSApp.activate(ignoringOtherApps: true)
      activationChannel?.invokeMethod("onActivate", arguments: nil)
    }
  }
}
