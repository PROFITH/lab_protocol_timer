import 'dart:math' as math;

import '../models/activity_battery.dart';
import '../models/sync_window.dart';
import '../services/lab_redcap_service.dart';
import 'session_clock.dart';

/// State of the session timer.
enum SessionStatus { idle, running, paused, finished }

/// Phases of each activity, with the names used in the files and by SAVES.
enum SessionPhase {
  prep('static_prep'),
  main('activity_main'),
  post('static_post'),
  wait('transition_lap');

  const SessionPhase(this.wireName);

  final String wireName;

  bool get isStatic => this == prep || this == post;

  static SessionPhase fromWire(String? name) => SessionPhase.values
      .firstWhere((p) => p.wireName == name || p.name == name,
          orElse: () => SessionPhase.prep);
}

/// Durations and metadata of one activity of the session.
class ActivityPlan {
  final int index;
  final String? name;
  final String? compendiumCode;
  final double? met;

  /// Position in the battery without calibration box segments.
  final int? labIndex;
  final String kind;
  final int prepSeconds;
  final int mainSeconds;
  final int postSeconds;
  final int? faces;
  final String animation;
  final String? instructions;
  final bool restingHr;

  const ActivityPlan({
    required this.index,
    this.name,
    this.compendiumCode,
    this.met,
    this.labIndex,
    this.kind = 'activity',
    required this.prepSeconds,
    required this.mainSeconds,
    required this.postSeconds,
    this.faces,
    this.animation = 'stand',
    this.instructions,
    this.restingHr = false,
  });

  bool get isCalibration => kind == 'calibration';

  String get label => name == null ? 'Actividad $index' : name!;

  int secondsOf(SessionPhase phase) => switch (phase) {
        SessionPhase.prep => prepSeconds,
        SessionPhase.main => mainSeconds,
        SessionPhase.post => postSeconds,
        SessionPhase.wait => 0,
      };

  /// Seconds each face lasts in a calibration box, or null.
  int? get faceSeconds {
    if (!isCalibration) return null;
    final n = faces ?? 6;
    if (n < 2 || mainSeconds < n) return null;
    return mainSeconds ~/ n;
  }
}

/// Sync manoeuvre in progress: a 3-2-1 countdown, then the go.
class SyncCue {
  final String eventId;

  /// `clap` or `jump` (a jump falls back to a clap in lying or seated
  /// postures).
  final String kind;
  final bool manual;
  final int activityIndex;
  final SessionPhase phase;
  final Duration startMono;
  final DateTime startUtc;

  /// Beeps already given (3 before the go).
  int beeps = 0;
  SyncWindow? window;

  SyncCue({
    required this.eventId,
    required this.kind,
    required this.manual,
    required this.activityIndex,
    required this.phase,
    required this.startMono,
    required this.startUtc,
  });

  bool get went => window != null;
}

/// What happened in a call to the engine, for sounds, voice, files and the
/// Research Monitor.
sealed class EngineEvent {
  const EngineEvent();
}

class PhaseStarted extends EngineEvent {
  final ActivityPlan plan;
  final SessionPhase phase;
  final int attempt;

  /// True when the phase starts because the session was started or resumed
  /// after a recovery, not because the previous one ended.
  final bool first;

  const PhaseStarted(this.plan, this.phase, this.attempt, {this.first = false});
}

class ActivityLogged extends EngineEvent {
  final ActivityLog log;
  final int logIndex;
  const ActivityLogged(this.log, this.logIndex);
}

class ProtocolCompleted extends EngineEvent {
  const ProtocolCompleted();
}

class SyncCueStarted extends EngineEvent {
  final SyncCue cue;
  const SyncCueStarted(this.cue);
}

/// One beep of the countdown: 3, 2 or 1.
class SyncCueCountdown extends EngineEvent {
  final SyncCue cue;
  final int count;
  const SyncCueCountdown(this.cue, this.count);
}

class SyncCueGo extends EngineEvent {
  final SyncCue cue;
  final SyncWindow window;
  const SyncCueGo(this.cue, this.window);
}

class SyncCueCancelled extends EngineEvent {
  final SyncCue cue;
  const SyncCueCancelled(this.cue);
}

/// The cue left the participant's screen.
class SyncCueEnded extends EngineEvent {
  final SyncCue cue;
  const SyncCueEnded(this.cue);
}

class CalibrationFace extends EngineEvent {
  final int face;
  final int faces;
  const CalibrationFace(this.face, this.faces);
}

/// A request that could not be done now, with the reason for the operator.
class EngineRefused extends EngineEvent {
  final String reason;
  const EngineRefused(this.reason);
}

class SessionPaused extends EngineEvent {
  const SessionPaused();
}

class SessionResumed extends EngineEvent {
  const SessionResumed();
}

class SessionFinished extends EngineEvent {
  const SessionFinished();
}

/// Activity timer of a laboratory session: static preparation, the activity,
/// static end and the wait (lap) before the next one.
///
/// Every phase has a deadline on the monotonic clock; the time a phase
/// overruns (a slow frame) is carried into the next one, so the protocol
/// never drifts. The engine has no Flutter code: the timer page calls
/// [tick] several times a second and turns the returned events into voice,
/// sounds, files and messages to the Research Monitor.
class ProtocolEngine {
  ProtocolEngine({
    required this.clock,
    required ActivityPlan Function(int index) planFor,
    this.lastIndex,
    this.firstIndex = 1,
    this.lapMode = true,
    this.sync = const SyncSettings(),
    int? startIndex,
    List<ActivityLog>? logs,
    List<SyncWindow>? syncWindows,
    this.sessionStartUtc,
  })  : _planFor = planFor,
        logs = logs ?? [],
        syncWindows = syncWindows ?? [] {
    activityIndex = startIndex ?? firstIndex;
    nextIndex = activityIndex;
    attempt = _attemptsOf(activityIndex) + 1;
  }

  final SessionClock clock;
  ActivityPlan Function(int index) _planFor;

  /// Last activity of the battery; null without a battery (numbered
  /// activities with no end).
  int? lastIndex;
  final int firstIndex;
  bool lapMode;
  SyncSettings sync;

  /// Seconds of the countdown before the go, and of each sync window
  /// (counted from the first beep).
  static const int cueLeadSeconds = 3;
  static const int syncWindowSeconds = 10;

  /// Seconds the go stays on the participant's screen.
  static const int cueShowSeconds = 2;

  /// A cue needs this many seconds of static phase left (or the wait).
  static const int minSecondsForCue = 12;

  /// Static phases shorter than this get no automatic cue.
  static const int minStaticForAutoCue = 16;

  /// Postures where a jump is not possible: the cue asks for a clap.
  static const Set<String> noJumpAnimations = {
    'lie',
    'sit',
    'type',
    'cycle',
    'sit_to_stand',
  };

  SessionStatus status = SessionStatus.idle;
  late int activityIndex;

  /// Activity that "next" starts from the wait.
  late int nextIndex;
  SessionPhase phase = SessionPhase.prep;
  late int attempt;

  /// True in the wait after the last activity of the battery.
  bool protocolComplete = false;

  final List<ActivityLog> logs;
  final List<SyncWindow> syncWindows;
  DateTime? sessionStartUtc;
  DateTime? sessionEndUtc;

  SyncCue? cue;
  bool _autoCueGiven = false;

  /// Start of the last countdown, so two windows never overlap.
  Duration? _lastCueStartMono;

  Duration _phaseAccumulated = Duration.zero;
  Duration? _runningSince;

  DateTime? _mainStartUtc;
  Duration _mainPaused = Duration.zero;
  Duration? _pausedAtMono;

  /// Effort before an activity, typed in the wait before it.
  final Map<int, int> rpeBefore = {};

  int _lastFace = 0;

  ActivityPlan get plan => _planFor(activityIndex);
  ActivityPlan planAt(int index) => _planFor(index);

  void replacePlans(ActivityPlan Function(int index) planFor) {
    _planFor = planFor;
  }

  bool get isRunning => status == SessionStatus.running;
  bool get isPaused => status == SessionStatus.paused;
  bool get hasStarted => status != SessionStatus.idle;

  /// Main phase started and not yet logged.
  bool get mainInProgress => _mainStartUtc != null;

  Duration get phaseElapsed =>
      _phaseAccumulated +
      (_runningSince == null ? Duration.zero : clock.elapsed - _runningSince!);

  int get plannedPhaseSeconds => plan.secondsOf(phase);

  Duration get remaining {
    if (phase == SessionPhase.wait) return Duration.zero;
    final left = Duration(seconds: plannedPhaseSeconds) - phaseElapsed;
    return left.isNegative ? Duration.zero : left;
  }

  /// Seconds left, rounded up as a countdown shows them.
  int get remainingSeconds => (remaining.inMilliseconds / 1000).ceil();

  /// 1 at the start of a phase, 0 at its end.
  double get phaseFractionLeft {
    final planned = plannedPhaseSeconds;
    if (planned <= 0 || phase == SessionPhase.wait) return 0;
    return (remaining.inMilliseconds / (planned * 1000)).clamp(0.0, 1.0);
  }

  bool get hasNext => lastIndex == null || nextIndex <= lastIndex!;

  /// Activity shown as "next": the one after the current, or [nextIndex]
  /// in the wait.
  int? get upcomingIndex {
    final i = phase == SessionPhase.wait ? nextIndex : activityIndex + 1;
    if (lastIndex != null && i > lastIndex!) return null;
    return i;
  }

  /// Face of the calibration box on now, or null.
  int? get calibrationFace {
    final seconds = plan.faceSeconds;
    if (phase != SessionPhase.main || seconds == null) return null;
    return (phaseElapsed.inSeconds ~/ seconds + 1).clamp(1, plan.faces ?? 6);
  }

  // ===========================================================================
  // Sync
  // ===========================================================================

  /// Effective manoeuvre for the current activity.
  String get syncKindNow =>
      sync.kind == SyncKind.jump && !noJumpAnimations.contains(plan.animation)
          ? SyncKind.jump.name
          : SyncKind.clap.name;

  bool get cueActive => cue != null;

  /// Why a manual cue cannot be given now, or null when it can.
  String? get syncBlockedReason {
    if (!isRunning) {
      return isPaused ? 'La sesión está en pausa' : 'La sesión no ha empezado';
    }
    if (cue != null && !cue!.went) return 'Ya hay una cuenta atrás en marcha';
    if (_lastCueStartMono != null &&
        clock.elapsed - _lastCueStartMono! <
            const Duration(seconds: syncWindowSeconds)) {
      return 'Espera a que termine la ventana anterior';
    }
    if (phase == SessionPhase.wait) return null;
    if (phase == SessionPhase.main) return 'Solo en las fases estáticas o en la espera';
    if (remaining < const Duration(seconds: minSecondsForCue)) {
      return 'Quedan menos de $minSecondsForCue s de fase estática';
    }
    return null;
  }

  bool get syncAvailable => syncBlockedReason == null;

  List<EngineEvent> requestSync() {
    final blocked = syncBlockedReason;
    if (blocked != null) return [EngineRefused(blocked)];
    final events = <EngineEvent>[];
    _clearFinishedCue(events);
    _startCue(events, manual: true);
    return events;
  }

  void _startCue(List<EngineEvent> events, {required bool manual}) {
    final started = SyncCue(
      eventId: 'sync_${syncWindows.length + 1}',
      kind: syncKindNow,
      manual: manual,
      activityIndex: activityIndex,
      phase: phase,
      startMono: clock.elapsed,
      startUtc: clock.nowUtc(),
    );
    cue = started;
    _lastCueStartMono = started.startMono;
    // A phase with a sync already needs no automatic one.
    _autoCueGiven = true;
    events.add(SyncCueStarted(started));
    _advanceCue(events);
  }

  /// Seconds into the static phase at which the automatic cue starts: the
  /// go falls in the middle of the phase, with stillness on both sides.
  static int autoCueStartSeconds(int phaseSeconds) =>
      math.max(0, phaseSeconds ~/ 2 - cueLeadSeconds);

  bool get _autoCueWanted {
    if (!phase.isStatic || plan.isCalibration || _autoCueGiven) return false;
    if (plannedPhaseSeconds < minStaticForAutoCue) return false;
    return switch (sync.auto) {
      AutoSync.everyStatic => true,
      // The first static phase of this session (whatever activity it
      // starts at) and the end of the last activity.
      AutoSync.firstLast => (phase == SessionPhase.prep &&
              !logs.any((l) => !l.isSkipped) &&
              !syncWindows.any((w) => w.eventType == 'auto_sync')) ||
          (phase == SessionPhase.post &&
              lastIndex != null &&
              activityIndex == lastIndex),
      AutoSync.manual => false,
    };
  }

  void _maybeAutoCue(List<EngineEvent> events) {
    if (!_autoCueWanted || cue != null) return;
    if (_lastCueStartMono != null &&
        clock.elapsed - _lastCueStartMono! <
            const Duration(seconds: syncWindowSeconds)) {
      return;
    }
    final startAt = Duration(seconds: autoCueStartSeconds(plannedPhaseSeconds));
    if (phaseElapsed < startAt) return;
    // Too late for a whole window in this phase (resumed near its end).
    if (remaining < const Duration(seconds: syncWindowSeconds - 2)) {
      _autoCueGiven = true;
      return;
    }
    _startCue(events, manual: false);
  }

  void _advanceCue(List<EngineEvent> events) {
    final current = cue;
    if (current == null) return;
    final since = clock.elapsed - current.startMono;

    while (!current.went && current.beeps < cueLeadSeconds &&
        since >= Duration(seconds: current.beeps)) {
      events.add(SyncCueCountdown(current, cueLeadSeconds - current.beeps));
      current.beeps++;
    }

    if (!current.went && since >= const Duration(seconds: cueLeadSeconds)) {
      final goUtc =
          current.startUtc.add(const Duration(seconds: cueLeadSeconds));
      final window = SyncWindow(
        eventId: current.eventId,
        eventType: current.manual ? 'manual_sync' : 'auto_sync',
        activityIndex: current.activityIndex,
        phase: current.phase.wireName,
        windowStart: current.startUtc,
        windowEnd: current.startUtc
            .add(const Duration(seconds: syncWindowSeconds)),
        syncKind: current.kind,
        cueTime: goUtc,
      );
      current.window = window;
      syncWindows.add(window);
      events.add(SyncCueGo(current, window));
    }

    if (current.went &&
        since >= const Duration(seconds: cueLeadSeconds + cueShowSeconds)) {
      cue = null;
      events.add(SyncCueEnded(current));
    }
  }

  /// A countdown that has not reached the go is dropped (pause, phase
  /// change); one that went only leaves the screen.
  void _dropCue(List<EngineEvent> events) {
    final current = cue;
    if (current == null) return;
    cue = null;
    events.add(current.went ? SyncCueEnded(current) : SyncCueCancelled(current));
  }

  void _clearFinishedCue(List<EngineEvent> events) {
    final current = cue;
    if (current != null && current.went) {
      cue = null;
      events.add(SyncCueEnded(current));
    }
  }

  // ===========================================================================
  // Timer
  // ===========================================================================

  List<EngineEvent> start() {
    if (status != SessionStatus.idle) {
      return [const EngineRefused('La sesión ya ha empezado')];
    }
    status = SessionStatus.running;
    sessionStartUtc ??= clock.nowUtc();
    _runningSince = clock.elapsed;
    final events = <EngineEvent>[
      PhaseStarted(plan, phase, attempt, first: true),
    ];
    events.addAll(tick());
    return events;
  }

  List<EngineEvent> pause() {
    if (!isRunning) return [const EngineRefused('La sesión no está en marcha')];
    final events = <EngineEvent>[];
    _phaseAccumulated = phaseElapsed;
    _runningSince = null;
    status = SessionStatus.paused;
    _pausedAtMono = clock.elapsed;
    _dropCue(events);
    events.add(const SessionPaused());
    return events;
  }

  List<EngineEvent> resume() {
    if (!isPaused) return [const EngineRefused('La sesión no está en pausa')];
    status = SessionStatus.running;
    _runningSince = clock.elapsed;
    if (_pausedAtMono != null && _mainStartUtc != null) {
      _mainPaused += clock.elapsed - _pausedAtMono!;
    }
    _pausedAtMono = null;
    return [const SessionResumed(), ...tick()];
  }

  /// Moves the timer on; call it several times a second.
  List<EngineEvent> tick() {
    if (!isRunning) return const [];
    final events = <EngineEvent>[];
    _advanceCue(events);

    var guard = 0;
    while (isRunning &&
        phase != SessionPhase.wait &&
        phaseElapsed >= Duration(seconds: plannedPhaseSeconds) &&
        guard++ < 20) {
      final overflow = phaseElapsed - Duration(seconds: plannedPhaseSeconds);
      _endPhase(events, reason: 'timer', overflow: overflow);
    }

    if (isRunning) {
      _maybeAutoCue(events);
      final face = calibrationFace;
      if (face != null && face != _lastFace) {
        _lastFace = face;
        if (face > 1) events.add(CalibrationFace(face, plan.faces ?? 6));
      }
    }
    return events;
  }

  // ===========================================================================
  // Operator actions
  // ===========================================================================

  /// Ends the current phase now: start the activity, end it early (logged
  /// as partial), end the static phase, or start the next activity from the
  /// wait.
  List<EngineEvent> advance() {
    if (!hasStarted || status == SessionStatus.finished) {
      return [const EngineRefused('La sesión no ha empezado')];
    }
    final events = <EngineEvent>[];
    if (phase == SessionPhase.wait) {
      if (!hasNext) {
        return [
          const EngineRefused(
            'No quedan actividades: pulsa FINALIZAR Y GUARDAR',
          ),
        ];
      }
      _startActivity(events, nextIndex);
      return events;
    }
    if (isPaused && phase == SessionPhase.prep) {
      return [
        const EngineRefused('Reanuda la sesión para empezar la actividad'),
      ];
    }
    _endPhase(events, reason: 'early', overflow: Duration.zero);
    return events;
  }

  /// Does the current activity again from its static preparation. An
  /// activity cut in its main phase is kept as partial.
  List<EngineEvent> repeat() {
    if (!hasStarted || status == SessionStatus.finished) {
      return [const EngineRefused('La sesión no ha empezado')];
    }
    final events = <EngineEvent>[];
    if (_mainStartUtc != null) _logMain(events, reason: 'repeat');
    final index = activityIndex;
    _startActivity(events, index);
    return events;
  }

  /// In the static preparation: leaves the activity as not done and goes to
  /// the next one. In the wait: leaves the next activity as not done.
  List<EngineEvent> skip() {
    if (!hasStarted || status == SessionStatus.finished) {
      return [const EngineRefused('La sesión no ha empezado')];
    }
    final events = <EngineEvent>[];
    switch (phase) {
      case SessionPhase.prep:
        _logSkipped(events, activityIndex);
        final next = activityIndex + 1;
        if (lastIndex != null && next > lastIndex!) {
          _enterWait(events, next, overflow: Duration.zero);
        } else {
          _startActivity(events, next);
        }
      case SessionPhase.wait:
        if (!hasNext) {
          return [const EngineRefused('No quedan actividades que saltar')];
        }
        _logSkipped(events, nextIndex);
        nextIndex++;
        if (lastIndex != null && nextIndex > lastIndex!) {
          protocolComplete = true;
          events.add(const ProtocolCompleted());
        }
      case SessionPhase.main:
      case SessionPhase.post:
        return [
          const EngineRefused(
            'Solo se puede saltar antes de empezar la actividad',
          ),
        ];
    }
    return events;
  }

  /// From the wait, makes [index] the next activity; from a static
  /// preparation, starts it now.
  List<EngineEvent> goTo(int index) {
    if (!hasStarted || status == SessionStatus.finished) {
      return [const EngineRefused('La sesión no ha empezado')];
    }
    if (index < firstIndex || (lastIndex != null && index > lastIndex!)) {
      return [EngineRefused('No existe la actividad $index')];
    }
    if (phase == SessionPhase.main || phase == SessionPhase.post) {
      return [
        const EngineRefused(
          'Espera a la fase de espera para cambiar de actividad',
        ),
      ];
    }
    if (phase == SessionPhase.wait) {
      // The participant is resting: "next" starts it when ready.
      nextIndex = index;
      protocolComplete = false;
      return const [];
    }
    final events = <EngineEvent>[];
    _startActivity(events, index);
    return events;
  }

  /// Ends the session; an activity in its main phase is kept as partial.
  List<EngineEvent> finish() {
    if (status == SessionStatus.finished) return const [];
    final events = <EngineEvent>[];
    if (_mainStartUtc != null) _logMain(events, reason: 'finish');
    _dropCue(events);
    _phaseAccumulated = phaseElapsed;
    _runningSince = null;
    status = SessionStatus.finished;
    sessionEndUtc = clock.nowUtc();
    sessionStartUtc ??= sessionEndUtc;
    events.add(const SessionFinished());
    return events;
  }

  /// Replaces the annotations of one logged attempt.
  void updateLog(int logIndex, ActivityLog updated) {
    if (logIndex < 0 || logIndex >= logs.length) return;
    logs[logIndex] = updated;
  }

  // ===========================================================================
  // Phases
  // ===========================================================================

  void _endPhase(
    List<EngineEvent> events, {
    required String reason,
    required Duration overflow,
  }) {
    switch (phase) {
      case SessionPhase.prep:
        _enterPhase(events, SessionPhase.main, overflow);
        _beginMain(overflow);
      case SessionPhase.main:
        _logMain(events, reason: reason, overflow: overflow);
        _enterPhase(events, SessionPhase.post, overflow);
      case SessionPhase.post:
        final next = activityIndex + 1;
        final last = lastIndex != null && next > lastIndex!;
        if (lapMode || last) {
          _enterWait(events, next, overflow: overflow);
        } else {
          _startActivity(events, next, overflow: overflow);
        }
      case SessionPhase.wait:
        break;
    }
  }

  void _enterPhase(
    List<EngineEvent> events,
    SessionPhase next,
    Duration overflow,
  ) {
    _dropCue(events);
    phase = next;
    _autoCueGiven = false;
    _lastFace = 0;
    _phaseAccumulated = overflow;
    _runningSince = isRunning ? clock.elapsed : null;
    events.add(PhaseStarted(plan, phase, attempt));
  }

  void _enterWait(List<EngineEvent> events, int next,
      {required Duration overflow}) {
    nextIndex = next;
    _enterPhase(events, SessionPhase.wait, overflow);
    if (lastIndex != null && nextIndex > lastIndex!) {
      protocolComplete = true;
      events.add(const ProtocolCompleted());
    }
  }

  void _startActivity(List<EngineEvent> events, int index,
      {Duration overflow = Duration.zero}) {
    if (_mainStartUtc != null) _logMain(events, reason: 'early');
    activityIndex = index;
    nextIndex = index;
    attempt = _attemptsOf(index) + 1;
    protocolComplete = false;
    _enterPhase(events, SessionPhase.prep, overflow);
  }

  void _beginMain(Duration overflow) {
    _mainStartUtc = clock.nowUtc().subtract(overflow);
    _mainPaused = Duration.zero;
    _pausedAtMono = null;
  }

  int _attemptsOf(int index) => logs
      .where((l) => l.activityIndex == index && !l.isSkipped)
      .fold(0, (n, l) => math.max(n, l.attempt));

  void _logMain(
    List<EngineEvent> events, {
    required String reason,
    Duration overflow = Duration.zero,
  }) {
    final start = _mainStartUtc;
    if (start == null) return;
    final end = clock.nowUtc().subtract(overflow);
    var paused = _mainPaused;
    if (_pausedAtMono != null) paused += clock.elapsed - _pausedAtMono!;
    final seconds = math.max(
      0.0,
      (end.difference(start) - paused).inMicroseconds / 1e6,
    );
    final p = plan;
    final complete = reason == 'timer' ||
        (p.mainSeconds > 0 && seconds >= p.mainSeconds - 0.5);
    final log = ActivityLog(
      activityIndex: p.index,
      activityStartTime: start,
      activityEndTime: end,
      durationSeconds: seconds,
      activityName: p.name,
      compendiumCode: p.compendiumCode,
      plannedDurationSeconds: p.mainSeconds,
      met: p.met,
      labIndex: p.labIndex,
      activityKind: p.kind,
      attempt: attempt,
      completion:
          complete ? ActivityCompletion.complete : ActivityCompletion.partial,
      endReason: complete ? 'timer' : reason,
      pausedSeconds: paused.inMicroseconds / 1e6,
      rpeBefore: rpeBefore.remove(p.index),
    );
    logs.add(log);
    _mainStartUtc = null;
    _mainPaused = Duration.zero;
    _pausedAtMono = isPaused ? clock.elapsed : null;
    events.add(ActivityLogged(log, logs.length - 1));
  }

  void _logSkipped(List<EngineEvent> events, int index) {
    final p = _planFor(index);
    final now = clock.nowUtc();
    final log = ActivityLog(
      activityIndex: p.index,
      activityStartTime: now,
      activityEndTime: now,
      durationSeconds: 0,
      activityName: p.name,
      compendiumCode: p.compendiumCode,
      plannedDurationSeconds: p.mainSeconds,
      met: p.met,
      labIndex: p.labIndex,
      activityKind: p.kind,
      attempt: _attemptsOf(index) + 1,
      completion: ActivityCompletion.skipped,
      endReason: 'skipped',
    );
    logs.add(log);
    events.add(ActivityLogged(log, logs.length - 1));
  }

  // ===========================================================================
  // Recovery
  // ===========================================================================

  /// State to rebuild the session after the app closed.
  Map<String, dynamic> toJson() => {
        'status': status.name,
        'activity_index': activityIndex,
        'next_index': nextIndex,
        'phase': phase.wireName,
        'attempt': attempt,
        'protocol_complete': protocolComplete,
        'phase_elapsed_ms': phaseElapsed.inMilliseconds,
        if (_mainStartUtc != null)
          'main_start_time_utc': _mainStartUtc!.toIso8601String(),
        'main_paused_ms': _mainPaused.inMilliseconds,
        if (sessionStartUtc != null)
          'session_start_time_utc': sessionStartUtc!.toIso8601String(),
        if (sessionEndUtc != null)
          'session_end_time_utc': sessionEndUtc!.toIso8601String(),
        'rpe_before': {
          for (final e in rpeBefore.entries) e.key.toString(): e.value,
        },
        'activities': logs.map((l) => l.toJson()).toList(),
        'sync_windows': syncWindows.map((w) => w.toJson()).toList(),
      };

  /// Rebuilds a session saved with [toJson], paused. An activity that was
  /// in its main phase is kept as partial up to [lastAlive] (when the state
  /// was last saved) and starts again from its static preparation.
  static ProtocolEngine restore(
    Map<String, dynamic> json, {
    required SessionClock clock,
    required ActivityPlan Function(int index) planFor,
    int? lastIndex,
    int firstIndex = 1,
    bool lapMode = true,
    SyncSettings sync = const SyncSettings(),
    DateTime? lastAlive,
  }) {
    final logs = [
      for (final raw in json['activities'] as List? ?? const [])
        ActivityLog.fromJson(Map<String, dynamic>.from(raw as Map)),
    ];
    final windows = [
      for (final raw in json['sync_windows'] as List? ?? const [])
        SyncWindow.fromJson(Map<String, dynamic>.from(raw as Map)),
    ];
    DateTime? parse(Object? v) =>
        v is String ? DateTime.parse(v).toUtc() : null;

    final engine = ProtocolEngine(
      clock: clock,
      planFor: planFor,
      lastIndex: lastIndex,
      firstIndex: firstIndex,
      lapMode: lapMode,
      sync: sync,
      logs: logs,
      syncWindows: windows,
      sessionStartUtc: parse(json['session_start_time_utc']),
    );
    final index = json['activity_index'] as int? ?? firstIndex;
    final savedPhase = SessionPhase.fromWire(json['phase'] as String?);
    final savedAttempt = json['attempt'] as int? ?? 1;
    final mainStart = parse(json['main_start_time_utc']);
    final rawRpe = json['rpe_before'];
    if (rawRpe is Map) {
      for (final e in rawRpe.entries) {
        final key = int.tryParse(e.key.toString());
        final value = e.value is int ? e.value as int : int.tryParse('${e.value}');
        if (key != null && value != null) engine.rpeBefore[key] = value;
      }
    }

    engine.activityIndex = index;
    engine.attempt = savedAttempt;

    if (savedPhase == SessionPhase.main && mainStart != null) {
      // The activity was cut: keep what was done.
      final end = lastAlive ?? clock.nowUtc();
      final p = planFor(index);
      final paused = Duration(milliseconds: json['main_paused_ms'] as int? ?? 0);
      final seconds = math.max(
        0.0,
        (end.difference(mainStart) - paused).inMicroseconds / 1e6,
      );
      engine.logs.add(ActivityLog(
        activityIndex: p.index,
        activityStartTime: mainStart,
        activityEndTime: end.isBefore(mainStart) ? mainStart : end,
        durationSeconds: seconds,
        activityName: p.name,
        compendiumCode: p.compendiumCode,
        plannedDurationSeconds: p.mainSeconds,
        met: p.met,
        labIndex: p.labIndex,
        activityKind: p.kind,
        attempt: savedAttempt,
        completion: ActivityCompletion.partial,
        endReason: 'interrupted',
        pausedSeconds: paused.inMicroseconds / 1e6,
        rpeBefore: engine.rpeBefore.remove(p.index),
      ));
    }

    switch (savedPhase) {
      case SessionPhase.prep:
      case SessionPhase.main:
        engine.activityIndex = index;
        engine.nextIndex = index;
        engine.attempt = engine._attemptsOf(index) + 1;
        engine.phase = SessionPhase.prep;
      case SessionPhase.post:
      case SessionPhase.wait:
        engine.phase = SessionPhase.wait;
        engine.nextIndex = savedPhase == SessionPhase.post
            ? index + 1
            : json['next_index'] as int? ?? index + 1;
        engine.protocolComplete =
            lastIndex != null && engine.nextIndex > lastIndex;
    }
    engine._phaseAccumulated = Duration.zero;
    engine._runningSince = null;
    engine.status = SessionStatus.paused;
    engine._pausedAtMono = clock.elapsed;
    return engine;
  }

  /// Activities of the battery with no attempt at all (for REDCap).
  List<int> notDone() {
    final last = lastIndex;
    if (last == null) return const [];
    final done = {for (final l in logs) l.activityIndex};
    return [
      for (var i = firstIndex; i <= last; i++)
        if (!done.contains(i)) i,
    ];
  }
}
