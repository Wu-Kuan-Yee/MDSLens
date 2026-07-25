#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cstdlib>
#include <cwchar>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr wchar_t kWindowsVersionRegistryPath[] =
    L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion";

std::wstring ReadRegistryString(const wchar_t* name) {
  DWORD bytes = 0;
  const LSTATUS size_status =
      RegGetValueW(HKEY_LOCAL_MACHINE, kWindowsVersionRegistryPath, name,
                   RRF_RT_REG_SZ, nullptr, nullptr, &bytes);
  if (size_status != ERROR_SUCCESS || bytes < sizeof(wchar_t)) {
    return {};
  }
  std::vector<wchar_t> value(bytes / sizeof(wchar_t), L'\0');
  const LSTATUS read_status =
      RegGetValueW(HKEY_LOCAL_MACHINE, kWindowsVersionRegistryPath, name,
                   RRF_RT_REG_SZ, nullptr, value.data(), &bytes);
  if (read_status != ERROR_SUCCESS) {
    return {};
  }
  return std::wstring(value.data());
}

std::optional<DWORD> ReadRegistryDword(const wchar_t* name) {
  DWORD value = 0;
  DWORD bytes = sizeof(value);
  const LSTATUS status =
      RegGetValueW(HKEY_LOCAL_MACHINE, kWindowsVersionRegistryPath, name,
                   RRF_RT_REG_DWORD, nullptr, &value, &bytes);
  if (status != ERROR_SUCCESS) {
    return std::nullopt;
  }
  return value;
}

std::string Utf8FromWide(const std::wstring& value) {
  if (value.empty()) {
    return {};
  }
  const int bytes = WideCharToMultiByte(
      CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0,
      nullptr, nullptr);
  if (bytes <= 0) {
    return {};
  }
  std::string result(bytes, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(),
                      static_cast<int>(value.size()), result.data(), bytes,
                      nullptr, nullptr);
  return result;
}

std::string RuntimeArchitecture() {
#if defined(_M_ARM64)
  return "arm64";
#elif defined(_M_X64)
  return "x86_64";
#elif defined(_M_IX86)
  return "x86";
#else
  return "unknown";
#endif
}

flutter::EncodableValue ReadRuntimeSystemInfo() {
  std::wstring product_name = ReadRegistryString(L"ProductName");
  std::wstring display_version = ReadRegistryString(L"DisplayVersion");
  if (display_version.empty()) {
    display_version = ReadRegistryString(L"ReleaseId");
  }
  const std::wstring build_number = ReadRegistryString(L"CurrentBuildNumber");
  const unsigned long build =
      build_number.empty() ? 0 : std::wcstoul(build_number.c_str(), nullptr, 10);
  if (build >= 22000) {
    const std::wstring old_name = L"Windows 10";
    const size_t position = product_name.find(old_name);
    if (position != std::wstring::npos) {
      product_name.replace(position, old_name.size(), L"Windows 11");
    } else if (product_name.find(L"Windows 11") == std::wstring::npos) {
      product_name = L"Windows 11";
    }
  } else if (product_name.empty()) {
    product_name = L"Windows 10";
  }

  std::wstring version = display_version;
  if (!build_number.empty()) {
    if (!version.empty()) {
      version += L", ";
    }
    version += L"build ";
    version += build_number;
    if (const auto revision = ReadRegistryDword(L"UBR")) {
      version += L".";
      version += std::to_wstring(*revision);
    }
  }

  flutter::EncodableMap result;
  result[flutter::EncodableValue("name")] =
      flutter::EncodableValue(Utf8FromWide(product_name));
  result[flutter::EncodableValue("version")] =
      flutter::EncodableValue(Utf8FromWide(version));
  result[flutter::EncodableValue("architecture")] =
      flutter::EncodableValue(RuntimeArchitecture());
  return flutter::EncodableValue(result);
}

int CALLBACK CollectFontFamily(
    const LOGFONTW* logical_font, const TEXTMETRICW*, DWORD, LPARAM context) {
  auto* families = reinterpret_cast<std::set<std::wstring>*>(context);
  const std::wstring family(logical_font->lfFaceName);
  if (!family.empty() && family.front() != L'@') {
    families->insert(family);
  }
  return 1;
}

flutter::EncodableValue ReadSystemFontFamilies() {
  std::set<std::wstring> families;
  HDC device_context = GetDC(nullptr);
  if (device_context != nullptr) {
    LOGFONTW query = {};
    query.lfCharSet = DEFAULT_CHARSET;
    EnumFontFamiliesExW(
        device_context, &query,
        reinterpret_cast<FONTENUMPROCW>(CollectFontFamily),
        reinterpret_cast<LPARAM>(&families), 0);
    ReleaseDC(nullptr, device_context);
  }
  flutter::EncodableList result;
  result.reserve(families.size());
  for (const auto& family : families) {
    result.emplace_back(Utf8FromWide(family));
  }
  return flutter::EncodableValue(result);
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  system_info_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "mdsscope/system_info",
          &flutter::StandardMethodCodec::GetInstance());
  system_info_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() != "get") {
          result->NotImplemented();
          return;
        }
        result->Success(ReadRuntimeSystemInfo());
      });
  system_fonts_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "mdsscope/system_fonts",
          &flutter::StandardMethodCodec::GetInstance());
  system_fonts_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() != "listFamilies") {
          result->NotImplemented();
          return;
        }
        result->Success(ReadSystemFontFamilies());
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  system_fonts_channel_.reset();
  system_info_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
