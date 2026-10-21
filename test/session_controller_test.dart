import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lab_protocol_timer/models/activity_battery.dart';
import 'package:lab_protocol_timer/services/lab_redcap_service.dart';
import 'package:lab_protocol_timer/services/redcap_resend.dart';
import 'package:lab_protocol_timer/session/protocol_engine.dart';
import 'package:lab_protocol_timer/session/session_clock.dart';
import 'package:lab_protocol_timer/session/session_controller.dart';
import 'package:lab_protocol_timer/session/session_store.dart';
import 'package:lab_protocol_timer/windows/window_messages.dart';

/// Research Monitor that answers like the real one.
class FakeMonitor implements MonitorLink {
  final List<(String, dynamic)> sent = [];
  int restingHr = 52;
  bool videoMoved = false;

  @override
  Future<dynamic> send(String method, [dynamic arguments]) async {
    sent.add((method, arguments));
    switch (method) {
      case WindowMessages.sessionStopping:
        final dir = (arguments as Map)['session_dir'] as String;
        await File('$dir/video_session_001_cam_room_x.mp4').writeAsString('mp4');
        videoMoved = true;
        return {
          'video_files': ['video_session_001_cam_room_x.mp4'],
          'files': ['polar_hr_polar_h10_x.csv'],
          'cameras': 1,
        };
      case WindowMessages.restingHrRequested:
        return {'bpm': restingHr, 'beats': 110, 'source': 'polar_h10'};
    }
    return null;
  }

  Iterable<String> get methods => sent.map((m) => m.$1);
}

void main() {
  late Directory root;
  late ActivityBattery battery;
  final participants = [
    ParticipantEntry(participantId: '001', redcapEventName: 'da_0__visita_inici_arm_1'),
  ];

  setUpAll(() {
    battery = ActivityBattery.parse(
      File('assets/protocols/run4health_base.json').readAsStringSync(),
    );
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lpt_session_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  /// Runs the clock in steps of 100 ms for [seconds], doing what an
  /// evaluator would: give the effort, start the next activity.
  Future<void> run(
    SessionController c,
    FakeSessionClock clock,
    double seconds, {
    bool evaluator = true,
    bool Function()? until,
  }) async {
    final steps = (seconds * 10).round();
    for (var i = 0; i < steps; i++) {
      clock.advance(const Duration(milliseconds: 100));
      c.tick();
      if (until != null && until()) return;
      if (!evaluator || !c.engine.isRunning) continue;
      final pending = c.pendingRpeLog;
      if (pending != null) {
        await c.command('annotate', {'log_index': pending, 'rpe': 3});
        continue;
      }
      final before = c.rpeBeforeFor;
      if (before != null) {
        await c.command('rpe_before', {'index': before, 'value': 2});
        continue;
      }
      if (c.engine.phase == SessionPhase.wait && !c.engine.protocolComplete) {
        await c.command('advance');
      }
    }
  }

  SessionController controller(
    FakeSessionClock clock,
    FakeMonitor monitor,
    List<List<Map<String, dynamic>>> imported, {
    void Function(String?)? onActive,
  }) =>
      SessionController(
        participants: participants,
        battery: battery,
        dataRoot: root.path,
        operator: 'JHM',
        clock: clock,
        monitor: monitor,
        redcapConfigured: true,
        importRecords: (records) async {
          imported.add(records);
          return null;
        },
        onActiveSessionChanged: onActive,
      );

  test('a whole RUN4HEALTH visit leaves a folder that SAVES and REDCap use', () async {
    final clock = FakeSessionClock();
    final monitor = FakeMonitor();
    final imported = <List<Map<String, dynamic>>>[];
    final active = <String?>[];
    final c = controller(clock, monitor, imported, onActive: active.add);

    expect((await c.command('advance')).ok, isFalse);
    expect((await c.command('start', {'video': true})).ok, isTrue);
    final dir = c.store!.path;
    expect(dir, endsWith('R4H_001${Platform.pathSeparator}D0'));
    expect(active, [dir]);
    expect(monitor.methods, contains(WindowMessages.sessionStarted));

    // A skip in the middle of an activity is refused with a reason.
    await run(c, clock, 31);
    expect(c.engine.phase, SessionPhase.main);
    final refused = await c.command('skip');
    expect(refused.ok, isFalse);
    expect(refused.message, contains('antes de empezar'));

    await run(c, clock, 3600, until: () => c.engine.protocolComplete);
    expect(c.engine.protocolComplete, isTrue);
    // The effort of the last activity, given in the final wait.
    expect(c.pendingRpeLog, isNotNull);
    await c.command('annotate', {'log_index': c.pendingRpeLog, 'rpe': 3});
    expect(c.pendingRpeLog, isNull);

    // Values of the fitness tests typed by the evaluator.
    final chair = c.engine.logs.indexWhere((l) => l.activityIndex == 8);
    expect(chair, isNot(-1));
    expect(c.engine.logs.where((l) => l.activityIndex == 10), isEmpty,
        reason: 'the protocol has 9 activities');
    await c.command('annotate', {
      'log_index': chair,
      'fields': {'chairstand_repeticiones': '17'},
      'incident': 'Sin incidencias',
    });

    final summary = await c.finish();
    expect(summary, isNotNull);
    expect(summary!.done, 9);
    expect(summary.partial, 0);
    expect(summary.redcapError, isNull);
    expect(summary.videoSaved, isTrue);
    expect(active.last, isNull);
    expect(monitor.methods, containsAllInOrder([
      WindowMessages.sessionStarted,
      WindowMessages.restingHrRequested,
      WindowMessages.sessionStopping,
      WindowMessages.sessionSaved,
    ]));

    // Every static phase got a cue: 2 per activity.
    expect(c.engine.syncWindows.length, 18);
    expect(c.engine.syncWindows.first.syncKind, 'clap');

    final state = jsonDecode(File('$dir/${SessionStore.stateFile}').readAsStringSync());
    expect(state['status'], 'finished');
    final manifest = jsonDecode(File('$dir/${SessionStore.manifestFile}').readAsStringSync());
    expect(manifest['status'], 'complete');
    expect(manifest['schema_version'], '1.1');
    expect((manifest['activities'] as List).length, 9);
    expect((manifest['sync_windows'] as List).length, 18);
    expect(manifest['video']['files'], ['video_session_001_cam_room_x.mp4']);
    expect(manifest['sensors'], contains('polar_h10'));
    expect(File('$dir/activity_markers.csv').readAsLinesSync().length, 10);
    expect(File('$dir/sync_windows.csv').readAsLinesSync().length, 19);
    final events = File('$dir/${SessionStore.eventsFile}').readAsLinesSync();
    expect(events.first, SessionStore.eventsHeader);
    expect(events.where((e) => e.contains(',sync_go,')).length, 18);
    expect(events.any((e) => e.contains(',resting_hr,')), isTrue);

    // REDCap: summary, session, 9 lab_activity, fitness fields.
    expect(imported.length, 4);
    final summaryRecord = imported[0].single;
    expect(summaryRecord['lab_total_stations'], '9');
    expect(summaryRecord['act_9_end_time'], isNotNull);
    final session = imported[1].single;
    expect(session['ws_hr_rest'], '52');
    expect(session['ws_hr_rest_method'], '1');
    expect(session['ws_operator'], 'JHM');
    expect(session['ws_video_cameras'], '1');
    expect(session.containsKey('ws_bmi'), isFalse);
    final instances = imported[2];
    expect(instances.every((r) => r['redcap_repeat_instrument'] == 'lab_activity'), isTrue);
    expect(instances.length, 9);
    expect(instances.every((r) => r['la_completed'] == '1'), isTrue);
    expect(instances.every((r) => r['la_rpe'] == '3'), isTrue);
    expect(instances.any((r) => r.containsKey('la_duration_s')), isFalse);
    final fitness = imported[3].single;
    expect(fitness['chairstand_realiza'], '1');
    expect(fitness['chairstand_repeticiones'], '17');
    expect(fitness['incidencia_chairstand'], '0', reason: 'default of the choice');
    expect(fitness['rpe_chairstand_pre'], '2');
    expect(fitness['rpe_chairstand_post'], '3');
    expect(fitness['mwt_realiza'], '1');
    expect(fitness['rpe_6mwt_pre'], '2');
    expect(fitness.containsKey('distanciatotal_6mwt'), isFalse);
  });

  test('after a crash the session resumes in the same folder and keeps the cut attempt',
      () async {
    final clock = FakeSessionClock();
    final monitor = FakeMonitor();
    final imported = <List<Map<String, dynamic>>>[];
    final c = controller(clock, monitor, imported);
    await c.command('start', {'video': true});
    final dir = c.store!.path;

    // Into the main phase of activity 3.
    await run(c, clock, 3600,
        until: () =>
            c.engine.activityIndex == 3 &&
            c.engine.phase == SessionPhase.main &&
            c.engine.phaseElapsed > const Duration(seconds: 40));
    c.tick();
    await run(c, clock, 4, evaluator: false); // the last checkpoint
    await c.store!.drain();
    await c.store!.flushEvents();
    // The app dies here: nothing else is written.

    final saved = await UnfinishedSession.find(dir);
    expect(saved, isNotNull);
    expect(saved!.participants.single.participantId, '001');
    expect(saved.battery!.protocolId, 'run4health_base');

    final clock2 = FakeSessionClock(DateTime.utc(2026, 10, 21, 10));
    final monitor2 = FakeMonitor();
    final r = SessionController.resume(
      saved,
      clock: clock2,
      monitor: monitor2,
      redcapConfigured: true,
      importRecords: (records) async {
        imported.add(records);
        return null;
      },
    );
    expect(r.store!.path, dir);
    expect(r.engine.isPaused, isTrue);
    expect(r.engine.activityIndex, 3);
    expect(r.engine.phase, SessionPhase.prep);
    expect(r.engine.attempt, 2);
    final cut = r.engine.logs.last;
    expect(cut.activityIndex, 3);
    expect(cut.completion, ActivityCompletion.partial);
    expect(cut.endReason, 'interrupted');

    await r.reannounce();
    expect(monitor2.sent.first.$1, WindowMessages.sessionStarted);
    expect((monitor2.sent.first.$2 as Map)['resumed'], isTrue);

    expect((await r.command('start', {'video': true})).ok, isTrue);
    expect(r.engine.isRunning, isTrue);
    await run(r, clock2, 3600, until: () => r.engine.protocolComplete);
    final summary = await r.finish();
    expect(summary!.done, 9);

    final markers = File('$dir/activity_markers.csv').readAsLinesSync();
    expect(markers.length, 11, reason: '9 activities and the cut attempt');
    final labActivity =
        imported.expand((batch) => batch).where((r) => r['redcap_repeat_instrument'] == 'lab_activity').toList();
    expect(labActivity.length, 10);
    final first3 = labActivity.firstWhere((r) => r['la_name'] == battery.activityAt(3)!.name);
    expect(first3['la_completed'], '2');
    expect(first3['la_incident'], contains('se cerró'));
    final events = File('$dir/${SessionStore.eventsFile}').readAsLinesSync();
    expect(events.where((e) => e == SessionStore.eventsHeader).length, 1);
    expect(events.any((e) => e.contains('session_resumed_after_restart')), isTrue);
  });

  test('a cancelled session keeps its data, frees the visit folder and sends nothing',
      () async {
    final clock = FakeSessionClock();
    final monitor = FakeMonitor();
    final imported = <List<Map<String, dynamic>>>[];
    final c = controller(clock, monitor, imported);
    await c.command('start', {'video': false});
    final dir = c.store!.path;
    await run(c, clock, 50);
    await c.cancel(reason: 'Prueba');
    expect(imported, isEmpty);
    expect(Directory(dir).existsSync(), isFalse);
    final renamed = root
        .listSync(recursive: true)
        .whereType<Directory>()
        .where((d) => d.path.contains('D0_cancelada_'))
        .toList();
    expect(renamed, hasLength(1));
    final state = jsonDecode(
      File('${renamed.single.path}/${SessionStore.stateFile}').readAsStringSync(),
    );
    expect(state['status'], 'cancelled');
    expect(await UnfinishedSession.find(renamed.single.path), isNull);
    expect(monitor.methods, contains(WindowMessages.sessionCancelled));

    // The visit can be done again in the plain folder.
    final again = controller(FakeSessionClock(), FakeMonitor(), imported);
    await again.command('start', {'video': false});
    expect(again.store!.path, dir);
    // Its first files are still being written; the folder goes after them.
    await again.store!.close();
    again.dispose();
    c.dispose();
  });

  test('a REDCap failure keeps the records on disk and can be retried', () async {
    final clock = FakeSessionClock();
    final monitor = FakeMonitor();
    var fail = true;
    final c = SessionController(
      participants: participants,
      battery: battery,
      dataRoot: root.path,
      clock: clock,
      monitor: monitor,
      redcapConfigured: true,
      importRecords: (records) async => fail ? 'sin red' : null,
    );
    await c.command('start', {'video': false});
    await run(c, clock, 400);
    final summary = await c.finish();
    expect(summary!.redcapError, contains('sin red'));
    final dir = c.store!.path;
    final records = jsonDecode(File('$dir/redcap_records.json').readAsStringSync()) as List;
    expect(records, isNotEmpty);

    fail = false;
    await c.retryRedcap();
    expect(c.summary!.redcapError, isNull);
    // Once REDCap has them, nothing is left pending in the folder.
    expect(File('$dir/redcap_records.json').existsSync(), isFalse);
    expect(Directory(dir).listSync().any((f) => f.path.contains('redcap_records_enviados_')), isTrue);
  });

  test('a session saved without REDCap is sent later from its folder', () async {
    final clock = FakeSessionClock();
    final c = SessionController(
      participants: participants,
      battery: battery,
      dataRoot: root.path,
      clock: clock,
      monitor: FakeMonitor(),
      redcapConfigured: true,
      importRecords: (records) async => 'sin red',
    );
    await c.command('start', {'video': false});
    await run(c, clock, 400);
    await c.finish();
    final dir = Directory(c.store!.path);
    c.dispose();

    // The app was closed; the session goes from the start screen.
    final sent = <List<Map<String, dynamic>>>[];
    final error = await SavedSessionRedcap.send(dir, importRecords: (batch) async {
      sent.add(batch);
      return null;
    });
    expect(error, isNull);
    final all = sent.expand((b) => b).toList();
    expect(all.any((r) => r.containsKey('ws_session_id')), isTrue);
    expect(all.any((r) => r.containsKey('lab_total_stations')), isTrue);
    expect(sent.last.every((r) => r['redcap_repeat_instrument'] == 'lab_activity'), isTrue);
    expect(File('${dir.path}/redcap_records.json').existsSync(), isFalse);
  });

  test('an instrument that is not repeating stops only the activities, and says which', () async {
    final clock = FakeSessionClock();
    final sent = <Map<String, dynamic>>[];
    final c = SessionController(
      participants: participants,
      battery: battery,
      dataRoot: root.path,
      clock: clock,
      monitor: FakeMonitor(),
      redcapConfigured: true,
      importRecords: (records) async {
        if (records.any((r) => r.containsKey('redcap_repeat_instrument'))) {
          return 'REDCap respondió 400: {"error":"lab_activity is not a repeating instrument in this event"}';
        }
        sent.addAll(records);
        return null;
      },
    );
    await c.command('start', {'video': false});
    await run(c, clock, 400);
    final summary = await c.finish();
    final error = summary!.redcapError!;
    expect(error, startsWith('Actividades (lab_activity): '));
    expect(error, contains('«lab_activity» tiene que ser un instrumento repetible en da_0__visita_inici_arm_1'));
    expect(error, contains('Reintentar REDCap'));
    expect(error, isNot(contains('wearable_session')));
    // The session and the summary went in all the same.
    expect(sent.any((r) => r.containsKey('ws_session_id')), isTrue);
    expect(sent.any((r) => r.containsKey('lab_total_stations')), isTrue);
    c.dispose();
  });

  test('voice, settings and notes reach the state file', () async {
    final clock = FakeSessionClock();
    final audio = SilentAudio();
    final c = SessionController(
      participants: participants,
      battery: battery,
      dataRoot: root.path,
      clock: clock,
      audio: audio,
      redcapConfigured: false,
    );
    await c.command('start', {'video': false});
    expect(audio.said.first, startsWith('Actividad 1 de 9: tumbado en reposo'));
    await c.command('voice', {'enabled': false});
    await c.command('settings', {'prep_seconds': 20, 'lap_mode': false});
    expect(c.engine.plannedPhaseSeconds, 20);
    await c.command('notes', {'notes': 'Cámara movida a los 10 min'});
    await c.store!.drain();
    final state = jsonDecode(File('${c.store!.path}/${SessionStore.stateFile}').readAsStringSync());
    expect(state['settings']['voice'], isFalse);
    expect(state['settings']['prep_seconds'], 20);
    expect(state['notes'], 'Cámara movida a los 10 min');
    final before = audio.said.length;
    await run(c, clock, 30, evaluator: false);
    expect(audio.said.length, before, reason: 'voice is off');
    expect(audio.played, contains(SessionSound.countdown));
    expect(audio.played, contains(SessionSound.go));
    c.dispose();
  });
}
