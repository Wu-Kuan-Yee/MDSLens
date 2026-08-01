#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <propkey.h>
#include <propsys.h>
#include <shellapi.h>

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
constexpr wchar_t kAppUserModelId[] = L"MDSLens.MDSLens";

HRESULT SetStringProperty(IPropertyStore* store,
                          REFPROPERTYKEY key,
                          const std::wstring& text) {
  PROPVARIANT value = {};
  value.vt = VT_LPWSTR;
  value.pwszVal = const_cast<wchar_t*>(text.c_str());
  return store->SetValue(key, value);
}

void ConfigureTaskbarProperties(HWND window) {
  IPropertyStore* store = nullptr;
  if (FAILED(SHGetPropertyStoreForWindow(window, IID_PPV_ARGS(&store)))) {
    return;
  }
  std::vector<wchar_t> executable(MAX_PATH);
  const DWORD length = GetModuleFileNameW(
      nullptr, executable.data(), static_cast<DWORD>(executable.size()));
  if (length > 0 && static_cast<size_t>(length) < executable.size()) {
    const std::wstring path(executable.data(), length);
    const std::wstring command = L"\"" + path + L"\"";
    const HRESULT command_result = SetStringProperty(
        store, PKEY_AppUserModel_RelaunchCommand, command);
    const HRESULT name_result = SetStringProperty(
        store, PKEY_AppUserModel_RelaunchDisplayNameResource, L"MDSLens");
    if (SUCCEEDED(command_result) && SUCCEEDED(name_result)) {
      SetStringProperty(
          store, PKEY_AppUserModel_RelaunchIconResource, path + L",0");
      SetStringProperty(store, PKEY_AppUserModel_ID, kAppUserModelId);
      store->Commit();
    }
  }
  store->Release();
}

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

std::optional<std::wstring> WideFromUtf8(const std::string& value) {
  if (value.empty()) {
    return std::wstring();
  }
  const int characters = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  if (characters <= 0) {
    return std::nullopt;
  }
  std::wstring result(characters, L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          characters) != characters) {
    return std::nullopt;
  }
  return result;
}

// Quote one argument using the CommandLineToArgvW-compatible rules.  The
// Windows runner receives a vector from Dart, but CreateProcessW still needs a
// single mutable command line and treats backslashes before quotes specially.
std::wstring QuoteWindowsArgument(const std::wstring& value) {
  if (!value.empty() && value.find_first_of(L" \t\n\v\"") ==
                            std::wstring::npos) {
    return value;
  }
  std::wstring result = L"\"";
  size_t backslashes = 0;
  for (const wchar_t character : value) {
    if (character == L'\\') {
      ++backslashes;
      continue;
    }
    if (character == L'\"') {
      result.append(backslashes * 2 + 1, L'\\');
      result.push_back(L'\"');
    } else {
      result.append(backslashes, L'\\');
      result.push_back(character);
    }
    backslashes = 0;
  }
  result.append(backslashes * 2, L'\\');
  result.push_back(L'\"');
  return result;
}

std::optional<std::wstring> MapStringValue(
    const flutter::EncodableMap& map,
    const char* key) {
  const auto iterator = map.find(flutter::EncodableValue(key));
  if (iterator == map.end()) {
    return std::nullopt;
  }
  const auto* value = std::get_if<std::string>(
      static_cast<const flutter::EncodableValue::super*>(&iterator->second));
  if (value == nullptr) {
    return std::nullopt;
  }
  return WideFromUtf8(*value);
}

bool SpawnDetachedProcess(const flutter::EncodableMap& map,
                          std::string* error_message) {
  const auto executable = MapStringValue(map, "executable");
  if (!executable || executable->empty()) {
    *error_message = "The detached process executable is missing.";
    return false;
  }

  std::vector<std::wstring> arguments;
  const auto arguments_iterator =
      map.find(flutter::EncodableValue("arguments"));
  if (arguments_iterator != map.end()) {
    const auto* encoded_arguments = std::get_if<flutter::EncodableList>(
        static_cast<const flutter::EncodableValue::super*>(
            &arguments_iterator->second));
    if (encoded_arguments == nullptr) {
      *error_message = "The detached process arguments are invalid.";
      return false;
    }
    arguments.reserve(encoded_arguments->size());
    for (const auto& encoded_argument : *encoded_arguments) {
      const auto* argument = std::get_if<std::string>(
          static_cast<const flutter::EncodableValue::super*>(&encoded_argument));
      if (argument == nullptr) {
        *error_message = "The detached process arguments are invalid.";
        return false;
      }
      const auto wide_argument = WideFromUtf8(*argument);
      if (!wide_argument) {
        *error_message = "The detached process arguments are not UTF-8.";
        return false;
      }
      arguments.push_back(*wide_argument);
    }
  }

  std::wstring command_line = QuoteWindowsArgument(*executable);
  for (const auto& argument : arguments) {
    command_line.push_back(L' ');
    command_line += QuoteWindowsArgument(argument);
  }
  std::wstring working_directory;
  if (const auto value = MapStringValue(map, "workingDirectory")) {
    working_directory = *value;
  }

  auto launch = [&](DWORD extra_flags) {
    std::vector<wchar_t> mutable_command_line(command_line.begin(),
                                               command_line.end());
    mutable_command_line.push_back(L'\0');
    STARTUPINFOW startup = {};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process = {};
    const BOOL created = CreateProcessW(
        executable->c_str(), mutable_command_line.data(), nullptr, nullptr,
        FALSE,
        CREATE_UNICODE_ENVIRONMENT | CREATE_NEW_PROCESS_GROUP |
            DETACHED_PROCESS | extra_flags,
        nullptr, working_directory.empty() ? nullptr : working_directory.c_str(),
        &startup, &process);
    if (!created) {
      return false;
    }
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return true;
  };

  // Breakaway is the important part: it prevents a launcher-created
  // kill-on-close job from terminating the helper together with Flutter.
  if (launch(CREATE_BREAKAWAY_FROM_JOB)) {
    return true;
  }
  // Some Windows hosts do not place the app in a job that permits breakaway.
  // A normal detached process is still a useful compatibility fallback; Dart
  // will then try the historical shell handoff if this second launch fails.
  if (launch(0)) {
    return true;
  }
  *error_message = "CreateProcessW failed with error " +
                   std::to_string(static_cast<unsigned long>(GetLastError()));
  return false;
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
  ConfigureTaskbarProperties(GetHandle());

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
          flutter_controller_->engine()->messenger(), "mdslens/system_info",
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
          flutter_controller_->engine()->messenger(), "mdslens/system_fonts",
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
  updater_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "mdslens/updater",
          &flutter::StandardMethodCodec::GetInstance());
  updater_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() != "spawnDetached") {
          result->NotImplemented();
          return;
        }
        const auto* arguments = call.arguments() == nullptr
                                    ? nullptr
                                    : std::get_if<flutter::EncodableMap>(
                                          static_cast<
                                              const flutter::EncodableValue::super*>(
                                              call.arguments()));
        if (arguments == nullptr) {
          result->Error("INVALID_ARGUMENTS",
                        "The detached process arguments are missing.");
          return;
        }
        std::string error_message;
        if (!SpawnDetachedProcess(*arguments, &error_message)) {
          result->Error("SPAWN_FAILED", error_message);
          return;
        }
        result->Success(flutter::EncodableValue(true));
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
  updater_channel_.reset();
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
