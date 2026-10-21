import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lab_protocol_timer/models/activity_battery.dart';
import 'package:lab_protocol_timer/services/lab_redcap_service.dart';
import 'package:lab_protocol_timer/session/protocol_engine.dart';
import 'package:lab_protocol_timer/session/session_clock.dart';
import 'package:lab_protocol_timer/session/session_controller.dart';
import 'package:lab_protocol_timer/windows/monitor_session.dart';
import 'package:lab_protocol_timer/windows/session_console.dart';
import 'package:lab_protocol_timer/windows/window_messages.dart';

import 'support/loopback_monitor.dart';

void main() {
  late Directory root;
  late ActivityBattery battery;
  final participants = [
    ParticipantEntry(participantId: '001', redcapEventName: 'da_0__visita_inici_arm_1'),
  ];

  setUpAll(() {
    battery = ActivityBattery.parse(File('assets/protocols/run4health_base.json').readAsStringSync());
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lpt_link_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  ({SessionController c, MonitorSession s, LoopbackMonitor link, FakeSessionClock clock, SessionCommandSender send})
      setup({List<List<Map<String, dynamic>>>? imported}) {
    final clock = FakeSessionClock();
    final s = MonitorSession();
    final link = LoopbackMonitor(s);
    final c = SessionController(
      participants: participants,
      battery: battery,
      dataRoot: root.path,
      operator: 'JHM',
      clock: clock,
      monitor: link,
      redcapConfigured: true,
      importRecords: (records) async {
        imported?.add(records);
        return null;
      },
    );
    // What the monitor's buttons do.
    Future<Map<String, dynamic>> send(String command, [Map<String, dynamic> args = const {}]) async =>
        (await c.command(command, args)).toJson();
    return (c: c, s: s, link: link, clock: clock, send: send);
  }

  /// Moves the clock in steps of 100 ms; the monitor then gets the state
  /// (the throttling of the snapshots is left out).
  Future<void> run(SessionController c, FakeSessionClock clock, double seconds, {bool Function()? until}) async {
    final steps = (seconds * 10).round();
    for (var i = 0; i < steps; i++) {
      clock.advance(const Duration(milliseconds: 100));
      c.tick();
      if (until != null && until()) break;
    }
    // Let the async work of the events (resting HR, files) run.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final link = c.monitor as LoopbackMonitor;
    link.session.setSnapshot(c.snapshot());
  }

  /// Waits for the monitor to be told something (finish and cancel answer
  /// at once and work on in the background).
  Future<void> waitFor(bool Function() done) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(done(), isTrue, reason: 'timed out');
  }

  test('the monitor follows a session and its buttons drive it', () async {
    final imported = <List<Map<String, dynamic>>>[];
    final t = setup(imported: imported);
    final s = t.s;
    await t.c.reannounce();
    expect(s.isIdle, isTrue);
    expect(s.participants, '001');
    expect(s.visit, 'Día 0');
    expect(s.operator, 'JHM');
    expect(s.activityCount, 9);
    expect(s.nameOf(1), 'Tumbado en reposo');
    expect(nextAction(s).enabled, isFalse);

    // EMPEZAR SESIÓN (without camera).
    expect((await t.send('start', {'video': false}))['ok'], isTrue);
    await run(t.c, t.clock, 0);
    expect(s.isRunning, isTrue);
    expect(s.sessionDir, endsWith('R4H_001${Platform.pathSeparator}D0'));
    expect(s.video, isFalse);
    expect(s.phase, 'static_prep');
    expect(nextAction(s).label, 'EMPEZAR YA');

    // Pause and resume from the console (F5).
    expect((await t.send('toggle'))['ok'], isTrue);
    await run(t.c, t.clock, 0.1);
    expect(s.isPaused, isTrue);
    expect(nextAction(s).enabled, isFalse);
    expect((await t.send('toggle'))['ok'], isTrue);
    await run(t.c, t.clock, 0.1);
    expect(s.isRunning, isTrue);

    // Into the rest lying down: a still activity.
    await run(t.c, t.clock, 60, until: () => t.c.engine.phase == SessionPhase.main);
    expect(s.isMain, isTrue);
    expect(nextAction(s).label, 'TERMINAR ANTES');
    expect(s.plannedSeconds, 300);

    // Its end: resting HR from the monitor, the effort is asked.
    await run(t.c, t.clock, 400, until: () => t.c.engine.phase == SessionPhase.wait);
    await run(t.c, t.clock, 0.5);
    expect(s.isWait, isTrue);
    expect(s.pendingRpeLog, 0);
    expect(nextAction(s).label, 'EMPEZAR: De pie quieto');
    expect(t.link.methods, contains(WindowMessages.restingHrRequested));
    expect(s.logs.single.restingHr, 54);
    expect((await t.send('annotate', {'log_index': 0, 'rpe': 1}))['ok'], isTrue);
    await run(t.c, t.clock, 0.1);
    expect(s.pendingRpeLog, isNull);
    expect(s.logs.single.rpe, 1);

    // Skipping is refused once an activity is under way, with a reason.
    expect((await t.send('advance'))['ok'], isTrue);
    await run(t.c, t.clock, 40, until: () => t.c.engine.phase == SessionPhase.main);
    final skip = await t.send('skip');
    expect(skip['ok'], isFalse);
    expect(skip['message'], isNotEmpty);

    // TERMINAR ANTES: partial, then straight to the chair stand.
    expect((await t.send('advance'))['ok'], isTrue);
    await run(t.c, t.clock, 60, until: () => t.c.engine.phase == SessionPhase.wait);
    await run(t.c, t.clock, 0.2);
    expect(s.lastLogOf(2)!.isPartial, isTrue);
    await t.send('annotate', {'log_index': s.pendingRpeLog, 'rpe': 1});
    expect((await t.send('goto', {'index': 8}))['ok'], isTrue);
    await run(t.c, t.clock, 0.2);
    expect(s.nextIndex ?? s.activityIndex, 8);

    // A note of an incident on the partial activity.
    final partialLog = s.lastLogOf(2)!.logIndex;
    expect((await t.send('annotate', {'log_index': partialLog, 'incident': 'Se movió'}))['ok'], isTrue);
    await run(t.c, t.clock, 0.2);
    expect(s.lastLogOf(2)!.incident, 'Se movió');

    // FINALIZAR Y GUARDAR with notes: the missing ones go as not done.
    expect((await t.send('finish', {'notes': 'Prueba piloto'}))['ok'], isTrue);
    await waitFor(() => s.summary != null);
    expect(s.summary!['not_done'], greaterThan(0));
    expect(s.summary!['redcap_error'], isNull);
    expect(imported, isNotEmpty);
    s.setSnapshot(t.c.snapshot());
    expect(s.isClosing, isTrue);
    expect(nextAction(s).enabled, isFalse);

    // Orders after the end are refused, not crashed.
    expect((await t.send('advance'))['ok'], isFalse);

    final dir = Directory(s.summary!['directory'] as String);
    final names = dir.listSync().map((e) => e.path.split(Platform.pathSeparator).last).toSet();
    expect(names, containsAll(['session_manifest.json', 'activity_markers.csv', 'session_events.csv']));
    t.c.dispose();
  });

  test('no Polar for the resting heart rate: the session goes on with a notice', () async {
    final t = setup();
    t.link.restingHr = null;
    await t.send('start', {'video': false});
    await run(t.c, t.clock, 400, until: () => t.c.engine.phase == SessionPhase.wait);
    await run(t.c, t.clock, 0.5);
    expect(t.s.isWait, isTrue);
    expect(t.s.logs.single.restingHr, isNull);
    expect(t.s.notice, contains('FC de reposo'));
    // The evaluator types it by hand; nonsense is refused.
    expect((await t.send('annotate', {'log_index': 0, 'resting_hr': 300}))['ok'], isFalse);
    expect((await t.send('annotate', {'log_index': 0, 'resting_hr': '58'}))['ok'], isTrue);
    await run(t.c, t.clock, 0.2);
    expect(t.s.logs.single.restingHr, 58);
    await t.c.cancel(reason: 'fin de la prueba');
    t.c.dispose();
  });

  test('cancel from the monitor keeps the folder apart and clears the visit', () async {
    final t = setup();
    await t.send('start', {'video': false});
    await run(t.c, t.clock, 20);
    expect((await t.send('cancel', {'reason': 'El participante se encuentra mal'}))['ok'], isTrue);
    await waitFor(() => t.s.cancelled);
    expect(t.s.cancelledDirectory, contains('_cancelada_'));
    expect(Directory(t.s.cancelledDirectory!).existsSync(), isTrue);
    expect(await UnfinishedSession.scan(root.path), isEmpty);

    // The same visit can be measured again at once.
    final again = setup();
    expect((await again.send('start', {'video': false}))['ok'], isTrue);
    expect(again.s.sessionDir, endsWith('R4H_001${Platform.pathSeparator}D0'));
    await again.c.cancel();
    t.c.dispose();
    again.c.dispose();
  });

  test('closing the app mid-session saves it; reopening resumes it paused where it was', () async {
    final t = setup();
    await t.send('start', {'video': true});
    await run(t.c, t.clock, 60, until: () => t.c.engine.phase == SessionPhase.main);
    await run(t.c, t.clock, 30);
    final dir = t.c.store!.path;
    await t.c.suspend();
    expect(t.s.isIdle, isTrue, reason: 'the monitor forgets the session');
    t.c.dispose();

    final found = await UnfinishedSession.scan(root.path);
    expect(found, hasLength(1));
    expect(found.single.directory.path, dir);

    final s = MonitorSession();
    final link = LoopbackMonitor(s);
    final clock = FakeSessionClock();
    final c = SessionController.resume(found.single, clock: clock, monitor: link, redcapConfigured: false);
    await c.reannounce();
    s.setSnapshot(c.snapshot());
    expect(s.sessionDir, dir);
    expect(s.video, isTrue, reason: 'the camera records again after the restart');
    expect(s.isPaused, isTrue);
    expect(s.activityIndex, 1);
    expect(s.resumed, isTrue);
    expect(nextAction(s).enabled, isFalse);
    // REANUDAR (F5).
    expect((await c.command('toggle')).ok, isTrue);
    await run(c, clock, 0.2);
    expect(s.isRunning, isTrue);
    await c.cancel();
    c.dispose();
  });

  test('every order with wrong arguments is refused, never thrown', () async {
    final t = setup();
    final bad = <(String, Map<String, dynamic>)>[
      ('advance', {}),
      ('goto', {'index': 99}),
      ('goto', {}),
      ('annotate', {'log_index': 7, 'rpe': 3}),
      ('annotate', {}),
      ('rpe_before', {'index': 'x'}),
      ('annotate', {'log_index': 'cero', 'rpe': 'tres'}),
      ('voice', {'enabled': 'sí'}),
      ('settings', {'lap_mode': 'no'}),
      ('settings', {'prep_seconds': -5}),
      ('nonsense', {}),
      ('finish', {}),
    ];
    for (final (command, args) in bad) {
      final reply = await t.send(command, args);
      expect(reply['ok'], isA<bool>(), reason: command);
    }
    expect((await t.send('start', {'video': false}))['ok'], isTrue);
    expect((await t.send('start', {'video': false}))['ok'], isFalse);
    for (final (command, args) in bad.where((b) => b.$1 != 'finish')) {
      final reply = await t.send(command, args);
      expect(reply['ok'], isA<bool>(), reason: command);
    }
    await t.c.cancel();
    t.c.dispose();
  });
}
