# Zalo Account Workspace

Flutter desktop app để quản lý nhiều tài khoản Zalo cá nhân hợp pháp của chính người dùng, với mỗi tài khoản chạy trong một browser profile CEF riêng trên macOS và Windows.

## Safety Scope

- Chỉ hỗ trợ đăng nhập thủ công.
- Không lưu password.
- Không đọc, export, copy, hiển thị hoặc gửi cookie/token/session ra ngoài.
- Không bypass captcha, OTP, QR login hoặc bất kỳ cơ chế bảo vệ nào của Zalo.
- Không spam, không scrape danh bạ, không scrape nội dung chat.
- Chỉ đọc DOM tối thiểu để lấy `displayName` và `avatarUrl`.

## MVP Features

- Sidebar quản lý nhiều account profile.
- Mỗi account có thư mục browser data riêng:
  - macOS: `~/Library/Application Support/ZaloAccountWorkspace/profiles/<uuid>/`
  - Windows: `%APPDATA%\\ZaloAccountWorkspace\\profiles\\<uuid>\\`
- Main panel nhúng Chromium bằng `webview_cef`.
- Toolbar gồm `Back`, `Forward`, `Reload`, `Home`, `Check session`, current URL.
- Lưu metadata local bằng Hive:
  - `id`
  - `displayName`
  - `accountName`
  - `avatarUrl`
  - `profilePath`
  - `status`
  - `lastCheckedAt`
  - `createdAt`
  - `updatedAt`
- DOM extractor đọc selector config từ `assets/zalo_selectors.json`.
- Xóa profile sẽ xóa cả metadata lẫn thư mục browser data tương ứng.
- Đăng xuất trong menu account được implement theo hướng reset local session/profile data, sau đó yêu cầu người dùng đăng nhập thủ công lại.

## Tech Stack

- Flutter `3.29.3`
- Riverpod (provider + `ChangeNotifier` controller)
- Hive
- `webview_cef` vendored tại `packages/webview_cef`

## Local Patch: Profile Isolation

`webview_cef` upstream hiện hỗ trợ multiple instances, nhưng chưa có Dart API rõ ràng cho `cache/profile path` theo từng browser.

Project này đã vendor plugin vào `packages/webview_cef` và vá local:

- `WebViewController.initialize(..., cachePath: ...)`
- Native `create` method nhận `url + cachePath`
- Mỗi browser dùng `CefRequestContext` riêng với:
  - `cache_path = profilePath`
  - `persist_session_cookies = true`

Điều này cho phép từng account giữ session/cookie/storage riêng và persist sau khi tắt/mở app.

## Project Structure

```text
lib/
  main.dart
  src/
    app.dart
    browser/
    config/
    controllers/
    models/
    providers/
    repositories/
    screens/
    services/
    widgets/
assets/
  zalo_selectors.json
packages/
  webview_cef/   # local patched plugin
test/
  file_system_browser_profile_repository_test.dart
```

## Run

```bash
flutter pub get
flutter run -d macos
flutter run -d windows
```

## Build

```bash
flutter build macos
flutter build windows
```

## Platform Notes

### macOS

- Dùng `webview_cef` nên deployment target đã được nâng lên `macOS 12.0`.
- `macos/Podfile` đã thêm helper hook để embed CEF helper apps cho chế độ multi-process.
- `macos/Podfile` cũng patch lại CocoaPods-generated linker/code-sign scripts để xử lý framework CEF có tên chứa khoảng trắng.
- Lần build đầu, CocoaPods sẽ tải CEF và build wrapper native nên sẽ chậm hơn bình thường.
- Nếu build trong thư mục đồng bộ kiểu `Desktop` / file-provider và gặp lỗi codesign dạng `resource fork, Finder information, or similar detritus not allowed`, hãy di chuyển project sang workspace local không đồng bộ hoặc strip xattr trước khi codesign lại.

### Windows

- Dùng CEF, không cần WebView2 runtime.
- `windows/runner/main.cpp` đã được patch để:
  - gọi `initCEFProcesses(instance)` ngay đầu `wWinMain`
  - forward message loop qua `handleWndProcForCEF(...)`
- Lần build đầu sẽ tải CEF binary và compile native wrapper, vì vậy thời gian build đầu tiên khá lâu.

## Session Verification

### Automated

```bash
flutter test
```

Test hiện tại kiểm chứng:

- tạo 2 profile folder tách biệt
- xóa profile A không ảnh hưởng profile B
- reset profile sẽ recreate đúng folder ở cùng path
- từ chối xóa nhầm thư mục nằm ngoài `profiles/<uuid>/`
- extractor chỉ đọc `textContent` tên và `src` avatar, không đụng cookie/localStorage/sessionStorage/message/contact
- phân loại đúng `needsLogin` và `error` khi WebView trả về trang lỗi nội bộ

### Manual End-to-End

1. Mở app và bấm `Thêm tài khoản` hai lần để tạo profile A và B.
2. Kiểm tra hai thư mục khác nhau trong `profiles/<uuid>/`.
3. Đăng nhập thủ công vào A.
4. Chuyển sang B và đăng nhập thủ công vào B.
5. Quay lại A để xác nhận session A vẫn còn.
6. Tắt app, mở lại app, chọn lại A/B để xác nhận session vẫn còn nếu chưa logout.
7. Xóa profile A và kiểm tra:
   - metadata A biến mất khỏi sidebar
   - thư mục A bị xóa
   - thư mục B vẫn còn nguyên

## Quality Checks

Các bước đã chạy trong workspace này:

```bash
flutter analyze
flutter test
```

## Current Limitations

- DOM selectors trong `assets/zalo_selectors.json` có thể cần cập nhật nếu Zalo đổi markup.
- Local logout hiện là reset browser profile data cục bộ, không gọi remote logout endpoint.
- Profile isolation hiện đã hoạt động ở mức `cache_path` per browser context, nhưng toàn app vẫn chạy trong một global CEF runtime; nếu sau này cần control sâu hơn cho proxy/per-profile cookie API/native lifecycle, nên tiếp tục tách `BrowserEngine` sang wrapper CEF custom riêng.
- Chưa có integration test tự động cho flow login thật vì đăng nhập phải hoàn toàn thủ công và không được bypass cơ chế bảo mật của Zalo.
- Windows runner đã được patch để tương thích CEF, nhưng chưa thể build/launch trực tiếp trong workspace macOS hiện tại; cần xác nhận thêm trên một máy Windows thật trước khi chốt release.
- `flutter build macos --debug` trên máy hiện tại đã đi qua `pod install`, tải CEF, compile wrapper và link app, nhưng dừng ở bước codesign cuối do extended attributes (`com.apple.provenance` / Finder info) trong output bundle. Đây là lỗi packaging môi trường macOS, không phải lỗi Dart/analyze của app.
