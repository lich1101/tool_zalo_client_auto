import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.title = "Zalo Tool ChatPlus"

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Kênh để native báo cho Dart "đánh thức / lên trước" khi URL scheme
    // campaio-zalo:// được mở. AppDelegate giữ tham chiếu để gọi khi nhận URL.
    let activationChannel = FlutterMethodChannel(
      name: "site.campaio.zalo/activation",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    (NSApp.delegate as? AppDelegate)?.activationChannel = activationChannel

    super.awakeFromNib()
  }
}
