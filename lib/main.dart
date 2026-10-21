import 'dart:async';

import 'package:flutter/material.dart';
import 'package:multi_window_manager/multi_window_manager.dart';

import 'config/default_protocol_configuration.dart';
import 'models/activity_battery.dart';
import 'services/redcap_connection.dart';
import 'session/session_controller.dart';
import 'session/timer_page.dart';
import 'setup/participant_setup_page.dart';
import 'windows/research_monitor_bridge.dart';
import 'windows/research_monitor_window.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  debugPrint('[MAIN] args=$args');

  final windowId = args.isEmpty ? 0 : int.tryParse(args[0]) ?? 0;

  if (windowId == 0) {
    await MultiWindowManager.ensureInitialized(windowId);
  } else {
    await MultiWindowManager.ensureInitializedSecondary(
      windowId,
      isEnabledReuse: false,
    );
  }

  final isResearchMonitor = args.length > 1 && args[1] == 'research_monitor';

  if (isResearchMonitor) {
    debugPrint('[MAIN] Iniciando Research Monitor...');

    await MultiWindowManager.current.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1500, 950),
        minimumSize: Size(1200, 760),
        center: true,
        title: 'Research Monitor',
      ),
      () async {
        await MultiWindowManager.current.show();
        await MultiWindowManager.current.focus();
      },
    );

    runApp(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Research Monitor',
        theme: ThemeData.dark().copyWith(
          scaffoldBackgroundColor: const Color(0xFF07090E),
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFF38BDF8),
            surface: Color(0xFF1E293B),
          ),
        ),
        home: const ResearchMonitorHost(
          protocolConfiguration: defaultProtocolConfiguration,
        ),
      ),
    );
    return;
  }

  debugPrint('[MAIN] Iniciando Participant Timer...');

  await RedcapConnection.load();
  // The project's visits are asked in the background; without network the
  // ones saved last time are used.
  unawaited(RedcapConnection.refreshProject());

  runApp(const LabTimerApp());
}

/// The participant window: the setup, then the timer of each session.
///
/// Closing the window is intercepted: a running session is paused and
/// saved first, and the monitor releases the camera and Bluetooth.
class LabTimerApp extends StatefulWidget {
  const LabTimerApp({super.key});

  @override
  State<LabTimerApp> createState() => _LabTimerAppState();
}

class _LabTimerAppState extends State<LabTimerApp> with WindowListener {
  final _navigator = GlobalKey<NavigatorState>();
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    MultiWindowManager.current.addListener(this);
    unawaited(
      MultiWindowManager.current.setPreventClose(true).catchError((Object e) {
        debugPrint('[WINDOW] setPreventClose no disponible: $e');
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
    if (windowId != null && windowId != 0) return;
    unawaited(_close());
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    try {
      final guard = AppCloseGuard.handler;
      final close = guard == null ? true : await guard();
      if (!close) return;
      await ResearchMonitorBridge.instance.closeMonitorWindow();
      await MultiWindowManager.current.destroy();
    } catch (e) {
      debugPrint('[WINDOW] Error al cerrar: $e');
      await MultiWindowManager.current.destroy();
    } finally {
      _closing = false;
    }
  }

  Widget _setupPage() => ParticipantSetupPage(
        onStart: _startSession,
        monitor: ResearchMonitorBridge.instance,
        audioFactory: DeviceSessionAudio.new,
      );

  Future<void> _startSession(SessionController controller) async {
    await openResearchMonitorWindow(controller.battery);
    final navigator = _navigator.currentState;
    if (navigator == null) {
      controller.dispose();
      return;
    }
    await navigator.pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => TimerPage(
          controller: controller,
          onExit: () => _navigator.currentState?.pushReplacement(
            MaterialPageRoute<void>(builder: (_) => _setupPage()),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigator,
      title: 'Lab Timer - Accelerometer Sync',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B0F19),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF38BDF8),
          surface: Color(0xFF1E293B),
        ),
      ),
      home: _setupPage(),
    );
  }
}

/// Opens the Research Monitor (or shows the hidden one) for a session.
Future<void> openResearchMonitorWindow(ActivityBattery? battery) async {
  final bridge = ResearchMonitorBridge.instance;
  final configuration = protocolConfigurationFor(battery);
  try {
    bridge.setProtocolConfiguration(configuration);
    if (await bridge.hasLiveMonitorWindow()) {
      await bridge.reuseMonitorWindow();
      await bridge.sendProtocolConfiguration(configuration);
      return;
    }

    debugPrint('[WINDOW] Creando Research Monitor...');
    final window = await MultiWindowManager.createWindow(['research_monitor']);
    if (window == null) {
      debugPrint('[WINDOW] No se pudo crear Research Monitor.');
      return;
    }
    bridge.setMonitorWindow(window);
    debugPrint('[WINDOW] Research Monitor creado. ID=${window.id}');
  } catch (e, stackTrace) {
    debugPrint('[WINDOW] Error creando Research Monitor: $e\n$stackTrace');
  }
}
