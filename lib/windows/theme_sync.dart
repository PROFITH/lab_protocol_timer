import 'dart:async';

import 'package:flutter/material.dart';
import 'package:multi_window_manager/multi_window_manager.dart';

import '../ui/app_theme.dart';
import 'window_messages.dart';

/// Keeps the theme of the participant window and the Research Monitor the
/// same: a toggle in one is sent to the other (the monitors opened in their
/// own window take it from the Research Monitor).
class ThemeSync with WindowListener {
  ThemeSync._(this._peers);

  final Iterable<int> Function() _peers;

  static ThemeSync? _installed;

  /// Starts listening in this window; [peers] are the windows a toggle here
  /// is sent to.
  static void install(Iterable<int> Function() peers) {
    if (_installed != null) return;
    final sync = ThemeSync._(peers);
    _installed = sync;
    MultiWindowManager.current.addListener(sync);
    ThemeController.onToggle = sync._send;
  }

  void _send(ThemeMode mode) {
    for (final id in _peers()) {
      unawaited(
        MultiWindowManager.current
            .invokeMethodToWindow(id, WindowMessages.themeChanged, mode == ThemeMode.light ? 'light' : 'dark')
            .timeout(const Duration(seconds: 2), onTimeout: () => null)
            .catchError((Object e) {
          debugPrint('[THEME] No se pudo avisar a la ventana $id: $e');
          return null;
        }),
      );
    }
  }

  @override
  Future<dynamic> onEventFromWindow(String eventName, int fromWindowId, dynamic arguments) async {
    if (eventName != WindowMessages.themeChanged) return null;
    await ThemeController.set(arguments == 'light' ? ThemeMode.light : ThemeMode.dark);
    return true;
  }
}
