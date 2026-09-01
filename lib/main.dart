import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lab_protocol_timer/utils/web_exit_guard.dart';
import 'services/lab_redcap_service.dart';
import 'windows/research_monitor_window.dart';
import 'package:multi_window_manager/multi_window_manager.dart';
import 'windows/research_monitor_bridge.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  debugPrint('[MAIN] args=$args');

  final windowId = args.isEmpty
      ? 0
      : int.tryParse(args[0]) ?? 0;

  debugPrint('[MAIN] windowId=$windowId');

  if (windowId == 0) {
    await MultiWindowManager.ensureInitialized(windowId);
  } else {
    await MultiWindowManager.ensureInitializedSecondary(
      windowId,
      isEnabledReuse: false,
    );
  }

  final isResearchMonitor =
      args.length > 1 && args[1] == 'research_monitor';

  debugPrint(
    '[MAIN] isResearchMonitor=$isResearchMonitor',
  );

  if (isResearchMonitor) {
    debugPrint('[MAIN] Iniciando Research Monitor...');

    await MultiWindowManager.current.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1400, 900),
        minimumSize: Size(1100, 700),
        center: true,
        title: 'Research Monitor',
      ),
      () async {
        await MultiWindowManager.current.show();
        await MultiWindowManager.current.focus();
      },
    );

    runApp(
      const MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Research Monitor',
        home: ResearchMonitorWindow(),
      ),
    );
    return;
  }

  debugPrint('[MAIN] Iniciando Participant Timer...');

  runApp(const LabTimerApp());
}

class LabTimerApp extends StatelessWidget {
  const LabTimerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lab Timer - Accelerometer Sync',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B0F19),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF38BDF8),
          surface: Color(0xFF1E293B),
        ),
      ),
      home: const ParticipantSetupPage(),
    );
  }
}

// Dynamic form (nested participant and measurement indicator)
class ParticipantFieldGroup {
  final TextEditingController controller;
  String eventName;

  ParticipantFieldGroup({
    required this.controller,
    this.eventName = 'da_0__visita_inici_arm_1',
  });
}

// ==========================================
// 1. HOME (LOGIN) SCREEN
// ==========================================
class ParticipantSetupPage extends StatefulWidget {
  const ParticipantSetupPage({super.key});

  @override
  State<ParticipantSetupPage> createState() => _ParticipantSetupPageState();
}

class _ParticipantSetupPageState extends State<ParticipantSetupPage> {
  final _formKey = GlobalKey<FormState>();
  final List<ParticipantFieldGroup> _participants = [];
  final _activityController = TextEditingController(text: '1');

  static const Map<String, String> _eventOptions = {
    'da_0__visita_inici_arm_1': 'Visita Inicial (Día 0)',
    'da_8__visita_final_arm_1': 'Visita Final (Día 8)',
  };

  @override
  void initState() {
    super.initState();
    _addParticipantField(); // Default - 1 participant
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkUnsavedSession();
    });
  }

  void _addParticipantField([String initialId = '', String initialEvent = 'da_0__visita_inici_arm_1']) {
    setState(() {
      _participants.add(
        ParticipantFieldGroup(
          controller: TextEditingController(text: initialId),
          eventName: initialEvent,
        ),
      );
    });
  }

  void _removeParticipantField(int index) {
    if (_participants.length > 1) {
      setState(() {
        _participants[index].controller.dispose();
        _participants.removeAt(index);
      });
    }
  }

  @override
  void dispose() {
    unregisterWebExitGuard();
    for (final p in _participants) {
      p.controller.dispose();
    }
    _activityController.dispose();

    super.dispose();
  }

  Future<void> _checkUnsavedSession() async {
    final prefs = await SharedPreferences.getInstance();
    final savedParticipantsRaw = prefs.getString('saved_participants_list');
    final savedActivitiesRaw = prefs.getString('saved_completed_activities');
    final savedGlobalStartRaw = prefs.getString('saved_session_start');
    final savedCurrentActivity = prefs.getInt('saved_current_activity') ?? 1;

    if (savedParticipantsRaw != null &&
        savedActivitiesRaw != null &&
        savedGlobalStartRaw != null) {
      final List<dynamic> decodedParticipants = jsonDecode(savedParticipantsRaw);
      final List<ParticipantEntry> restoredParticipants = decodedParticipants
          .map((e) => ParticipantEntry.fromJson(e as Map<String, dynamic>))
          .toList();

      final List<dynamic> decodedActivities = jsonDecode(savedActivitiesRaw);
      final List<ActivityLog> restoredActivities = decodedActivities
          .map((e) => ActivityLog.fromJson(e as Map<String, dynamic>))
          .toList();

      final DateTime restoredGlobalStart = DateTime.parse(savedGlobalStartRaw);

      if (!mounted) return;

      final summaryNames = restoredParticipants.map((p) => p.participantId).join(', ');

      final action = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1E293B),
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(24)),
            ),
            title: const Row(
              children: [
                Icon(Icons.history_rounded, color: Color(0xFFFBBF24)),
                SizedBox(width: 10),
                Text('Sesión Recuperada', style: TextStyle(color: Colors.white)),
              ],
            ),
            content: Text(
              'Sesión no finalizada con ${restoredParticipants.length} participante(s):\n[$summaryNames]\n\n${restoredActivities.length} actividades guardadas.\n\n¿Deseas reanudarla?',
              style: const TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop('discard'),
                style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
                child: const Text('Descartar'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop('resume'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF38BDF8),
                  foregroundColor: Colors.black,
                ),
                child: const Text('Reanudar Sesión'),
              ),
            ],
          );
        },
      );

      if (action == 'resume') {
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (context) => TimerPage(
              initialParticipants: restoredParticipants,
              initialActivity: savedCurrentActivity,
              restoredActivities: restoredActivities,
              restoredSessionStartTime: restoredGlobalStart,
            ),
          ),
        );
      } else if (action == 'discard') {
        await _clearLocalBackup();
      }
    }
  }

  Future<void> _clearLocalBackup() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('saved_participants_list');
    await prefs.remove('saved_completed_activities');
    await prefs.remove('saved_session_start');
    await prefs.remove('saved_current_activity');
  }

  Future<void> _submitAndStart() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }

    final List<ParticipantEntry> entries = _participants.map((p) {
      return ParticipantEntry(
        participantId: p.controller.text.trim(),
        redcapEventName: p.eventName,
      );
    }).toList();

    final activity =
        int.tryParse(_activityController.text.trim()) ?? 1;

    await _openResearchMonitorWindow();

    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => TimerPage(
          initialParticipants: entries,
          initialActivity: activity,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.center,
            radius: 1.3,
            colors: [Color(0xFF1E293B), Color(0xFF0B0F19)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28.0, vertical: 24.0),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 580),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF38BDF8).withAlpha(30),
                          border: Border.all(
                            color: const Color(0xFF38BDF8).withAlpha(100),
                            width: 2,
                          ),
                        ),
                        child: const Icon(
                          Icons.groups_rounded,
                          size: 54,
                          color: Color(0xFF38BDF8),
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'PARTICIPANTES A EVALUAR',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 2.0,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const SizedBox(height: 28),

                      // Dynamic list of participants
                      ListView.separated(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: _participants.length,
                        separatorBuilder: (context, index) => const SizedBox(height: 14),
                        itemBuilder: (context, index) {
                          final item = _participants[index];
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
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      'PARTICIPANTE #${index + 1}',
                                      style: const TextStyle(
                                        color: Color(0xFF38BDF8),
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 1.1,
                                      ),
                                    ),
                                    if (_participants.length > 1)
                                      IconButton(
                                        icon: const Icon(Icons.remove_circle_outline, color: Colors.redAccent, size: 20),
                                        onPressed: () => _removeParticipantField(index),
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(),
                                        tooltip: 'Eliminar participante',
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                TextFormField(
                                  controller: item.controller,
                                  textCapitalization: TextCapitalization.characters,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15,
                                  ),
                                  decoration: InputDecoration(
                                    labelText: 'ID / CÓDIGO *',
                                    labelStyle: const TextStyle(color: Colors.white60, fontSize: 12),
                                    hintText: 'Ej. 1, 2, 3,...',
                                    hintStyle: const TextStyle(color: Colors.white24),
                                    prefixIcon: const Icon(Icons.person_pin_rounded, color: Color(0xFF38BDF8), size: 20),
                                    filled: true,
                                    fillColor: const Color(0xFF0F172A),
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                                  ),
                                  validator: (val) => (val == null || val.trim().isEmpty) ? 'Requerido' : null,
                                ),
                                const SizedBox(height: 10),
                                DropdownButtonFormField<String>(
                                  initialValue: item.eventName,
                                  dropdownColor: const Color(0xFF1E293B),
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                                  decoration: InputDecoration(
                                    labelText: 'MEDICIÓN / VISITA',
                                    labelStyle: const TextStyle(color: Colors.white60, fontSize: 12),
                                    prefixIcon: const Icon(Icons.event_repeat_rounded, color: Color(0xFF38BDF8), size: 20),
                                    filled: true,
                                    fillColor: const Color(0xFF0F172A),
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                                  ),
                                  items: _eventOptions.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
                                  onChanged: (val) {
                                    if (val != null) setState(() => item.eventName = val);
                                  },
                                ),
                              ],
                            ),
                          );
                        },
                      ),

                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _addParticipantField,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF38BDF8),
                          side: const BorderSide(color: Color(0xFF38BDF8)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        ),
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('Añadir Otro Participante'),
                      ),

                      const SizedBox(height: 20),
                      TextFormField(
                        controller: _activityController,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16),
                        decoration: InputDecoration(
                          labelText: 'ACTIVIDAD INICIAL *',
                          labelStyle: const TextStyle(color: Color(0xFF38BDF8), fontSize: 13, fontWeight: FontWeight.bold),
                          hintText: 'Ej. 1',
                          prefixIcon: const Icon(Icons.pin_rounded, color: Color(0xFF38BDF8)),
                          filled: true,
                          fillColor: const Color(0xFF1E293B),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                        ),
                        validator: (value) {
                          final numVal = int.tryParse(value ?? '');
                          if (numVal == null || numVal < 1) return 'Debe ser mínimo 1';
                          return null;
                        },
                      ),

                      const SizedBox(height: 28),
                      SizedBox(
                        width: double.infinity,
                        height: 54,
                        child: FilledButton.icon(
                          onPressed: _submitAndStart,
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF38BDF8),
                            foregroundColor: Colors.black,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          ),
                          icon: const Icon(Icons.arrow_forward_rounded, size: 24),
                          label: Text(
                            'COMENZAR SESIÓN (${_participants.length} SUJETO${_participants.length > 1 ? 'S' : ''})',
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900, letterSpacing: 1.2),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openResearchMonitorWindow() async {
    try {
      debugPrint('[WINDOW] Creando Research Monitor...');

      final window = await MultiWindowManager.createWindow([
        'research_monitor',
      ]);

      if (window == null) {
        debugPrint(
          '[WINDOW] No se pudo crear Research Monitor.',
        );
        return;
      }

      debugPrint(
        '[WINDOW] Ventana creada. ID=${window.id}',
      );

      ResearchMonitorBridge.instance.setMonitorWindow(window);

      /* await window.waitUntilReadyToShow(
        const WindowOptions(
          size: Size(1400, 900),
          minimumSize: Size(1100, 700),
          center: true,
          title: 'Research Monitor',
        ),
        () async {
          debugPrint(
            '[WINDOW] Research Monitor preparada. '
            'Mostrando ventana ID=${window.id}',
          );

          await window.show();
          await window.focus();
        },
      ); */

      debugPrint(
        '[WINDOW] Research Monitor lista. ID=${window.id}',
      );
    } catch (e, stackTrace) {
      debugPrint(
        '[WINDOW] Error creando Research Monitor: '
        '$e\n$stackTrace',
      );
    }
  }
}

// ==========================================
// MAIN (TIMER) SCREEN
// ==========================================
class TimerPage extends StatefulWidget {
  final List<ParticipantEntry> initialParticipants;
  final int initialActivity;
  final List<ActivityLog>? restoredActivities;
  final DateTime? restoredSessionStartTime;

  const TimerPage({
    super.key,
    required this.initialParticipants,
    required this.initialActivity,
    this.restoredActivities,
    this.restoredSessionStartTime,
  });

  @override
  TimerPageState createState() => TimerPageState();
}

class TimerPageState extends State<TimerPage>
    with SingleTickerProviderStateMixin {
  late List<ParticipantEntry> _participants;
  late int _currentActivity;

  int _prepSeconds = 30;
  int _activitySeconds = 600;
  int _postSeconds = 30;
  bool _useLapMode = true;
  bool _enableTts = true;

  int _seconds = 30;
  int _currentPhase = 0;
  int _waitingElapsedSeconds = 0;
  bool _hasSpokenActionWindow = false;

  List<ActivityLog> _completedActivities = [];
  DateTime? _sessionStartTime;
  DateTime? _currentActivityStartTime;
  bool _isSyncingRedCap = false;

  Timer? _timer;
  bool _isRunning = false;
  bool _isPaused = false;
  // bool _cameraReady = false;

  final AudioPlayer _audioPlayer = AudioPlayer();
  final FlutterTts _flutterTts = FlutterTts();
  // final PolarBleService _polarService = PolarBleService();
  // final VideoRecordingService _videoService = VideoRecordingService();

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  /* String _cameraDisplayName(CameraDescription? camera) {
    if (camera == null) {
      return 'Sin Cámara';
    }

    final name = camera.name.toLowerCase();

    if (name.contains('integrated')) {
      return 'Cámara integrada';
    }

    if (name.contains('mobile') || name.contains('phone')) {
      return 'Cámara del móvil';
    }

    return camera.name;
  } */

  @override
  void initState() {
    super.initState();
    _participants = List.from(widget.initialParticipants);
    _currentActivity = widget.initialActivity;
    _completedActivities = widget.restoredActivities != null
        ? List.from(widget.restoredActivities!)
        : [];
    _sessionStartTime = widget.restoredSessionStartTime;
    _seconds = _prepSeconds;
    _initTts();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.96, end: 1.04).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    registerWebExitGuard(() => _isRunning || _completedActivities.isNotEmpty);
    
    // _initCamera();
  }

  /* Future<void> _initCamera() async {
    try {
      debugPrint('[VIDEO] Buscando cámaras disponibles...');

      final cameras = await availableCameras();

      debugPrint('[VIDEO] Cámaras encontradas: ${cameras.length}');

      if (cameras.isEmpty) {
        debugPrint('[VIDEO] No se encontraron cámaras.');

        if (mounted) {
          setState(() {
            _cameraReady = false;
          });
        }

        return;
      }

      for (final camera in cameras) {
        debugPrint(
          '[VIDEO] Cámara: '
          'name=${camera.name}, '
          'lensDirection=${camera.lensDirection}, '
          'sensorOrientation=${camera.sensorOrientation}',
        );
      }
      // Buscar "Integrated Camera" como opción por defecto.
      CameraDescription defaultCamera = cameras.first;

      for (final camera in cameras) {
        final name = camera.name.toLowerCase();

        if (name.contains('integrated')) {
          defaultCamera = camera;
          break;
        }
      }

      debugPrint(
        '[VIDEO] Cámara seleccionada por defecto: '
        '${defaultCamera.name}',
      );

      // Mostrar diálogo para que el usuario pueda seleccionar la cámara.
      if (!mounted) return;

      final selectedCamera = await _showCameraSelectionDialog(
        cameras,
        defaultCamera,
      );

      // El usuario ha elegido "Sin cámara".
      if (selectedCamera == null) {
        debugPrint('[VIDEO] Usuario ha seleccionado: Sin cámara.');

        if (mounted) {
          setState(() {
            _cameraReady = false;
          });
        }

        return;
      }

      debugPrint(
        '[VIDEO] Cámara seleccionada por el usuario: '
        '${selectedCamera.name}',
      );

      // Inicializar la cámara seleccionada.
      final success = await _videoService.initializeCamera(
        selectedCamera,
      );

      if (mounted) {
        setState(() {
          _cameraReady = success;
        });
      }
    } catch (e, stackTrace) {
      debugPrint(
        '[VIDEO] Error buscando/inicializando cámaras: '
        '$e\n$stackTrace',
      );

      if (mounted) {
        setState(() {
          _cameraReady = false;
        });
      }
    }
  } */

  void _initTts() async {
    await _flutterTts.setLanguage("es-ES");
    await _flutterTts.setSpeechRate(0.5);
    await _flutterTts.setVolume(1.0);
    await _flutterTts.setPitch(1.0);
  }

  Future<void> _speak(String text) async {
    if (!_enableTts) return;
    await _flutterTts.stop();
    await _flutterTts.awaitSpeakCompletion(true);
    await _flutterTts.speak(text);
  }

  Future<void> _playSound(String sound) async {
    try {
      await _audioPlayer.play(AssetSource(sound));
    } catch (_) {}
  }

  Future<void> _speakThenPlaySound(String text, [String? sound]) async {
    if (_enableTts) {
      await _speak(text);
    }
    if (sound != null) {
      await _playSound(sound);
    }
  }

  @override
  void dispose() {
    unregisterWebExitGuard();
    _timer?.cancel();
    // _polarService.dispose();
    _pulseController.dispose();
    _audioPlayer.dispose();
    _flutterTts.stop();
    // _videoService.dispose();
    super.dispose();
  }

  Future<void> _persistSessionLocally() async {
    final prefs = await SharedPreferences.getInstance();
    final rawParticipants = jsonEncode(_participants.map((e) => e.toJson()).toList());
    await prefs.setString('saved_participants_list', rawParticipants);
    await prefs.setInt('saved_current_activity', _currentActivity);
    if (_sessionStartTime != null) {
      await prefs.setString(
          'saved_session_start', _sessionStartTime!.toIso8601String());
    }
    final rawActivities =
        jsonEncode(_completedActivities.map((e) => e.toJson()).toList());
    await prefs.setString('saved_completed_activities', rawActivities);
  }

  Future<void> _clearLocalBackup() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('saved_participants_list');
    await prefs.remove('saved_completed_activities');
    await prefs.remove('saved_session_start');
    await prefs.remove('saved_current_activity');
  }

  String get _currentPhaseName {
    switch (_currentPhase) {
      case 0:
        return 'static_prep';
      case 1:
        return 'activity_main';
      case 2:
        return 'static_post';
      case 3:
      default:
        return 'transition_lap';
    }
  }

  Future<void> _cancelSession() async {
    final shouldCancel = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(24)),
          ),
          title: const Row(
            children: [
              Icon(Icons.cancel_rounded, color: Colors.redAccent),
              SizedBox(width: 10),
              Text('Cancelar Prueba', style: TextStyle(color: Colors.white)),
            ],
          ),
          content: Text(
            '¿Seguro que deseas cancelar la prueba de ${_participants.length} participante(s)?\n\nSe descartarán los datos y no se enviará nada a REDCap.',
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Continuar', style: TextStyle(color: Colors.white54)),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
              icon: const Icon(Icons.delete_forever_rounded),
              label: const Text('Cancelar y Salir'),
            ),
          ],
        );
      },
    );

    if (shouldCancel == true) {
      _timer?.cancel();
      _flutterTts.stop();
      await _clearLocalBackup();

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => const ParticipantSetupPage()),
      );
    }
  }

  Future<void> _startPauseTimer() async {
    if (_isPaused) {
      _resumeTimer();
      return;
    }
    if (_isRunning) {
      setState(() {
        _isRunning = false;
        _isPaused = true;
      });
      _timer?.cancel();
      await ResearchMonitorBridge.instance.sessionPaused();
      await _speak("Pausado");
      return;
    }

    setState(() {
      _isRunning = true;
      _isPaused = false;
      _hasSpokenActionWindow = false;
      _sessionStartTime ??= DateTime.now();
    });

    final participantSummary = _participants.map((p) => p.participantId).join(';');

    await ResearchMonitorBridge.instance.sessionStarted(
      participantIds: participantSummary,
      activityIndex: _currentActivity,
      phaseName: _currentPhaseName,
    );

    await _persistSessionLocally();

    // Enviar orden de grabar al monitor de investigación
    await ResearchMonitorBridge.instance.startVideoRecording(participantSummary);

    await _speak("Preparación estática. Permanezcan inmóviles.");
    _startProtocolTimer();
  }

  void _resumeTimer() {
    _isRunning = true;
    _isPaused = false;
    ResearchMonitorBridge.instance.sessionResumed();
    _speak("Reanudando");
    _startProtocolTimer();
  }

  void _nextActivity() {
    _timer?.cancel();
    _flutterTts.stop();

    setState(() {
      _currentActivity++;
      _currentPhase = 0;
      _seconds = _prepSeconds;
      _waitingElapsedSeconds = 0;
      _isRunning = true;
      _isPaused = false;
      _hasSpokenActionWindow = false;
    });
    _persistSessionLocally();
    _speak("Actividad $_currentActivity. Fase estática inicial.");
    _startProtocolTimer();
  }

  Future<void> _confirmFinishSession() async {
    final pendingCount = _completedActivities.length;

    final shouldFinish = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(24)),
          ),
          title: const Row(
            children: [
              Icon(Icons.cloud_upload_rounded, color: Color(0xFF38BDF8)),
              SizedBox(width: 10),
              Text('Finalizar Sesión', style: TextStyle(color: Colors.white)),
            ],
          ),
          content: Text(
            'Se cerrará la sesión de ${_participants.length} participante(s) ($pendingCount actividades registradas).\n\n¿Deseas enviar los datos a REDCap ahora?',
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Continuar', style: TextStyle(color: Colors.white54)),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF38BDF8), foregroundColor: Colors.black),
              icon: const Icon(Icons.check_circle_rounded),
              label: const Text('Finalizar y Sincronizar'),
            ),
          ],
        );
      },
    );

    if (shouldFinish == true) {
      await _finishAndSyncSession();
    }
  }

  Future<void> _finishAndSyncSession() async {
    _timer?.cancel();
    _flutterTts.stop();

    final participantSummary = _participants.map((p) => p.participantId).join(';');

    // Detener vídeo en el monitor
    await ResearchMonitorBridge.instance.stopVideoRecording(
      participantSummary, 
      _completedActivities.length
    );

    await ResearchMonitorBridge.instance.sessionFinished();

    final sessionEndTime = DateTime.now();
    final sessionStartTime = _sessionStartTime ?? sessionEndTime;

    final double totalProtocolSeconds =
        sessionEndTime.difference(sessionStartTime).inMilliseconds / 1000.0;

    final double totalActivitySeconds = _completedActivities.fold<double>(
      0.0,
      (sum, item) => sum + item.durationSeconds,
    );

    final double totalTransitionSeconds =
        (totalProtocolSeconds - totalActivitySeconds).clamp(0.0, double.infinity);

    final int totalStations = _completedActivities.length;

    setState(() {
      _isRunning = false;
      _isPaused = false;
      _isSyncingRedCap = true;
    });

    /* // Export HR csv (POLAR)
    if (_polarService.recordedSamples.isNotEmpty) {
      final csvContent = _polarService.exportCsv();
      final timestampStr = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
      final fileName = 'polar_hr_session_$timestampStr.csv';
      
      await saveCsvFile(fileName, csvContent);
    }

    // Export accelerometer csv (POLAR)
    if (_polarService.recordedAccelerationSamples.isNotEmpty) {
      final accCsvContent = _polarService.exportAccelerationCsv();
      final timestampStr = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
      final accFileName = 'polar_acc_raw_200hz_$timestampStr.csv';
      
      await saveCsvFile(accFileName, accCsvContent);
      debugPrint('[POLAR DEBUG] Guardadas ${_polarService.recordedAccelerationSamples.length} muestras ACC en $accFileName');
    }

    // Export ECG csv (POLAR)
    if (_polarService.recordedEcgSamples.isNotEmpty) {
      final ecgCsvContent = _polarService.exportEcgCsv();
      final timestampStr = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
      final ecgFileName = 'polar_ecg_raw_130hz_$timestampStr.csv';
      
      await saveCsvFile(ecgFileName, ecgCsvContent);
      debugPrint('[POLAR DEBUG] Guardadas ${_polarService.recordedEcgSamples.length} muestras ECG en $ecgFileName');
    }

    // Export video
    if (_videoService.isRecording) {
      final participantSummary =
          _participants.map((p) => p.participantId).join(';');
      await _videoService.stopSessionRecording(
        participantSummary: participantSummary,
        totalActivities: _completedActivities.length,
      );

      // Exportar CSV de sincronización de vídeo
      if (_videoService.recordedVideoLogs.isNotEmpty) {
        final videoSyncContent = _videoService.exportVideoSyncCsv();
        final timestampStr = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
        final videoSyncFileName = 'video_sync_session_$timestampStr.csv';
        await saveCsvFile(videoSyncFileName, videoSyncContent);
      }
    } */

    final success = await LabRedCapService.sendFlatProtocolSession(
      participants: _participants,
      sessionStartTime: sessionStartTime,
      sessionEndTime: sessionEndTime,
      activities: List.from(_completedActivities),
      totalProtocolSeconds: totalProtocolSeconds,
      totalActivitySeconds: totalActivitySeconds,
      totalTransitionSeconds: totalTransitionSeconds,
      totalStations: totalStations,
    );

    if (mounted) {
      setState(() => _isSyncingRedCap = false);

      if (success) {
        await _clearLocalBackup();
      }

      if (!mounted) return;

      final totalMins = (totalProtocolSeconds / 60).toStringAsFixed(1);
      final actMins = (totalActivitySeconds / 60).toStringAsFixed(1);
      final transMins = (totalTransitionSeconds / 60).toStringAsFixed(1);
      final summaryNames = _participants.map((p) => p.participantId).join(', ');

      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1E293B),
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(24)),
            ),
            title: Row(
              children: [
                Icon(
                  success ? Icons.check_circle_rounded : Icons.error_rounded,
                  color: success ? const Color(0xFF34D399) : Colors.redAccent,
                ),
                const SizedBox(width: 10),
                Text(
                  success ? 'Sincronización Batch Exitosa' : 'Aviso de Conexión',
                  style: const TextStyle(color: Colors.white),
                ),
              ],
            ),
            content: Text(
              success
                  ? 'Sesión registrada para ${_participants.length} sujeto(s):\n[$summaryNames]\n\n'
                      '⏱ Total: $totalMins min\n'
                      '🏃 En Actividad: $actMins min\n'
                      '⏳ En Transiciones: $transMins min\n'
                      '📊 Total Actividades: $totalStations'
                  : 'No se pudo conectar con REDCap. La sesión permanece guardada localmente.',
              style: const TextStyle(color: Colors.white70),
            ),
            actions: [
              FilledButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  if (success && mounted) {
                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute(
                        builder: (context) => const ParticipantSetupPage(),
                      ),
                    );
                  }
                },
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF38BDF8),
                  foregroundColor: Colors.black,
                ),
                child: Text(success ? 'Nueva Evaluación' : 'Reintentar luego'),
              ),
            ],
          );
        },
      );
    }
  }

  void _startProtocolTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        final participantSummary =
            _participants.map((p) => p.participantId).join(';');

        // Notificar al Research Monitor del segundo y fase actual
        ResearchMonitorBridge.instance.updateProtocolContext(
          participantIds: participantSummary,
          activityIndex: _currentActivity,
          phaseName: _currentPhaseName,
        );

        if (_currentPhase == 3) {
          _waitingElapsedSeconds++;
          return;
        }

        if ((_currentPhase == 0 && _seconds <= 5 && _seconds > 0) ||
            (_currentPhase == 2 &&
                _seconds >= (_postSeconds - 5) &&
                _seconds > (_postSeconds - 6))) {
          if (!_hasSpokenActionWindow) {
            _hasSpokenActionWindow = true;
            _speak("¡Entrechocar acelerómetros ahora!");
          }
        }

        if (_seconds > 0) {
          _seconds--;
        } else {
          _hasSpokenActionWindow = false;

          if (_currentPhase == 0) {
            _currentPhase = 1;
            _seconds = _activitySeconds;
            _currentActivityStartTime = DateTime.now();

            _speakThenPlaySound(
                "Realice la actividad a ritmo constante.", 'gong.ogg');
          } else if (_currentPhase == 1) {
            final now = DateTime.now();
            if (_currentActivityStartTime != null) {
              final duration = now
                      .difference(_currentActivityStartTime!)
                      .inMilliseconds /
                  1000.0;

              _completedActivities.add(
                ActivityLog(
                  activityIndex: _currentActivity,
                  activityStartTime: _currentActivityStartTime!,
                  activityEndTime: now,
                  durationSeconds: duration,
                ),
              );
              _currentActivityStartTime = null;
              _persistSessionLocally();
            }

            _currentPhase = 2;
            _seconds = _postSeconds;
            _speakThenPlaySound("Fin de actividad. Quédese quieto.");
          } else if (_currentPhase == 2) {
            if (_useLapMode) {
              _currentPhase = 3;
              _waitingElapsedSeconds = 0;
              _speakThenPlaySound("Actividad completada.");
            } else {
              _currentPhase = 0;
              _seconds = _prepSeconds;
              _currentActivity++;
              _persistSessionLocally();
              _speakThenPlaySound("Permanezca inmóvil.");
            }
          }
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    int minutes = _seconds ~/ 60;
    int seconds = _seconds % 60;

    double progress = 1.0;
    if (_currentPhase == 0) {
      progress = _prepSeconds > 0 ? _seconds / _prepSeconds : 0.0;
    } else if (_currentPhase == 1) {
      progress =
          _activitySeconds > 0 ? _seconds / _activitySeconds : 0.0;
    } else if (_currentPhase == 2) {
      progress = _postSeconds > 0 ? _seconds / _postSeconds : 0.0;
    }

    bool isActionWindow = (_currentPhase == 0 && _seconds <= 5) ||
        (_currentPhase == 2 && _seconds >= (_postSeconds - 5));

    String mainTitle;
    String actionAdvice;
    Color accentColor;
    Color bannerBg;
    Color screenBg;
    IconData actionIcon;

    if (isActionWindow) {
      mainTitle = '¡ENTRECHOCAR SENSORES!';
      actionAdvice = 'GOLPEA LOS ACELERÓMETROS AHORA';
      accentColor = const Color(0xFFFDE047);
      bannerBg = const Color(0xFF854D0E);
      screenBg = const Color(0xFF451A03);
      actionIcon = Icons.sensors;
    } else {
      switch (_currentPhase) {
        case 0:
          mainTitle = 'TOTALMENTE ESTÁTICO';
          actionAdvice = 'Quédate completamente inmóvil';
          accentColor = const Color(0xFFFB923C);
          bannerBg = const Color(0xFF9A3412);
          screenBg = const Color(0xFF2C1005);
          actionIcon = Icons.accessibility_new_rounded;
          break;
        case 1:
          mainTitle = 'ACTIVIDAD EN CURSO';
          actionAdvice = 'Ejecuta el ejercicio asignado';
          accentColor = const Color(0xFF34D399);
          bannerBg = const Color(0xFF065F46);
          screenBg = const Color(0xFF022C22);
          actionIcon = Icons.directions_run_rounded;
          break;
        case 2:
          mainTitle = 'FINALIZACIÓN';
          actionAdvice = 'Detén el movimiento y mantente inmóvil';
          accentColor = const Color(0xFFF87171);
          bannerBg = const Color(0xFF991B1B);
          screenBg = const Color(0xFF450A0A);
          actionIcon = Icons.accessibility_new_rounded;
          break;
        case 3:
        default:
          mainTitle = 'EN ESPERA (LAP)';
          actionAdvice = 'Rotación de actividad - Pulsa "Lap"';
          accentColor = const Color(0xFF94A3B8);
          bannerBg = const Color(0xFF334155);
          screenBg = const Color(0xFF0F172A);
          actionIcon = Icons.pause_circle_filled_rounded;
          break;
      }
    }

    final headerText = _participants.length == 1
        ? '${_participants.first.participantId} (${_participants.first.redcapEventName.contains("da_0") ? "Día 0" : "Día 8"})'
        : '${_participants.length} Sujetos (${_participants.map((p) => p.participantId).join(", ")})';

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (!mounted) return;
        if (_completedActivities.isEmpty && _currentActivityStartTime == null) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (context) => const ParticipantSetupPage(),
            ),
          );
          return;
        }

        final action = await showDialog<String>(
          context: context,
          builder: (context) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1E293B),
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(24)),
              ),
              title: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Color(0xFFFBBF24)),
                  SizedBox(width: 10),
                  Text('Sesión en curso', style: TextStyle(color: Colors.white)),
                ],
              ),
              content: Text(
                'Hay una sesión activa para ${_participants.length} participantes con ${_completedActivities.length} actividades.\n\n¿Qué deseas hacer?',
                style: const TextStyle(color: Colors.white70),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop('cancel'),
                  child: const Text('Continuar', style: TextStyle(color: Colors.white54)),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop('discard'),
                  style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
                  child: const Text('Descartar'),
                ),
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).pop('sync'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF38BDF8),
                    foregroundColor: Colors.black,
                  ),
                  icon: const Icon(Icons.cloud_upload_rounded),
                  label: const Text('Enviar y Salir'),
                ),
              ],
            );
          },
        );

        if (!mounted) return;

        if (action == 'sync') {
          await _finishAndSyncSession();
        } else if (action == 'discard') {
          await _clearLocalBackup();
          _timer?.cancel();
          _flutterTts.stop();
          if (context.mounted) {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (context) => const ParticipantSetupPage(),
              ),
            );
          }
        }
      },
      child: Scaffold(
        body: AnimatedContainer(
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeInOut,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [screenBg, const Color(0xFF07090E)],
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.white12,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '$headerText | Actividad $_currentActivity',
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                                color: Colors.white70,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0xFF38BDF8).withAlpha(30),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '${_completedActivities.length} guardadas',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF38BDF8),
                              ),
                            ),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          IconButton(
                            icon: Icon(
                              _enableTts ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                              color: _enableTts ? accentColor : Colors.white24,
                            ),
                            onPressed: () => setState(() => _enableTts = !_enableTts),
                            tooltip: 'Voz',
                          ),
                          IconButton(
                            icon: const Icon(Icons.settings_rounded, color: Colors.white54),
                            onPressed: () => _showSettingsDialog(context),
                            tooltip: 'Ajustes',
                          ),
                          IconButton(
                            icon: const Icon(Icons.close_rounded, color: Colors.redAccent),
                            onPressed: _cancelSession,
                            tooltip: 'Cancelar Prueba',
                          ),
                        ],
                      )
                    ],
                  ),
                ),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 350),
                    transitionBuilder: (child, animation) {
                      return ScaleTransition(
                        scale: CurvedAnimation(
                            parent: animation, curve: Curves.easeOutBack),
                        child: FadeTransition(opacity: animation, child: child),
                      );
                    },
                    child: Container(
                      key: ValueKey<String>(mainTitle),
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          vertical: 20, horizontal: 16),
                      decoration: BoxDecoration(
                        color: bannerBg,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: accentColor,
                          width: isActionWindow ? 3.0 : 1.5,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: accentColor.withAlpha(isActionWindow ? 120 : 40),
                            blurRadius: isActionWindow ? 35 : 15,
                            spreadRadius: isActionWindow ? 4 : 0,
                          ),
                        ],
                      ),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(actionIcon, size: 36, color: accentColor),
                              const SizedBox(width: 12),
                              Flexible(
                                child: Text(
                                  mainTitle,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: isActionWindow ? 24 : 22,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 1.5,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            actionAdvice.toUpperCase(),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.1,
                              color: accentColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const Spacer(),
                LayoutBuilder(
                  builder: (context, constraints) {
                    double dialSize = constraints.maxWidth * 0.72;
                    if (dialSize > 340) dialSize = 340;
                    if (dialSize < 240) dialSize = 240;

                    Widget timerDisplay = Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          width: dialSize,
                          height: dialSize,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFF0F172A).withAlpha(180),
                            boxShadow: [
                              BoxShadow(
                                color: accentColor.withAlpha(isActionWindow ? 90 : 25),
                                blurRadius: 30,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                        ),
                        if (_currentPhase != 3)
                          SizedBox(
                            width: dialSize - 16,
                            height: dialSize - 16,
                            child: CircularProgressIndicator(
                              value: progress,
                              strokeWidth: 16,
                              strokeCap: StrokeCap.round,
                              valueColor:
                                  AlwaysStoppedAnimation<Color>(accentColor),
                              backgroundColor: Colors.white.withAlpha(20),
                            ),
                          ),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _currentPhase == 3
                                  ? '${_waitingElapsedSeconds}s'
                                  : '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}',
                              style: TextStyle(
                                fontSize: dialSize * 0.27,
                                fontWeight: FontWeight.w900,
                                color: Colors.white,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ],
                              ),
                            ),
                            const Text(
                              'TIEMPO RESTANTE',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 2.0,
                                color: Colors.white38,
                              ),
                            ),
                          ],
                        ),
                      ],
                    );

                    return isActionWindow
                        ? ScaleTransition(
                            scale: _pulseAnimation, child: timerDisplay)
                        : timerDisplay;
                  },
                ),
                const Spacer(flex: 2),
                Container(
                  margin:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B).withAlpha(220),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton.filledTonal(
                        onPressed: _confirmFinishSession,
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.redAccent.withAlpha(40),
                          foregroundColor: Colors.redAccent,
                          padding: const EdgeInsets.all(16),
                        ),
                        icon: _isSyncingRedCap
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.redAccent),
                              )
                            : const Icon(Icons.stop_rounded),
                        tooltip: 'Finalizar Protocolo y Sincronizar',
                      ),
                      FilledButton.icon(
                        onPressed: _startPauseTimer,
                        style: FilledButton.styleFrom(
                          backgroundColor: accentColor,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 32, vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                        ),
                        icon: Icon(
                          _isRunning && !_isPaused
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          size: 28,
                        ),
                        label: Text(
                          _isRunning && !_isPaused ? 'Pausar' : 'Iniciar',
                          style: const TextStyle(
                              fontWeight: FontWeight.w900, fontSize: 16),
                        ),
                      ),
                      FilledButton.tonal(
                        onPressed: _nextActivity,
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.white.withAlpha(20),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.skip_next_rounded),
                            SizedBox(width: 4),
                            Text('Lap',
                                style: TextStyle(fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showSettingsDialog(BuildContext context) {
    final prepController = TextEditingController(text: _prepSeconds.toString());
    final activityController =
        TextEditingController(text: (_activitySeconds ~/ 60).toString());
    final postController = TextEditingController(text: _postSeconds.toString());
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
                  Icon(Icons.tune_rounded, color: Color(0xFF38BDF8)),
                  SizedBox(width: 10),
                  Text('Ajustes del Protocolo',
                      style: TextStyle(color: Colors.white)),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Sujetos (${_participants.length}):',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF38BDF8),
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 4),
                          ..._participants.map((p) => Text(
                                '• ${p.participantId} (${p.redcapEventName.contains("da_0") ? "Día 0" : "Día 8"})',
                                style: const TextStyle(color: Colors.white, fontSize: 13),
                              )),
                          const SizedBox(height: 6),
                          Text(
                            'Actividad actual: $_currentActivity  •  ${_completedActivities.length} guardadas',
                            style: const TextStyle(color: Colors.white54, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const Divider(color: Colors.white12, height: 28),
                    _buildInputField(
                      controller: prepController,
                      label: 'Preparación estática inicial',
                      suffix: 'segundos',
                    ),
                    const SizedBox(height: 12),
                    _buildInputField(
                      controller: activityController,
                      label: 'Actividad principal',
                      suffix: 'minutos',
                    ),
                    const SizedBox(height: 12),
                    _buildInputField(
                      controller: postController,
                      label: 'Post-actividad estática final',
                      suffix: 'segundos',
                    ),
                    const SizedBox(height: 16),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Indicaciones por voz',
                          style: TextStyle(fontSize: 14, color: Colors.white)),
                      subtitle: const Text(
                          'Dicta las instrucciones y cambios de fase',
                          style:
                              TextStyle(fontSize: 12, color: Colors.white54)),
                      value: tempTtsMode,
                      activeTrackColor: const Color(0xFF38BDF8),
                      onChanged: (val) =>
                          setStateDialog(() => tempTtsMode = val),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Modo Lap (Espera manual)',
                          style: TextStyle(fontSize: 14, color: Colors.white)),
                      subtitle: const Text(
                          'Pausa al finalizar para rotación de actividad',
                          style:
                              TextStyle(fontSize: 12, color: Colors.white54)),
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
                  child: const Text('Cancelar',
                      style: TextStyle(color: Colors.white54)),
                ),
                FilledButton(
                  onPressed: () {
                    setState(() {
                      int newPrep =
                          int.tryParse(prepController.text) ?? _prepSeconds;
                      int newActivityMins = int.tryParse(
                              activityController.text) ??
                          (_activitySeconds ~/ 60);
                      int newPost =
                          int.tryParse(postController.text) ?? _postSeconds;

                      _prepSeconds = newPrep < 5 ? 5 : newPrep;
                      _activitySeconds = newActivityMins < 1
                          ? 60
                          : newActivityMins * 60;
                      _postSeconds = newPost < 5 ? 5 : newPost;
                      _useLapMode = tempLapMode;
                      _enableTts = tempTtsMode;

                      if (!_isRunning) {
                        _seconds = _prepSeconds;
                      }
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

  Widget _buildInputField({
    required TextEditingController controller,
    required String label,
    required String suffix,
    bool isNumeric = true,
  }) {
    return TextField(
      controller: controller,
      keyboardType: isNumeric ? TextInputType.number : TextInputType.text,
      inputFormatters:
          isNumeric ? [FilteringTextInputFormatter.digitsOnly] : null,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white70, fontSize: 13),
        suffixText: suffix.isNotEmpty ? suffix : null,
        suffixStyle: const TextStyle(color: Colors.white38, fontSize: 12),
        filled: true,
        fillColor: const Color(0xFF0F172A),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}
