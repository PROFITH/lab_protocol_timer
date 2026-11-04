import 'dart:async';

import 'package:flutter/material.dart';
import 'package:multi_window_manager/multi_window_manager.dart';

import 'config/default_protocol_configuration.dart';
import 'models/protocol_configuration.dart';
import 'services/redcap_connection.dart';
import 'session/session_controller.dart';
import 'session/timer_page.dart';
import 'setup/participant_setup_page.dart';
import 'ui/app_theme.dart';
import 'windows/monitor_popout.dart';
import 'windows/research_monitor_bridge.dart';
import 'windows/research_monitor_window.dart';
import 'windows/theme_sync.dart';

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
  final popoutOwner = monitorPopoutOwner(args);

  // Light or dark, as it was left on this computer.
  await ThemeController.load();

  if (popoutOwner != null) {
    const title = 'Monitor';
    debugPrint('[MAIN] Iniciando ventana de monitor...');
    await MultiWindowManager.current.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(960, 540),
        minimumSize: Size(360, 220),
        center: true,
        title: title,
      ),
      () async {
        await MultiWindowManager.current.show();
        await MultiWindowManager.current.focus();
      },
    );
    runApp(MonitorPopoutApp(ownerWindowId: popoutOwner));
    return;
  }

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

    // A toggle here is sent to the participant window.
    ThemeSync.install(() => const [0]);

    runApp(
      ThemeScope(
        builder: (context, mode) => MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Research Monitor',
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: mode,
          home: const ResearchMonitorHost(
            protocolConfiguration: defaultProtocolConfiguration,
          ),
        ),
      ),
    );
    return;
  }

  debugPrint('[MAIN] Iniciando Participant Timer...');

  // A toggle here is sent to the Research Monitor.
  ThemeSync.install(() => [
        if (ResearchMonitorBridge.instance.monitorWindowId != null) ResearchMonitorBridge.instance.monitorWindowId!,
      ]);

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

  /// The Research Monitor was opened from the waiting room for the session
  /// about to start: it keeps its Polar and cameras.
  bool _monitorFromWaitingRoom = false;

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
        onPrepare: (configuration, fresh) {
          _monitorFromWaitingRoom = true;
          return openResearchMonitorWindow(configuration, fresh: fresh);
        },
        monitor: ResearchMonitorBridge.instance,
        audioFactory: DeviceSessionAudio.new,
      );

  Future<void> _startSession(SessionController controller) async {
    // From the waiting room the monitor keeps its links (Polar, cameras).
    final fresh = !_monitorFromWaitingRoom;
    _monitorFromWaitingRoom = false;
    await openResearchMonitorWindow(controller.protocolConfiguration, fresh: fresh);
    final navigator = _navigator.currentState;
    if (navigator == null) {
      controller.dispose();
      return;
    }
    await navigator.pushReplacement(
      MaterialPageRoute<void>(
        // The participant's screen is always dark.
        builder: (_) => AlwaysDark(
          child: TimerPage(
            controller: controller,
            onExit: () => _navigator.currentState?.pushReplacement(
              MaterialPageRoute<void>(builder: (_) => _setupPage()),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ThemeScope(
      builder: (context, mode) => MaterialApp(
        navigatorKey: _navigator,
        title: 'Lab Timer - Accelerometer Sync',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: mode,
        home: _setupPage(),
      ),
    );
  }
}

/// Opens the Research Monitor (or shows the hidden one) for a session with
/// [configuration] (each participant's sensors and the cameras).
///
/// [fresh] rebuilds a monitor left from an earlier evaluation; false only
/// shows it and updates its devices, keeping what is linked.
Future<void> openResearchMonitorWindow(ProtocolConfiguration configuration, {bool fresh = true}) async {
  final bridge = ResearchMonitorBridge.instance;
  try {
    bridge.setProtocolConfiguration(configuration);
    if (await bridge.hasLiveMonitorWindow()) {
      if (fresh) {
        await bridge.reuseMonitorWindow();
      } else {
        await bridge.showMonitor();
      }
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
