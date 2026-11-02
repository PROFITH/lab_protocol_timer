import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:multi_window_manager/multi_window_manager.dart';

import '../windows/research_monitor_bridge.dart';
import 'participant_view.dart';
import 'session_controller.dart';

/// Voice (Windows speech) and the beeps of the session.
///
/// Every sound is loaded once at the start, so the beeps of the sync
/// countdown are not late on their first use. A failing sound or voice
/// never stops the timer.
class DeviceSessionAudio extends SessionAudio {
  DeviceSessionAudio() {
    unawaited(_init());
  }

  final FlutterTts _tts = FlutterTts();
  final Map<SessionSound, AudioPlayer> _players = {};
  bool _ready = false;

  static const _sources = {
    SessionSound.countdown: 'sounds/countdown.wav',
    SessionSound.go: 'sounds/go.wav',
    SessionSound.tick: 'sounds/tick.wav',
    SessionSound.start: 'gong.ogg',
    SessionSound.end: 'gong2.ogg',
  };

  Future<void> _init() async {
    try {
      await _tts.setLanguage('es-ES');
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
    } catch (e) {
      debugPrint('[AUDIO] Voz no disponible: $e');
    }
    for (final entry in _sources.entries) {
      try {
        final player = AudioPlayer();
        await player.setReleaseMode(ReleaseMode.stop);
        await player.setSource(AssetSource(entry.value));
        _players[entry.key] = player;
      } catch (e) {
        debugPrint('[AUDIO] No se pudo cargar ${entry.value}: $e');
      }
    }
    _ready = true;
  }

  @override
  void say(String text) {
    if (!voiceEnabled) return;
    unawaited(() async {
      try {
        await _tts.stop();
        await _tts.speak(text);
      } catch (e) {
        debugPrint('[AUDIO] Error de voz: $e');
      }
    }());
  }

  @override
  void stopVoice() {
    unawaited(() async {
      try {
        await _tts.stop();
      } catch (_) {}
    }());
  }

  @override
  void play(SessionSound sound) {
    unawaited(() async {
      try {
        final player = _players[sound];
        if (player == null) {
          if (_ready) return;
          // Still loading: play it the slow way.
          await AudioPlayer().play(AssetSource(_sources[sound]!));
          return;
        }
        await player.stop();
        await player.resume();
      } catch (e) {
        debugPrint('[AUDIO] Error de sonido $sound: $e');
      }
    }());
  }

  @override
  Future<void> dispose() async {
    try {
      await _tts.stop();
    } catch (_) {}
    for (final player in _players.values) {
      try {
        await player.dispose();
      } catch (_) {}
    }
    _players.clear();
  }
}

/// Decides what happens when the evaluator closes the participant window.
///
/// The window does not close by itself (`setPreventClose`): the page on
/// screen answers whether the app may quit, after saving what it must.
class AppCloseGuard {
  AppCloseGuard._();

  /// Returns true when the app may close. Null: close at once.
  static Future<bool> Function()? handler;
}

/// The participant window during a session: the timer they follow, the
/// voice and beeps, and the link that lets the Research Monitor run it.
class TimerPage extends StatefulWidget {
  const TimerPage({super.key, required this.controller, required this.onExit});

  final SessionController controller;

  /// Back to the setup page, once the session is saved or cancelled.
  final VoidCallback onExit;

  @override
  State<TimerPage> createState() => _TimerPageState();
}

class _TimerPageState extends State<TimerPage> {
  SessionController get controller => widget.controller;
  bool _fullScreen = false;
  bool _exiting = false;

  @override
  void initState() {
    super.initState();
    final bridge = ResearchMonitorBridge.instance;
    bridge.attach(controller);
    bridge.onCloseSession = _exit;
    controller.startTicker();
    unawaited(controller.reannounce());
    AppCloseGuard.handler = _onCloseRequested;
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    if (AppCloseGuard.handler == _onCloseRequested) AppCloseGuard.handler = null;
    final bridge = ResearchMonitorBridge.instance;
    if (bridge.onCloseSession == _exit) bridge.onCloseSession = null;
    super.dispose();
  }

  Future<void> _exit() async {
    if (_exiting || !mounted) return;
    if (controller.isActive || controller.closing == 'finishing') {
      controller.setNotice('Finaliza o cancela la sesión antes de volver al inicio');
      return;
    }
    _exiting = true;
    controller.stopTicker();
    ResearchMonitorBridge.instance.attach(null);
    await ResearchMonitorBridge.instance.closeMonitorWindow();
    await controller.audio.dispose();
    controller.dispose();
    if (_fullScreen) {
      try {
        await MultiWindowManager.current.setFullScreen(false);
      } catch (_) {}
    }
    widget.onExit();
  }

  Future<bool> _onCloseRequested() async {
    if (controller.closing == 'finishing') {
      controller.setNotice('Espera a que termine de guardarse la sesión');
      return false;
    }
    if (!controller.isActive) return true;
    final close = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('Hay una sesión en curso'),
        content: const SizedBox(
          width: 460,
          child: Text(
            'Si cierras la aplicación, la sesión se pausa y se guarda tal como está '
            '(actividades, marcas, Polar y vídeo hasta ahora). Al volver a abrirla '
            'podrás reanudarla desde donde se quedó.',
            style: TextStyle(color: Colors.white70, height: 1.4),
          ),
        ),
        actions: [
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Seguir con la sesión'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Pausar y cerrar'),
          ),
        ],
      ),
    );
    if (close != true) return false;
    await controller.suspend();
    return true;
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent || !mounted) return false;
    // A dialog of this window is open: its own keys.
    if (ModalRoute.of(context)?.isCurrent == false) return false;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.f2) {
      unawaited(ResearchMonitorBridge.instance.showMonitor());
      return true;
    }
    if (key == LogicalKeyboardKey.f11) {
      _fullScreen = !_fullScreen;
      unawaited(MultiWindowManager.current.setFullScreen(_fullScreen).catchError((_) {}));
      return true;
    }
    if (key == LogicalKeyboardKey.f5) {
      if (!controller.engine.hasStarted) {
        // The start checks the sensors and the camera in the monitor.
        unawaited(ResearchMonitorBridge.instance.showMonitor());
      } else {
        unawaited(controller.command('toggle'));
      }
      return true;
    }
    if (key == LogicalKeyboardKey.f6) {
      if (controller.engine.mainInProgress) {
        controller.setNotice('Para terminar antes de tiempo, usa el Research Monitor');
      } else {
        unawaited(controller.command('advance'));
      }
      return true;
    }
    if (key == LogicalKeyboardKey.f7) {
      unawaited(controller.command('sync'));
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF05070C),
      body: ParticipantView(
        controller: controller,
        onShowMonitor: () => ResearchMonitorBridge.instance.showMonitor(),
        onNewSession: _exit,
      ),
    );
  }
}
