import 'package:flutter/foundation.dart';
import 'package:multi_window_manager/multi_window_manager.dart';
import 'window_messages.dart';
import '../models/protocol_configuration.dart';
import '../config/default_protocol_configuration.dart';

class ResearchMonitorBridge extends WindowListener {
  ResearchMonitorBridge._();

  static final ResearchMonitorBridge instance = ResearchMonitorBridge._();

  MultiWindowManager? _monitorWindow;

  int? get monitorWindowId => _monitorWindow?.id;

  void setMonitorWindow(MultiWindowManager window) {
    MultiWindowManager.current.addListener(this);

    _monitorWindow = window;
    debugPrint('[IPC] Research Monitor registrado. ID=${window.id}');
  }

  @override
  Future<dynamic> onEventFromWindow(
    String eventName,
    int fromWindowId,
    dynamic arguments,
  ) async {
    debugPrint(
      '[IPC] Evento recibido desde ventana $fromWindowId: $eventName',
    );

    if (eventName == WindowMessages.researchMonitorReady) {
      debugPrint(
        '[IPC] Research Monitor confirma que está listo.',
      );

      sendProtocolConfiguration(
        defaultProtocolConfiguration,
      );
    }

    return null;
  }

  Future<dynamic> send(String method, [dynamic arguments]) async {
    final window = _monitorWindow;

    if (window == null) {
      debugPrint('[IPC] Ignorado "$method": No existe Research Monitor.');
      return null;
    }

    try {
      return await MultiWindowManager.current.invokeMethodToWindow(
        window.id,
        method,
        arguments,
      );
    } catch (e) {
      debugPrint('[IPC] Error enviando "$method": $e');
      return null;
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
  Future<dynamic> sessionFinished() =>
    send(WindowMessages.sessionFinished);

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

  Future<void> sendProtocolConfiguration(
    ProtocolConfiguration configuration,
  ) {
    return send(
      WindowMessages.protocolConfiguration,
      configuration.toJson(),
    );
  }

  // ===========================================================================
  // CONTROL REMOTO DE LA CÁMARA (De Principal -> Monitor)
  // ===========================================================================

  Future<dynamic> startVideoRecording(String participantSummary) {
    return send('START_VIDEO_RECORDING', participantSummary);
  }

  Future<void> stopVideoRecording(String participantSummary, int totalActivities) {
    return send('STOP_VIDEO_RECORDING', {
      'participantSummary': participantSummary,
      'totalActivities': totalActivities,
    });
  }
}