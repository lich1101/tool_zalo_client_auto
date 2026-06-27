#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>

#include "flutter_window.h"
#include "utils.h"
#include "webview_cef/webview_cef_plugin_c_api.h"

namespace {

// Khớp với window class/title của Flutter runner + tên kênh Dart/macOS.
constexpr wchar_t kUrlScheme[] = L"campaio-zalo";
constexpr wchar_t kSingleInstanceMutex[] =
    L"Local\\CampaioZaloWorkspaceSingleInstance";
constexpr wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kWindowTitle[] = L"Zalo Tool ChatPlus";
constexpr ULONG_PTR kActivateCopyDataTag = 0x43414D50;  // 'CAMP'

// Đăng ký URL scheme campaio-zalo:// vào HKCU (không cần quyền admin). Idempotent
// — chạy mỗi lần mở app để đảm bảo đường dẫn exe luôn đúng (sau khi di chuyển).
void RegisterUrlProtocol() {
  wchar_t exe_path[MAX_PATH] = {0};
  if (::GetModuleFileNameW(nullptr, exe_path, MAX_PATH) == 0) {
    return;
  }
  const std::wstring command =
      L"\"" + std::wstring(exe_path) + L"\" \"%1\"";
  const std::wstring base = std::wstring(L"Software\\Classes\\") + kUrlScheme;

  HKEY key = nullptr;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, base.c_str(), 0, nullptr, 0,
                        KEY_WRITE, nullptr, &key, nullptr) == ERROR_SUCCESS) {
    const wchar_t desc[] = L"URL:Campaio Zalo Workspace";
    ::RegSetValueExW(key, nullptr, 0, REG_SZ,
                     reinterpret_cast<const BYTE*>(desc),
                     static_cast<DWORD>((wcslen(desc) + 1) * sizeof(wchar_t)));
    ::RegSetValueExW(key, L"URL Protocol", 0, REG_SZ,
                     reinterpret_cast<const BYTE*>(L""), sizeof(wchar_t));
    ::RegCloseKey(key);
  }
  const std::wstring command_key = base + L"\\shell\\open\\command";
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, command_key.c_str(), 0, nullptr, 0,
                        KEY_WRITE, nullptr, &key, nullptr) == ERROR_SUCCESS) {
    ::RegSetValueExW(
        key, nullptr, 0, REG_SZ,
        reinterpret_cast<const BYTE*>(command.c_str()),
        static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
    ::RegCloseKey(key);
  }
}

// Lấy URL campaio-zalo://... từ command line khi app được mở bởi protocol.
std::wstring ExtractActivationUrl() {
  int argc = 0;
  LPWSTR* argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  std::wstring url;
  if (argv) {
    const std::wstring prefix = std::wstring(kUrlScheme) + L"://";
    for (int i = 1; i < argc; ++i) {
      const std::wstring arg = argv[i];
      if (arg.rfind(prefix, 0) == 0) {
        url = arg;
        break;
      }
    }
    ::LocalFree(argv);
  }
  return url;
}

// Forward tín hiệu đánh thức tới instance đang chạy (nếu có). True nếu đã gửi.
bool ForwardActivationToRunningInstance(const std::wstring& url) {
  HWND existing = ::FindWindowW(kWindowClassName, kWindowTitle);
  if (!existing) {
    return false;
  }
  COPYDATASTRUCT cds{};
  cds.dwData = kActivateCopyDataTag;
  cds.cbData = static_cast<DWORD>((url.size() + 1) * sizeof(wchar_t));
  cds.lpData = const_cast<wchar_t*>(url.c_str());
  ::SendMessageW(existing, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&cds));
  ::SetForegroundWindow(existing);
  return true;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  int exit_code = initCEFProcesses(instance);
  if (exit_code >= 0) {
    return exit_code;
  }

  // Đảm bảo URL scheme campaio-zalo:// được đăng ký cho user hiện tại.
  RegisterUrlProtocol();

  // Single-instance: nếu đã có app chạy, forward yêu cầu đánh thức (URL nếu có)
  // sang instance đó rồi thoát — tránh mở app trùng khi web/extension gọi scheme.
  HANDLE single_instance_mutex =
      ::CreateMutexW(nullptr, TRUE, kSingleInstanceMutex);
  const bool already_running =
      single_instance_mutex != nullptr &&
      ::GetLastError() == ERROR_ALREADY_EXISTS;
  if (already_running) {
    ForwardActivationToRunningInstance(ExtractActivationUrl());
    if (single_instance_mutex) {
      ::CloseHandle(single_instance_mutex);
    }
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Zalo Tool ChatPlus", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
    handleWndProcForCEF(msg.hwnd, msg.message, msg.wParam, msg.lParam);
  }

  ::CoUninitialize();
  if (single_instance_mutex) {
    ::CloseHandle(single_instance_mutex);
  }
  return EXIT_SUCCESS;
}
