import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lab_protocol_timer/config/default_protocol_configuration.dart';
import 'package:lab_protocol_timer/models/activity_battery.dart';
import 'package:lab_protocol_timer/models/protocol_configuration.dart';
import 'package:lab_protocol_timer/models/session_manifest.dart';
import 'package:lab_protocol_timer/services/lab_redcap_service.dart';
import 'package:lab_protocol_timer/services/protocol_library.dart';
import 'package:lab_protocol_timer/session/session_clock.dart';
import 'package:lab_protocol_timer/session/session_controller.dart';
import 'package:lab_protocol_timer/session/session_store.dart';
import 'package:lab_protocol_timer/windows/monitor_session.dart';
import 'package:lab_protocol_timer/windows/window_messages.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _day0 = 'da_0__visita_inici_arm_1';
final _sep = Platform.pathSeparator;

/// A Research Monitor that writes one Polar file into the folder of each
/// participant when the session stops, as the real one does.
class _FolderMonitor implements MonitorLink {
  Map<String, dynamic>? started;
  final List<String> methods = [];

  @override
  Future<dynamic> send(String method, [dynamic arguments]) async {
    methods.add(method);
    final args = arguments is Map ? Map<String, dynamic>.from(arguments) : const <String, dynamic>{};
    switch (method) {
      case WindowMessages.sessionStarted:
        started = args;
        return true;
      case WindowMessages.sessionStopping:
        final dirs = Map<String, dynamic>.from(started?['participant_dirs'] as Map? ?? const {});
        final files = <String>[];
        for (final dir in dirs.values) {
          final path = '$dir${_sep}polar_hr_polar_h10_x.csv';
          await File(path).writeAsString('timestamp_iso\n');
          files.add(path);
        }
        return {'video_files': <String>[], 'files': files, 'cameras': 0};
    }
    return null;
  }
}

void main() {
  late ActivityBattery battery;
  late ParticipantEntry p1;
  late ParticipantEntry p2;

  List<SessionSensor> worn(String prefix) => [
        for (final s in battery.sensors)
          if (s.connection != 'video') s.copyWith(serial: '$prefix-${s.sensorId}'),
      ];

  setUpAll(() {
    battery = ActivityBattery.parse(File('assets/protocols/run4health_base.json').readAsStringSync());
    p1 = ParticipantEntry(participantId: '001', redcapEventName: _day0, sensors: worn('A'));
    p2 = ParticipantEntry(participantId: '002', redcapEventName: _day0, sensors: worn('B'));
  });

  group('devices of the Research Monitor', () {
    test('one participant keeps the sensor IDs and gets their serials', () {
      final c = protocolConfigurationFor(battery, [p1]);
      expect(c.devices.map((d) => d.deviceId), [
        ...p1.sensors.map((s) => s.sensorId),
        'cam_room',
      ]);
      expect(c.deviceById('polar_h10')!.participantId, '001');
      expect(c.deviceById('polar_h10')!.sensorId, 'polar_h10');
      expect(c.deviceById('polar_h10')!.serial, 'A-polar_h10');
      expect(c.deviceById('cam_room')!.participantId, isNull);
      expect(c.participantIds, ['001']);
    });

    test('two participants wear the layout each; the cameras are shared', () {
      final c = protocolConfigurationFor(battery, [p1, p2]);
      expect(c.deviceById('polar_h10@001')!.serial, 'A-polar_h10');
      expect(c.deviceById('polar_h10@002')!.serial, 'B-polar_h10');
      expect(c.deviceById('polar_h10@002')!.sensorId, 'polar_h10');
      expect(c.deviceById('polar_h10@002')!.label, 'Polar H10 · Pecho · 002');
      expect(c.participantIds, ['001', '002']);
      expect(c.devices.where((d) => d.isCamera).map((d) => d.deviceId), ['cam_room']);
      expect(c.devicesOf('002').map((d) => d.deviceId), [
        for (final s in p2.sensors) '${s.sensorId}@002',
        'cam_room',
      ]);

      final copy = ProtocolConfiguration.fromJson(
        jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>,
      );
      expect(jsonEncode(copy.toJson()), jsonEncode(c.toJson()));
      expect(copy.deviceById('verity_arm@002')!.participantId, '002');
      expect(copy.deviceById('verity_arm@002')!.sensorId, 'verity_arm');
    });

    test('a participant without sensors of their own wears the layout', () {
      final plain = ParticipantEntry(participantId: '003', redcapEventName: _day0);
      final c = protocolConfigurationFor(battery, [p1, plain]);
      expect(c.deviceById('ax3_wnd@003')!.serial, isNull);
      expect(c.deviceById('ax3_wnd@003')!.placement, 'wrist');
    });

    test('the monitor sends each device to its participant folder', () {
      final s = MonitorSession();
      s.setStarted({
        'session_dir': '/d/R4H_001/D0',
        'participant_dirs': {'001': '/d/R4H_001/D0', '002': '/d/R4H_002/D0'},
        'file_stamp': 'x',
      });
      expect(s.directoryOf('002'), '/d/R4H_002/D0');
      expect(s.directoryOf('001'), '/d/R4H_001/D0');
      expect(s.directoryOf(null), '/d/R4H_001/D0');
      expect(s.directories, ['/d/R4H_001/D0', '/d/R4H_002/D0']);
      s.clear();
      expect(s.directories, isEmpty);
    });
  });

  group('manifest of a participant folder', () {
    test('lists their sensors by sensor ID, their files and the shared cameras', () {
      final c = protocolConfigurationFor(battery, [p1, p2]);
      final start = DateTime.utc(2026, 11, 2, 9);
      final m = buildSessionManifest(
        sessionId: 's',
        sessionStartTime: start,
        sessionEndTime: start.add(const Duration(hours: 1)),
        participants: [p1, p2],
        activities: const [],
        syncWindows: const [],
        generatedFiles: const [
          '/d/R4H_002/D0/polar_hr_polar_h10_x.csv',
          '/d/R4H_002/D0/video_cam_room_x.mp4',
        ],
        protocolConfiguration: c,
        battery: battery,
        participantId: '002',
      );
      final sensors = m['sensors'] as Map<String, dynamic>;
      expect(sensors.keys, containsAll(['polar_h10', 'verity_arm', 'ax3_wnd', 'matrix_wnd']));
      expect(sensors.keys.any((k) => k.contains('@')), isFalse);
      expect(sensors['polar_h10']['serial'], 'B-polar_h10');
      expect(sensors['polar_h10']['connection'], 'live');
      expect(sensors['polar_h10']['files'], ['polar_hr_polar_h10_x.csv']);
      expect(sensors['verity_arm']['files'], isEmpty);
      expect(m['participants'], [
        {'participant_id': '002', 'redcap_event_name': _day0},
      ]);
      expect(m['session_participants'], ['001', '002']);
      final video = m['video'] as Map<String, dynamic>;
      expect(video['files'], ['video_cam_room_x.mp4']);
      expect((video['cameras'] as List).single['camera_id'], 'cam_room');
    });
  });

  group('folders', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('lpt_pf_');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('one per participant, chosen or automatic, never shared', () async {
      final chosen = '${tmp.path}${_sep}elegida';
      final dirs = await SessionStore.chooseFolders(
        root: tmp.path,
        study: 'RUN4HEALTH',
        participants: [p1, p2.copyWith(folder: chosen)],
      );
      expect(dirs['001']!.path, '${tmp.path}${_sep}R4H_001${_sep}D0');
      expect(dirs['002']!.path, chosen);
      expect(SessionStore.defaultFolder(tmp.path, 'RUN4HEALTH', p2), '${tmp.path}${_sep}R4H_002${_sep}D0');

      // A chosen folder that already holds a session is not reused.
      await Directory(chosen).create();
      await File('$chosen${_sep}session_state.json').writeAsString('{}');
      final again = await SessionStore.chooseFolders(
        root: tmp.path,
        study: 'RUN4HEALTH',
        participants: [p2.copyWith(folder: chosen)],
        now: DateTime(2026, 11, 2, 9, 5),
      );
      expect(again['002']!.path, '${chosen}_20261102-0905');

      // Two participants pointed at the same folder get one each.
      final shared = '${tmp.path}${_sep}compartida';
      final split = await SessionStore.chooseFolders(
        root: tmp.path,
        study: null,
        participants: [p1.copyWith(folder: shared), p2.copyWith(folder: shared)],
      );
      expect(split['001']!.path, shared);
      expect(split['002']!.path, '${shared}_002');
    });

    test('the store writes what the session shares to every folder', () async {
      final a = Directory('${tmp.path}${_sep}a');
      final b = Directory('${tmp.path}${_sep}b');
      final store = await SessionStore.create(a, participantDirectories: {'001': a, '002': b});
      expect(store.directories.map((d) => d.path), [a.path, b.path]);
      expect(store.directoryOf('002').path, b.path);
      expect(store.directoryOf('zzz').path, a.path);
      store.writeJson('state.json', {'x': 1});
      store.writeJsonTo(b, 'own.json', {'y': 2});
      store.logEvent('session_started');
      await store.close();

      expect(jsonDecode(File('${a.path}${_sep}state.json').readAsStringSync()), {'x': 1});
      expect(jsonDecode(File('${b.path}${_sep}state.json').readAsStringSync()), {'x': 1});
      expect(File('${a.path}${_sep}own.json').existsSync(), isFalse);
      expect(File('${b.path}${_sep}own.json').existsSync(), isTrue);
      for (final dir in [a, b]) {
        final lines = File('${dir.path}$_sep${SessionStore.eventsFile}').readAsLinesSync();
        expect(lines, hasLength(2), reason: dir.path);
        expect(lines[1], contains(',session_started,'));
      }
    });
  });

  group('a session with two participants', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('lpt_two_');
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    SessionController controller(FakeSessionClock clock, MonitorLink monitor) => SessionController(
          participants: [p1, p2],
          battery: battery,
          dataRoot: root.path,
          operators: ['JHM', 'MDF'],
          clock: clock,
          monitor: monitor,
          redcapConfigured: false,
        );

    void run(SessionController c, FakeSessionClock clock, double seconds) {
      for (var i = 0; i < (seconds * 10).round(); i++) {
        clock.advance(const Duration(milliseconds: 100));
        c.tick();
      }
    }

    test('gets a folder each, with their own manifest, and resumes as one session', () async {
      final clock = FakeSessionClock();
      final monitor = _FolderMonitor();
      final c = controller(clock, monitor);
      expect((await c.command('start', {'video': false})).ok, isTrue);

      final main = c.store!.path;
      final second = c.store!.directoryOf('002').path;
      expect(main, endsWith('R4H_001${_sep}D0'));
      expect(second, endsWith('R4H_002${_sep}D0'));
      expect(monitor.started!['session_dir'], main);
      expect(monitor.started!['participant_dirs'], {'001': main, '002': second});
      expect(c.protocolConfiguration.deviceById('polar_h10@002'), isNotNull);

      run(c, clock, 40);
      await c.store!.drain();
      await c.store!.flushEvents();

      // Both folders hold the state, with the folder and sensors of each one.
      for (final dir in [main, second]) {
        final state = jsonDecode(File('$dir$_sep${SessionStore.stateFile}').readAsStringSync());
        final participants = state['participants'] as List;
        expect(participants[0]['folder'], main, reason: dir);
        expect(participants[1]['folder'], second, reason: dir);
        expect((participants[1]['sensors'] as List).first['serial'], startsWith('B-'));
        expect(state['data_root'], root.path);
        expect(state['operators'], ['JHM', 'MDF'], reason: dir);
        expect(state['operator'], 'JHM, MDF', reason: dir);
        expect(File('$dir$_sep${SessionStore.eventsFile}').existsSync(), isTrue);
      }

      // Found from any of its folders, resumed from the main one, listed once.
      final saved = await UnfinishedSession.find(second);
      expect(saved!.directory.path, main);
      expect(saved.participantDirectories['002']!.path, second);
      expect(saved.participants.map((p) => p.participantId), ['001', '002']);
      expect((await UnfinishedSession.scan(root.path)).map((s) => s.directory.path), [main]);
      final resumed = SessionController.resume(saved, clock: FakeSessionClock(), monitor: _FolderMonitor(), redcapConfigured: false);
      expect(resumed.store!.directoryOf('002').path, second);
      expect(resumed.dataRoot, root.path);
      expect(resumed.operators, ['JHM', 'MDF']);
      await resumed.store!.close();
      resumed.dispose();

      await c.finish();
      final m1 = jsonDecode(File('$main$_sep${SessionStore.manifestFile}').readAsStringSync()) as Map;
      final m2 = jsonDecode(File('$second$_sep${SessionStore.manifestFile}').readAsStringSync()) as Map;
      expect((m1['participants'] as List).single['participant_id'], '001');
      expect((m2['participants'] as List).single['participant_id'], '002');
      for (final m in [m1, m2]) {
        expect(m['operators'], ['JHM', 'MDF']);
        expect(m['operator'], 'JHM, MDF');
      }
      expect(m2['session_participants'], ['001', '002']);
      expect(m1['sensors']['polar_h10']['serial'], 'A-polar_h10');
      expect(m2['sensors']['polar_h10']['serial'], 'B-polar_h10');
      expect(m1['sensors']['polar_h10']['files'], ['polar_hr_polar_h10_x.csv']);
      expect(m2['sensors']['polar_h10']['files'], ['polar_hr_polar_h10_x.csv']);
      expect((m2['files'] as List).every((f) => (f as String).startsWith(second)), isTrue);
      expect((m1['files'] as List).every((f) => (f as String).startsWith(main)), isTrue);
      expect(m2['status'], 'complete');
      for (final dir in [main, second]) {
        expect(File('$dir${_sep}activity_markers.csv').existsSync(), isTrue, reason: dir);
        expect(File('$dir${_sep}sync_windows.csv').existsSync(), isTrue, reason: dir);
      }
      // The records for REDCap are kept once, in the main folder.
      expect(File('$main${_sep}redcap_records.json').existsSync(), isTrue);
      expect(File('$second${_sep}redcap_records.json').existsSync(), isFalse);
      expect(c.summary!.directories, [main, second]);
      expect(await UnfinishedSession.scan(root.path), isEmpty);
      c.dispose();
    });

    test('cancelling marks every folder as cancelled', () async {
      final clock = FakeSessionClock();
      final c = controller(clock, _FolderMonitor());
      await c.command('start', {'video': false});
      final main = c.store!.path;
      final second = c.store!.directoryOf('002').path;
      run(c, clock, 5);
      await c.cancel(reason: 'Prueba');
      expect(Directory(main).existsSync(), isFalse);
      expect(Directory(second).existsSync(), isFalse);
      final renamed = root
          .listSync(recursive: true)
          .whereType<Directory>()
          .where((d) => d.path.contains('D0_cancelada_'))
          .map((d) => d.path)
          .toList()
        ..sort();
      expect(renamed, hasLength(2));
      expect(renamed.first, contains('R4H_001'));
      expect(renamed.last, contains('R4H_002'));
      expect(await UnfinishedSession.scan(root.path), isEmpty);
      c.dispose();
    });
  });

  group('remembered setups', () {
    test('keep the sensors of each participant, with their own serials', () async {
      SharedPreferences.setMockInitialValues({});
      await ProtocolLibrary.remember([p1, p2], battery);
      final remembered = await ProtocolLibrary.loadRemembered();
      expect(remembered.keys, containsAll(['001', '002']));
      final second = remembered['002']!.battery;
      expect(second.protocolId, battery.protocolId);
      expect(second.sensors.firstWhere((s) => s.sensorId == 'polar_h10').serial, 'B-polar_h10');
      expect(second.sensors.where((s) => s.connection == 'video').map((s) => s.sensorId), ['cam_room']);
      expect(remembered['001']!.battery.sensors.firstWhere((s) => s.sensorId == 'ax3_wnd').serial, 'A-ax3_wnd');
      expect(remembered['002']!.eventName, _day0);
    });
  });
}
