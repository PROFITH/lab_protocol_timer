#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <iostream>
#include <memory>
#include <vector>

#include "flutter_window.h"
#include "utils.h"
#include "multi_window_manager/multi_window_manager_plugin.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);

  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);

  if (!window.Create(L"Lab Protocol Timer", origin, size)) {
    return EXIT_FAILURE;
  }

  // IMPORTANT:
  // MultiWindowManager manages application lifetime when multiple
  // windows are open.
  window.SetQuitOnClose(false);

  // ------------------------------------------------------------------
  // MultiWindowManager: create secondary Flutter windows
  // ------------------------------------------------------------------

  MultiWindowManagerPluginSetWindowCreatedCallback(
      [](std::vector<std::string> command_line_arguments) {
        flutter::DartProject project(L"data");

        project.set_dart_entrypoint_arguments(
            std::move(command_line_arguments));

        auto window = std::make_shared<FlutterWindow>(project);

        Win32Window::Point origin(50, 50);
        Win32Window::Size size(1280, 720);

        if (!window->Create(L"Lab Protocol Timer", origin, size)) {
          std::cerr << "[NATIVE] Failed to create secondary window"
                    << std::endl;
          return std::shared_ptr<FlutterWindow>();
        }

        window->SetQuitOnClose(false);

        std::cerr << "[NATIVE] Secondary window created successfully"
                  << std::endl;

        return window;
      });

  ::MSG msg;

  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();

  return EXIT_SUCCESS;
}