import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../config/default_protocol_configuration.dart';
import '../models/activity_battery.dart';
import '../models/session_manifest.dart';
import '../models/sync_window.dart';
import '../services/lab_redcap_service.dart';
import '../services/redcap_resend.dart';
import '../windows/window_messages.dart';
import 'csv_stream_writer.dart';
import 'protocol_engine.dart';
import 'session_clock.dart';
import 'session_store.dart';

/// Durations for the phases an activity leaves open, and timer options.
class SessionSettings {
  final int prepSeconds;
  final int mainSeconds;
  final int postSeconds;

  /// Wait after each activity until the evaluator starts the next one.
  final bool lapMode;
  final bool voice;

  const SessionSettings({
    this.prepSeconds = 30,
    this.mainSeconds = 600,
    this.postSeconds = 30,
    this.lapMode = true,
    this.voice = true,
  });

  SessionSettings copyWith({
    int? prepSeconds,
    int? mainSeconds,
    int? postSeconds,
    bool? lapMode,
    bool? voice,
  }) =>
      SessionSettings(
        prepSeconds: prepSeconds ?? this.prepSeconds,
        mainSeconds: mainSeconds ?? this.mainSeconds,
        postSeconds: postSeconds ?? this.postSeconds,
        lapMode: lapMode ?? this.lapMode,
        voice: voice ?? this.voice,
      );

  Map<String, dynamic> toJson() => {
        'prep_seconds': prepSeconds,
        'main_seconds': mainSeconds,
        'post_seconds': postSeconds,
        'lap_mode': lapMode,
        'voice': voice,
      };

  factory SessionSettings.fromJson(Object? json) {
    if (json is! Map) return const SessionSettings();
    int seconds(String key, int fallback) {
      final v = json[key];
      return v is num && v >= 0 ? v.round() : fallback;
    }

    return SessionSettings(
      prepSeconds: seconds('prep_seconds', 30),
      mainSeconds: math.max(1, seconds('main_seconds', 600)),
      postSeconds: seconds('post_seconds', 30),
      lapMode: json['lap_mode'] as bool? ?? true,
      voice: json['voice'] as bool? ?? true,
    );
  }
}

/// Sounds of the participant screen.
enum SessionSound {
  /// One beep of the 3-2-1 before a clap or a jump.
  countdown,

  /// The moment to clap or jump.
  go,

  /// Last seconds of a phase.
  tick,

  /// Start of the activity.
  start,

  /// End of the activity.
  end,
}

/// Voice and sounds for the participant.
abstract class SessionAudio {
  bool voiceEnabled = true;

  /// Says [text], cutting what was being said.
  void say(String text);
  void play(SessionSound sound);
  void stopVoice();
  Future<void> dispose();
}

/// No sound (tests, or a computer without audio). Keeps what would have
/// been said and played.
class SilentAudio extends SessionAudio {
  final List<String> said = [];
  final List<SessionSound> played = [];

  @override
  void say(String text) {
    if (voiceEnabled) said.add(text);
  }

  @override
  void play(SessionSound sound) => played.add(sound);

  @override
  void stopVoice() {}

  @override
  Future<void> dispose() async {}
}

/// The Research Monitor window, as the session sees it.
abstract class MonitorLink {
  /// Sends [method] to the monitor; null when there is no monitor or it
  /// did not answer.
  Future<dynamic> send(String method, [dynamic arguments]);
}

class NoMonitor implements MonitorLink {
  @override
  Future<dynamic> send(String method, [dynamic arguments]) async => null;
}

/// Answer to a command of the Research Monitor.
class CommandResult {
  final bool ok;
  final String? message;

  const CommandResult.ok([this.message]) : ok = true;
  const CommandResult.refused(this.message) : ok = false;

  Map<String, dynamic> toJson() => {'ok': ok, if (message != null) 'message': message};
}

/// What was saved at the end of a session, shown to the evaluator.
class SessionSummary {
  final String directory;
  final int done;
  final int partial;
  final int skipped;
  final int notDone;
  final int syncWindows;
  final double totalSeconds;
  final List<String> files;
  final bool videoSaved;
  final String? redcapError;
  final bool redcapSkipped;
  final String? storeError;

  const SessionSummary({
    required this.directory,
    required this.done,
    required this.partial,
    required this.skipped,
    required this.notDone,
    required this.syncWindows,
    required this.totalSeconds,
    required this.files,
    required this.videoSaved,
    this.redcapError,
    this.redcapSkipped = false,
    this.storeError,
  });

  Map<String, dynamic> toJson() => {
        'directory': directory,
        'done': done,
        'partial': partial,
        'skipped': skipped,
        'not_done': notDone,
        'sync_windows': syncWindows,
        'total_seconds': totalSeconds,
        'files': files,
        'video_saved': videoSaved,
        if (redcapError != null) 'redcap_error': redcapError,
        if (redcapSkipped) 'redcap_skipped': true,
        if (storeError != null) 'store_error': storeError,
      };
}

/// A session saved on disk that did not finish (the app closed), found when
/// the app starts again.
class UnfinishedSession {
  final Directory directory;
  final Map<String, dynamic> state;

  const UnfinishedSession(this.directory, this.state);

  List<ParticipantEntry> get participants => [
        for (final p in state['participants'] as List? ?? const [])
          ParticipantEntry.fromJson(Map<String, dynamic>.from(p as Map)),
      ];

  ActivityBattery? get battery {
    final raw = state['battery'];
    if (raw is! Map) return null;
    try {
      return ActivityBattery.fromJson(Map<String, dynamic>.from(raw));
    } on FormatException {
      return null;
    }
  }

  DateTime? get savedAt => DateTime.tryParse(state['saved_at_utc']?.toString() ?? '');

  int get loggedActivities {
    final engine = state['engine'];
    if (engine is! Map) return 0;
    return [
      for (final a in engine['activities'] as List? ?? const [])
        if ((a as Map)['completion'] != ActivityCompletion.skipped) a,
    ].length;
  }

  /// Reads [directory]; null when it holds no session or one that ended.
  static Future<UnfinishedSession?> find(String directory) async {
    final state = await SessionStore.readState(directory);
    if (state == null) return null;
    final status = state['status']?.toString();
    if (status == 'finished' || status == 'cancelled') return null;
    return UnfinishedSession(Directory(directory), state);
  }

  /// Sessions left open under [root] (`<root>/<participant>/<visit>`),
  /// newest first.
  static Future<List<UnfinishedSession>> scan(String root) async {
    final found = <UnfinishedSession>[];
    final base = Directory(root);
    try {
      if (!await base.exists()) return found;
      await for (final participant in base.list(followLinks: false)) {
        if (participant is! Directory) continue;
        await for (final visit in participant.list(followLinks: false)) {
          if (visit is! Directory || visit.path.contains('_cancelada_')) continue;
          try {
            final session = await find(visit.path);
            if (session != null) found.add(session);
          } catch (_) {
            // A half-written or foreign folder: not a session to resume.
          }
        }
      }
    } on FileSystemException {
      return found;
    }
    found.sort((a, b) => (b.savedAt ?? DateTime(0)).compareTo(a.savedAt ?? DateTime(0)));
    return found;
  }
}

/// One laboratory session: the protocol timer, its folder on disk, the
/// voice and sounds, and the link with the Research Monitor.
///
/// The Research Monitor sends the evaluator's commands ([command]); the
/// controller runs them on the [ProtocolEngine], writes everything to the
/// session folder as it happens and tells the monitor the new state
/// ([snapshot]). The participant screen listens to it.
class SessionController extends ChangeNotifier {
  SessionController({
    required List<ParticipantEntry> participants,
    required this.battery,
    required this.dataRoot,
    this.settings = const SessionSettings(),
    this.operator,
    int startIndex = 1,
    SessionClock? clock,
    SessionAudio? audio,
    MonitorLink? monitor,
    this.importRecords = LabRedCapService.importRecords,
    this.onActiveSessionChanged,
    this.redcapConfigured = LabRedCapService.isConfigured,
  })  : participants = List.unmodifiable(participants),
        clock = clock ?? SystemSessionClock(),
        audio = audio ?? SilentAudio(),
        monitor = monitor ?? NoMonitor() {
    this.audio.voiceEnabled = settings.voice;
    engine = ProtocolEngine(
      clock: this.clock,
      planFor: _planFor,
      lastIndex: battery?.activities.length,
      lapMode: settings.lapMode,
      sync: battery?.sync ?? const SyncSettings(),
      startIndex: startIndex,
    );
  }

  /// Rebuilds a session from its folder after the app closed. It starts
  /// paused; the Polar files and the event log go on in the same files.
  factory SessionController.resume(
    UnfinishedSession saved, {
    SessionClock? clock,
    SessionAudio? audio,
    MonitorLink? monitor,
    Future<String?> Function(List<Map<String, dynamic>>) importRecords =
        LabRedCapService.importRecords,
    void Function(String? directory)? onActiveSessionChanged,
    bool redcapConfigured = LabRedCapService.isConfigured,
  }) {
    final state = saved.state;
    final controller = SessionController(
      participants: saved.participants,
      battery: saved.battery,
      dataRoot: saved.directory.parent.parent.path,
      settings: SessionSettings.fromJson(state['settings']),
      operator: state['operator']?.toString(),
      clock: clock,
      audio: audio,
      monitor: monitor,
      importRecords: importRecords,
      onActiveSessionChanged: onActiveSessionChanged,
      redcapConfigured: redcapConfigured,
    );
    final engineState = state['engine'];
    if (engineState is Map) {
      controller.engine = ProtocolEngine.restore(
        Map<String, dynamic>.from(engineState),
        clock: controller.clock,
        planFor: controller._planFor,
        lastIndex: controller.battery?.activities.length,
        lapMode: controller.settings.lapMode,
        sync: controller.battery?.sync ?? const SyncSettings(),
        lastAlive: saved.savedAt,
      );
    }
    controller.sessionId = state['session_id']?.toString();
    controller._videoFiles.addAll([
      for (final f in state['video_files'] as List? ?? const []) f.toString(),
    ]);
    controller.notes = state['notes']?.toString();
    controller.videoRequested = state['video_requested'] == true;
    controller.resumed = true;
    controller.store = SessionStore.reopen(
      saved.directory,
      state['file_stamp']?.toString() ?? SessionStore.stampOf(DateTime.now()),
    );
    controller.store!.logEvent(
      'session_resumed_after_restart',
      activityIndex: controller.engine.activityIndex,
      attempt: controller.engine.attempt,
      phase: controller.engine.phase.wireName,
      detail: 'Último guardado: ${state['saved_at_utc']}',
    );
    return controller;
  }

  final List<ParticipantEntry> participants;
  final ActivityBattery? battery;
  final String dataRoot;
  SessionSettings settings;
  final String? operator;
  final SessionClock clock;
  final SessionAudio audio;
  final MonitorLink monitor;
  final Future<String?> Function(List<Map<String, dynamic>>) importRecords;
  final bool redcapConfigured;

  /// Called with the session folder when a session starts, and with null
  /// when it ends, so the app can offer to resume it after a crash.
  final void Function(String? directory)? onActiveSessionChanged;

  late ProtocolEngine engine;
  SessionStore? _store;

  /// The session folder; its log uses the session clock.
  SessionStore? get store => _store;
  set store(SessionStore? value) {
    _store = value;
    value?.now = clock.nowUtc;
  }
  String? sessionId;

  /// True when this session was rebuilt after the app closed.
  bool resumed = false;

  /// Notes of the evaluator about the whole session (`ws_incidents`).
  String? notes;

  /// Video files moved into the session folder.
  final List<String> _videoFiles = [];

  /// The evaluator started the session with video: the monitor records
  /// (again after a restart).
  bool videoRequested = false;

  /// `finishing`, `saved` or `cancelled` after the engine has finished.
  String? closing;
  SessionSummary? summary;

  /// Last message for the evaluator (a refused command, a warning).
  final ValueNotifier<String?> notice = ValueNotifier(null);

  Timer? _ticker;
  int _lastShownSecond = -1;
  int _lastSessionSecond = -1;
  int _lastTickBeep = -1;
  DateTime? _lastStateSave;
  bool _disposed = false;

  /// Seconds between two saves of the session state while it runs.
  static const Duration checkpointEvery = Duration(seconds: 5);

  // ===========================================================================
  // Plan of each activity
  // ===========================================================================

  BatteryActivity? activityAt(int index) => battery?.activityAt(index);

  int? _labIndexOf(int index) {
    final b = battery;
    if (b == null) return null;
    var calibrations = 0;
    for (var i = 1; i < index && i <= b.activities.length; i++) {
      if (b.activityAt(i)!.isCalibration) calibrations++;
    }
    return index - calibrations;
  }

  ActivityPlan _planFor(int index) {
    final a = activityAt(index);
    return ActivityPlan(
      index: index,
      name: a?.name,
      compendiumCode: a?.compendiumCode,
      met: a?.met,
      labIndex: _labIndexOf(index),
      kind: a?.kind.name ?? ActivityKind.activity.name,
      prepSeconds: a?.prepSeconds ?? settings.prepSeconds,
      mainSeconds: a?.durationSeconds ?? settings.mainSeconds,
      postSeconds: a?.postSeconds ?? settings.postSeconds,
      faces: a?.faces,
      animation: a?.animationOrGuess ?? 'stand',
      instructions: a?.instructions,
      restingHr: a?.restingHr ?? false,
    );
  }

  String get participantSummary => participants.map((p) => p.participantId).join(';');

  String get visitCode => SessionStore.visitCode(
        participants.isEmpty ? '' : participants.first.redcapEventName,
      );

  int get activityCount => battery?.activities.length ?? 0;

  bool get isActive => engine.hasStarted && closing == null;

  // ===========================================================================
  // Clock
  // ===========================================================================

  /// Starts calling [tick]; the timer page does it while it is shown.
  void startTicker({Duration every = const Duration(milliseconds: 50)}) {
    _ticker?.cancel();
    _ticker = Timer.periodic(every, (_) => tick());
  }

  void stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  /// Moves the session on: phase changes, sync cues, the last-seconds
  /// beeps and the periodic checkpoint.
  void tick() {
    if (_disposed) return;
    final events = engine.tick();
    _handle(events);

    if (engine.isRunning) {
      final remaining = engine.remainingSeconds;
      if (engine.phase != SessionPhase.wait &&
          engine.plannedPhaseSeconds >= 6 &&
          engine.cue == null &&
          remaining >= 1 &&
          remaining <= 3 &&
          remaining != _lastTickBeep) {
        _lastTickBeep = remaining;
        audio.play(SessionSound.tick);
      }
      final now = DateTime.now();
      if (_lastStateSave == null || now.difference(_lastStateSave!) >= checkpointEvery) {
        _saveState();
      }
    }

    final shown = engine.phase == SessionPhase.wait
        ? engine.phaseElapsed.inSeconds
        : engine.remainingSeconds;
    final sessionSecond = sessionElapsedSeconds;
    if (events.isNotEmpty || shown != _lastShownSecond || sessionSecond != _lastSessionSecond) {
      _lastShownSecond = shown;
      _lastSessionSecond = sessionSecond;
      notifyListeners();
      // The clocks of the monitor's console move only with a snapshot.
      unawaited(sendSnapshot());
    }
  }

  /// Seconds since the session started; it goes on during a pause.
  int get sessionElapsedSeconds {
    final start = engine.sessionStartUtc;
    if (start == null) return 0;
    return (engine.sessionEndUtc ?? clock.nowUtc()).difference(start).inSeconds;
  }

  // ===========================================================================
  // Commands of the Research Monitor
  // ===========================================================================

  /// Runs a command of the evaluator. [args] come from the monitor; a
  /// malformed one is refused, never thrown.
  Future<CommandResult> command(String name, [Map<String, dynamic> args = const {}]) async {
    try {
      return await _command(name, args);
    } catch (e, stack) {
      debugPrint('[SESSION] Orden "$name" no válida: $e\n$stack');
      return CommandResult.refused('Orden no válida ($name): $e');
    }
  }

  static int? _int(Object? value) => value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');

  Future<CommandResult> _command(String name, Map<String, dynamic> args) async {
    if (_disposed) return const CommandResult.refused('La sesión ya se ha cerrado');
    if (closing != null && !const {'snapshot', 'redcap_retry', 'log'}.contains(name)) {
      return const CommandResult.refused('La sesión ya se está guardando');
    }
    switch (name) {
      case 'start':
        return start(video: args['video'] == true);
      case 'pause':
        return _run(name, engine.pause());
      case 'resume':
        return _run(name, engine.resume());
      case 'toggle':
        if (!engine.hasStarted) return start(video: args['video'] == true);
        return _run(engine.isPaused ? 'resume' : 'pause',
            engine.isPaused ? engine.resume() : engine.pause());
      case 'advance':
        return _run(name, engine.advance());
      case 'repeat':
        return _run(name, engine.repeat());
      case 'skip':
        return _run(name, engine.skip());
      case 'goto':
        final index = _int(args['index']);
        if (index == null) return const CommandResult.refused('Falta la actividad');
        return _run(name, engine.goTo(index), detail: '$index');
      case 'sync':
        return _run(name, engine.requestSync());
      case 'annotate':
        return annotate(args);
      case 'rpe_before':
        return setRpeBefore(
          _int(args['index']) ?? engine.upcomingIndex ?? engine.activityIndex,
          _int(args['value']),
        );
      case 'voice':
        final enabled = args['enabled'] is bool ? args['enabled'] as bool : !settings.voice;
        settings = settings.copyWith(voice: enabled);
        audio.voiceEnabled = enabled;
        if (!enabled) audio.stopVoice();
        _changed(saveState: true);
        return const CommandResult.ok();
      case 'settings':
        return updateSettings(args);
      case 'notes':
        notes = args['notes']?.toString();
        _changed(saveState: true);
        return const CommandResult.ok();
      case 'finish':
        if (args['notes'] != null) notes = args['notes'].toString();
        unawaited(finish());
        return const CommandResult.ok('Guardando la sesión...');
      case 'cancel':
        unawaited(cancel(reason: args['reason']?.toString()));
        return const CommandResult.ok('Cancelando la sesión...');
      case 'redcap_retry':
        unawaited(retryRedcap());
        return const CommandResult.ok('Enviando a REDCap...');
      case 'snapshot':
        unawaited(sendInfo());
        unawaited(sendSnapshot());
        return const CommandResult.ok();
      case 'log':
        // Sensor and camera events seen by the monitor, in the session log.
        store?.logEvent(
          args['event']?.toString() ?? 'monitor',
          activityIndex: engine.activityIndex,
          phase: engine.phase.wireName,
          detail: args['detail']?.toString() ?? '',
        );
        return const CommandResult.ok();
    }
    return CommandResult.refused('Orden desconocida: $name');
  }

  CommandResult _run(String name, List<EngineEvent> events, {String? detail}) {
    final refused = events.whereType<EngineRefused>().firstOrNull;
    if (refused != null) {
      notice.value = refused.reason;
      notifyListeners();
      return CommandResult.refused(refused.reason);
    }
    store?.logEvent(
      'operator_$name',
      activityIndex: engine.activityIndex,
      attempt: engine.attempt,
      phase: engine.phase.wireName,
      detail: detail,
    );
    _handle(events);
    _changed(saveState: true);
    return const CommandResult.ok();
  }

  /// Starts the session: creates its folder and starts the timer.
  /// [video] tells whether the monitor is recording video.
  Future<CommandResult> start({required bool video}) async {
    if (engine.hasStarted) {
      // A session rebuilt after a crash starts paused.
      if (engine.isPaused) return _run('resume', engine.resume());
      return const CommandResult.refused('La sesión ya ha empezado');
    }
    try {
      if (store == null) {
        final dir = await SessionStore.chooseFolder(
          root: dataRoot,
          study: battery?.study,
          participants: participants,
        );
        store = await SessionStore.create(dir);
        await _checkWritable(dir);
      }
    } catch (e) {
      store = null;
      final message = 'No se pudo crear la carpeta de la sesión en $dataRoot: $e';
      notice.value = message;
      notifyListeners();
      return CommandResult.refused(message);
    }

    sessionId ??= 'session_${DateTime.now().toUtc().microsecondsSinceEpoch}';
    videoRequested = video;
    final events = engine.start();
    store!.logEvent(
      'session_started',
      activityIndex: engine.activityIndex,
      attempt: engine.attempt,
      phase: engine.phase.wireName,
      detail: video ? 'con vídeo' : 'sin vídeo',
    );
    onActiveSessionChanged?.call(store!.path);
    await _announceStart();
    _handle(events);
    _changed(saveState: true, outputs: true);
    return const CommandResult.ok();
  }

  static Future<void> _checkWritable(Directory dir) async {
    final probe = File('${dir.path}${Platform.pathSeparator}.write_test');
    await probe.writeAsString('ok', flush: true);
    await probe.delete();
  }

  /// Sends the session folder to the monitor so it writes the Polar files
  /// and moves the video there.
  Future<void> _announceStart() async {
    final s = store;
    if (s == null) return;
    await monitor.send(WindowMessages.sessionStarted, {
      'session_dir': s.path,
      'file_stamp': s.fileStamp,
      'session_id': sessionId,
      'participants': participantSummary,
      'resumed': resumed,
      'video': videoRequested,
    });
  }

  /// Tells a monitor opened (or reset) after the start where to write.
  Future<void> reannounce() async {
    if (store != null && isActive) await _announceStart();
    await sendInfo();
    await sendSnapshot();
  }

  Future<CommandResult> annotate(Map<String, dynamic> args) async {
    final index = _int(args['log_index']);
    if (index == null || index < 0 || index >= engine.logs.length) {
      return const CommandResult.refused('No existe ese registro');
    }
    var log = engine.logs[index];
    if (args.containsKey('rpe')) {
      final rpe = _int(args['rpe']);
      log = rpe == null ? log.copyWith(clearRpe: true) : log.copyWith(rpe: rpe.clamp(0, 10));
    }
    if (args.containsKey('rpe_before')) {
      final rpe = _int(args['rpe_before']);
      log = rpe == null
          ? log.copyWith(clearRpeBefore: true)
          : log.copyWith(rpeBefore: rpe.clamp(0, 10));
    }
    if (args.containsKey('incident')) {
      final text = args['incident']?.toString().trim() ?? '';
      log = text.isEmpty ? log.copyWith(clearIncident: true) : log.copyWith(incident: text);
    }
    if (args['completion'] is String &&
        const {
          ActivityCompletion.complete,
          ActivityCompletion.partial,
          ActivityCompletion.skipped,
        }.contains(args['completion'])) {
      log = log.copyWith(completion: args['completion'] as String);
    }
    if (args['fields'] is Map) {
      final values = Map<String, String>.from(log.fieldValues);
      (args['fields'] as Map).forEach((key, value) {
        final text = value?.toString().trim() ?? '';
        if (text.isEmpty) {
          values.remove(key.toString());
        } else {
          values[key.toString()] = text;
        }
      });
      log = log.copyWith(fieldValues: values);
    }
    if (args.containsKey('resting_hr')) {
      final bpm = _int(args['resting_hr']);
      if (bpm != null && (bpm < 25 || bpm > 230)) {
        return const CommandResult.refused('La FC de reposo debe estar entre 25 y 230 lpm');
      }
      log = bpm == null
          ? log.copyWith(clearRestingHr: true)
          : log.copyWith(restingHrBpm: bpm, restingHrTime: log.activityEndTime);
    }
    engine.updateLog(index, log);
    store?.logEvent(
      'annotation',
      activityIndex: log.activityIndex,
      attempt: log.attempt,
      detail: [
        if (log.rpe != null) 'rpe=${log.rpe}',
        if (log.rpeBefore != null) 'rpe_antes=${log.rpeBefore}',
        if (log.completion != ActivityCompletion.complete) log.completion,
        for (final e in log.fieldValues.entries) '${e.key}=${e.value}',
        if (log.incident != null) 'incidencia',
      ].join(' '),
    );
    _changed(saveState: true, outputs: true);
    return const CommandResult.ok();
  }

  /// Effort before activity [index], asked in the wait before it.
  CommandResult setRpeBefore(int index, int? value) {
    if (value == null) {
      engine.rpeBefore.remove(index);
    } else {
      engine.rpeBefore[index] = value.clamp(0, 10);
    }
    store?.logEvent('rpe_before', activityIndex: index, detail: '${value ?? ''}');
    _changed(saveState: true);
    return const CommandResult.ok();
  }

  CommandResult updateSettings(Map<String, dynamic> args) {
    int? seconds(String key) {
      final v = args[key];
      return v is num && v >= 0 ? v.round() : null;
    }

    settings = settings.copyWith(
      prepSeconds: seconds('prep_seconds'),
      mainSeconds: seconds('main_seconds') == 0 ? null : seconds('main_seconds'),
      postSeconds: seconds('post_seconds'),
      lapMode: args['lap_mode'] is bool ? args['lap_mode'] as bool : null,
    );
    engine.lapMode = settings.lapMode;
    engine.replacePlans(_planFor);
    store?.logEvent('settings', detail: settings.toJson().toString());
    _changed(saveState: true);
    unawaited(sendInfo());
    return const CommandResult.ok();
  }

  // ===========================================================================
  // Engine events
  // ===========================================================================

  void _handle(List<EngineEvent> events) {
    for (final event in events) {
      switch (event) {
        case PhaseStarted(:final plan, :final phase, :final attempt, :final first):
          _lastTickBeep = -1;
          store?.logEvent(
            'phase_started',
            activityIndex: plan.index,
            attempt: attempt,
            phase: phase.wireName,
            detail: plan.name,
          );
          _speakPhase(plan, phase, attempt, first: first);
          if (phase == SessionPhase.main) audio.play(SessionSound.start);
          if (phase == SessionPhase.post) audio.play(SessionSound.end);
          _changed(saveState: true);
        case ActivityLogged(:final log):
          store?.logEvent(
            'activity_logged',
            activityIndex: log.activityIndex,
            attempt: log.attempt,
            detail: '${log.completion} ${log.endReason} ${log.durationSeconds.toStringAsFixed(1)} s',
          );
          // A resting heart rate needs a minute at least of real rest.
          if (_planFor(log.activityIndex).restingHr && !log.isSkipped && log.durationSeconds >= 60 && closing != 'cancelled') {
            _restingHrJob = _measureRestingHr(log);
          }
          _changed(saveState: true, outputs: true);
        case ProtocolCompleted():
          store?.logEvent('protocol_completed');
        case SyncCueStarted(:final cue):
          audio.stopVoice();
          store?.logEvent(
            'sync_cue',
            activityIndex: cue.activityIndex,
            phase: cue.phase.wireName,
            detail: '${cue.eventId} ${cue.kind} ${cue.manual ? 'manual' : 'auto'}',
          );
        case SyncCueCountdown():
          audio.play(SessionSound.countdown);
        case SyncCueGo(:final window):
          audio.play(SessionSound.go);
          store?.logEvent(
            'sync_go',
            activityIndex: window.activityIndex,
            phase: window.phase,
            detail: '${window.eventId} ${window.syncKind}',
            time: window.cueTime,
          );
          _changed(saveState: true, outputs: true);
        case SyncCueCancelled(:final cue):
          store?.logEvent('sync_cancelled', activityIndex: cue.activityIndex, detail: cue.eventId);
        case SyncCueEnded():
          break;
        case CalibrationFace(:final face, :final faces):
          audio.say('Gira la caja. Cara $face de $faces.');
        case EngineRefused(:final reason):
          notice.value = reason;
        case SessionPaused():
          store?.logEvent('session_paused', activityIndex: engine.activityIndex, phase: engine.phase.wireName);
          audio.say('Pausa.');
        case SessionResumed():
          store?.logEvent('session_resumed', activityIndex: engine.activityIndex, phase: engine.phase.wireName);
          audio.say('Seguimos.');
        case SessionFinished():
          store?.logEvent('session_finished', activityIndex: engine.activityIndex);
      }
    }
  }

  /// Name of an activity to be read aloud.
  String _spoken(ActivityPlan plan) =>
      plan.name == null ? 'Actividad ${plan.index}' : plan.name!.toLowerCase();

  void _speakPhase(ActivityPlan plan, SessionPhase phase, int attempt, {required bool first}) {
    final count = activityCount;
    switch (phase) {
      case SessionPhase.prep:
        final position = count > 0 ? 'Actividad ${plan.index} de $count' : 'Actividad ${plan.index}';
        final again = attempt > 1 ? ', otra vez' : '';
        final name = plan.name == null ? '' : ': ${_spoken(plan)}';
        audio.say('$position$name$again. Quédate quieto.');
      case SessionPhase.main:
        audio.say(plan.isCalibration ? 'Caja de calibración. Cara 1.' : '¡Empieza!');
      case SessionPhase.post:
        audio.say('Para. Quédate quieto.');
      case SessionPhase.wait:
        audio.say(engine.protocolComplete
            ? 'Protocolo completado. ¡Muy bien!'
            : 'Actividad terminada. Descansa.');
    }
  }

  /// Resting heart rate of [log] from the Polar of the monitor: the mean of
  /// its last two minutes.
  Future<void>? _restingHrJob;

  Future<void> _measureRestingHr(ActivityLog log) async {
    final to = log.activityEndTime;
    final from = to.subtract(Duration(seconds: math.min(120, log.durationSeconds.floor())));
    final reply = await monitor.send(WindowMessages.restingHrRequested, {
      'from_utc': from.toIso8601String(),
      'to_utc': to.toIso8601String(),
    });
    if (reply is! Map || reply['bpm'] is! num) {
      notice.value = 'No se pudo calcular la FC de reposo (¿H10 conectada?)';
      notifyListeners();
      return;
    }
    // The log may have been replaced meanwhile (the effort was typed).
    final i = engine.logs.indexWhere((l) =>
        l.activityIndex == log.activityIndex &&
        l.attempt == log.attempt &&
        l.activityStartTime == log.activityStartTime);
    if (i < 0) return;
    engine.updateLog(
      i,
      engine.logs[i].copyWith(
        restingHrBpm: (reply['bpm'] as num).round(),
        restingHrTime: to,
      ),
    );
    store?.logEvent(
      'resting_hr',
      activityIndex: log.activityIndex,
      detail: '${reply['bpm']} lpm (${reply['device'] ?? reply['source'] ?? ''}, '
          '${reply['method'] == 'rr' ? 'RR' : 'FC'}, n=${reply['n'] ?? reply['beats'] ?? '?'})',
    );
    _changed(saveState: true, outputs: true);
  }

  // ===========================================================================
  // Files
  // ===========================================================================

  /// A message for the evaluator, shown in the monitor.
  void setNotice(String message) {
    notice.value = message;
    _changed();
  }

  void _changed({bool saveState = false, bool outputs = false}) {
    if (saveState) _saveState();
    if (outputs) _writeOutputs();
    notifyListeners();
    unawaited(sendSnapshot());
  }

  Map<String, dynamic> stateJson({String? status}) => {
        'format': 'lab_protocol_timer.session_state',
        'version': 1,
        'saved_at_utc': DateTime.now().toUtc().toIso8601String(),
        'status': status ?? closing ?? engine.status.name,
        'session_id': sessionId,
        'file_stamp': store?.fileStamp,
        'participants': participants.map((p) => p.toJson()).toList(),
        if (operator != null) 'operator': operator,
        if (notes != null) 'notes': notes,
        'battery': battery?.toJson(),
        'settings': settings.toJson(),
        'video_files': _videoFiles,
        'video_requested': videoRequested,
        'engine': engine.toJson(),
      };

  void _saveState({String? status}) {
    final s = store;
    if (s == null) return;
    _lastStateSave = DateTime.now();
    s.writeJson(SessionStore.stateFile, stateJson(status: status));
  }

  /// Attempts written to the manifest: the skipped ones have no time span.
  List<ActivityLog> get _manifestActivities =>
      engine.logs.where((l) => !l.isSkipped).toList();

  Map<String, dynamic> manifestJson({required String status, List<String> files = const []}) {
    final start = engine.sessionStartUtc ?? DateTime.now().toUtc();
    final end = engine.sessionEndUtc ?? DateTime.now().toUtc();
    return {
      ...buildSessionManifest(
        sessionId: sessionId ?? 'session',
        sessionStartTime: start,
        sessionEndTime: end.isBefore(start) ? start : end,
        participants: participants,
        activities: _manifestActivities,
        syncWindows: engine.syncWindows,
        generatedFiles: [..._videoFiles, ...files],
        protocolConfiguration: protocolConfigurationFor(battery),
        battery: battery,
        redcapInstances: LabRedCapService.labActivityInstances(engine.logs),
      ),
      'status': status,
      if (operator != null) 'operator': operator,
      if (notes != null && notes!.isNotEmpty) 'notes': notes,
      'settings': settings.toJson(),
      if (files.isNotEmpty) 'files': files,
    };
  }

  void _writeOutputs({String status = 'in_progress', List<String> files = const []}) {
    final s = store;
    if (s == null) return;
    s.writeJson(SessionStore.manifestFile, manifestJson(status: status, files: files));
    s.writeText('activity_markers.csv', activityMarkersCsv(engine.logs));
    s.writeText('sync_windows.csv', syncWindowsCsv(engine.syncWindows));
  }

  static const activityMarkersHeader = 'activity_index,activity_start_time_utc,'
      'activity_end_time_utc,duration_seconds,activity_name,compendium_code,'
      'planned_duration_seconds,met,activity_kind,attempt,completion,'
      'end_reason,paused_seconds,rpe,rpe_before,resting_hr_bpm,incident';

  /// One row per attempt with a time span (skipped activities are left out).
  static String activityMarkersCsv(List<ActivityLog> logs) {
    final buffer = StringBuffer()..writeln(activityMarkersHeader);
    for (final a in logs) {
      if (a.isSkipped) continue;
      buffer.writeln([
        a.activityIndex,
        a.activityStartTime.toUtc().toIso8601String(),
        a.activityEndTime.toUtc().toIso8601String(),
        a.durationSeconds.toStringAsFixed(6),
        csvField(a.activityName),
        a.compendiumCode ?? '',
        a.plannedDurationSeconds ?? '',
        a.met ?? '',
        a.activityKind,
        a.attempt,
        a.completion,
        a.endReason,
        a.pausedSeconds.toStringAsFixed(3),
        a.rpe ?? '',
        a.rpeBefore ?? '',
        a.restingHrBpm ?? '',
        csvField(a.incident),
      ].join(','));
    }
    return buffer.toString();
  }

  static String syncWindowsCsv(List<SyncWindow> windows) {
    final buffer = StringBuffer()..writeln(SyncWindow.csvHeader);
    for (final w in windows) {
      buffer.writeln(w.toCsvRow());
    }
    return buffer.toString();
  }

  // ===========================================================================
  // End of the session
  // ===========================================================================

  /// Ends the session: stops the video and the Polar files in the monitor,
  /// writes the final manifest and sends the visit to REDCap.
  Future<SessionSummary?> finish() async {
    if (closing != null) return summary;
    if (!engine.hasStarted) {
      notice.value = 'La sesión no ha empezado';
      notifyListeners();
      return null;
    }
    closing = 'finishing';
    _handle(engine.finish());
    _changed(saveState: true);
    final s = store!;
    // The resting heart rate of the last rest, if it is still being asked.
    await _restingHrJob?.timeout(const Duration(seconds: 8), onTimeout: () {});

    // The monitor stops the cameras, moves the videos into the folder and
    // closes the Polar files.
    final reply = await monitor.send(WindowMessages.sessionStopping, {'session_dir': s.path});
    final files = <String>[];
    if (reply is Map) {
      for (final f in reply['video_files'] as List? ?? const []) {
        final name = f.toString();
        if (!_videoFiles.contains(name)) _videoFiles.add(name);
      }
      files.addAll([for (final f in reply['files'] as List? ?? const []) f.toString()]);
      cameras = (reply['cameras'] as num?)?.toInt() ?? cameras;
    }

    _writeOutputs(status: 'complete', files: files);
    s.logEvent('outputs_written');

    final redcapError = await _sendRedcap();
    closing = 'saved';
    _saveState(status: 'finished');
    await s.close();
    onActiveSessionChanged?.call(null);

    summary = _summary(redcapError: redcapError, files: await _folderFiles(s.directory));
    _changed();
    await monitor.send(WindowMessages.sessionSaved, summary!.toJson());
    return summary;
  }

  /// Every file left in the session folder, for the summary.
  static Future<List<String>> _folderFiles(Directory dir) async {
    final names = <String>[];
    try {
      await for (final entry in dir.list(followLinks: false)) {
        if (entry is File) names.add(entry.path.split(RegExp(r'[\\/]')).last);
      }
    } catch (_) {
      // The summary goes without the list.
    }
    return names..sort();
  }

  SessionSummary _summary({String? redcapError, List<String> files = const [], bool redcapSkipped = false}) {
    final logs = engine.logs;
    final last = <int, ActivityLog>{};
    for (final l in logs) {
      final previous = last[l.activityIndex];
      if (previous == null || !l.isSkipped || previous.isSkipped) last[l.activityIndex] = l;
    }
    final start = engine.sessionStartUtc ?? DateTime.now().toUtc();
    final end = engine.sessionEndUtc ?? DateTime.now().toUtc();
    return SessionSummary(
      directory: store?.path ?? '',
      done: last.values.where((l) => l.completion == ActivityCompletion.complete).length,
      partial: last.values.where((l) => l.completion == ActivityCompletion.partial).length,
      skipped: last.values.where((l) => l.isSkipped).length,
      notDone: engine.notDone().length,
      syncWindows: engine.syncWindows.length,
      totalSeconds: end.difference(start).inMilliseconds / 1000,
      files: files,
      videoSaved: _videoFiles.isNotEmpty,
      redcapError: redcapError,
      redcapSkipped: redcapSkipped,
      storeError: store?.lastError.value,
    );
  }

  /// Records sent to REDCap for this session (also kept on disk when the
  /// import fails).
  List<List<Map<String, dynamic>>> redcapImports() {
    final start = engine.sessionStartUtc ?? DateTime.now().toUtc();
    final end = engine.sessionEndUtc ?? DateTime.now().toUtc();
    final logs = List<ActivityLog>.from(engine.logs);
    return LabRedCapService.buildSessionImports(
      participants: participants,
      sessionId: sessionId ?? 'session',
      battery: battery,
      sessionStartTime: start,
      sessionEndTime: end,
      logs: logs,
      notReached: [for (final i in engine.notDone()) _notReachedLog(i, end)],
      cameras: _videoFiles.isEmpty ? 0 : math.max(1, cameras),
      notes: notes,
      operator: operator,
      pendingRpeBefore: Map.of(engine.rpeBefore),
    );
  }

  /// Cameras that recorded video in the session (told by the monitor).
  int cameras = 0;

  ActivityLog _notReachedLog(int index, DateTime at) {
    final p = _planFor(index);
    return ActivityLog(
      activityIndex: p.index,
      activityStartTime: at,
      activityEndTime: at,
      durationSeconds: 0,
      activityName: p.name,
      compendiumCode: p.compendiumCode,
      plannedDurationSeconds: p.mainSeconds,
      met: p.met,
      labIndex: p.labIndex,
      activityKind: p.kind,
      completion: ActivityCompletion.skipped,
      endReason: 'not_reached',
    );
  }

  Future<String?> _sendRedcap() async {
    final s = store;
    if (s == null) return null;
    final imports = redcapImports();
    final errors = <String>[];
    if (!redcapConfigured) {
      errors.add('Falta el token de REDCap (compila con --dart-define=REDCAP_TOKEN=...)');
    } else {
      const names = LabRedCapService.sessionImportNames;
      for (var i = 0; i < imports.length; i++) {
        if (imports[i].isEmpty) continue;
        final error = await importRecords(imports[i]);
        if (error == null) continue;
        errors.add('${i < names.length ? names[i] : 'Envío ${i + 1}'}: '
            '${LabRedCapService.explainImportError(error, imports[i])}');
      }
    }
    final error = errors.isEmpty ? null : errors.join('\n');
    s.logEvent(error == null ? 'redcap_sent' : 'redcap_failed', detail: error);
    if (error != null) {
      // What would have been sent, to send it again from the start screen.
      s.writeJson(SavedSessionRedcap.pendingFile, [for (final batch in imports) ...batch]);
    }
    await s.drain();
    if (error == null) await SavedSessionRedcap.markSent(s.directory);
    return error;
  }

  /// Sends a saved session to REDCap again (after a network error).
  Future<void> retryRedcap() async {
    final s = store;
    if (s == null || summary == null) return;
    // The store was closed: reopen it for the log and the records file.
    final reopened = SessionStore.reopen(s.directory, s.fileStamp);
    store = reopened;
    final error = await _sendRedcap();
    await reopened.close();
    summary = _summary(redcapError: error, files: summary!.files);
    _changed();
    await monitor.send(WindowMessages.sessionSaved, summary!.toJson());
  }

  /// Ends the session without REDCap. The folder keeps what was recorded
  /// and is renamed `..._cancelada_<hora>` so the visit can be done again.
  Future<void> cancel({String? reason}) async {
    if (closing != null) return;
    closing = 'cancelled';
    if (engine.hasStarted) _handle(engine.finish());
    final s = store;
    if (s == null) {
      onActiveSessionChanged?.call(null);
      _changed();
      await monitor.send(WindowMessages.sessionCancelled, {});
      return;
    }
    s.logEvent('session_cancelled', detail: reason);
    _saveState(status: 'cancelled');
    final reply = await monitor.send(WindowMessages.sessionStopping, {
      'session_dir': s.path,
      'cancelled': true,
    });
    if (reply is Map) {
      for (final f in reply['video_files'] as List? ?? const []) {
        if (!_videoFiles.contains(f.toString())) _videoFiles.add(f.toString());
      }
    }
    _writeOutputs(status: 'cancelled');
    _saveState(status: 'cancelled');
    await s.close();
    onActiveSessionChanged?.call(null);

    String? renamed;
    try {
      final now = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      // Two cancellations in the same minute get different folders.
      var target = '${s.path}_cancelada_${two(now.hour)}${two(now.minute)}';
      for (var n = 2; await Directory(target).exists(); n++) {
        target = '${s.path}_cancelada_${two(now.hour)}${two(now.minute)}_$n';
      }
      renamed = (await s.directory.rename(target)).path;
    } catch (e) {
      debugPrint('[SESSION] No se pudo renombrar la carpeta cancelada: $e');
    }
    summary = _summary(redcapSkipped: true);
    _changed();
    await monitor.send(WindowMessages.sessionCancelled, {
      'directory': renamed ?? s.path,
    });
  }

  /// Closes the app in the middle of a session: everything is saved and the
  /// session can be resumed when the app opens again.
  Future<void> suspend() async {
    if (!isActive) return;
    if (engine.isRunning) _handle(engine.pause());
    store?.logEvent('app_closed_during_session');
    _saveState();
    await monitor.send(WindowMessages.sessionSuspending, {'session_dir': store?.path});
    await store?.drain();
    await store?.flushEvents();
  }

  // ===========================================================================
  // Research Monitor
  // ===========================================================================

  DateTime? _lastSnapshotAt;
  bool _snapshotQueued = false;

  /// Sends the state to the monitor, at most about five times a second.
  Future<void> sendSnapshot() async {
    if (_disposed) return;
    final now = DateTime.now();
    if (_lastSnapshotAt != null &&
        now.difference(_lastSnapshotAt!) < const Duration(milliseconds: 180)) {
      if (_snapshotQueued) return;
      _snapshotQueued = true;
      await Future.delayed(const Duration(milliseconds: 200));
      _snapshotQueued = false;
      if (_disposed) return;
    }
    _lastSnapshotAt = DateTime.now();
    await monitor.send(WindowMessages.sessionSnapshot, snapshot());
  }

  /// What does not change every second: the protocol and the participants.
  Future<void> sendInfo() => monitor.send(WindowMessages.sessionInfo, info());

  Map<String, dynamic> info() => {
        'participants': participantSummary,
        'visit': visitCode,
        'event_name': participants.isEmpty ? null : participants.first.redcapEventName,
        'operator': operator,
        'battery': battery?.toJson(),
        'settings': settings.toJson(),
        'data_root': dataRoot,
        'redcap_configured': redcapConfigured,
        'resumed': resumed,
      };

  /// Current state for the monitor and the participant screen.
  Map<String, dynamic> snapshot() {
    final plan = engine.plan;
    final upcoming = engine.upcomingIndex;
    final cue = engine.cue;
    final logs = engine.logs;
    return {
      'status': closing ?? engine.status.name,
      'session_dir': store?.path,
      'session_id': sessionId,
      'activity_index': engine.activityIndex,
      'activity_count': activityCount,
      'activity_name': plan.label,
      'animation': plan.animation,
      'phase': engine.phase.wireName,
      'attempt': engine.attempt,
      'remaining_s': engine.remainingSeconds,
      'planned_s': engine.plannedPhaseSeconds,
      'elapsed_phase_s': engine.phaseElapsed.inSeconds,
      'session_elapsed_s': sessionElapsedSeconds,
      'next_index': upcoming,
      'next_name': upcoming == null ? null : _planFor(upcoming).label,
      'protocol_complete': engine.protocolComplete,
      'main_in_progress': engine.mainInProgress,
      'sync_available': engine.syncAvailable,
      'sync_reason': engine.syncBlockedReason,
      'sync_kind': engine.syncKindNow,
      'sync_count': engine.syncWindows.length,
      if (cue != null)
        'cue': {
          'kind': cue.kind,
          'count': cue.went ? 0 : ProtocolEngine.cueLeadSeconds - cue.beeps + 1,
          'manual': cue.manual,
        },
      'voice': settings.voice,
      'store_error': store?.lastError.value,
      'notice': notice.value,
      'rpe_before': {for (final e in engine.rpeBefore.entries) '${e.key}': e.value},
      'pending_rpe_log': pendingRpeLog,
      'rpe_before_for': rpeBeforeFor,
      'logs': [
        for (var i = 0; i < logs.length; i++) {...logs[i].toJson(), 'log_index': i},
      ],
      'not_done': engine.notDone(),
    };
  }

  /// Logged attempt whose effort the participant should give now (the one
  /// just finished), in the wait.
  int? get pendingRpeLog {
    if (battery?.askRpe != true || engine.phase != SessionPhase.wait) return null;
    for (var i = engine.logs.length - 1; i >= 0; i--) {
      final log = engine.logs[i];
      if (log.isSkipped) continue;
      if (log.isCalibration) return null;
      return log.rpe == null ? i : null;
    }
    return null;
  }

  /// Next activity that asks the effort before it, when it has none yet.
  int? get rpeBeforeFor {
    if (engine.phase != SessionPhase.wait || pendingRpeLog != null) return null;
    final next = engine.upcomingIndex;
    if (next == null) return null;
    final mapping = activityAt(next)?.redcap;
    if (mapping?.rpeBeforeField == null) return null;
    return engine.rpeBefore.containsKey(next) ? null : next;
  }

  @override
  void dispose() {
    _disposed = true;
    stopTicker();
    notice.dispose();
    super.dispose();
  }
}
