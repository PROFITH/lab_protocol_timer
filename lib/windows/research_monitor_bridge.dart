import 'package:flutter/foundation.dart';
import 'package:multi_window_manager/multi_window_manager.dart';
import 'window_messages.dart';

class ResearchMonitorBridge {
  ResearchMonitorBridge._();

  static final ResearchMonitorBridge instance = ResearchMonitorBridge._();

  MultiWindowManager? _monitorWindow;

  int? get monitorWindowId => _monitorWindow?.id;

  void setMonitorWindow(MultiWindowManager window) {
    _monitorWindow = window;
    debugPrint('[IPC] Research Monitor registrado. ID=${window.id}');
  }

  Future<void> send(String method, [dynamic arguments]) async {
    final window = _monitorWindow;
    if (window == null) {
      debugPrint('[IPC] Ignorado "$method": No existe Research Monitor.');
      return;
    }
    try {
      await MultiWindowManager.current.invokeMethodToWindow(
        window.id,
        method,
        arguments,
      );
    } catch (e) {
      debugPrint('[IPC] Error enviando "$method": $e');
    }
  }

  // ===========================================================================
  // ESTADO DE SESIÓN (De Principal -> Monitor)
  // ===========================================================================

  Future<void> sessionStarted({
    required String participantIds,
    required int activityIndex,
    required String phaseName,
  }) {
    return send(WindowMessages.sessionStarted, {
      'participantIds': participantIds,
      'activityIndex': activityIndex,
      'phaseName': phaseName,
    });
  }

  Future<void> sessionPaused() => send(WindowMessages.sessionPaused);
  Future<void> sessionResumed() => send(WindowMessages.sessionResumed);
  Future<void> sessionFinished() => send(WindowMessages.sessionFinished);

  Future<void> updateProtocolContext({
    required String participantIds,
    required int activityIndex,
    required String phaseName,
  }) {
    return send(WindowMessages.protocolContext, {
      'participantIds': participantIds,
      'activityIndex': activityIndex,
      'phaseName': phaseName,
    });
  }

  // ===========================================================================
  // CONTROL REMOTO DE LA CÁMARA (De Principal -> Monitor)
  // ===========================================================================

  Future<void> startVideoRecording(String participantSummary) {
    return send('START_VIDEO_RECORDING', participantSummary);
  }

  Future<void> stopVideoRecording(String participantSummary, int totalActivities) {
    return send('STOP_VIDEO_RECORDING', {
      'participantSummary': participantSummary,
      'totalActivities': totalActivities,
    });
  }
}