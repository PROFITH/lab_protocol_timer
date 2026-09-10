import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:multi_window_manager/multi_window_manager.dart';
import 'package:universal_ble/universal_ble.dart';
import 'package:camera/camera.dart';
import 'dart:math' as math;

import '../services/polar_ble_service.dart';
import '../services/video_recording_service.dart';
import '../models/device_status.dart';
import '../models/protocol_configuration.dart';
import '../models/monitor_slot.dart';
import '../models/monitor_visualization.dart';
import 'window_messages.dart';
import 'sensor_chart_card.dart';
import 'dart:io';


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
    with WindowListener {
  
  // State variables
  final PolarBleService _polarService = PolarBleService();
  final VideoRecordingService _videoService = VideoRecordingService();
  final List<double> _hrHistory = [];
  final List<double> _rrHistory = [];
  final List<double> _accHistory = [];
  final List<double> _ecgHistory = [];

  final List<MonitorSlot> _monitorSlots = [
    const MonitorSlot(slotId: 1),
    const MonitorSlot(slotId: 2),
    const MonitorSlot(slotId: 3),
    const MonitorSlot(slotId: 4),
  ];

  String _participantIds = '--';
  int _activityIndex = 0;
  String _phaseName = 'idle';
  bool _sessionActive = false;
  bool _sessionPaused = false;
  bool _cameraReady = false;
  bool _syncAvailable = false;
  Directory? _sessionExportDirectory;
  late ProtocolConfiguration _protocolConfiguration;
  int _prepSeconds = 10;
  int _activitySeconds = 60;
  int _postSeconds = 10;
  bool _useLapMode = false;
  bool _enableTts = true;

  // Valores de visualización en tiempo real
  int _heartRate = 0;
  PolarAccelerationSample? _lastAcc;
  PolarEcgSample? _lastEcg;

  // Modo de acelerometría: 'VM' o 'XYZ'
  String _accMode = 'XYZ';

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
    switch (deviceId) {
      case 'polar_h10':
        return _showPolarConnectionDialog;
      case 'camera':
      return _showCameraConnectionDialog;

      default:
        return null;
    }
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

  // Búferes individuales para los 3 ejes
  final List<double> _accXHistory = [];
  final List<double> _accYHistory = [];
  final List<double> _accZHistory = [];

  @override
  void initState() {
    super.initState();
    
    _protocolConfiguration = widget.protocolConfiguration;

    MultiWindowManager.current.addListener(this);

    MultiWindowManager.current.invokeMethodToWindow(
      0,
      WindowMessages.researchMonitorReady,
    );

    // Escuchar streams de Polar para refrescar el panel visual
    _polarService.hrStream.listen((bpm) {
      if (mounted) {
        setState(() {
          _heartRate = bpm;
          _hrHistory.add(bpm.toDouble());
          if (_hrHistory.length > 100) _hrHistory.removeAt(0);
        });
      }
    });

    _polarService.rrStream.listen((rrMs) {
      if (mounted) {
        setState(() {
          _rrHistory.add(rrMs.toDouble());

          if (_rrHistory.length > 100) {
            _rrHistory.removeAt(0);
          }
        });
      }
    });

    _polarService.accelerationUiStream.listen((acc) {
      if (mounted) {
        final vm = math.sqrt((acc.xMg * acc.xMg) + (acc.yMg * acc.yMg) + (acc.zMg * acc.zMg));
        setState(() {
          _lastAcc = acc;
          _accHistory.add(vm);
          if (_accHistory.length > 100) _accHistory.removeAt(0);

          _accXHistory.add(acc.xMg.toDouble());
          if (_accXHistory.length > 100) _accXHistory.removeAt(0);

          _accYHistory.add(acc.yMg.toDouble());
          if (_accYHistory.length > 100) _accYHistory.removeAt(0);

          _accZHistory.add(acc.zMg.toDouble());
          if (_accZHistory.length > 100) _accZHistory.removeAt(0);
        });
      }
    });

    _polarService.ecgUiStream.listen((ecg) {
      if (mounted) {
        setState(() {
          _lastEcg = ecg;
          _ecgHistory.add(ecg.microVolts.toDouble());
          if (_ecgHistory.length > 100) _ecgHistory.removeAt(0);
        });
      }
    });

    debugPrint('[MONITOR] Research Monitor inicializado con servicios locales.');
  }

  Future<void> _showCameraConnectionDialog() async {
    try {
      debugPrint('[VIDEO] Buscando cámaras disponibles...');
      final cameras = await availableCameras();
      debugPrint('[VIDEO] Cámaras encontradas: ${cameras.length}');

      if (cameras.isEmpty) {
        debugPrint('[VIDEO] No se encontraron cámaras.');
        if (mounted) setState(() => _cameraReady = false);
        return;
      }

      // Mostrar diálogo para que elijas qué cámara usar
      if (!mounted) return;
      final CameraDescription? selectedCamera = await showDialog<CameraDescription>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext dialogContext) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1E293B),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            title: const Row(
              children: [
                Icon(Icons.videocam_rounded, color: Color(0xFF38BDF8)),
                SizedBox(width: 10),
                Text('Seleccionar Cámara', style: TextStyle(color: Colors.white)),
              ],
            ),
            content: SizedBox(
              width: 350,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: cameras.length,
                itemBuilder: (context, index) {
                  final camera = cameras[index];
                  return ListTile(
                    leading: const Icon(Icons.camera_alt, color: Color(0xFF38BDF8)),
                    title: Text(
                      camera.name,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      'Lens: ${camera.lensDirection.name}',
                      style: const TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                    onTap: () => Navigator.of(dialogContext).pop(camera),
                  );
                },
              ),
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

      final CameraDescription chosenCamera = selectedCamera;

      debugPrint('[VIDEO] Inicializando cámara seleccionada: ${chosenCamera.name}');

      // Invocamos tu método pasándole la cámara elegida
      final success = await _videoService.initializeCamera(chosenCamera);
      if (!mounted) return;
      setState(() => _cameraReady = success);
    } catch (e, stackTrace) {
      debugPrint('[VIDEO] Error inicializando cámara: $e\n$stackTrace');
      if (mounted) setState(() => _cameraReady = false);
    }
  }

  @override
  void dispose() {
    MultiWindowManager.current.removeListener(this);
    _polarService.dispose();
    _videoService.dispose();
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

      case 'START_VIDEO_RECORDING':
        if (!_cameraReady) {
          debugPrint(
            '[VIDEO] No se puede iniciar: cámara no preparada.',
          );
          return false;
        }

        if (_videoService.isRecording) {
          debugPrint(
            '[VIDEO] No se puede iniciar: ya existe una grabación activa.',
          );
          return false;
        }

        final summary = arguments?.toString() ?? _participantIds;

        final success = await _videoService.startSessionRecording(
          participantSummary: summary,
        );

        if (mounted) {
          setState(() {});
        }

        debugPrint(
          '[VIDEO] Resultado inicio grabación: $success',
        );

        return success;

      case 'STOP_VIDEO_RECORDING':
        if (_videoService.isRecording && arguments is Map) {
          final summary = arguments['participantSummary']?.toString() ?? _participantIds;
          final totalActs = int.tryParse(arguments['totalActivities']?.toString() ?? '0') ?? 0;
          await _videoService.stopSessionRecording(
            participantSummary: summary,
            totalActivities: totalActs,
          );
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
      _phaseName = args['phaseName']?.toString() ?? 'idle';
    });

    _polarService.updateProtocolContext(
      participantId: _participantIds,
      activityIndex: _activityIndex,
      phaseName: _phaseName,
    );
  }

  void _handleProtocolContext(dynamic args) {
    if (args is! Map) return;

    setState(() {
      _participantIds = args['participantIds']?.toString() ?? '--';
      _activityIndex = int.tryParse(args['activityIndex']?.toString() ?? '') ?? 0;
      _phaseName = args['phaseName']?.toString() ?? 'idle';
    });

    if (_polarService.isConnected) {
      // Registrar muestra por segundo de HR sincronizada
      if (_sessionActive) {
        _polarService.captureSample(
          participantId: _participantIds,
          activityIndex: _activityIndex,
          phaseName: _phaseName,
        );
      }

      _polarService.updateProtocolContext(
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
    // 1. HEART RATE
    // ========================================================================

    if (_polarService.recordedSamples.isNotEmpty) {
      final csvContent = _polarService.exportCsv();

      final filePath = await _createTemporaryCsvFile(
        'polar_hr_session_$timestampStr.csv',
        csvContent,
      );

      generatedFiles.add(filePath);

      debugPrint('[MONITOR] Preparado HR CSV: $filePath');
    }

    // ========================================================================
    // 2. ACCELEROMETRÍA
    // ========================================================================

    if (_polarService.recordedAccelerationSamples.isNotEmpty) {
      final csvContent =
          _polarService.exportAccelerationCsv();

      final filePath = await _createTemporaryCsvFile(
        'polar_acc_raw_200hz_$timestampStr.csv',
        csvContent,
      );

      generatedFiles.add(filePath);

      debugPrint('[MONITOR] Preparado ACC CSV: $filePath');
    }

    // ========================================================================
    // 3. ECG
    // ========================================================================

    if (_polarService.recordedEcgSamples.isNotEmpty) {
      final csvContent =
          _polarService.exportEcgCsv();

      final filePath = await _createTemporaryCsvFile(
        'polar_ecg_raw_130hz_$timestampStr.csv',
        csvContent,
      );

      generatedFiles.add(filePath);

      debugPrint('[MONITOR] Preparado ECG CSV: $filePath');
    }

    // ========================================================================
    // 4. VIDEO SYNC CSV
    // ========================================================================

    if (_videoService.recordedVideoLogs.isNotEmpty) {
      final csvContent =
          _videoService.exportVideoSyncCsv();

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

      for (final videoLog
          in _videoService.recordedVideoLogs) {
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

  void _showPolarConnectionDialog() {
    _polarService.startScan();

    showDialog(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1E293B),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              title: const Row(
                children: [
                  Icon(Icons.bluetooth_searching_rounded, color: Color(0xFF38BDF8)),
                  SizedBox(width: 10),
                  Text('Conectar Sensor Polar H10', style: TextStyle(color: Colors.white)),
                ],
              ),
              content: SizedBox(
                width: 400,
                height: 300,
                child: StreamBuilder<List<BleDevice>>(
                  stream: _polarService.scanStream,
                  builder: (context, snapshot) {
                    final results = snapshot.data ?? [];
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
                        final device = results[index];
                        final name = device.name?.isNotEmpty == true
                            ? device.name!
                            : 'Dispositivo BLE (${device.deviceId})';

                        return ListTile(
                          leading: const Icon(Icons.favorite, color: Colors.redAccent),
                          title: Text(name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                          subtitle: Text(device.deviceId, style: const TextStyle(color: Colors.white38, fontSize: 11)),
                          trailing: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF38BDF8),
                              foregroundColor: Colors.black,
                            ),
                            onPressed: () async {
                              await _polarService.stopScan();
                              final connected = await _polarService.connectToDevice(device);
                              if (connected) {
                                try {
                                  final polarConfiguration =
                                      _protocolConfiguration.deviceById('polar_h10');

                                  if (polarConfiguration != null) {
                                    await _polarService.startHeartRate();
                                    await _polarService.startAcceleration();
                                    await _polarService.startEcg();
                                  }
                                } catch (e) {
                                  debugPrint(
                                    '[POLAR DEBUG] Error al iniciar sensores: $e',
                                  );
                                }
                              }
                              if (dialogCtx.mounted) {
                                Navigator.of(dialogCtx).pop();
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(connected ? 'Conectado a $name' : 'Fallo de conexión'),
                                    backgroundColor: connected ? const Color(0xFF34D399) : Colors.redAccent,
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
                TextButton(
                  onPressed: () {
                    _polarService.stopScan();
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

  List<DeviceStatus> get _deviceStatuses {
    final statuses = <DeviceStatus>[];

    for (final device in _protocolConfiguration.devices) {
      switch (device.deviceId) {
        case 'camera':
          statuses.add(
            DeviceStatus(
              id: device.deviceId,
              name: device.deviceName,
              icon: Icons.videocam_rounded,
              connectionStatus: _cameraReady
                  ? DeviceConnectionStatus.connected
                  : DeviceConnectionStatus.disconnected,
              sensors: [
                if (device.hasSensor('video'))
                  SensorStatus(
                    id: 'video',
                    name: 'Vídeo',
                    icon: Icons.videocam_rounded,
                    status: _videoService.isRecording
                        ? SensorAcquisitionStatus.acquiring
                        : _cameraReady
                            ? SensorAcquisitionStatus.ready
                            : SensorAcquisitionStatus.unavailable,
                  ),
              ],
            ),
          );
          break;

        case 'polar_h10':
          statuses.add(
            DeviceStatus(
              id: device.deviceId,
              name: device.deviceName,
              icon: Icons.favorite_rounded,
              connectionStatus: _polarService.isConnected
                  ? DeviceConnectionStatus.connected
                  : DeviceConnectionStatus.disconnected,
              sensors: [
                if (device.hasSensor('heart_rate'))
                  SensorStatus(
                    id: 'heart_rate',
                    name: 'HR',
                    icon: Icons.favorite_rounded,
                    status: _polarService.isHeartRateStreaming
                        ? SensorAcquisitionStatus.acquiring
                        : _polarService.isConnected
                            ? SensorAcquisitionStatus.stopped
                            : SensorAcquisitionStatus.unavailable,
                  ),

                if (device.hasSensor('rr'))
                  SensorStatus(
                    id: 'rr',
                    name: 'RR',
                    icon: Icons.timeline_rounded,
                    status: _polarService.isRrStreaming
                        ? SensorAcquisitionStatus.acquiring
                        : _polarService.isConnected
                            ? SensorAcquisitionStatus.stopped
                            : SensorAcquisitionStatus.unavailable,
                  ),

                if (device.hasSensor('acc'))
                  SensorStatus(
                    id: 'acc',
                    name: 'ACC',
                    icon: Icons.sensors_rounded,
                    status: _polarService.isAccelerationStreaming
                        ? SensorAcquisitionStatus.acquiring
                        : _polarService.isConnected
                            ? SensorAcquisitionStatus.stopped
                            : SensorAcquisitionStatus.unavailable,
                    detail: '200 Hz',
                  ),
                if (device.hasSensor('ecg'))
                  SensorStatus(
                    id: 'ecg',
                    name: 'ECG',
                    icon: Icons.show_chart_rounded,
                    status: _polarService.isEcgStreaming
                        ? SensorAcquisitionStatus.acquiring
                        : _polarService.isConnected
                            ? SensorAcquisitionStatus.stopped
                            : SensorAcquisitionStatus.unavailable,
                    detail: '130 Hz',
                  ),
              ],
            ),
          );
          break;

        default:
          debugPrint(
            '[MONITOR] Dispositivo no soportado: ${device.deviceId}',
          );
          break;
      }
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
            tooltip: 'Voz',
            onPressed: () async {
              await MultiWindowManager.current.invokeMethodToWindow(
                0,
                WindowMessages.voiceToggleRequested,
              );
            },
            icon: const Icon(Icons.volume_up_rounded),
          ),
          IconButton(
            tooltip: 'Ajustes',
            onPressed: _showSettingsDialog,
            icon: const Icon(Icons.settings_rounded),
          ),
          IconButton(
            tooltip: 'Cancelar prueba',
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

  Widget _buildHeartRateMonitor(MonitorSlot slot) {
    return SensorChartCard(
      title: 'MONITOR ${slot.slotId}',
      subtitle: 'HR · ${slot.sensorId}',
      icon: Icons.favorite_rounded,
      currentValue: _heartRate > 0 ? '$_heartRate' : '--',
      unit: 'bpm',
      seriesList: [
        ChartSeries(
          points: _hrHistory,
          color: Colors.redAccent,
          label: 'HR',
        ),
      ],
    );
  }

  Widget _buildRrMonitor(MonitorSlot slot) {
    return SensorChartCard(
      title: 'MONITOR ${slot.slotId}',
      subtitle: 'RR · ${slot.sensorId}',
      icon: Icons.timeline_rounded,
      currentValue: _rrHistory.isNotEmpty
          ? _rrHistory.last.toStringAsFixed(0)
          : '--',
      unit: 'ms',
      seriesList: [
        ChartSeries(
          points: _rrHistory,
          color: Colors.orangeAccent,
          label: 'RR',
        ),
      ],
    );
  }

  Widget _buildAccelerationMonitor(MonitorSlot slot) {
    return SensorChartCard(
      title: 'MONITOR ${slot.slotId}',
      subtitle: 'ACC · ${slot.sensorId}',
      icon: Icons.sensors_rounded,
      currentValue: _accMode == 'VM'
          ? (_accHistory.isNotEmpty
              ? _accHistory.last.toStringAsFixed(1)
              : '--')
          : (_lastAcc != null
              ? _lastAcc!.zMg.toStringAsFixed(1)
              : '--'),
      unit: 'mg',
      seriesList: _accMode == 'VM'
          ? [
              ChartSeries(
                points: _accHistory,
                color: const Color(0xFF38BDF8),
                label: 'VM',
              ),
            ]
          : [
              ChartSeries(
                points: _accXHistory,
                color: Colors.redAccent,
                label: 'X',
              ),
              ChartSeries(
                points: _accYHistory,
                color: Colors.greenAccent,
                label: 'Y',
              ),
              ChartSeries(
                points: _accZHistory,
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
    return SensorChartCard(
      title: 'MONITOR ${slot.slotId}',
      subtitle: 'ECG · ${slot.sensorId}',
      icon: Icons.show_chart_rounded,
      currentValue: _lastEcg != null
          ? _lastEcg!.microVolts.toStringAsFixed(1)
          : '--',
      unit: 'µV',
      seriesList: [
        ChartSeries(
          points: _ecgHistory,
          color: const Color(0xFFF43F5E),
          label: 'ECG',
        ),
      ],
    );
  }

  Widget _buildVideoMonitor(MonitorSlot slot) {
    final controller = _videoService.controller;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: (_cameraReady &&
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
                if (_videoService.isRecording)
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
          // Identificación de la sesión
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$_participantIds · Día 0',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Actividad ${_activityIndex + 1} · $_phaseName',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey.shade400,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),

          // Número de actividades guardadas
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 8,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: Colors.white.withValues(alpha: 0.06),
            ),
            child: Text(
              '${_hrHistory.length} guardadas',
              style: const TextStyle(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),

          const SizedBox(width: 16),

          // Estado de la sesión
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
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  color: _sessionActive
                      ? Colors.greenAccent
                      : Colors.grey.shade400,
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

  const _DeviceStatusCard({
    required this.device,
    required this.onSensorTap,
    this.onDeviceAction,
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
            const SizedBox(height: 10),
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