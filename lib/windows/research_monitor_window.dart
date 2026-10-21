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
import '../session/csv_stream_writer.dart';
import '../models/device_configuration.dart';
import '../models/device_status.dart';
import '../models/protocol_configuration.dart';
import '../models/monitor_slot.dart';
import '../models/monitor_visualization.dart';
import 'live_signal.dart';
import 'monitor_session.dart';
import 'polar_session_files.dart';
import 'session_console.dart';
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
    // Closing a secondary window takes the whole app down on Windows: the
    // close button hides it instead (F2 in the participant window shows it).
    unawaited(
      MultiWindowManager.current.setPreventClose(true).catchError((Object e) {
        debugPrint('[MONITOR] setPreventClose no disponible: $e');
      }),
    );
  }

  @override
  void dispose() {
    MultiWindowManager.current.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose([int? windowId]) {
    unawaited(MultiWindowManager.current.hide().catchError((Object _) {}));
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

  /// The session that runs in the participant window.
  final MonitorSession _session = MonitorSession();

  /// Polar files of the running session, by device ID.
  final Map<String, PolarSessionFiles> _polarFiles = {};

  /// `video_sync_session_<stamp>.csv`: one row per saved video segment.
  CsvStreamWriter? _videoLog;

  late ProtocolConfiguration _protocolConfiguration;

  /// Right column: 0 activities, 1 devices.
  int _rightTab = 1;
  bool _summaryOpen = false;
  String _lastStatus = 'idle';

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
        participantSummary: _session.participants,
        activityIndex: _session.activityIndex,
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
    if (_session.isActive) {
      _log(ok ? 'camera_recovered' : 'camera_lost', camera.configuration.deviceId);
    }

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
    HardwareKeyboard.instance.addHandler(_onKey);
    _session.addListener(_onSessionChanged);

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

      await camera.service.loadSettings();
      var preset = camera.service.resolutionPreset;
      var quality = camera.service.quality;

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
                    DropdownButtonFormField<VideoQuality>(
                      key: ValueKey('video_quality_${preset.name}'),
                      initialValue: quality,
                      dropdownColor: const Color(0xFF1E293B),
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Calidad',
                        labelStyle: TextStyle(color: Colors.white54),
                      ),
                      items: [
                        for (final option in VideoQuality.values)
                          DropdownMenuItem(
                            value: option,
                            child: Text(
                              '${option.label} · ${VideoRecordingService.formatPerHour(VideoRecordingService.bitrateFor(VideoRecordingService.nominalSize(preset), option))}',
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) setDialogState(() => quality = value);
                      },
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Normal basta para contar pasos y repeticiones. El peso es '
                      'por cámara y, si la cámara da menos resolución de la '
                      'elegida, menor.',
                      style: TextStyle(color: Colors.white38, fontSize: 11),
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
      camera.service.quality = quality;
      unawaited(camera.service.saveSettings());
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
    HardwareKeyboard.instance.removeHandler(_onKey);
    _session.removeListener(_onSessionChanged);
    for (final files in _polarFiles.values) {
      unawaited(files.stop());
    }
    unawaited(_videoLog?.close());
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


  // ===========================================================================
  // SESIÓN (la lleva la ventana del participante)
  // ===========================================================================

  /// Sends an order of the evaluator to the session.
  Future<Map<String, dynamic>> _send(String command, [Map<String, dynamic> args = const {}]) async {
    Map<String, dynamic> result;
    try {
      final reply = await MultiWindowManager.current
          .invokeMethodToWindow(0, WindowMessages.sessionCommand, {'command': command, 'args': args})
          .timeout(const Duration(seconds: 10));
      result = reply is Map
          ? Map<String, dynamic>.from(reply)
          : {'ok': false, 'message': 'La ventana del participante no responde'};
    } catch (e) {
      result = {'ok': false, 'message': 'La ventana del participante no responde: $e'};
    }
    if (result['ok'] == false && command != 'log' && mounted) {
      _snack(result['message']?.toString() ?? 'No se pudo hacer', error: true);
    }
    return result;
  }

  /// An event of the sensors or cameras, in the session log.
  void _log(String event, String detail) {
    if (_session.sessionDir == null) return;
    unawaited(_send('log', {'event': event, 'detail': detail}));
  }

  void _snack(String text, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: error ? Colors.redAccent : const Color(0xFF334155),
        duration: Duration(seconds: error ? 6 : 4),
      ),
    );
  }

  void _onSessionChanged() {
    final status = _session.status;
    if (status != _lastStatus) {
      final wasIdle = _lastStatus == 'idle';
      _lastStatus = status;
      if (wasIdle && status != 'idle' && _rightTab != 0) {
        setState(() => _rightTab = 0);
      }
    }
  }

  /// Shortcuts of the evaluator: F5 start / pause, F6 next, F7 sync. Only
  /// F keys: the participant may be typing (activity at the computer).
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent || !mounted) return false;
    if (ModalRoute.of(context)?.isCurrent == false) return false;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.f5) {
      if (_session.isIdle) {
        unawaited(_onStartRequested());
      } else if (!_session.isClosing) {
        unawaited(_send('toggle'));
      }
      return true;
    }
    if (key == LogicalKeyboardKey.f6) {
      unawaited(runNext(context, _session, _send));
      return true;
    }
    if (key == LogicalKeyboardKey.f7) {
      if (_session.syncAvailable) unawaited(_send('sync'));
      return true;
    }
    return false;
  }

  static String _joinOr(List<String> parts, String empty) => parts.isEmpty ? empty : parts.join(' · ');

  /// Checks the devices and starts the session, with or without video.
  Future<void> _onStartRequested() async {
    if (!_session.isIdle) return;
    final items = <PreflightItem>[];
    final manual = <PreflightItem>[];
    for (final device in _protocolConfiguration.devices) {
      final name = device.placementLabel == null
          ? '${device.deviceName} (${device.deviceId})'
          : '${device.deviceName} · ${device.placementLabel} (${device.deviceId})';
      final camera = _cameras[device.deviceId];
      if (camera != null) {
        items.add(PreflightItem(
          name,
          camera.ready,
          camera.ready
              ? 'Preparada · ${camera.service.resolutionLabel} · ${camera.service.qualityLabel}'
                  '${camera.service.audioUnavailable ? ' · sin audio' : ' · con audio'}'
              : 'No preparada: púlsala en la barra de dispositivos para elegir la cámara',
          isCamera: true,
        ));
        continue;
      }
      final live = _liveDevices[device.deviceId];
      if (live != null) {
        final service = live.service;
        final hr = service.currentHeartRate;
        final missing = [
          for (final sensor in _sensorLabels.keys)
            if (device.hasSensor(sensor) && service.isConnected && !_streaming(service, sensor))
              _sensorLabels[sensor]!.$1,
        ];
        items.add(PreflightItem(
          name,
          service.isConnected && missing.isEmpty,
          !service.isConnected
              ? 'Sin conectar: sus datos no se guardarán hasta que se conecte'
              : missing.isNotEmpty
                  ? 'Conectado, pero sin ${missing.join(', ')}'
                  : _joinOr([
                      if (hr > 0) '$hr lpm',
                      if (service.isAccelerationStreaming) 'ACC ${service.accSampleRateHz} Hz',
                      if (service.isEcgStreaming) 'ECG',
                    ], 'Conectado'),
        ));
        continue;
      }
      // Sensors that record on their own: only the evaluator can check them.
      manual.add(PreflightItem(
        name,
        true,
        'Graba por su cuenta: comprueba que está colocado y grabando',
        manual: true,
      ));
    }
    final configured = _session.redcapConfigured;
    items.add(PreflightItem(
      'REDCap',
      true,
      configured
          ? 'Se envía al finalizar (y se puede reintentar)'
          : 'Sin conexión con REDCap: la sesión se guarda solo en su carpeta y se puede enviar después',
      info: !configured,
    ));
    final root = _session.info['data_root']?.toString();
    final service = _cameras.values.isEmpty ? null : _cameras.values.first.service;
    final free = service == null ? null : await service.getFreeDiskSpaceGB(root);
    if (free != null) {
      // GB per hour of all the cameras that will record.
      final perHour = _cameras.values.where((c) => c.ready).fold<double>(
            0,
            (sum, c) => sum +
                VideoRecordingService.gigabytesPerHour(c.service.videoBitrate,
                    withAudio: !c.service.audioUnavailable),
          );
      items.add(PreflightItem(
        'Espacio en disco',
        free >= VideoRecordingService.minimumFreeSpaceGB,
        '${free.toStringAsFixed(1)} GB libres${root == null ? '' : ' en la carpeta de datos'}'
            '${perHour > 0 ? ' (caben unas ${(free / perHour).floor()} h de vídeo)' : ''}'
            '${free >= VideoRecordingService.minimumFreeSpaceGB ? '' : ' (mínimo ${VideoRecordingService.minimumFreeSpaceGB.toStringAsFixed(0)} GB para grabar vídeo)'}',
      ));
    }
    if (!mounted || !_session.isIdle) return;
    final cameraReady = _cameras.values.any((c) => c.ready);
    final choice = await showPreflightDialog(context, items: [...items, ...manual], cameraReady: cameraReady);
    if (choice == null || !_session.isIdle) return;
    await _send('start', {'video': choice});
  }

  Future<void> _onSessionStarted(Map<dynamic, dynamic> args) async {
    final alreadyRecording = _session.sessionDir != null && _session.sessionDir == args['session_dir']?.toString();
    _session.setStarted(args);
    final dir = _session.sessionDir;
    final stamp = _session.fileStamp;
    if (dir == null || stamp == null) return;
    final sep = Platform.pathSeparator;

    _videoLog ??= CsvStreamWriter('$dir${sep}video_sync_session_$stamp.csv', VideoLogEntry.csvHeader);
    for (final camera in _cameras.values) {
      camera.service.sessionDirectory = dir;
      camera.service.sessionFileStamp = stamp;
      camera.service.onSegmentSaved = _onVideoSegment;
    }
    for (final entry in _liveDevices.entries) {
      _polarFiles.putIfAbsent(entry.key, () {
        final files = PolarSessionFiles(
          directory: dir,
          stamp: stamp,
          deviceId: entry.key,
          service: entry.value.service,
        );
        files.start();
        return files;
      });
    }
    if (_session.video && !alreadyRecording) await _startVideo();
    if (mounted) setState(() => _rightTab = 0);
  }

  Future<void> _startVideo() async {
    final ready = _cameras.values.where((c) => c.ready && !c.service.isRecording).toList();
    if (ready.isEmpty) {
      if (_cameras.values.any((c) => c.service.isRecording)) return;
      _log('video_not_started', 'Ninguna cámara preparada');
      _snack('La sesión empezó SIN VÍDEO: ninguna cámara estaba preparada.', error: true);
      return;
    }
    final results = await Future.wait([
      for (final camera in ready) camera.service.startSessionRecording(participantSummary: _session.participants),
    ]);
    for (var i = 0; i < ready.length; i++) {
      final camera = ready[i];
      if (results[i]) {
        _log('video_started', camera.configuration.deviceId);
      } else {
        final reason = camera.service.lastStartError ?? 'error desconocido';
        _log('video_failed', '${camera.configuration.deviceId}: $reason');
        _snack('${camera.configuration.deviceName} no graba: $reason', error: true);
      }
    }
    if (mounted) setState(() {});
  }

  void _onVideoSegment(VideoLogEntry entry) {
    final log = _videoLog;
    if (log != null) {
      log.add(entry.toCsvRow());
      unawaited(log.flush());
    }
    _log('video_saved', '${entry.cameraId} ${entry.filePath.split(RegExp(r'[\\/]')).last}');
  }

  /// Stops the cameras (the videos stay in the session folder) and closes
  /// the Polar files. Answers with the files written.
  Future<Map<String, dynamic>> _stopRecording() async {
    final recording = _cameras.values.where((c) => c.service.isRecording).toList();
    final entries = await Future.wait([
      for (final camera in recording)
        camera.service.stopSessionRecording(
          participantSummary: _session.participants,
          totalActivities: _session.activityIndex,
        ),
    ]);
    final videoFiles = [
      for (final camera in _cameras.values)
        for (final log in camera.service.recordedVideoLogs)
          if (_session.sessionDir != null && log.filePath.startsWith(_session.sessionDir!)) log.filePath,
    ];
    for (var i = 0; i < recording.length; i++) {
      if (entries[i] == null) {
        _log('video_stop_failed', recording[i].configuration.deviceId);
      }
    }
    final files = <String>[];
    for (final polar in _polarFiles.values) {
      files.addAll(await polar.stop());
    }
    _polarFiles.clear();
    final log = _videoLog;
    _videoLog = null;
    if (log != null) {
      await log.close();
      if (log.rows > 0 || File(log.path).existsSync()) files.add(log.path);
    }
    for (final camera in _cameras.values) {
      camera.service.sessionDirectory = null;
      camera.service.sessionFileStamp = null;
      camera.service.onSegmentSaved = null;
    }
    if (mounted) setState(() {});
    return {
      'video_files': videoFiles,
      'files': files,
      'cameras': _cameras.values.where((c) => c.service.recordedVideoLogs.isNotEmpty).length,
    };
  }

  void _onSnapshot(Map<dynamic, dynamic> args) {
    _session.setSnapshot(args);
    final participant = _session.info['participants']?.toString() ?? '';
    for (final device in _liveDevices.values) {
      device.service.updateProtocolContext(
        participantId: _session.isActive ? participant : 'idle',
        activityIndex: _session.activityIndex,
        phaseName: _session.isActive ? _session.phase : 'idle',
      );
    }
  }

  Map<String, dynamic>? _restingHeartRate(dynamic args) {
    if (args is! Map) return null;
    final from = DateTime.tryParse(args['from_utc']?.toString() ?? '');
    final to = DateTime.tryParse(args['to_utc']?.toString() ?? '');
    if (from == null || to == null) return null;
    RestingHeartRate? best;
    String? bestDevice;
    for (final entry in _polarFiles.entries) {
      final result = entry.value.restingHeartRate(from.toUtc(), to.toUtc());
      if (result == null) continue;
      final better = best == null ||
          (result.method == 'rr' && best.method != 'rr') ||
          (result.method == best.method && result.count > best.count);
      if (better) {
        best = result;
        bestDevice = entry.key;
      }
    }
    if (best == null) return null;
    return {...best.toJson(), 'device': bestDevice};
  }

  Future<void> _showSummary() async {
    if (_summaryOpen || !mounted) return;
    _summaryOpen = true;
    try {
      await MultiWindowManager.current.show();
      await MultiWindowManager.current.focus();
    } catch (_) {}
    if (!mounted) return;
    await showSessionSummaryDialog(
      context,
      session: _session,
      send: _send,
      onOpenFolder: _openFolder,
      onNewSession: () => unawaited(_send('close')),
    );
    _summaryOpen = false;
  }

  void _openFolder(String path) {
    try {
      if (Platform.isWindows) {
        unawaited(Process.run('explorer', [path]));
      } else if (Platform.isMacOS) {
        unawaited(Process.run('open', [path]));
      } else {
        unawaited(Process.run('xdg-open', [path]));
      }
    } catch (e) {
      _snack('No se pudo abrir la carpeta: $e', error: true);
    }
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
    if (eventName != WindowMessages.sessionSnapshot) {
      debugPrint('[MONITOR] Evento recibido: $eventName');
    }

    switch (eventName) {
      case WindowMessages.sessionSnapshot:
        if (arguments is Map) _onSnapshot(arguments);
        return true;

      case WindowMessages.sessionInfo:
        if (arguments is Map) _session.setInfo(arguments);
        return true;

      case WindowMessages.sessionStarted:
        if (arguments is Map) await _onSessionStarted(arguments);
        return true;

      case WindowMessages.sessionStopping:
        return await _stopRecording();

      case WindowMessages.sessionSuspending:
        final result = await _stopRecording();
        _session.clear();
        return result;

      case WindowMessages.sessionSaved:
        if (arguments is Map) _session.setSaved(arguments);
        unawaited(_showSummary());
        return true;

      case WindowMessages.sessionCancelled:
        _session.setCancelled(arguments is Map ? arguments : const {});
        _snack('Sesión cancelada. Los archivos se conservan en una carpeta marcada como cancelada.');
        unawaited(_send('close'));
        return true;

      case WindowMessages.restingHrRequested:
        return _restingHeartRate(arguments);

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
        return true;

      case WindowMessages.releaseResources:
        try {
          if (_polarFiles.isNotEmpty || _cameras.values.any((c) => c.service.isRecording)) {
            await _stopRecording();
          }
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
    }
    return null;
  }

  // ===========================================================================
  // DIÁLOGO DE AJUSTES DE PROTOCOLO
  // ===========================================================================
  
  void _showSettingsDialog() {
    final settings = _session.settings;
    final prep = (settings['prep_seconds'] as num?)?.toInt() ?? 30;
    final main = (settings['main_seconds'] as num?)?.toInt() ?? 600;
    final post = (settings['post_seconds'] as num?)?.toInt() ?? 30;
    final prepMinutesController = TextEditingController(text: (prep ~/ 60).toString().padLeft(2, '0'));
    final prepSecondsController = TextEditingController(text: (prep % 60).toString().padLeft(2, '0'));
    final activityMinutesController = TextEditingController(text: (main ~/ 60).toString().padLeft(2, '0'));
    final activitySecondsController = TextEditingController(text: (main % 60).toString().padLeft(2, '0'));
    final postMinutesController = TextEditingController(text: (post ~/ 60).toString().padLeft(2, '0'));
    final postSecondsController = TextEditingController(text: (post % 60).toString().padLeft(2, '0'));
    var lapMode = settings['lap_mode'] as bool? ?? true;

    showDialog<void>(
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
                  Icon(Icons.tune_rounded, color: Color(0xFF38BDF8)),
                  SizedBox(width: 10),
                  Text('Duración de las fases', style: TextStyle(color: Colors.white)),
                ],
              ),
              content: SizedBox(
                width: 440,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Text(
                        'Valen para las actividades que no fijan su propia duración en el '
                        'protocolo. Los cambios se aplican desde la siguiente actividad.',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      const SizedBox(height: 14),
                      _buildDurationInput(
                        label: 'Fase estática antes (quieto)',
                        minutesController: prepMinutesController,
                        secondsController: prepSecondsController,
                      ),
                      const SizedBox(height: 12),
                      _buildDurationInput(
                        label: 'Actividad',
                        minutesController: activityMinutesController,
                        secondsController: activitySecondsController,
                      ),
                      const SizedBox(height: 12),
                      _buildDurationInput(
                        label: 'Fase estática después (quieto)',
                        minutesController: postMinutesController,
                        secondsController: postSecondsController,
                      ),
                      const SizedBox(height: 16),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Esperar al evaluador entre actividades',
                            style: TextStyle(fontSize: 14, color: Colors.white)),
                        subtitle: const Text(
                          'Tras cada actividad, descanso hasta pulsar SIGUIENTE (recomendado)',
                          style: TextStyle(fontSize: 12, color: Colors.white54),
                        ),
                        value: lapMode,
                        activeTrackColor: const Color(0xFF38BDF8),
                        onChanged: (val) => setStateDialog(() => lapMode = val),
                      ),
                    ],
                  ),
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
                ),
                FilledButton(
                  onPressed: () {
                    final newPrep = _durationFromControllers(
                      minutesController: prepMinutesController,
                      secondsController: prepSecondsController,
                      minimumSeconds: 5,
                      fallbackSeconds: prep,
                    );
                    final newActivity = _durationFromControllers(
                      minutesController: activityMinutesController,
                      secondsController: activitySecondsController,
                      minimumSeconds: 1,
                      fallbackSeconds: main,
                    );
                    final newPost = _durationFromControllers(
                      minutesController: postMinutesController,
                      secondsController: postSecondsController,
                      minimumSeconds: 5,
                      fallbackSeconds: post,
                    );
                    unawaited(_send('settings', {
                      'prep_seconds': newPrep,
                      'main_seconds': newActivity,
                      'post_seconds': newPost,
                      'lap_mode': lapMode,
                    }));
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
                  detail: camera.ready
                      ? '${camera.service.resolutionLabel} · ${VideoRecordingService.formatBitrate(camera.service.videoBitrate)}'
                      : null,
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
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SessionConsole(
                session: _session,
                send: _send,
                onStart: _onStartRequested,
                devices: _deviceChips,
                recording: _anyCameraRecording,
                onOpenFolder: _openFolder,
                onSettings: _showSettingsDialog,
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 3,
                      child: _buildMonitoringArea(),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: _buildRightColumn(),
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

  /// Activities of the protocol (with the notes of each attempt) and the
  /// devices, one at a time: the activities during the session.
  Widget _buildRightColumn() {
    final lost = _deviceChips.any((c) => c.warning);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<int>(
          showSelectedIcon: false,
          segments: [
            const ButtonSegment(
              value: 0,
              icon: Icon(Icons.checklist_rounded),
              label: Text('Actividades'),
            ),
            ButtonSegment(
              value: 1,
              icon: Icon(
                lost ? Icons.warning_amber_rounded : Icons.devices_other_rounded,
                color: lost ? Colors.orangeAccent : null,
              ),
              label: const Text('Dispositivos'),
            ),
          ],
          selected: {_rightTab},
          onSelectionChanged: (value) => setState(() => _rightTab = value.first),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: IndexedStack(
            index: _rightTab,
            sizing: StackFit.expand,
            children: [
              _MonitorCard(
                title: 'ACTIVIDADES DEL PROTOCOLO',
                icon: Icons.checklist_rounded,
                expandChild: true,
                child: ActivityPanel(session: _session, send: _send),
              ),
              _buildDeviceStatusPanel(),
            ],
          ),
        ),
      ],
    );
  }

  /// The devices that can be checked from here (cameras and live Polar
  /// sensors), for the status strip of the console.
  List<DeviceChip> get _deviceChips {
    final chips = <DeviceChip>[];
    final active = !_session.isIdle && !_session.isClosing;
    void showDevices() => setState(() => _rightTab = 1);

    for (final device in _protocolConfiguration.devices) {
      final camera = _cameras[device.deviceId];
      if (camera != null) {
        final service = camera.service;
        final recording = service.isRecording;
        final error = service.cameraError.value;
        final (String detail, Color color) = camera.recovering
            ? ('Recuperando...', Colors.orangeAccent)
            : recording
                ? ('Grabando${service.audioUnavailable ? ' sin audio' : ''}', const Color(0xFFF87171))
                : camera.ready
                    ? ('Preparada', const Color(0xFF34D399))
                    : error != null
                        ? ('Error', Colors.redAccent)
                        : ('Sin preparar', Colors.white38);
        chips.add(DeviceChip(
          label: device.deviceName,
          detail: detail,
          color: color,
          icon: recording ? Icons.fiber_manual_record_rounded : Icons.videocam_rounded,
          warning: active && _session.video && !recording,
          onTap: camera.ready || camera.recovering || recording
              ? showDevices
              : () => _showCameraConnectionDialog(device.deviceId),
        ));
        continue;
      }
      final live = _liveDevices[device.deviceId];
      if (live == null) continue;
      final service = live.service;
      final state = service.linkStatus.value.state;
      final connected = service.isConnected && state != PolarLinkState.reconnecting;
      final missing = [
        for (final sensor in _sensorLabels.keys)
          if (device.hasSensor(sensor) && connected && !_streaming(service, sensor)) _sensorLabels[sensor]!.$1,
      ];
      final hr = service.currentHeartRate;
      final (String detail, Color color) = switch (state) {
        _ when connected && missing.isEmpty => (
            [if (hr > 0) '$hr lpm' else 'Conectado', if (device.hasSensor('acc')) 'ACC'].join(' · '),
            const Color(0xFF34D399),
          ),
        _ when connected => ('Sin ${missing.join(', ')}', Colors.orangeAccent),
        PolarLinkState.reconnecting => ('Reconectando...', Colors.orangeAccent),
        PolarLinkState.connecting || PolarLinkState.pairing || PolarLinkState.configuring =>
          ('Conectando...', Colors.orangeAccent),
        PolarLinkState.error => ('Error', Colors.redAccent),
        _ => ('Sin conectar', Colors.white38),
      };
      chips.add(DeviceChip(
        label: device.placementLabel == null ? device.deviceName : '${device.deviceName} · ${device.placementLabel}',
        detail: detail,
        color: color,
        icon: Icons.favorite_rounded,
        // Lost during the session: it was connected and is not now.
        warning: active && service.hasLastDevice && !connected,
        onTap: connected ? showDevices : () => _showPolarConnectionDialog(device.deviceId),
      ));
    }
    return chips;
  }

  static bool _streaming(PolarBleService service, String sensor) => switch (sensor) {
        'heart_rate' => service.isHeartRateStreaming,
        'rr' => service.isRrStreaming,
        'acc' => service.isAccelerationStreaming,
        'ecg' => service.isEcgStreaming,
        _ => false,
      };

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
