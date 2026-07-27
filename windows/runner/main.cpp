#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <propkey.h>
#include <propsys.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

void EnsurePortableStartMenuShortcut() {
  PWSTR programs_path = nullptr;
  if (FAILED(SHGetKnownFolderPath(
          FOLDERID_Programs, KF_FLAG_CREATE, nullptr, &programs_path))) {
    return;
  }
  const std::wstring shortcut_path =
      std::wstring(programs_path) + L"\\MDSLens.lnk";
  CoTaskMemFree(programs_path);
  if (GetFileAttributesW(shortcut_path.c_str()) != INVALID_FILE_ATTRIBUTES) {
    return;
  }

  wchar_t executable[MAX_PATH] = {};
  if (GetModuleFileNameW(nullptr, executable, MAX_PATH) == 0) {
    return;
  }
  IShellLinkW* link = nullptr;
  if (FAILED(CoCreateInstance(
          CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&link)))) {
    return;
  }
  HRESULT result = link->SetPath(executable);
  if (SUCCEEDED(result)) result = link->SetDescription(L"MDSLens");
  if (SUCCEEDED(result)) result = link->SetIconLocation(executable, 0);

  IPropertyStore* properties = nullptr;
  if (SUCCEEDED(result)) {
    result = link->QueryInterface(IID_PPV_ARGS(&properties));
  }
  if (SUCCEEDED(result)) {
    PROPVARIANT value = {};
    value.vt = VT_LPWSTR;
    value.pwszVal = const_cast<wchar_t*>(L"MDSLens.MDSLens");
    result = properties->SetValue(PKEY_AppUserModel_ID, value);
    if (SUCCEEDED(result)) result = properties->Commit();
  }
  if (properties != nullptr) properties->Release();

  IPersistFile* persist = nullptr;
  if (SUCCEEDED(result)) {
    result = link->QueryInterface(IID_PPV_ARGS(&persist));
  }
  if (SUCCEEDED(result)) {
    persist->Save(shortcut_path.c_str(), TRUE);
  }
  if (persist != nullptr) persist->Release();
  link->Release();
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  ::SetCurrentProcessExplicitAppUserModelID(L"MDSLens.MDSLens");
  ::RegisterApplicationRestart(L"", RESTART_NO_PATCH | RESTART_NO_REBOOT);
  EnsurePortableStartMenuShortcut();

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1440, 920);
  if (!window.Create(L"MDSLens", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
