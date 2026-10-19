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
  VoidCallback? _onVoiceToggleRequested;
  VoidCallback? _onSettingsRequested;

  int? get monitorWindowId => _monitorWindow?.id;

  void setMonitorWindow(MultiWindowManager window) {
    // A new evaluation opens a new monitor; register the listener only once
    // or every message is handled twice.
    MultiWindowManager.current.removeListener(this);
    MultiWindowManager.current.addListener(this);

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

    // The operator closed the monitor by hand.
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

  /// Ends the monitor's part in the current evaluation.
  ///
  /// Destroying a secondary Flutter engine on Windows takes the whole process
  /// down ("Lost connection to device"), so the monitor releases the camera
  /// and Bluetooth and is hidden. The next evaluation reuses it.
  Future<void> closeMonitorWindow() async {
    final window = _monitorWindow;

    if (window == null) {
      debugPrint('[IPC] No hay Research Monitor que cerrar.');
      return;
    }

    debugPrint(
      '[WINDOW] Ocultando Research Monitor. ID=${window.id}',
    );

    try {
      await send(WindowMessages.releaseResources)
          .timeout(const Duration(seconds: 5), onTimeout: () => null);
      await window.hide();
    } catch (e) {
      debugPrint(
        '[WINDOW] Error ocultando Research Monitor: $e',
      );
    } finally {
      _onSyncWindowRequested = null;
    }
  }

  void Function(Map<String, dynamic>)? _onProtocolSettingsUpdated;

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

  void setOnVoiceToggleRequested(VoidCallback callback) {
    _onVoiceToggleRequested = callback;
  }

  void setOnSettingsRequested(VoidCallback callback) {
    _onSettingsRequested = callback;
  }

  void setOnProtocolSettingsUpdated(
    void Function(Map<String, dynamic>) callback,
  ) {
    _onProtocolSettingsUpdated = callback;
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

    if (eventName == WindowMessages.voiceToggleRequested) {
      debugPrint('[IPC] Solicitud de cambio de voz recibida.');
      _onVoiceToggleRequested?.call();
    }

    if (eventName == WindowMessages.settingsRequested) {
      debugPrint('[IPC] Solicitud de ajustes recibida.');
      _onSettingsRequested?.call();
    }

    if (eventName == WindowMessages.protocolSettingsUpdated) {
      debugPrint('[IPC] Nueva configuración de protocolo recibida.');

      if (arguments is Map) {
        _onProtocolSettingsUpdated?.call(
          Map<String, dynamic>.from(arguments),
        );
      }
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
    String? activityName,
    required String phaseName,
  }) {
    return send(WindowMessages.sessionStarted, {
      'participantIds': participantIds,
      'activityIndex': activityIndex,
      if (activityName != null) 'activityName': activityName,
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
    String? activityName,
    required String phaseName,
  }) {
    return send(WindowMessages.protocolContext, {
      'participantIds': participantIds,
      'activityIndex': activityIndex,
      if (activityName != null) 'activityName': activityName,
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

  Future<void> sendProtocolSettings({
    required int prepSeconds,
    required int activitySeconds,
    required int postSeconds,
    required bool useLapMode,
    required bool enableTts,
  }) {
    return send(
      WindowMessages.protocolSettings,
      {
        'prepSeconds': prepSeconds,
        'activitySeconds': activitySeconds,
        'postSeconds': postSeconds,
        'useLapMode': useLapMode,
        'enableTts': enableTts,
      },
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