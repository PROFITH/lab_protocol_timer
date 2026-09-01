import 'package:flutter/material.dart';
import 'package:multi_window_manager/multi_window_manager.dart';
import 'package:universal_ble/universal_ble.dart';
import 'package:camera/camera.dart';
import 'dart:math' as math;

import '../services/polar_ble_service.dart';
import '../services/video_recording_service.dart';
import 'window_messages.dart';
import 'sensor_chart_card.dart';
import 'dart:io';


class ResearchMonitorWindow extends StatefulWidget {
  const ResearchMonitorWindow({super.key});

  @override
  State<ResearchMonitorWindow> createState() =>
      _ResearchMonitorWindowState();
}

class _ResearchMonitorWindowState extends State<ResearchMonitorWindow>
    with WindowListener {
  final PolarBleService _polarService = PolarBleService();
  final VideoRecordingService _videoService = VideoRecordingService();
  final List<double> _hrHistory = [];
  final List<double> _accHistory = [];
  final List<double> _ecgHistory = [];

  String _participantIds = '--';
  int _activityIndex = 0;
  String _phaseName = 'idle';
  bool _sessionActive = false;
  bool _cameraReady = false;
  Directory? _sessionExportDirectory;

  // Valores de visualización en tiempo real
  int _heartRate = 0;
  PolarAccelerationSample? _lastAcc;
  PolarEcgSample? _lastEcg;

  // Modo de acelerometría: 'VM' o 'XYZ'
  String _accMode = 'VM';

  // Búferes individuales para los 3 ejes
  final List<double> _accXHistory = [];
  final List<double> _accYHistory = [];
  final List<double> _accZHistory = [];

  @override
  void initState() {
    super.initState();
    MultiWindowManager.current.addListener(this);

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

    _initCamera();
    debugPrint('[MONITOR] Research Monitor inicializado con servicios locales.');
  }

  Future<void> _initCamera() async {
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

      // Si el usuario cierra el diálogo sin elegir, por seguridad cogemos la primera
      final CameraDescription chosenCamera = selectedCamera ?? cameras.first;

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
        setState(() => _sessionActive = false);
        break;

      case WindowMessages.sessionResumed:
        setState(() => _sessionActive = true);
        break;

      case WindowMessages.protocolContext:
        _handleProtocolContext(arguments);
        break;

      case WindowMessages.sessionFinished:
        return await _handleSessionFinished();

      case 'START_VIDEO_RECORDING':
        if (_cameraReady && !_videoService.isRecording) {
          final summary = arguments?.toString() ?? _participantIds;
          await _videoService.startSessionRecording(participantSummary: summary);
          if (mounted) setState(() {});
        }
        break;

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
    }
  }

  void _handleSessionStarted(dynamic args) {
    if (args is! Map) return;

    setState(() {
      _sessionActive = true;
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
                                  await _polarService.startAcceleration();
                                  await _polarService.startEcg();
                                } catch (e) {
                                  debugPrint('[POLAR DEBUG] Error al iniciar PMD: $e');
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

  // ===========================================================================
  // UI
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              _buildHeader(),
              const SizedBox(height: 20),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: _buildVideoPanel(),
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      flex: 2,
                      child: _buildSensorPanel(),
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

  Widget _buildHeader() {
    return Row(
      children: [
        const Icon(
          Icons.monitor_heart_rounded,
          color: Color(0xFF38BDF8),
          size: 30,
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Text(
            'RESEARCH MONITOR',
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.5,
            ),
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              'Participante: $_participantIds',
              style: const TextStyle(
                color: Colors.white70,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              'Actividad $_activityIndex • $_phaseName',
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 12,
              ),
            ),
          ],
        ),
        const SizedBox(width: 20),
        _buildStatusIndicator(),
      ],
    );
  }

  Widget _buildStatusIndicator() {
    return Row(
      children: [
        ActionChip(
          avatar: Icon(
            Icons.bluetooth_rounded,
            color: _polarService.isConnected ? const Color(0xFF38BDF8) : Colors.white24,
            size: 18,
          ),
          label: Text(
            _polarService.isConnected ? 'Polar Conectado' : 'Conectar Polar',
            style: TextStyle(
              color: _polarService.isConnected ? Colors.white : Colors.white60,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
          backgroundColor: _polarService.isConnected
              ? const Color(0xFF38BDF8).withAlpha(40)
              : const Color(0xFF1E293B),
          side: BorderSide(
            color: _polarService.isConnected ? const Color(0xFF38BDF8) : Colors.white24,
          ),
          onPressed: _showPolarConnectionDialog,
        ),
        const SizedBox(width: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: _sessionActive ? const Color(0xFF14532D) : const Color(0xFF334155),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              Icon(
                Icons.circle,
                color: _sessionActive ? const Color(0xFF34D399) : Colors.white38,
                size: 10,
              ),
              const SizedBox(width: 8),
              Text(
                _sessionActive ? 'SESIÓN ACTIVA' : 'EN ESPERA',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildVideoPanel() {
    final controller = _videoService.controller;
    
    return _MonitorCard(
      title: 'VÍDEO EN DIRECTO',
      icon: Icons.videocam_rounded,
      child: Container(
        color: Colors.black,
        child: (_cameraReady && controller != null && controller.value.isInitialized)
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
                      top: 12,
                      right: 12,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.redAccent,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.fiber_manual_record, color: Colors.white, size: 12),
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
                    Icon(Icons.videocam_off_rounded, color: Colors.white38, size: 50),
                    SizedBox(height: 10),
                    Text(
                      'Cámara no disponible o inicializando...',
                      style: TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                  ],
                ),
              ),
      ),
      
    );
  }

  Widget _buildSensorPanel() {
    return Column(
      children: [
        // 1. Tarjeta de Frecuencia Cardíaca (HR)
        Expanded(
          child: SensorChartCard(
            title: 'HR',
            subtitle: 'Pulso',
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
          ),
        ),
        const SizedBox(height: 10),
        // 2. Tarjeta de Acelerometría (ACC) con Toggle VM / XYZ
        Expanded(
          flex: 2,
          child: SensorChartCard(
            title: 'ACC',
            subtitle: 'Acelerometría (200 Hz)',
            icon: Icons.sensors_rounded,
            currentValue: _lastAcc != null ? '${_lastAcc!.zMg}' : '--',
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
            trailingAction: Container(
              height: 26,
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildToggleBtn('VM', _accMode == 'VM', const Color(0xFF38BDF8)),
                  _buildToggleBtn('XYZ', _accMode == 'XYZ', null),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        // 3. Tarjeta de Electrocardiograma (ECG)
        Expanded(
          child: SensorChartCard(
            title: 'ECG',
            subtitle: 'Electrocardiograma (130 Hz)',
            icon: Icons.show_chart_rounded,
            currentValue: _lastEcg != null ? '${_lastEcg!.microVolts}' : '--',
            unit: 'µV',
            seriesList: [
              ChartSeries(
                points: _ecgHistory,
                color: const Color(0xFFF43F5E),
                label: 'ECG',
              ),
            ],
          ),
        ),
      ],
    );
  }

  // Widget auxiliar para el selector VM / XYZ del acelerómetro
  Widget _buildToggleBtn(String label, bool isSelected, Color? singleColor) {
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

  const _MonitorCard({
    required this.title,
    required this.icon,
    required this.child,
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
              Icon(icon, color: const Color(0xFF38BDF8), size: 20),
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
          Expanded(child: child),
        ],
      ),
    );
  }
}