import 'package:flutter/foundation.dart';
import 'package:multi_window_manager/multi_window_manager.dart';
import 'window_messages.dart';
import '../models/protocol_configuration.dart';

class ResearchMonitorBridge extends WindowListener {
  ResearchMonitorBridge._();

  static final ResearchMonitorBridge instance = ResearchMonitorBridge._();

  MultiWindowManager? _monitorWindow;
  ProtocolConfiguration? _protocolConfiguration;
  VoidCallback? _onSyncWindowRequested;
  VoidCallback? _onSessionStartRequested;
  VoidCallback? _onSessionPauseRequested;
  VoidCallback? _onSessionResumeRequested;
  VoidCallback? _onLapRequested;
  VoidCallback? _onSessionFinishRequested;
  VoidCallback? _onSessionCancelRequested;

  int? get monitorWindowId => _monitorWindow?.id;

  void setMonitorWindow(MultiWindowManager window) {
    MultiWindowManager.current.addListener(this);

    _monitorWindow = window;
    debugPrint('[IPC] Research Monitor registrado. ID=${window.id}');
  }

  Future<void> closeMonitorWindow() async {
    final window = _monitorWindow;

    if (window == null) {
      debugPrint('[IPC] No hay Research Monitor que cerrar.');
      return;
    }

    debugPrint(
      '[WINDOW] Cerrando Research Monitor. ID=${window.id}',
    );

    try {
      await window.close();
    } catch (e) {
      debugPrint(
        '[WINDOW] Error cerrando Research Monitor: $e',
      );
    } finally {
      MultiWindowManager.current.removeListener(this);
      _monitorWindow = null;
      _onSyncWindowRequested = null;

      debugPrint(
        '[WINDOW] Research Monitor desconectado del bridge.',
      );
    }
  }

  void setProtocolConfiguration(
    ProtocolConfiguration configuration,
  ) {
    _protocolConfiguration = configuration;

    debugPrint(
      '[IPC] Configuración de protocolo almacenada.',
    );
  }

  void setOnSyncWindowRequested(VoidCallback callback) {
    _onSyncWindowRequested = callback;
  }

  void setOnSessionStartRequested(VoidCallback callback) {
    _onSessionStartRequested = callback;
  }

  void setOnSessionPauseRequested(VoidCallback callback) {
    _onSessionPauseRequested = callback;
  }

  void setOnSessionResumeRequested(VoidCallback callback) {
    _onSessionResumeRequested = callback;
  }

  void setOnLapRequested(VoidCallback callback) {
    _onLapRequested = callback;
  }

  void setOnSessionFinishRequested(VoidCallback callback) {
    _onSessionFinishRequested = callback;
  }

  void setOnSessionCancelRequested(VoidCallback callback) {
    _onSessionCancelRequested = callback;
  }

  Future<void> setSyncAvailability(bool available) async {
    await send(
      WindowMessages.syncAvailability,
      available,
    );

    debugPrint(
      '[SYNC] Disponibilidad actualizada: '
      '${available ? 'ACTIVA' : 'INACTIVA'}',
    );
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

    final monitorWindow = _monitorWindow;

    if (monitorWindow == null ||
        fromWindowId != monitorWindow.id) {
      debugPrint(
        '[IPC] Evento ignorado: ventana $fromWindowId '
        'no es el Research Monitor activo.',
      );
      return null;
    }

    if (eventName == WindowMessages.researchMonitorReady) {
      debugPrint(
        '[IPC] Research Monitor confirma que está listo.',
      );

      final configuration = _protocolConfiguration;

      if (configuration != null) {
        await sendProtocolConfiguration(configuration);
      } else {
        debugPrint(
          '[IPC] No hay configuración de protocolo disponible.',
        );
      }
    }

    if (eventName == WindowMessages.syncWindowRequested) {
      debugPrint('[SYNC] Solicitud de ventana de sincronización recibida.');
      _onSyncWindowRequested?.call();
    }

    if (eventName == WindowMessages.sessionStartRequested) {
      debugPrint('[IPC] Solicitud de INICIAR recibida.');
      _onSessionStartRequested?.call();
    }

    if (eventName == WindowMessages.sessionPauseRequested) {
      debugPrint('[IPC] Solicitud de PAUSAR recibida.');
      _onSessionPauseRequested?.call();
    }

    if (eventName == WindowMessages.sessionResumeRequested) {
      debugPrint('[IPC] Solicitud de REANUDAR recibida.');
      _onSessionResumeRequested?.call();
    }

    if (eventName == WindowMessages.lapRequested) {
      debugPrint('[IPC] Solicitud de LAP recibida.');
      _onLapRequested?.call();
    }

    if (eventName == WindowMessages.sessionFinishRequested) {
      debugPrint('[IPC] Solicitud de FINALIZAR recibida.');
      _onSessionFinishRequested?.call();
    }

    if (eventName == WindowMessages.sessionCancelRequested) {
      debugPrint('[IPC] Solicitud de CANCELAR recibida.');
      _onSessionCancelRequested?.call();
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