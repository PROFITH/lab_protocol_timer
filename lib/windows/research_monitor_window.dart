import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:multi_window_manager/multi_window_manager.dart';
import 'package:universal_ble/universal_ble.dart';
import 'package:camera/camera.dart';

import '../services/polar_ble_service.dart';
import '../services/video_recording_service.dart';
import '../models/device_configuration.dart';
import '../models/device_status.dart';
import '../models/protocol_configuration.dart';
import '../models/monitor_slot.dart';
import '../models/monitor_visualization.dart';
import 'live_signal.dart';
import 'window_messages.dart';
import 'sensor_chart_card.dart';


/// Keeps one monitor window for the whole run of the app.
///
/// The window is hidden, not destroyed, between evaluations; on
/// [WindowMessages.resetMonitor] the monitor is rebuilt with a fresh state.
class ResearchMonitorHost extends StatefulWidget {
  final ProtocolConfiguration protocolConfiguration;

  const ResearchMonitorHost({
    super.key,
    required this.protocolConfiguration,
  });

  @override
  State<ResearchMonitorHost> createState() => _ResearchMonitorHostState();
}

class _ResearchMonitorHostState extends State<ResearchMonitorHost>
    with WindowListener {
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    MultiWindowManager.current.addListener(this);
  }

  @override
  void dispose() {
    MultiWindowManager.current.removeListener(this);
    super.dispose();
  }

  @override
  Future<dynamic> onEventFromWindow(
    String eventName,
    int fromWindowId,
    dynamic arguments,
  ) async {
    if (eventName != WindowMessages.resetMonitor) return null;
    if (mounted) setState(() => _generation++);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return ResearchMonitorWindow(
      key: ValueKey(_generation),
      protocolConfiguration: widget.protocolConfiguration,
    );
  }
}

class ResearchMonitorWindow extends StatefulWidget {
  final ProtocolConfiguration protocolConfiguration;

  const ResearchMonitorWindow({
    super.key,
    required this.protocolConfiguration,
  });

  @override
  State<ResearchMonitorWindow> createState() =>
      _ResearchMonitorWindowState();
}

class _ResearchMonitorWindowState extends State<ResearchMonitorWindow>
    with WindowListener, SingleTickerProviderStateMixin {
  
  // State variables
  //
  // One Polar service per live device of the session (Polar H10, Verity
  // Sense) and one recorder per camera, keyed by the device ID of the
  // session setup. Connecting them is optional: offline sensors are only
  // listed, and a live device can be left unconnected.
  final Map<String, _LiveDevice> _liveDevices = {};
  final Map<String, _CameraDevice> _cameras = {};

  /// Charts repaint on this clock, once per frame with new samples, instead
  /// of rebuilding the window on every sample.
  final LiveFrameClock _frameClock = LiveFrameClock();
  late final Ticker _frameTicker;
  bool _samplesPending = false;

  final List<MonitorSlot> _monitorSlots = [
    const MonitorSlot(slotId: 1),
    const MonitorSlot(slotId: 2),
    const MonitorSlot(slotId: 3),
    const MonitorSlot(slotId: 4),
  ];

  String _participantIds = '--';
  int _activityIndex = 0;
  String? _activityName;
  String _phaseName = 'idle';
  bool _sessionActive = false;
  bool _sessionPaused = false;
  bool _syncAvailable = false;
  Directory? _sessionExportDirectory;
  late ProtocolConfiguration _protocolConfiguration;
  int _prepSeconds = 10;
  int _activitySeconds = 60;
  int _postSeconds = 10;
  bool _useLapMode = false;
  bool _enableTts = true;

  // Modo de acelerometría: 'VM' o 'XYZ'
  String _accMode = 'XYZ';

  bool get _anyCameraRecording =>
      _cameras.values.any((c) => c.service.isRecording);


  String _sourceId(
    String deviceId,
    String sensorId,
  ) {
    return '$deviceId:$sensorId';
  }

  int? _monitorForSource(
    String deviceId,
    String sensorId,
  ) {
    final sourceId = _sourceId(deviceId, sensorId);

    for (final slot in _monitorSlots) {
      if (slot.sourceId == sourceId) {
        return slot.slotId;
      }
    }

    return null;
  }

  VoidCallback? _deviceActionForDevice(String deviceId) {
    if (_liveDevices.containsKey(deviceId)) {
      return () => _showPolarConnectionDialog(deviceId);
    }
    if (_cameras.containsKey(deviceId)) {
      return () => _showCameraConnectionDialog(deviceId);
    }
    return null;
  }

  /// "Reintentar conexión" of each device: shown for a Polar that was
  /// connected and dropped (or is waiting to reconnect), and for a camera
  /// that failed.
  VoidCallback? _retryActionForDevice(String deviceId) {
    final live = _liveDevices[deviceId];
    if (live != null) {
      final service = live.service;
      final state = service.linkStatus.value.state;
      if (!service.hasLastDevice) return null;
      if (service.isConnected && state != PolarLinkState.reconnecting) {
        return null;
      }
      if (state == PolarLinkState.connecting ||
          state == PolarLinkState.pairing ||
          state == PolarLinkState.configuring) {
        return null;
      }
      return () => _retryPolar(deviceId);
    }

    final camera = _cameras[deviceId];
    if (camera != null) {
      if (camera.ready || camera.recovering) return null;
      if (camera.service.lastCamera == null) return null;
      return () => _retryCamera(deviceId);
    }

    return null;
  }

  Future<void> _retryPolar(String deviceId) async {
    final device = _liveDevices[deviceId];
    if (device == null) return;

    final ok = await device.service.retryConnection(
      configuration: device.configuration,
    );

    if (!mounted) return;
    setState(() {});

    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(device.service.linkStatus.value.message),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  /// A camera error (USB unplugged, MediaFoundation failure...) is retried
  /// on its own; if it was recording, a new video segment starts.
  void _onCameraError(String deviceId) {
    final camera = _cameras[deviceId];
    if (camera == null || !mounted) return;

    final error = camera.service.cameraError.value;
    setState(() {
      if (error != null) camera.ready = false;
    });

    if (error != null && !camera.recovering) {
      _retryCamera(deviceId, automatic: true);
    }
  }

  Future<void> _retryCamera(String deviceId, {bool automatic = false}) async {
    final camera = _cameras[deviceId];
    if (camera == null || camera.recovering) return;
    if (camera.service.lastCamera == null) {
      if (!automatic) await _showCameraConnectionDialog(deviceId);
      return;
    }

    setState(() => camera.recovering = true);

    final wasRecording = camera.service.isRecording;
    var ok = false;
    for (var attempt = 1; attempt <= 3 && mounted; attempt++) {
      ok = await camera.service.recoverCamera(
        participantSummary: _participantIds,
        activityIndex: _activityIndex,
        restartRecording: wasRecording,
      );
      if (ok) break;
      await Future.delayed(Duration(seconds: 2 * attempt));
    }

    if (!mounted) return;

    setState(() {
      camera.recovering = false;
      camera.ready = ok;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? '${camera.configuration.deviceName} recuperada'
              : 'No se pudo recuperar ${camera.configuration.deviceName}: '
                  '${camera.service.lastStartError ?? camera.service.cameraError.value ?? 'error desconocido'}',
        ),
        backgroundColor: ok ? const Color(0xFF34D399) : Colors.redAccent,
      ),
    );
  }


  void _assignSourceToSlot(
    int slotId,
    String deviceId,
    String sensorId,
  ) {
    final index = _monitorSlots.indexWhere(
      (slot) => slot.slotId == slotId,
    );

    if (index == -1) {
      return;
    }

    setState(() {
      _monitorSlots[index] = MonitorSlot(
        slotId: slotId,
        deviceId: deviceId,
        sensorId: sensorId,
        visualization: _visualizationForSensor(sensorId),
      );
    });
  }

  Future<void> _handleSensorTap(
    String deviceId,
    String sensorId,
  ) async {
    final currentSlot = _monitorForSource(
      deviceId,
      sensorId,
    );

    final selectedSlot = await showDialog<int>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Mostrar sensor en...'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final slot in _monitorSlots)
                ListTile(
                  leading: Icon(
                    slot.isAssigned
                        ? Icons.monitor_rounded
                        : Icons.monitor_outlined,
                  ),
                  title: Text(
                    'Monitor ${slot.slotId}',
                  ),
                  subtitle: slot.isAssigned
                      ? Text(
                          '${slot.deviceId}:${slot.sensorId}',
                        )
                      : const Text(
                          'Sin sensor asignado',
                        ),
                  trailing: currentSlot == slot.slotId
                      ? const Icon(
                          Icons.check_circle,
                        )
                      : null,
                  onTap: () {
                    Navigator.of(context).pop(
                      slot.slotId,
                    );
                  },
                ),
            ],
          ),
        );
      },
    );

    if (selectedSlot == null || !mounted) {
      return;
    }

    _assignSourceToSlot(
      selectedSlot,
      deviceId,
      sensorId,
    );

    debugPrint(
      '[MONITOR] Fuente asignada: '
      '$deviceId:$sensorId → Monitor $selectedSlot',
    );
  }

  MonitorVisualization _visualizationForSensor(String sensorId) {
    switch (sensorId) {
      case 'heart_rate':
        return MonitorVisualization.heartRate;

      case 'rr':
        return MonitorVisualization.rr;

      case 'acc':
        return MonitorVisualization.acceleration;

      case 'ecg':
        return MonitorVisualization.ecg;

      case 'video':
        return MonitorVisualization.video;

      default:
        return MonitorVisualization.unknown;
    }
  }

  @override
  void initState() {
    super.initState();
    
    _protocolConfiguration = widget.protocolConfiguration;
    _syncDevices();

    _frameTicker = createTicker((_) {
      if (_samplesPending) {
        _samplesPending = false;
        _frameClock.tick();
      }
    })
      ..start();

    MultiWindowManager.current.addListener(this);

    MultiWindowManager.current.invokeMethodToWindow(
      0,
      WindowMessages.researchMonitorReady,
    );

    debugPrint('[MONITOR] Research Monitor inicializado con servicios locales.');
  }

  /// Creates the services of new live devices and cameras of
  /// [_protocolConfiguration] and releases those no longer listed.
  void _syncDevices() {
    final live = {
      for (final d in _protocolConfiguration.devices)
        if (d.isLive && d.sensors.isNotEmpty) d.deviceId: d,
    };
    final cameras = {
      for (final d in _protocolConfiguration.devices)
        if (d.isCamera) d.deviceId: d,
    };

    for (final id in _liveDevices.keys.toList()) {
      if (!live.containsKey(id)) _liveDevices.remove(id)!.dispose();
    }
    for (final id in _cameras.keys.toList()) {
      if (!cameras.containsKey(id)) _cameras.remove(id)!.service.dispose();
    }

    live.forEach((id, configuration) {
      final existing = _liveDevices[id];
      if (existing != null) {
        existing.configuration = configuration;
        return;
      }
      _liveDevices[id] = _LiveDevice(
        configuration,
        onSamples: () => _samplesPending = true,
        onStatusChanged: () {
          if (mounted) setState(() {});
        },
      );
    });
    cameras.forEach((id, configuration) {
      final existing = _cameras[id];
      if (existing != null) {
        existing.configuration = configuration;
        return;
      }
      final camera = _CameraDevice(configuration);
      camera.service.cameraError.addListener(() => _onCameraError(id));
      _cameras[id] = camera;
    });

    // Monitors showing a device that left the session are emptied.
    for (var i = 0; i < _monitorSlots.length; i++) {
      final deviceId = _monitorSlots[i].deviceId;
      if (deviceId != null &&
          !_liveDevices.containsKey(deviceId) &&
          !_cameras.containsKey(deviceId)) {
        _monitorSlots[i] = _monitorSlots[i].copyWith(clearSource: true);
      }
    }
  }

  Future<void> _showCameraConnectionDialog(String deviceId) async {
    final camera = _cameras[deviceId];
    if (camera == null) return;
    try {
      debugPrint('[VIDEO] Buscando cámaras disponibles...');
      final cameras = await availableCameras();
      debugPrint('[VIDEO] Cámaras encontradas: ${cameras.length}');

      if (cameras.isEmpty) {
        debugPrint('[VIDEO] No se encontraron cámaras.');
        if (mounted) {
          setState(() => camera.ready = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'No hay cámaras. Si usas el móvil, abre DroidCam en el '
                'móvil y en el ordenador antes de buscar.',
              ),
            ),
          );
        }
        return;
      }

      // Cameras already taken by another device of the session.
      final taken = {
        for (final other in _cameras.values)
          if (other != camera && other.ready)
            other.service.selectedCamera?.name,
      };

      var preset = camera.service.resolutionPreset;

      // Mostrar diálogo para que elijas qué cámara usar
      if (!mounted) return;
      final CameraDescription? selectedCamera = await showDialog<CameraDescription>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext dialogContext) {
          return StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
              backgroundColor: const Color(0xFF1E293B),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              title: Row(
                children: [
                  const Icon(Icons.videocam_rounded, color: Color(0xFF38BDF8)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Cámara para ${camera.configuration.deviceId}',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 380,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: cameras.length,
                        itemBuilder: (context, index) {
                          final option = cameras[index];
                          final busy = taken.contains(option.name);
                          return ListTile(
                            enabled: !busy,
                            leading: const Icon(Icons.camera_alt, color: Color(0xFF38BDF8)),
                            title: Text(
                              option.name,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                            ),
                            subtitle: Text(
                              busy ? 'En uso por otra cámara de la sesión' : 'Lens: ${option.lensDirection.name}',
                              style: const TextStyle(color: Colors.white38, fontSize: 11),
                            ),
                            onTap: () => Navigator.of(dialogContext).pop(option),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<ResolutionPreset>(
                      initialValue: preset,
                      dropdownColor: const Color(0xFF1E293B),
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Resolución',
                        labelStyle: TextStyle(color: Colors.white54),
                      ),
                      items: const [
                        DropdownMenuItem(value: ResolutionPreset.high, child: Text('720p')),
                        DropdownMenuItem(value: ResolutionPreset.veryHigh, child: Text('1080p')),
                        DropdownMenuItem(value: ResolutionPreset.ultraHigh, child: Text('4K (si la cámara lo da)')),
                      ],
                      onChanged: (value) {
                        if (value != null) setDialogState(() => preset = value);
                      },
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'El vídeo graba también audio (las palmadas) del primer '
                      'micrófono que da Windows; con DroidCam conviene dejar '
                      'activado su micrófono virtual o desactivar los demás.',
                      style: TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancelar'),
                ),
              ],
            ),
          );
        },
      );

      // Comprobamos si el widget sigue montado tras el diálogo asíncrono
      if (!mounted) return;

      // Si el usuario cierra el diálogo sin elegir...
      if (selectedCamera == null) {
        debugPrint('[VIDEO] Selección de cámara cancelada.');
        return;
      }

      debugPrint('[VIDEO] Inicializando cámara seleccionada: ${selectedCamera.name}');

      camera.service.resolutionPreset = preset;
      final success = await camera.service.initializeCamera(selectedCamera);
      if (!mounted) return;
      setState(() => camera.ready = success);
      if (success && camera.service.audioUnavailable) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No se pudo abrir el micrófono: la cámara grabará sin audio.',
            ),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } catch (e, stackTrace) {
      debugPrint('[VIDEO] Error inicializando cámara: $e\n$stackTrace');
      if (mounted) setState(() => camera.ready = false);
    }
  }

  @override
  void dispose() {
    MultiWindowManager.current.removeListener(this);
    _frameTicker.dispose();
    for (final device in _liveDevices.values) {
      device.dispose();
    }
    for (final camera in _cameras.values) {
      camera.service.dispose();
    }
    _frameClock.dispose();
    super.dispose();
  }


  Future<void> _requestSyncWindow() async {
    await MultiWindowManager.current.invokeMethodToWindow(
      0,
      WindowMessages.syncWindowRequested,
    );

    debugPrint(
      '[SYNC] Solicitud de ventana de sincronización enviada.',
    );
  }

  // ===========================================================================
  // EVENTOS RECIBIDOS DE LA VENTANA PRINCIPAL (IPC)
  // ===========================================================================

  @override
  Future<dynamic> onEventFromWindow(
    String eventName,
    int fromWindowId,
    dynamic arguments,
  ) async {
    debugPrint('[MONITOR] Evento recibido: $eventName | args: $arguments');

    switch (eventName) {
      case WindowMessages.sessionStarted:
        _handleSessionStarted(arguments);
        break;

      case WindowMessages.sessionPaused:
        setState(() {
          _sessionActive = false;
          _sessionPaused = true;
        });
        break;

      case WindowMessages.sessionResumed:
        setState(() {
          _sessionActive = true;
          _sessionPaused = false;
        });
        break;

      case WindowMessages.protocolContext:
        _handleProtocolContext(arguments);
        break;
      
      case WindowMessages.protocolConfiguration:
        if (arguments is Map) {
          final configuration =
              ProtocolConfiguration.fromJson(
            Map<String, dynamic>.from(arguments),
          );

          setState(() {
            _protocolConfiguration = configuration;
            _syncDevices();
          });

          debugPrint(
            '[MONITOR] Configuración de protocolo actualizada: '
            '${configuration.devices.length} dispositivos',
          );
        }
        break;
      
      case WindowMessages.protocolSettings:
        if (arguments is Map) {
          final settings = Map<String, dynamic>.from(arguments);

          setState(() {
            _prepSeconds = settings['prepSeconds'] as int;
            _activitySeconds = settings['activitySeconds'] as int;
            _postSeconds = settings['postSeconds'] as int;
            _useLapMode = settings['useLapMode'] as bool;
            _enableTts = settings['enableTts'] as bool;
          });

          debugPrint(
            '[MONITOR] Ajustes del protocolo recibidos: $settings',
          );
        }
        break;
      
      case WindowMessages.sessionFinished:
        return await _handleSessionFinished();

      case WindowMessages.releaseResources:
        try {
          for (final camera in _cameras.values) {
            await camera.service.dispose();
            camera.ready = false;
          }
          for (final device in _liveDevices.values) {
            await device.service.disconnect();
          }
        } catch (e) {
          debugPrint('[MONITOR] Error liberando cámara/Bluetooth: $e');
        }
        if (mounted) setState(() {});
        return true;

      case 'START_VIDEO_RECORDING':
        // Devuelve {'ok': bool, 'reason': String?} para que la ventana
        // principal muestre la causa concreta del fallo.
        final ready = _cameras.values.where((c) => c.ready).toList();
        if (ready.isEmpty) {
          const reason =
              'La cámara no está preparada. Selecciónala o pulsa '
              '"Reintentar" en el panel de dispositivos.';
          debugPrint('[VIDEO] No se puede iniciar: $reason');
          return {'ok': false, 'reason': reason};
        }

        if (_anyCameraRecording) {
          const reason = 'Ya existe una grabación activa.';
          debugPrint('[VIDEO] No se puede iniciar: $reason');
          return {'ok': false, 'reason': reason};
        }

        final summary = arguments?.toString() ?? _participantIds;

        // All cameras start together; the result is true if any started.
        final results = await Future.wait([
          for (final camera in ready)
            camera.service.startSessionRecording(
              participantSummary: summary,
            ),
        ]);
        final success = results.any((r) => r);

        if (mounted) {
          setState(() {});
        }

        final failures = [
          for (var i = 0; i < ready.length; i++)
            if (!results[i])
              '${ready[i].configuration.deviceName}: '
                  '${ready[i].service.lastStartError ?? 'error desconocido'}',
        ];

        debugPrint(
          '[VIDEO] Resultado inicio grabación: $results $failures',
        );

        return {
          'ok': success,
          'reason': failures.isEmpty ? null : failures.join('\n'),
        };

      case 'STOP_VIDEO_RECORDING':
        if (_anyCameraRecording && arguments is Map) {
          final summary = arguments['participantSummary']?.toString() ?? _participantIds;
          final totalActs = int.tryParse(arguments['totalActivities']?.toString() ?? '0') ?? 0;
          await Future.wait([
            for (final camera in _cameras.values)
              if (camera.service.isRecording)
                camera.service.stopSessionRecording(
                  participantSummary: summary,
                  totalActivities: totalActs,
                ),
          ]);
          if (mounted) setState(() {});
        }
        break;
      
      case WindowMessages.syncAvailability:
        if (arguments is bool) {
          setState(() {
            _syncAvailable = arguments;
          });

          debugPrint(
            '[SYNC] Disponibilidad recibida: '
            '${_syncAvailable ? 'ACTIVA' : 'INACTIVA'}',
          );
        }
        break;
    }
  }

  void _handleSessionStarted(dynamic args) {
    if (args is! Map) return;

    setState(() {
      _sessionActive = true;
      _sessionPaused = false;
      _participantIds = args['participantIds']?.toString() ?? '--';
      _activityIndex = int.tryParse(args['activityIndex']?.toString() ?? '') ?? 0;
      _activityName = args['activityName']?.toString();
      _phaseName = args['phaseName']?.toString() ?? 'idle';
    });

    for (final device in _liveDevices.values) {
      device.service.updateProtocolContext(
        participantId: _participantIds,
        activityIndex: _activityIndex,
        phaseName: _phaseName,
      );
    }
  }

  void _handleProtocolContext(dynamic args) {
    if (args is! Map) return;

    setState(() {
      _participantIds = args['participantIds']?.toString() ?? '--';
      _activityIndex = int.tryParse(args['activityIndex']?.toString() ?? '') ?? 0;
      _activityName = args['activityName']?.toString();
      _phaseName = args['phaseName']?.toString() ?? 'idle';
    });

    for (final device in _liveDevices.values) {
      final service = device.service;
      if (!service.isConnected) continue;

      // Registrar muestra por segundo de HR sincronizada
      if (_sessionActive) {
        service.captureSample(
          participantId: _participantIds,
          activityIndex: _activityIndex,
          phaseName: _phaseName,
        );
      }

      service.updateProtocolContext(
        participantId: _sessionActive ? _participantIds : 'idle',
        activityIndex: _activityIndex,
        phaseName: _sessionActive ? _phaseName : 'idle',
      );
    }
  }

  Future<List<String>> _handleSessionFinished() async {
    setState(() => _sessionActive = false);

    final timestampStr = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;

    final generatedFiles = <String>[];

    // ========================================================================
    // 1-3. HR, ACC y ECG de cada dispositivo en directo
    // ========================================================================
    //
    // The file names carry the device ID of the session (`polar_h10`,
    // `verity_arm`...), which SAVES uses to match each file with its sensor
    // in the manifest.

    for (final device in _liveDevices.values) {
      final service = device.service;
      final id = device.configuration.deviceId;

      if (service.recordedSamples.isNotEmpty) {
        final filePath = await _createTemporaryCsvFile(
          'polar_hr_${id}_$timestampStr.csv',
          service.exportCsv(),
        );
        generatedFiles.add(filePath);
        debugPrint('[MONITOR] Preparado HR CSV: $filePath');
      }

      if (service.recordedAccelerationSamples.isNotEmpty) {
        final filePath = await _createTemporaryCsvFile(
          'polar_acc_${id}_$timestampStr.csv',
          service.exportAccelerationCsv(),
        );
        generatedFiles.add(filePath);
        debugPrint('[MONITOR] Preparado ACC CSV: $filePath');
      }

      if (service.recordedEcgSamples.isNotEmpty) {
        final filePath = await _createTemporaryCsvFile(
          'polar_ecg_${id}_$timestampStr.csv',
          service.exportEcgCsv(),
        );
        generatedFiles.add(filePath);
        debugPrint('[MONITOR] Preparado ECG CSV: $filePath');
      }

      // Disconnections, data gaps and reconnections, to locate the gaps.
      if (service.connectionEvents.isNotEmpty) {
        final filePath = await _createTemporaryCsvFile(
          'polar_connection_events_${id}_$timestampStr.csv',
          service.exportConnectionEventsCsv(),
        );
        generatedFiles.add(filePath);
      }
    }

    // ========================================================================
    // 4. VIDEO SYNC CSV (una fila por vídeo, de todas las cámaras)
    // ========================================================================

    final videoLogs = [
      for (final camera in _cameras.values) ...camera.service.recordedVideoLogs,
    ];

    if (videoLogs.isNotEmpty) {
      final csvContent = VideoRecordingService.exportVideoSyncCsvFor(videoLogs);

      final filePath = await _createTemporaryCsvFile(
        'video_sync_session_$timestampStr.csv',
        csvContent,
      );

      generatedFiles.add(filePath);

      debugPrint(
        '[MONITOR] Preparado Video Sync CSV: $filePath',
      );

      // ======================================================================
      // 5. VIDEO
      // ======================================================================

      for (final videoLog in videoLogs) {
        if (await File(videoLog.filePath).exists()) {
          generatedFiles.add(videoLog.filePath);

          debugPrint(
            '[MONITOR] Vídeo preparado: ${videoLog.filePath}',
          );
        }
      }
    }

    return generatedFiles;
  }


  // ===========================================================================
  // DIÁLOGO DE AJUSTES DE PROTOCOLO
  // ===========================================================================
  
  void _showSettingsDialog() {
    final prepMinutesController = TextEditingController(
      text: (_prepSeconds ~/ 60).toString().padLeft(2, '0'),
    );
    final prepSecondsController = TextEditingController(
      text: (_prepSeconds % 60).toString().padLeft(2, '0'),
    );

    final activityMinutesController = TextEditingController(
      text: (_activitySeconds ~/ 60).toString().padLeft(2, '0'),
    );
    final activitySecondsController = TextEditingController(
      text: (_activitySeconds % 60).toString().padLeft(2, '0'),
    );

    final postMinutesController = TextEditingController(
      text: (_postSeconds ~/ 60).toString().padLeft(2, '0'),
    );
    final postSecondsController = TextEditingController(
      text: (_postSeconds % 60).toString().padLeft(2, '0'),
    );

    bool tempLapMode = _useLapMode;
    bool tempTtsMode = _enableTts;

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1E293B),
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(24)),
              ),
              title: const Row(
                children: [
                  Icon(
                    Icons.tune_rounded,
                    color: Color(0xFF38BDF8),
                  ),
                  SizedBox(width: 10),
                  Text(
                    'Ajustes del Protocolo',
                    style: TextStyle(color: Colors.white),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    _buildDurationInput(
                      label: 'Preparación estática inicial',
                      minutesController: prepMinutesController,
                      secondsController: prepSecondsController,
                    ),
                    const SizedBox(height: 12),
                    _buildDurationInput(
                      label: 'Actividad principal',
                      minutesController: activityMinutesController,
                      secondsController: activitySecondsController,
                    ),
                    const SizedBox(height: 12),
                    _buildDurationInput(
                      label: 'Post-actividad estática final',
                      minutesController: postMinutesController,
                      secondsController: postSecondsController,
                    ),
                    const SizedBox(height: 16),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'Indicaciones por voz',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.white,
                        ),
                      ),
                      subtitle: const Text(
                        'Dicta las instrucciones y cambios de fase',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white54,
                        ),
                      ),
                      value: tempTtsMode,
                      activeTrackColor: const Color(0xFF38BDF8),
                      onChanged: (val) =>
                          setStateDialog(() => tempTtsMode = val),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'Modo Lap (Espera manual)',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.white,
                        ),
                      ),
                      subtitle: const Text(
                        'Pausa al finalizar para rotación de actividad',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white54,
                        ),
                      ),
                      value: tempLapMode,
                      activeTrackColor: const Color(0xFF38BDF8),
                      onChanged: (val) =>
                          setStateDialog(() => tempLapMode = val),
                    ),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text(
                    'Cancelar',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
                FilledButton(
                  onPressed: () {
                    final newPrep = _durationFromControllers(
                      minutesController: prepMinutesController,
                      secondsController: prepSecondsController,
                      minimumSeconds: 5,
                      fallbackSeconds: _prepSeconds,
                    );

                    final newActivity = _durationFromControllers(
                      minutesController: activityMinutesController,
                      secondsController: activitySecondsController,
                      minimumSeconds: 1,
                      fallbackSeconds: _activitySeconds,
                    );

                    final newPost = _durationFromControllers(
                      minutesController: postMinutesController,
                      secondsController: postSecondsController,
                      minimumSeconds: 5,
                      fallbackSeconds: _postSeconds,
                    );

                    MultiWindowManager.current.invokeMethodToWindow(
                      0,
                      WindowMessages.protocolSettingsUpdated,
                      {
                        'prepSeconds': newPrep,
                        'activitySeconds': newActivity,
                        'postSeconds': newPost,
                        'useLapMode': tempLapMode,
                        'enableTts': tempTtsMode,
                      },
                    );

                    setState(() {
                      _prepSeconds = newPrep;
                      _activitySeconds = newActivity;
                      _postSeconds = newPost;
                      _useLapMode = tempLapMode;
                      _enableTts = tempTtsMode;
                    });

                    Navigator.of(context).pop();
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF38BDF8),
                    foregroundColor: Colors.black,
                  ),
                  child: const Text('Guardar'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ===========================================================================
  // DIÁLOGO DE CONEXIÓN POLAR BLE
  // ===========================================================================

  /// Words of the advertised name that identify each live device type.
  static const _bleNameHints = {
    'polar_h10': 'h10',
    'verity_sense': 'sense',
  };

  void _showPolarConnectionDialog(String deviceId) {
    final device = _liveDevices[deviceId];
    if (device == null) return;
    final service = device.service;
    final configuration = device.configuration;
    final title = configuration.placementLabel == null
        ? configuration.deviceName
        : '${configuration.deviceName} · ${configuration.placementLabel}';

    debugPrint(
      '[POLAR UI] $deviceId isConnected = ${service.isConnected}',
    );
    
    if (service.isConnected) {
      showDialog(
        context: context,
        builder: (dialogCtx) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1E293B),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            title: Row(
              children: [
                const Icon(
                  Icons.bluetooth_connected_rounded,
                  color: Color(0xFF38BDF8),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
            content: Text(
              'Vinculado a ${service.connectedDeviceName ?? service.connectedDeviceId}.',
              style: const TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(dialogCtx).pop();
                },
                child: const Text('Cancelar'),
              ),
              FilledButton.icon(
                onPressed: () async {
                  await service.disconnect();

                  if (!dialogCtx.mounted) return;

                  Navigator.of(dialogCtx).pop();

                  if (!mounted) return;

                  setState(() {});

                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('$title desvinculado'),
                    ),
                  );
                },
                icon: const Icon(Icons.bluetooth_disabled_rounded),
                label: const Text('Desvincular'),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          );
        },
      );

      return;
    }

    // Devices already linked to another sensor of the session.
    final taken = {
      for (final other in _liveDevices.values)
        if (other != device && other.service.connectedDeviceId != null)
          other.service.connectedDeviceId!,
    };
    final hint = _bleNameHints[configuration.type];
    final serial = configuration.serial?.toLowerCase();

    service.startScan();

    var connecting = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1E293B),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              title: Row(
                children: [
                  const Icon(Icons.bluetooth_searching_rounded, color: Color(0xFF38BDF8)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('Conectar $title', style: const TextStyle(color: Colors.white)),
                  ),
                ],
              ),
              content: SizedBox(
                width: 420,
                height: 320,
                child: connecting
                    ? _buildPolarConnectingView(service)
                    : StreamBuilder<List<BleDevice>>(
                  stream: service.scanStream,
                  builder: (context, snapshot) {
                    // Devices of this type first; the serial (printed on
                    // the sensor and part of its Bluetooth name) on top.
                    int rank(BleDevice d) {
                      final name = (d.name ?? '').toLowerCase();
                      if (serial != null && serial.isNotEmpty && name.contains(serial)) return 0;
                      if (hint != null && name.contains(hint)) return 1;
                      if (name.contains('polar')) return 2;
                      return 3;
                    }

                    final results = [
                      for (final d in snapshot.data ?? const <BleDevice>[])
                        if (!taken.contains(d.deviceId)) d,
                    ]..sort((a, b) => rank(a).compareTo(rank(b)));
                    if (results.isEmpty) {
                      return const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(color: Color(0xFF38BDF8)),
                            SizedBox(height: 16),
                            Text('Buscando dispositivos BLE...', style: TextStyle(color: Colors.white54)),
                          ],
                        ),
                      );
                    }

                    return ListView.builder(
                      itemCount: results.length,
                      itemBuilder: (context, index) {
                        final bleDevice = results[index];
                        final r = rank(bleDevice);
                        final name = bleDevice.name?.isNotEmpty == true
                            ? bleDevice.name!
                            : 'Dispositivo BLE (${bleDevice.deviceId})';

                        return ListTile(
                          leading: Icon(
                            r == 0 ? Icons.verified_rounded : Icons.favorite,
                            color: r <= 1 ? Colors.redAccent : Colors.white24,
                          ),
                          title: Text(
                            name,
                            style: TextStyle(
                              color: r <= 1 ? Colors.white : Colors.white54,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: Text(
                            r == 0 ? 'Coincide el número de serie' : bleDevice.deviceId,
                            style: const TextStyle(color: Colors.white38, fontSize: 11),
                          ),
                          trailing: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF38BDF8),
                              foregroundColor: Colors.black,
                            ),
                            onPressed: () async {
                              setDialogState(() => connecting = true);
                              await service.stopScan();
                              final connected = await service.connectToDevice(bleDevice);
                              final failed = connected
                                  ? await device.startConfiguredSignals()
                                  : const <String>[];
                              if (dialogCtx.mounted) {
                                Navigator.of(dialogCtx).pop();
                              }
                              if (mounted) {
                                ScaffoldMessenger.of(this.context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      !connected
                                          ? service.linkStatus.value.message
                                          : failed.isEmpty
                                              ? 'Conectado a $name'
                                              : 'Conectado a $name, sin ${failed.join(', ')}'
                                                  '${service.pmdProblem == null ? '' : '. ${service.pmdProblem}.'}',
                                    ),
                                    duration: Duration(seconds: connected && failed.isEmpty ? 4 : 12),
                                    backgroundColor: !connected
                                        ? Colors.redAccent
                                        : failed.isEmpty
                                            ? const Color(0xFF34D399)
                                            : Colors.orange,
                                  ),
                                );
                                setState(() {});
                              }
                            },
                            child: const Text('Vincular'),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
              actions: [
                if (connecting)
                  TextButton(
                    onPressed: () async {
                      Navigator.of(dialogCtx).pop();
                      await service.cancelConnection();
                    },
                    child: const Text('Cancelar conexión', style: TextStyle(color: Colors.white54)),
                  )
                else
                  TextButton(
                    onPressed: () {
                      service.stopScan();
                      Navigator.of(dialogCtx).pop();
                    },
                    child: const Text('Cerrar', style: TextStyle(color: Colors.white54)),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildPolarConnectingView(PolarBleService service) {
    return ValueListenableBuilder<PolarLinkStatus>(
      valueListenable: service.linkStatus,
      builder: (context, status, _) {
        final isError = status.state == PolarLinkState.error;
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isError)
                const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 40)
              else
                const CircularProgressIndicator(color: Color(0xFF38BDF8)),
              const SizedBox(height: 16),
              Text(
                status.message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              if (status.state == PolarLinkState.pairing) ...[
                const SizedBox(height: 12),
                const Text(
                  'Si Windows pide permiso para emparejar, pulsa "Permitir". '
                  'Si no aparece nada en un minuto, cancela y vuelve a intentarlo.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  static DeviceConnectionStatus _polarConnectionStatus(PolarBleService service) {
    switch (service.linkStatus.value.state) {
      case PolarLinkState.connected:
        return DeviceConnectionStatus.connected;
      case PolarLinkState.connecting:
      case PolarLinkState.pairing:
      case PolarLinkState.configuring:
      case PolarLinkState.reconnecting:
        return DeviceConnectionStatus.connecting;
      case PolarLinkState.error:
        return DeviceConnectionStatus.error;
      case PolarLinkState.disconnected:
        return service.isConnected
            ? DeviceConnectionStatus.connected
            : DeviceConnectionStatus.disconnected;
    }
  }

  static const _sensorLabels = {
    'heart_rate': ('HR', Icons.favorite_rounded),
    'rr': ('RR', Icons.timeline_rounded),
    'acc': ('ACC', Icons.sensors_rounded),
    'ecg': ('ECG', Icons.show_chart_rounded),
  };

  /// Every device of the session, in the order of the session setup.
  List<DeviceStatus> get _deviceStatuses {
    final statuses = <DeviceStatus>[];

    for (final device in _protocolConfiguration.devices) {
      final subtitle = [
        if (device.placementLabel != null) device.placementLabel!,
        if (device.serial != null) 'n.º ${device.serial}',
      ].join(' · ');

      final camera = _cameras[device.deviceId];
      if (camera != null) {
        statuses.add(
          DeviceStatus(
            id: device.deviceId,
            name: '${device.deviceName} · ${device.deviceId}',
            subtitle: camera.ready
                ? camera.service.selectedCamera?.name
                : (subtitle.isEmpty ? null : subtitle),
            icon: Icons.videocam_rounded,
            connectionStatus: camera.recovering
                ? DeviceConnectionStatus.connecting
                : camera.ready
                    ? DeviceConnectionStatus.connected
                    : camera.service.cameraError.value != null
                        ? DeviceConnectionStatus.error
                        : DeviceConnectionStatus.disconnected,
            statusMessage: camera.recovering
                ? 'Recuperando cámara...'
                : camera.ready
                    ? null
                    : camera.service.cameraError.value,
            sensors: [
              if (device.hasSensor('video'))
                SensorStatus(
                  id: 'video',
                  name: camera.service.audioUnavailable ? 'Vídeo (sin audio)' : 'Vídeo + audio',
                  icon: Icons.videocam_rounded,
                  status: camera.service.isRecording
                      ? SensorAcquisitionStatus.acquiring
                      : camera.ready
                          ? SensorAcquisitionStatus.ready
                          : SensorAcquisitionStatus.unavailable,
                  detail: camera.ready ? camera.service.resolutionLabel : null,
                ),
            ],
          ),
        );
        continue;
      }

      final live = _liveDevices[device.deviceId];
      if (live != null) {
        final service = live.service;
        bool streaming(String sensor) => switch (sensor) {
              'heart_rate' => service.isHeartRateStreaming,
              'rr' => service.isRrStreaming,
              'acc' => service.isAccelerationStreaming,
              'ecg' => service.isEcgStreaming,
              _ => false,
            };
        statuses.add(
          DeviceStatus(
            id: device.deviceId,
            name: '${device.deviceName} · ${device.deviceId}',
            subtitle: service.isConnected
                ? [
                    service.connectedDeviceName ?? service.connectedDeviceId,
                    if (subtitle.isNotEmpty) subtitle,
                  ].join(' · ')
                : (subtitle.isEmpty ? null : subtitle),
            icon: Icons.favorite_rounded,
            connectionStatus: _polarConnectionStatus(service),
            statusMessage: switch (service.linkStatus.value.state) {
              PolarLinkState.connected || PolarLinkState.disconnected => null,
              _ => service.linkStatus.value.message,
            },
            sensors: [
              for (final sensor in _sensorLabels.keys)
                if (device.hasSensor(sensor))
                  SensorStatus(
                    id: sensor,
                    name: _sensorLabels[sensor]!.$1,
                    icon: _sensorLabels[sensor]!.$2,
                    status: streaming(sensor)
                        ? SensorAcquisitionStatus.acquiring
                        : service.isConnected
                            ? SensorAcquisitionStatus.stopped
                            : SensorAcquisitionStatus.unavailable,
                    detail: switch (sensor) {
                      'acc' when service.isAccelerationStreaming =>
                        '${service.accSampleRateHz} Hz',
                      'ecg' => '${PolarBleService.ecgSampleRateHz} Hz',
                      _ => null,
                    },
                  ),
            ],
          ),
        );
        continue;
      }

      // Offline sensors (and live ones without signals here): listed so the
      // team sees the whole setup, but they record on their own.
      statuses.add(
        DeviceStatus(
          id: device.deviceId,
          name: '${device.deviceName} · ${device.deviceId}',
          subtitle: subtitle.isEmpty ? null : subtitle,
          icon: Icons.watch_rounded,
          connectionStatus: DeviceConnectionStatus.disconnected,
          note: 'Graba por su cuenta (sin conexión en directo)',
        ),
      );
    }

    return statuses;
  }


  // ===========================================================================
  // UI
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF07090E),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              _buildHeader(),
              const SizedBox(height: 16),

              // ===============================================================
              // CONTROL DE SESIÓN
              // ===============================================================
              _buildSessionControlPanel(),

              const SizedBox(height: 16),

              // ===============================================================
              // MONITORIZACIÓN
              // ===============================================================
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 3,
                      child: _buildMonitoringArea(),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      flex: 2,
                      child: _buildDeviceStatusPanel(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSessionControlPanel() {
    return _MonitorCard(
      title: 'CONTROL DE SESIÓN',
      icon: Icons.tune_rounded,
      child: Row(
        children: [
          FilledButton.icon(
            onPressed: () async {
              final message = !_sessionActive && !_sessionPaused
                  ? WindowMessages.sessionStartRequested
                  : _sessionPaused
                      ? WindowMessages.sessionResumeRequested
                      : WindowMessages.sessionPauseRequested;

              await MultiWindowManager.current.invokeMethodToWindow(
                0,
                message,
              );
            },
            icon: Icon(
              _sessionPaused
                  ? Icons.play_arrow_rounded
                  : _sessionActive
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
            ),
            label: Text(
              _sessionPaused
                  ? 'REANUDAR'
                  : _sessionActive
                      ? 'PAUSAR'
                      : 'INICIAR',
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton.tonalIcon(
              onPressed: () async {
                await MultiWindowManager.current.invokeMethodToWindow(
                  0,
                  WindowMessages.lapRequested,
                );
              },
              icon: const Icon(Icons.skip_next_rounded),
              label: const Text(
                'LAP',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          _buildSyncButton(),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton.icon(
              onPressed: () async {
                await MultiWindowManager.current.invokeMethodToWindow(
                  0,
                  WindowMessages.sessionFinishRequested,
                );
              },
              style: FilledButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.stop_rounded),
              label: const Text(
                'FINALIZAR Y SINCRONIZAR',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          IconButton(
            tooltip: _enableTts ? 'Desactivar voz' : 'Activar voz',
            style: IconButton.styleFrom(
              foregroundColor: const Color(0xFF38BDF8),
              backgroundColor: const Color(0xFF1E293B),
            ),
            onPressed: () async {
              await MultiWindowManager.current.invokeMethodToWindow(
                0,
                WindowMessages.voiceToggleRequested,
              );
            },
            icon: Icon(
              _enableTts
                  ? Icons.volume_up_rounded
                  : Icons.volume_off_rounded,
            ),
          ),
          IconButton(
            tooltip: 'Ajustes',
            style: IconButton.styleFrom(
              foregroundColor: const Color(0xFF38BDF8),
              backgroundColor: const Color(0xFF1E293B),
            ),
            onPressed: _showSettingsDialog,
            icon: const Icon(Icons.settings_rounded),
          ),
          IconButton(
            tooltip: 'Cancelar prueba',
            style: IconButton.styleFrom(
              foregroundColor: const Color.fromARGB(255, 243, 52, 52),
              backgroundColor: const Color(0xFF1E293B),
            ),
            onPressed: () async {
              await MultiWindowManager.current.invokeMethodToWindow(
                0,
                WindowMessages.sessionCancelRequested,
              );
            },
            icon: const Icon(
              Icons.close_rounded,
              color: Colors.redAccent,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMonitoringArea() {
    return _MonitorCard(
      title: 'MONITORIZACIÓN EN TIEMPO REAL',
      icon: Icons.monitor_heart_rounded,
      expandChild: true,
      child: _buildVideoAndCharts(),
    );
  }

  Widget _buildVideoAndCharts() {
    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 1.6,
      ),
      itemCount: _monitorSlots.length,
      itemBuilder: (context, index) {
        return _buildMonitorSlot(_monitorSlots[index]);
      },
    );
  }

  Widget _buildMonitorSlot(MonitorSlot slot) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white12),
      ),
      padding: const EdgeInsets.all(14),
      child: !slot.isAssigned
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.add_chart_rounded,
                    size: 32,
                    color: Colors.grey.shade600,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'MONITOR ${slot.slotId}',
                    style: TextStyle(
                      color: Colors.grey.shade400,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.0,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Sin sensor asignado',
                    style: TextStyle(
                      color: Colors.grey.shade600,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            )
          : switch (slot.visualization) {
              MonitorVisualization.heartRate =>
                _buildHeartRateMonitor(slot),
              MonitorVisualization.rr =>
                _buildRrMonitor(slot),
              MonitorVisualization.acceleration =>
                _buildAccelerationMonitor(slot),
              MonitorVisualization.ecg =>
                _buildEcgMonitor(slot),
              MonitorVisualization.video =>
                _buildVideoMonitor(slot),
              MonitorVisualization.unknown =>
                _buildAssignedMonitorPlaceholder(slot),
            },
    );
  }

  Widget _buildChart({
    required MonitorSlot slot,
    required String label,
    required IconData icon,
    required String unit,
    required Duration window,
    required List<ChartSeries> series,
    required String Function() currentValue,
    Widget? trailingAction,
  }) {
    return SensorChartCard(
      title: 'MONITOR ${slot.slotId}',
      subtitle: '$label · ${slot.deviceId}',
      icon: icon,
      currentValue: currentValue,
      unit: unit,
      window: window,
      clock: _frameClock,
      seriesList: series,
      trailingAction: trailingAction,
    );
  }

  static String _format(double? value, [int decimals = 0]) =>
      value == null ? '--' : value.toStringAsFixed(decimals);

  Widget _buildHeartRateMonitor(MonitorSlot slot) {
    final device = _liveDevices[slot.deviceId];
    if (device == null) return _buildAssignedMonitorPlaceholder(slot);
    return _buildChart(
      slot: slot,
      label: 'HR',
      icon: Icons.favorite_rounded,
      unit: 'bpm',
      window: device.hr.window,
      currentValue: () => _format(device.hr.lastValue),
      series: [
        ChartSeries(
          buffer: device.hr,
          color: Colors.redAccent,
          label: 'HR',
        ),
      ],
    );
  }

  Widget _buildRrMonitor(MonitorSlot slot) {
    final device = _liveDevices[slot.deviceId];
    if (device == null) return _buildAssignedMonitorPlaceholder(slot);
    return _buildChart(
      slot: slot,
      label: 'RR',
      icon: Icons.timeline_rounded,
      unit: 'ms',
      window: device.rr.window,
      currentValue: () => _format(device.rr.lastValue),
      series: [
        ChartSeries(
          buffer: device.rr,
          color: Colors.orangeAccent,
          label: 'RR',
        ),
      ],
    );
  }

  Widget _buildAccelerationMonitor(MonitorSlot slot) {
    final device = _liveDevices[slot.deviceId];
    if (device == null) return _buildAssignedMonitorPlaceholder(slot);
    return _buildChart(
      slot: slot,
      label: 'ACC',
      icon: Icons.sensors_rounded,
      unit: 'mg',
      window: device.accVm.window,
      currentValue: () => _accMode == 'VM'
          ? _format(device.accVm.lastValue, 1)
          : _format(device.accZ.lastValue, 1),
      series: _accMode == 'VM'
          ? [
              ChartSeries(
                buffer: device.accVm,
                color: const Color(0xFF38BDF8),
                label: 'VM',
              ),
            ]
          : [
              ChartSeries(
                buffer: device.accX,
                color: Colors.redAccent,
                label: 'X',
              ),
              ChartSeries(
                buffer: device.accY,
                color: Colors.greenAccent,
                label: 'Y',
              ),
              ChartSeries(
                buffer: device.accZ,
                color: const Color(0xFF38BDF8),
                label: 'Z',
              ),
            ],
      trailingAction: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildAccelerationModeToggle(
            'VM',
            _accMode == 'VM',
            const Color(0xFF38BDF8),
          ),
          _buildAccelerationModeToggle(
            'XYZ',
            _accMode == 'XYZ',
            null,
          ),
        ],
      ),
    );
  }

  Widget _buildEcgMonitor(MonitorSlot slot) {
    final device = _liveDevices[slot.deviceId];
    if (device == null) return _buildAssignedMonitorPlaceholder(slot);
    return _buildChart(
      slot: slot,
      label: 'ECG',
      icon: Icons.show_chart_rounded,
      unit: 'µV',
      window: device.ecg.window,
      currentValue: () => _format(device.ecg.lastValue),
      series: [
        ChartSeries(
          buffer: device.ecg,
          color: const Color(0xFFF43F5E),
          label: 'ECG',
        ),
      ],
    );
  }

  Widget _buildVideoMonitor(MonitorSlot slot) {
    final camera = _cameras[slot.deviceId];
    final controller = camera?.service.controller;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: (camera != null &&
              camera.ready &&
              controller != null &&
              controller.value.isInitialized)
          ? Stack(
              fit: StackFit.expand,
              children: [
                Center(
                  child: AspectRatio(
                    aspectRatio: controller.value.aspectRatio,
                    child: CameraPreview(controller),
                  ),
                ),
                Positioned(
                  top: 10,
                  left: 10,
                  child: Text(
                    slot.deviceId ?? '',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.w800,
                      fontSize: 11,
                      shadows: [Shadow(blurRadius: 4)],
                    ),
                  ),
                ),
                if (camera.service.isRecording)
                  Positioned(
                    top: 10,
                    right: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.redAccent,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.fiber_manual_record,
                            color: Colors.white,
                            size: 12,
                          ),
                          SizedBox(width: 6),
                          Text(
                            'REC',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w900,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            )
          : const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.videocam_off_rounded,
                    color: Colors.white38,
                    size: 40,
                  ),
                  SizedBox(height: 10),
                  Text(
                    'Cámara no disponible o inicializando...',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 13,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildAssignedMonitorPlaceholder(MonitorSlot slot) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              Icons.monitor_heart_rounded,
              size: 18,
              color: Colors.lightBlueAccent,
            ),
            const SizedBox(width: 8),
            Text(
              'MONITOR ${slot.slotId}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.0,
              ),
            ),
          ],
        ),
        const Spacer(),
        Center(
          child: Text(
            '${slot.deviceId}:${slot.sensorId}',
            style: TextStyle(
              color: Colors.grey.shade400,
              fontSize: 13,
            ),
          ),
        ),
        const Spacer(),
      ],
    );
  }

  Widget _buildDeviceStatusPanel() {
    return _MonitorCard(
      title: 'DISPOSITIVOS Y SENSORES',
      icon: Icons.devices_other_rounded,
      expandChild: true,
      child: ListView.separated(
        itemCount: _deviceStatuses.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          return _DeviceStatusCard(
            device: _deviceStatuses[index],
            onSensorTap: _handleSensorTap,
            onDeviceAction: _deviceActionForDevice(
              _deviceStatuses[index].id,
            ),
            onRetry: _retryActionForDevice(
              _deviceStatuses[index].id,
            ),
          );
        },
      ),
    );
  }

  Widget _buildHeader() {
    return _MonitorCard(
      title: 'SESIÓN',
      icon: Icons.assignment_rounded,
      child: Row(
        children: [
          // ---------------------------------------------------------------
          // PARTICIPANTE
          // ---------------------------------------------------------------
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'PARTICIPANTE',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: Colors.white38,
                    letterSpacing: 1.1,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$_participantIds · Día 0',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),

          // Separador
          Container(
            width: 1,
            height: 38,
            color: Colors.white12,
          ),

          const SizedBox(width: 20),

          // ---------------------------------------------------------------
          // ACTIVIDAD
          // ---------------------------------------------------------------
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'ACTIVIDAD ACTUAL',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: Colors.white38,
                    letterSpacing: 1.1,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        _sessionActive || _sessionPaused
                            ? _activityName == null
                                ? 'Actividad $_activityIndex'
                                : 'Actividad $_activityIndex · $_activityName'
                            : 'No iniciado',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF38BDF8).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        _phaseName.toUpperCase(),
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF38BDF8),
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Separador
          Container(
            width: 1,
            height: 38,
            color: Colors.white12,
          ),

          const SizedBox(width: 20),

          // ---------------------------------------------------------------
          // ESTADO
          // ---------------------------------------------------------------
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _StatusDot(
                color: _sessionActive
                    ? Colors.greenAccent
                    : Colors.grey,
              ),
              const SizedBox(width: 8),
              Text(
                _sessionActive ? 'SESIÓN ACTIVA' : 'EN ESPERA',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  color: _sessionActive
                      ? Colors.greenAccent
                      : Colors.grey.shade400,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSyncButton() {
    return ElevatedButton.icon(
      onPressed: _syncAvailable ? _requestSyncWindow : null,
      icon: const Icon(
        Icons.sync_rounded,
        size: 18,
      ),
      label: const Text(
        'SINCRONIZAR',
        style: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 12,
        ),
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF38BDF8),
        foregroundColor: Colors.black,
        disabledBackgroundColor: Colors.grey.shade300,
        disabledForegroundColor: Colors.grey.shade600,
        padding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 10,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
    );
  }

  Widget _buildTimePartField({
    required TextEditingController controller,
    required String label,
    required String hint,
  }) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(2),
      ],
      textAlign: TextAlign.center,
      style: const TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.w800,
        fontFeatures: [
          FontFeature.tabularFigures(),
        ],
      ),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: const TextStyle(
          color: Colors.white70,
          fontSize: 12,
        ),
        hintStyle: const TextStyle(
          color: Colors.white24,
          fontSize: 11,
        ),
        filled: true,
        fillColor: const Color(0xFF0F172A),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _buildDurationInput({
    required String label,
    required TextEditingController minutesController,
    required TextEditingController secondsController,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: Colors.white70,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _buildTimePartField(
                controller: minutesController,
                label: 'MM',
                hint: 'min',
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                ':',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            Expanded(
              child: _buildTimePartField(
                controller: secondsController,
                label: 'SS',
                hint: 'seg',
              ),
            ),
          ],
        ),
      ],
    );
  }

  // Widget auxiliar para el selector VM / XYZ del acelerómetro
  Widget _buildAccelerationModeToggle(String label, bool isSelected, Color? singleColor) {
    return GestureDetector(
      onTap: () => setState(() => _accMode = label),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF38BDF8) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: label == 'XYZ' && isSelected
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'XYZ',
                    style: TextStyle(
                      color: isSelected ? Colors.black : Colors.white60,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 4),
                  // Mini indicadores de los 3 ejes
                  Container(width: 5, height: 5, decoration: const BoxDecoration(color: Colors.redAccent, shape: BoxShape.circle)),
                  const SizedBox(width: 2),
                  Container(width: 5, height: 5, decoration: const BoxDecoration(color: Colors.greenAccent, shape: BoxShape.circle)),
                  const SizedBox(width: 2),
                  Container(width: 5, height: 5, decoration: const BoxDecoration(color: Color(0xFF38BDF8), shape: BoxShape.circle)),
                ],
              )
            : Text(
                label,
                style: TextStyle(
                  color: isSelected ? Colors.black : Colors.white60,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
      ),
    );
  }

  int _durationFromControllers({
    required TextEditingController minutesController,
    required TextEditingController secondsController,
    required int minimumSeconds,
    required int fallbackSeconds,
  }) {
    final minutes =
        int.tryParse(minutesController.text) ?? (fallbackSeconds ~/ 60);

    final seconds =
        int.tryParse(secondsController.text) ?? (fallbackSeconds % 60);

    final totalSeconds =
        (minutes.clamp(0, 99) * 60) + seconds.clamp(0, 59);

    return totalSeconds < minimumSeconds
        ? minimumSeconds
        : totalSeconds;
  }

  Future<String> _createTemporaryCsvFile(
    String fileName,
    String content,
  ) async {
    _sessionExportDirectory ??=
        await Directory.systemTemp.createTemp(
      'lab_protocol_timer_session_',
    );

    final file = File(
      '${_sessionExportDirectory!.path}'
      '${Platform.pathSeparator}'
      '$fileName',
    );

    await file.writeAsString(content);

    return file.path;
  }
}

class _MonitorCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;
  final bool expandChild;

  const _MonitorCard({
    required this.title,
    required this.icon,
    required this.child,
    this.expandChild = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                color: const Color(0xFF38BDF8),
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          if (expandChild)
            Expanded(child: child)
          else
            child,
        ],
      ),
    );
  }
}

class _DeviceStatusCard extends StatelessWidget {
  final DeviceStatus device;
  final void Function(String deviceId, String sensorId) onSensorTap;
  final VoidCallback? onDeviceAction;
  final VoidCallback? onRetry;

  const _DeviceStatusCard({
    required this.device,
    required this.onSensorTap,
    this.onDeviceAction,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(device.icon),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    device.name,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                if (onRetry != null) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Reintentar conexión',
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                    onPressed: onRetry,
                  ),
                ],
                if (onDeviceAction != null) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Configurar dispositivo',
                    icon: const Icon(Icons.settings_rounded, size: 20),
                    onPressed: onDeviceAction,
                  ),
                ],
                _StatusDot(
                  color: _deviceConnectionColor(
                    device.connectionStatus,
                  ),
                ),
              ],
            ),
            if (device.subtitle != null)
              Padding(
                padding: const EdgeInsets.only(left: 32, top: 2),
                child: Text(
                  device.subtitle!,
                  style: const TextStyle(fontSize: 12, color: Colors.white54),
                ),
              ),
            if (device.statusMessage != null)
              Padding(
                padding: const EdgeInsets.only(left: 32, top: 2),
                child: Text(
                  device.statusMessage!,
                  style: TextStyle(
                    fontSize: 12,
                    color: device.connectionStatus ==
                            DeviceConnectionStatus.error
                        ? Colors.redAccent
                        : Colors.orangeAccent,
                  ),
                ),
              ),
            if (device.note != null)
              Padding(
                padding: const EdgeInsets.only(left: 32, top: 4),
                child: Text(
                  device.note!,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.white38,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            if (device.sensors.isNotEmpty) const SizedBox(height: 10),
            ...device.sensors.map(
              (sensor) => Padding(
                padding: const EdgeInsets.only(top: 4),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    onSensorTap(
                      device.id,
                      sensor.id,
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 6,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          sensor.icon,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(sensor.name),
                        ),
                        if (sensor.detail != null) ...[
                          Text(
                            sensor.detail!,
                            style: const TextStyle(
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        _StatusDot(
                          color: _sensorStatusColor(
                            sensor.status,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _deviceConnectionColor(
    DeviceConnectionStatus status,
  ) {
    switch (status) {
      case DeviceConnectionStatus.connected:
        return Colors.green;
      case DeviceConnectionStatus.connecting:
        return Colors.orange;
      case DeviceConnectionStatus.disconnected:
        return Colors.grey;
      case DeviceConnectionStatus.error:
        return Colors.red;
    }
  }

  Color _sensorStatusColor(
    SensorAcquisitionStatus status,
  ) {
    switch (status) {
      case SensorAcquisitionStatus.acquiring:
        return Colors.green;
      case SensorAcquisitionStatus.ready:
        return Colors.blue;
      case SensorAcquisitionStatus.stopped:
        return Colors.orange;
      case SensorAcquisitionStatus.unavailable:
        return Colors.grey;
      case SensorAcquisitionStatus.error:
        return Colors.red;
    }
  }
}


class _StatusDot extends StatelessWidget {
  final Color color;

  const _StatusDot({
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }
}
/// A live Polar device of the session and the last seconds of each signal.
class _LiveDevice {
  DeviceConfiguration configuration;
  final PolarBleService service = PolarBleService();
  final VoidCallback onSamples;
  final VoidCallback onStatusChanged;

  // Windows of the live charts. The ECG strip is short so each beat is
  // wide enough to read; heart rate and RR show the trend of two minutes.
  final SignalBuffer hr = SignalBuffer(window: const Duration(minutes: 2), maxRateHz: 4);
  final SignalBuffer rr = SignalBuffer(window: const Duration(minutes: 2), maxRateHz: 5);
  final SignalBuffer ecg = SignalBuffer(window: const Duration(seconds: 6), maxRateHz: 140);
  final SignalBuffer accX = SignalBuffer(window: const Duration(seconds: 10), maxRateHz: 210);
  final SignalBuffer accY = SignalBuffer(window: const Duration(seconds: 10), maxRateHz: 210);
  final SignalBuffer accZ = SignalBuffer(window: const Duration(seconds: 10), maxRateHz: 210);
  final SignalBuffer accVm = SignalBuffer(window: const Duration(seconds: 10), maxRateHz: 210);

  final List<StreamSubscription<dynamic>> _subscriptions = [];

  _LiveDevice(
    this.configuration, {
    required this.onSamples,
    required this.onStatusChanged,
  }) {
    service.linkStatus.addListener(onStatusChanged);
    _subscriptions.addAll([
      service.hrStream.listen((bpm) {
        if (bpm <= 0) return; // 0 = disconnected
        hr.add(DateTime.now().toUtc(), bpm.toDouble());
        onSamples();
      }),
      service.rrStream.listen((rrMs) {
        rr.add(DateTime.now().toUtc(), rrMs.toDouble());
        onSamples();
      }),
      // Every sample, with the sensor's own timestamps.
      service.ecgStream.listen((sample) {
        ecg.add(sample.timestamp, sample.microVolts.toDouble());
        onSamples();
      }),
      service.accelerationStream.listen((sample) {
        final t = sample.timestamp;
        accX.add(t, sample.xMg);
        accY.add(t, sample.yMg);
        accZ.add(t, sample.zMg);
        accVm.add(
          t,
          math.sqrt(sample.xMg * sample.xMg + sample.yMg * sample.yMg + sample.zMg * sample.zMg),
        );
        onSamples();
      }),
    ]);
  }

  /// Starts the signals of [configuration] one by one and returns those that
  /// the device refused (e.g. ECG on a sensor without it).
  Future<List<String>> startConfiguredSignals() async {
    final failed = <String>[];
    for (final (signal, start) in [
      ('heart_rate', service.startHeartRate),
      ('acc', service.startAcceleration),
      ('ecg', service.startEcg),
    ]) {
      if (!configuration.hasSensor(signal)) continue;
      try {
        await start();
      } catch (e) {
        debugPrint('[POLAR DEBUG] ${configuration.deviceId}: $signal no iniciado: $e');
        failed.add(signal == 'heart_rate' ? 'HR' : signal.toUpperCase());
      }
    }
    for (final buffer in [hr, rr, ecg, accX, accY, accZ, accVm]) {
      buffer.clear();
    }
    return failed;
  }

  void dispose() {
    service.linkStatus.removeListener(onStatusChanged);
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    service.dispose();
  }
}

/// A camera of the session.
class _CameraDevice {
  DeviceConfiguration configuration;
  final VideoRecordingService service;
  bool ready = false;

  /// True while the camera is being reopened after an error or a retry.
  bool recovering = false;

  _CameraDevice(this.configuration)
      : service = VideoRecordingService(cameraId: configuration.deviceId);
}
