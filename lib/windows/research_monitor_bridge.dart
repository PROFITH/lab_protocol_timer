import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:multi_window_manager/multi_window_manager.dart';

import '../models/protocol_configuration.dart';
import '../session/session_controller.dart';
import 'window_messages.dart';

/// The participant window's side of the link with the Research Monitor.
///
/// The session runs here ([SessionController]); the monitor shows it,
/// sends the evaluator's orders ([WindowMessages.sessionCommand]) and
/// records the Polar sensors and the cameras into the session folder.
class ResearchMonitorBridge extends WindowListener implements MonitorLink {
  ResearchMonitorBridge._();

  static final ResearchMonitorBridge instance = ResearchMonitorBridge._();

  MultiWindowManager? _monitorWindow;
  ProtocolConfiguration? _protocolConfiguration;
  SessionController? _controller;
  bool _listening = false;

  /// Back to the setup page (the evaluator closed the summary).
  Future<void> Function()? onCloseSession;

  int? get monitorWindowId => _monitorWindow?.id;

  bool get hasMonitor => _monitorWindow != null;

  /// The session whose orders the monitor sends (null between sessions).
  void attach(SessionController? controller) {
    _controller = controller;
    _listen();
  }

  void _listen() {
    if (_listening) return;
    MultiWindowManager.current.addListener(this);
    _listening = true;
  }

  void setMonitorWindow(MultiWindowManager window) {
    _listen();
    _monitorWindow = window;
    debugPrint('[IPC] Research Monitor registrado. ID=${window.id}');
  }

  /// Whether a monitor window from an earlier evaluation is still alive and
  /// can be reused instead of creating a new one.
  Future<bool> hasLiveMonitorWindow() async {
    final window = _monitorWindow;
    if (window == null) return false;

    try {
      final aliveIds = await MultiWindowManager.getAllAliveEngineIds();
      if (aliveIds.contains(window.id)) return true;
    } catch (e) {
      debugPrint('[IPC] No se pudo consultar las ventanas vivas: $e');
    }

    _monitorWindow = null;
    return false;
  }

  /// Rebuilds the hidden monitor for a new evaluation and shows it again.
  Future<void> reuseMonitorWindow() async {
    final window = _monitorWindow;
    if (window == null) return;

    debugPrint('[WINDOW] Reutilizando Research Monitor. ID=${window.id}');

    await send(WindowMessages.resetMonitor);
    await window.show();
    await window.focus();
  }

  /// Brings the monitor to the front (F2 in the participant window).
  Future<void> showMonitor() async {
    final window = _monitorWindow;
    if (window == null) return;
    try {
      await window.show();
      await window.focus();
    } catch (e) {
      debugPrint('[WINDOW] No se pudo mostrar el Research Monitor: $e');
    }
  }

  /// Ends the monitor's part in the current evaluation.
  ///
  /// Destroying a secondary Flutter engine on Windows takes the whole process
  /// down, so the monitor releases the camera and Bluetooth and is hidden.
  /// The next evaluation reuses it.
  Future<void> closeMonitorWindow() async {
    final window = _monitorWindow;
    if (window == null) return;

    debugPrint('[WINDOW] Ocultando Research Monitor. ID=${window.id}');

    try {
      await send(WindowMessages.releaseResources, null, const Duration(seconds: 8));
      await window.hide();
    } catch (e) {
      debugPrint('[WINDOW] Error ocultando Research Monitor: $e');
    }
  }

  void setProtocolConfiguration(ProtocolConfiguration configuration) {
    _protocolConfiguration = configuration;
  }

  Future<void> sendProtocolConfiguration(ProtocolConfiguration configuration) {
    return send(WindowMessages.protocolConfiguration, configuration.toJson());
  }

  @override
  Future<dynamic> onEventFromWindow(
    String eventName,
    int fromWindowId,
    dynamic arguments,
  ) async {
    final monitorWindow = _monitorWindow;
    if (monitorWindow == null || fromWindowId != monitorWindow.id) {
      return null;
    }

    switch (eventName) {
      case WindowMessages.researchMonitorReady:
        debugPrint('[IPC] Research Monitor listo.');
        final configuration = _protocolConfiguration;
        if (configuration != null) await sendProtocolConfiguration(configuration);
        // A monitor opened (or rebuilt) during a session learns where to
        // write and what is going on.
        unawaited(_controller?.reannounce());
        return true;

      case WindowMessages.sessionCommand:
        final map = arguments is Map ? Map<String, dynamic>.from(arguments) : const <String, dynamic>{};
        final command = map['command']?.toString() ?? '';
        final args = map['args'] is Map ? Map<String, dynamic>.from(map['args'] as Map) : <String, dynamic>{};
        if (command == 'close') {
          final close = onCloseSession;
          if (close != null) unawaited(close());
          return const CommandResult.ok().toJson();
        }
        final controller = _controller;
        if (controller == null) {
          return const CommandResult.refused('No hay ninguna sesión abierta').toJson();
        }
        try {
          final result = await controller.command(command, args);
          return result.toJson();
        } catch (e, stack) {
          debugPrint('[IPC] Error en la orden "$command": $e\n$stack');
          return CommandResult.refused('Error: $e').toJson();
        }
    }
    return null;
  }

  /// Sends [method] to the monitor. Messages that stop the recordings wait
  /// longer (the video may be copied to another drive).
  @override
  Future<dynamic> send(String method, [dynamic arguments, Duration? timeout]) async {
    final window = _monitorWindow;
    if (window == null) return null;

    final limit = timeout ??
        switch (method) {
          WindowMessages.sessionStopping || WindowMessages.sessionSuspending => const Duration(minutes: 15),
          WindowMessages.restingHrRequested => const Duration(seconds: 5),
          _ => const Duration(seconds: 3),
        };
    try {
      return await MultiWindowManager.current
          .invokeMethodToWindow(window.id, method, arguments)
          .timeout(limit, onTimeout: () {
        debugPrint('[IPC] Sin respuesta del Research Monitor a "$method".');
        return null;
      });
    } catch (e) {
      debugPrint('[IPC] Error enviando "$method": $e');
      return null;
    }
  }
}
