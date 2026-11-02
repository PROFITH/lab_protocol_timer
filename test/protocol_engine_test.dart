import 'package:flutter_test/flutter_test.dart';
import 'package:lab_protocol_timer/models/activity_battery.dart';
import 'package:lab_protocol_timer/services/lab_redcap_service.dart';
import 'package:lab_protocol_timer/session/protocol_engine.dart';
import 'package:lab_protocol_timer/session/session_clock.dart';

/// Three activities: 30 s static phases, 60 s / 120 s / 30 s main phases.
ActivityPlan plan(int i) => ActivityPlan(
      index: i,
      name: 'A$i',
      compendiumCode: '0000$i',
      met: 1.0 + i,
      labIndex: i,
      prepSeconds: 30,
      mainSeconds: switch (i) { 1 => 60, 2 => 120, _ => 30 },
      postSeconds: 30,
      animation: i == 1 ? 'lie' : 'walk',
    );

ProtocolEngine engine(
  FakeSessionClock clock, {
  bool lapMode = true,
  SyncSettings sync = const SyncSettings(auto: AutoSync.manual),
}) =>
    ProtocolEngine(
      clock: clock,
      planFor: plan,
      lastIndex: 3,
      lapMode: lapMode,
      sync: sync,
    );

/// Advances the clock in 50 ms ticks, collecting events.
List<EngineEvent> run(ProtocolEngine e, FakeSessionClock clock, Duration d) {
  final events = <EngineEvent>[];
  var left = d;
  const step = Duration(milliseconds: 50);
  while (left > Duration.zero) {
    final s = left < step ? left : step;
    clock.advance(s);
    left -= s;
    events.addAll(e.tick());
  }
  return events;
}

void main() {
  test('runs prep, main, post and waits; logs the activity on time', () {
    final clock = FakeSessionClock();
    final e = engine(clock);
    final t0 = clock.nowUtc();

    final started = e.start();
    expect(started.whereType<PhaseStarted>().single.phase, SessionPhase.prep);
    expect(e.remainingSeconds, 30);

    run(e, clock, const Duration(seconds: 29, milliseconds: 950));
    expect(e.phase, SessionPhase.prep);
    expect(e.remainingSeconds, 1);

    final toMain = run(e, clock, const Duration(milliseconds: 50));
    expect(e.phase, SessionPhase.main);
    expect(toMain.whereType<PhaseStarted>().single.phase, SessionPhase.main);

    final toPost = run(e, clock, const Duration(seconds: 60));
    expect(e.phase, SessionPhase.post);
    final logged = toPost.whereType<ActivityLogged>().single.log;
    expect(logged.activityIndex, 1);
    expect(logged.completion, ActivityCompletion.complete);
    expect(logged.endReason, 'timer');
    expect(logged.activityStartTime, t0.add(const Duration(seconds: 30)));
    expect(logged.activityEndTime, t0.add(const Duration(seconds: 90)));
    expect(logged.durationSeconds, closeTo(60, 1e-6));

    run(e, clock, const Duration(seconds: 30));
    expect(e.phase, SessionPhase.wait);
    expect(e.nextIndex, 2);
    expect(e.upcomingIndex, 2);

    // The wait lasts until the operator moves on.
    run(e, clock, const Duration(minutes: 5));
    expect(e.phase, SessionPhase.wait);

    final next = e.advance();
    expect(next.whereType<PhaseStarted>().single.plan.index, 2);
    expect(e.activityIndex, 2);
    expect(e.phase, SessionPhase.prep);
    expect(e.attempt, 1);
  });

  test('a slow frame does not shift the protocol (deadlines carry over)', () {
    final clock = FakeSessionClock();
    final e = engine(clock);
    final t0 = clock.nowUtc();
    e.start();

    // One tick 2.7 s late at the end of the prep.
    run(e, clock, const Duration(seconds: 29));
    clock.advance(const Duration(milliseconds: 3700));
    e.tick();
    expect(e.phase, SessionPhase.main);
    // 0.7 s of the main phase already gone.
    expect(e.remaining.inMilliseconds, 60000 - 2700);

    final events = run(e, clock, const Duration(seconds: 60));
    final log = events.whereType<ActivityLogged>().single.log;
    expect(log.activityStartTime, t0.add(const Duration(seconds: 30)));
    expect(log.activityEndTime, t0.add(const Duration(seconds: 90)));
  });

  test('a skipped tick spanning several phases ends each at its deadline', () {
    final clock = FakeSessionClock();
    final e = engine(clock, lapMode: false);
    final t0 = clock.nowUtc();
    e.start();
    clock.advance(const Duration(seconds: 125));
    final events = e.tick();
    // prep (30) + main (60) + post (30) = 120 s: activity 2 prep, 5 s in.
    expect(e.activityIndex, 2);
    expect(e.phase, SessionPhase.prep);
    expect(e.remainingSeconds, 25);
    final log = events.whereType<ActivityLogged>().single.log;
    expect(log.activityEndTime, t0.add(const Duration(seconds: 90)));
  });

  test('pauses stop the clock and are left out of the duration', () {
    final clock = FakeSessionClock();
    final e = engine(clock);
    final t0 = clock.nowUtc();
    e.start();
    run(e, clock, const Duration(seconds: 40)); // 10 s into main
    e.pause();
    expect(e.isPaused, isTrue);
    clock.advance(const Duration(seconds: 100));
    expect(e.tick(), isEmpty);
    expect(e.remainingSeconds, 50);
    e.resume();
    final events = run(e, clock, const Duration(seconds: 50));
    final log = events.whereType<ActivityLogged>().single.log;
    expect(log.completion, ActivityCompletion.complete);
    expect(log.durationSeconds, closeTo(60, 1e-6));
    expect(log.pausedSeconds, closeTo(100, 1e-6));
    expect(log.activityEndTime, t0.add(const Duration(seconds: 190)));
  });

  test('ending the activity early keeps it as partial', () {
    final clock = FakeSessionClock();
    final e = engine(clock);
    e.start();
    run(e, clock, const Duration(seconds: 30 + 25));
    final events = e.advance();
    final log = events.whereType<ActivityLogged>().single.log;
    expect(log.completion, ActivityCompletion.partial);
    expect(log.endReason, 'early');
    expect(log.durationSeconds, closeTo(25, 1e-6));
    expect(e.phase, SessionPhase.post);
  });

  test('advance in the prep starts the activity; refused while paused', () {
    final clock = FakeSessionClock();
    final e = engine(clock);
    e.start();
    run(e, clock, const Duration(seconds: 5));
    e.pause();
    expect(e.advance().single, isA<EngineRefused>());
    e.resume();
    e.advance();
    expect(e.phase, SessionPhase.main);
    expect(e.remainingSeconds, 60);
  });

  test('repeat in the main phase keeps a partial attempt and starts again', () {
    final clock = FakeSessionClock();
    final e = engine(clock);
    e.start();
    run(e, clock, const Duration(seconds: 45));
    final events = e.repeat();
    final cut = events.whereType<ActivityLogged>().single.log;
    expect(cut.endReason, 'repeat');
    expect(cut.attempt, 1);
    expect(e.phase, SessionPhase.prep);
    expect(e.activityIndex, 1);
    expect(e.attempt, 2);

    final done = run(e, clock, const Duration(seconds: 90));
    final log = done.whereType<ActivityLogged>().single.log;
    expect(log.attempt, 2);
    expect(log.completion, ActivityCompletion.complete);
  });

  test('repeat from the wait does the activity just finished again', () {
    final clock = FakeSessionClock();
    final e = engine(clock);
    e.start();
    run(e, clock, const Duration(seconds: 120));
    expect(e.phase, SessionPhase.wait);
    expect(e.repeat().whereType<ActivityLogged>(), isEmpty);
    expect(e.activityIndex, 1);
    expect(e.attempt, 2);
    expect(e.phase, SessionPhase.prep);
  });

  test('skip in the prep logs the activity as not done', () {
    final clock = FakeSessionClock();
    final e = engine(clock);
    e.start();
    run(e, clock, const Duration(seconds: 3));
    final events = e.skip();
    final log = events.whereType<ActivityLogged>().single.log;
    expect(log.activityIndex, 1);
    expect(log.completion, ActivityCompletion.skipped);
    expect(e.activityIndex, 2);
    expect(e.phase, SessionPhase.prep);
    expect(e.remainingSeconds, 30);
  });

  test('skip in the wait skips the next activity; skip in main is refused', () {
    final clock = FakeSessionClock();
    final e = engine(clock);
    e.start();
    run(e, clock, const Duration(seconds: 120));
    final events = e.skip();
    expect(events.whereType<ActivityLogged>().single.log.activityIndex, 2);
    expect(e.nextIndex, 3);
    e.advance();
    expect(e.activityIndex, 3);
    run(e, clock, const Duration(seconds: 35));
    expect(e.phase, SessionPhase.main);
    expect(e.skip().single, isA<EngineRefused>());
  });

  test('the last activity ends in a completed wait', () {
    final clock = FakeSessionClock();
    final e = engine(clock, lapMode: false);
    e.start();
    final events = run(e, clock, const Duration(seconds: 120 + 180 + 90));
    expect(events.whereType<ProtocolCompleted>(), hasLength(1));
    expect(e.phase, SessionPhase.wait);
    expect(e.protocolComplete, isTrue);
    expect(e.hasNext, isFalse);
    expect(e.upcomingIndex, isNull);
    expect(e.advance().single, isA<EngineRefused>());
    expect(e.logs.map((l) => l.activityIndex), [1, 2, 3]);
    expect(e.notDone(), isEmpty);
  });

  test('goTo from the wait chooses the next activity; from the prep starts it',
      () {
    final clock = FakeSessionClock();
    final e = engine(clock);
    e.start();
    run(e, clock, const Duration(seconds: 120));
    expect(e.goTo(3), isEmpty);
    expect(e.phase, SessionPhase.wait);
    expect(e.nextIndex, 3);
    e.advance();
    expect(e.activityIndex, 3);
    run(e, clock, const Duration(seconds: 2));
    e.goTo(2);
    expect(e.activityIndex, 2);
    expect(e.phase, SessionPhase.prep);
    expect(e.remainingSeconds, 30);
    expect(e.goTo(9).single, isA<EngineRefused>());
    expect(e.notDone(), [2, 3]);
  });

  test('finish in the main phase keeps the activity as partial', () {
    final clock = FakeSessionClock();
    final e = engine(clock);
    e.start();
    run(e, clock, const Duration(seconds: 50));
    final events = e.finish();
    final log = events.whereType<ActivityLogged>().single.log;
    expect(log.endReason, 'finish');
    expect(log.completion, ActivityCompletion.partial);
    expect(e.status, SessionStatus.finished);
    expect(e.sessionEndUtc, isNotNull);
    expect(e.tick(), isEmpty);
    expect(e.notDone(), [2, 3]);
  });

  group('sync cue', () {
    test('every static phase gets one cue with the go in its middle', () {
      final clock = FakeSessionClock();
      final e = engine(
        clock,
        sync: const SyncSettings(kind: SyncKind.clap, auto: AutoSync.everyStatic),
      );
      final t0 = clock.nowUtc();
      final events = <EngineEvent>[...e.start()];
      events.addAll(run(e, clock, const Duration(seconds: 120)));

      final counts = events.whereType<SyncCueCountdown>().map((c) => c.count);
      expect(counts, [3, 2, 1, 3, 2, 1]);
      final windows = e.syncWindows;
      expect(windows, hasLength(2));
      expect(windows[0].phase, 'static_prep');
      expect(windows[0].eventType, 'auto_sync');
      expect(windows[0].syncKind, 'clap');
      expect(windows[0].windowStart, t0.add(const Duration(seconds: 12)));
      expect(windows[0].cueTime, t0.add(const Duration(seconds: 15)));
      expect(windows[0].windowEnd, t0.add(const Duration(seconds: 22)));
      expect(windows[1].phase, 'static_post');
      expect(windows[1].cueTime, t0.add(const Duration(seconds: 90 + 15)));
      expect(windows.map((w) => w.eventId), ['sync_1', 'sync_2']);
      expect(events.whereType<SyncCueEnded>(), hasLength(2));
      expect(e.cue, isNull);
    });

    test('jump falls back to a clap when lying down', () {
      final clock = FakeSessionClock();
      final e = engine(
        clock,
        sync: const SyncSettings(kind: SyncKind.jump, auto: AutoSync.everyStatic),
      );
      e.start();
      run(e, clock, const Duration(seconds: 120));
      e.advance();
      run(e, clock, const Duration(seconds: 20));
      expect(e.syncWindows.map((w) => w.syncKind), ['clap', 'clap', 'jump']);
    });

    test('a pause before the go cancels the cue; after the go keeps the window',
        () {
      final clock = FakeSessionClock();
      final e = engine(
        clock,
        sync: const SyncSettings(auto: AutoSync.everyStatic),
      );
      e.start();
      run(e, clock, const Duration(seconds: 13));
      expect(e.cue, isNotNull);
      final paused = e.pause();
      expect(paused.whereType<SyncCueCancelled>(), hasLength(1));
      expect(e.syncWindows, isEmpty);
      e.resume();
      // The phase already had its cue: no second automatic one.
      run(e, clock, const Duration(seconds: 17));
      expect(e.syncWindows, isEmpty);
      expect(e.phase, SessionPhase.main);

      run(e, clock, const Duration(seconds: 60 + 16));
      expect(e.syncWindows, hasLength(1));
      final events = e.pause();
      expect(events.whereType<SyncCueEnded>(), hasLength(1));
      expect(e.syncWindows, hasLength(1));
    });

    test('manual cue: refused in main, with less than 12 s left or overlapping',
        () {
      final clock = FakeSessionClock();
      final e = engine(clock);
      expect(e.requestSync().single, isA<EngineRefused>());
      e.start();
      run(e, clock, const Duration(seconds: 1));
      final ok = e.requestSync();
      expect(ok.whereType<SyncCueStarted>(), hasLength(1));
      expect(ok.whereType<SyncCueCountdown>().single.count, 3);
      run(e, clock, const Duration(seconds: 6));
      expect(e.cue, isNull);
      expect(e.requestSync().single, isA<EngineRefused>(),
          reason: 'the window of the first cue is still open');
      run(e, clock, const Duration(seconds: 4));
      expect(e.syncAvailable, isTrue);
      run(e, clock, const Duration(seconds: 8)); // 19 s into the prep
      expect(e.syncAvailable, isFalse); // 11 s left
      run(e, clock, const Duration(seconds: 15));
      expect(e.phase, SessionPhase.main);
      expect(e.syncBlockedReason, contains('estáticas'));
      expect(e.syncWindows.single.eventType, 'manual_sync');
    });

    test('manual cue in the wait at any time', () {
      final clock = FakeSessionClock();
      final e = engine(clock);
      e.start();
      run(e, clock, const Duration(seconds: 120));
      expect(e.phase, SessionPhase.wait);
      e.requestSync();
      run(e, clock, const Duration(seconds: 4));
      expect(e.syncWindows.single.phase, 'transition_lap');
    });

    test('the cue of a phase that ends before the go is cancelled', () {
      final clock = FakeSessionClock();
      final e = engine(clock);
      e.start();
      run(e, clock, const Duration(seconds: 17)); // 13 s left
      e.requestSync();
      run(e, clock, const Duration(seconds: 1));
      final events = e.advance();
      expect(events.whereType<SyncCueCancelled>(), hasLength(1));
      expect(e.syncWindows, isEmpty);
    });

    test('first_last cues only the first prep and the last post', () {
      final clock = FakeSessionClock();
      final e = engine(
        clock,
        lapMode: false,
        sync: const SyncSettings(auto: AutoSync.firstLast),
      );
      e.start();
      run(e, clock, const Duration(seconds: 120 + 180 + 90));
      expect(e.syncWindows.map((w) => '${w.activityIndex}:${w.phase}'),
          ['1:static_prep', '3:static_post']);
    });
  });

  test('the rpe typed before an activity goes to its log', () {
    final clock = FakeSessionClock();
    final e = engine(clock);
    e.start();
    run(e, clock, const Duration(seconds: 120));
    e.rpeBefore[2] = 3;
    e.advance();
    final events = run(e, clock, const Duration(seconds: 150));
    expect(events.whereType<ActivityLogged>().single.log.rpeBefore, 3);
    expect(e.rpeBefore, isEmpty);
  });

  test('restore after a crash in the main phase keeps a partial attempt', () {
    final clock = FakeSessionClock();
    final e = engine(clock);
    e.start();
    run(e, clock, const Duration(seconds: 120)); // activity 1 done
    e.advance();
    run(e, clock, const Duration(seconds: 70)); // 40 s into activity 2
    final saved = e.toJson();
    final lastAlive = clock.nowUtc();

    final clock2 = FakeSessionClock(clock.nowUtc().add(const Duration(minutes: 3)));
    final r = ProtocolEngine.restore(
      saved,
      clock: clock2,
      planFor: plan,
      lastIndex: 3,
      lastAlive: lastAlive,
    );
    expect(r.isPaused, isTrue);
    expect(r.logs, hasLength(2));
    final cut = r.logs.last;
    expect(cut.activityIndex, 2);
    expect(cut.endReason, 'interrupted');
    expect(cut.completion, ActivityCompletion.partial);
    expect(cut.durationSeconds, closeTo(40, 1e-6));
    expect(r.activityIndex, 2);
    expect(r.phase, SessionPhase.prep);
    expect(r.attempt, 2);
    expect(r.sessionStartUtc, e.sessionStartUtc);

    r.resume();
    final events = run(r, clock2, const Duration(seconds: 150));
    expect(events.whereType<ActivityLogged>().single.log.attempt, 2);
  });

  test('restore after a crash in the post phase waits before the next one', () {
    final clock = FakeSessionClock();
    final e = engine(clock);
    e.start();
    run(e, clock, const Duration(seconds: 100));
    expect(e.phase, SessionPhase.post);
    final r = ProtocolEngine.restore(
      e.toJson(),
      clock: FakeSessionClock(),
      planFor: plan,
      lastIndex: 3,
    );
    expect(r.phase, SessionPhase.wait);
    expect(r.nextIndex, 2);
    expect(r.logs, hasLength(1));
    r.resume();
    r.advance();
    expect(r.activityIndex, 2);
  });

  test('numbered activities with no battery never complete', () {
    final clock = FakeSessionClock();
    final e = ProtocolEngine(
      clock: clock,
      planFor: (i) => ActivityPlan(
        index: i,
        prepSeconds: 10,
        mainSeconds: 20,
        postSeconds: 10,
      ),
      lapMode: false,
      sync: const SyncSettings(auto: AutoSync.manual),
    );
    e.start();
    run(e, clock, const Duration(seconds: 40 * 5));
    expect(e.activityIndex, 6);
    expect(e.protocolComplete, isFalse);
    expect(e.notDone(), isEmpty);
  });

  test('calibration box: a new face every 60 s', () {
    final clock = FakeSessionClock();
    final e = ProtocolEngine(
      clock: clock,
      planFor: (i) => ActivityPlan(
        index: i,
        kind: 'calibration',
        prepSeconds: 0,
        mainSeconds: 360,
        postSeconds: 0,
        faces: 6,
      ),
      lastIndex: 1,
      sync: const SyncSettings(auto: AutoSync.everyStatic),
    );
    e.start();
    final events = run(e, clock, const Duration(seconds: 361));
    expect(events.whereType<CalibrationFace>().map((f) => f.face),
        [2, 3, 4, 5, 6]);
    expect(e.syncWindows, isEmpty);
  });
}
