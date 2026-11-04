import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lab_protocol_timer/calibration/calibration_page.dart';
import 'package:lab_protocol_timer/calibration/calibration_program.dart';
import 'package:lab_protocol_timer/calibration/calibration_store.dart';
import 'package:lab_protocol_timer/calibration/dodecahedron.dart';
import 'package:lab_protocol_timer/models/session_sensor.dart';
import 'package:lab_protocol_timer/services/lab_redcap_service.dart';
import 'package:lab_protocol_timer/session/session_clock.dart';
import 'package:lab_protocol_timer/session/session_controller.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('lpt_calib_'));
  tearDown(() => root.deleteSync(recursive: true));

  test('the 12-face program: 10 s to get ready, knocks, 40 s per face, knocks', () {
    final p = CalibrationProgram();
    expect(p.totalSeconds, 10 + 10 + 12 * 40 + 10);
    expect(p.stepAt(0)!.kind, CalibrationStepKind.still);
    expect(p.stepAt(10)!.kind, CalibrationStepKind.knock);
    expect(p.stepAt(20)!.face, 1);
    expect(p.stepAt(20 + 11 * 40 + 1)!.face, 12);
    expect(p.stepAt(p.totalSeconds.toDouble()), isNull);
    expect(CalibrationProgram(faces: 6).faceSeconds, 60);
    // The instructions are for the technician, never for a participant.
    for (final s in p.steps) {
      expect(p.instruction(s).toLowerCase(), isNot(contains('de pie')));
    }
  });

  test('the sensor editor proposes rate and range from device and place', () {
    expect(proposedSettings('ax3', 'wrist'), (samplingRateHz: 100, rangeG: 8));
    expect(proposedSettings('ax3', 'shoe'), (samplingRateHz: 100, rangeG: 16));
    expect(proposedSettings('ax6', 'shoe'), (samplingRateHz: 100, rangeG: 16));
    expect(proposedSettings('matrix', 'wrist'), (samplingRateHz: 25, rangeG: 8));
    expect(proposedSettings('sens', 'thigh').samplingRateHz, 12.5);
    expect(sensorTypeByKey('sens').fixedSettings, isTrue);
    expect(proposedSettings('polar_h10', 'chest'), (samplingRateHz: null, rangeG: null));
  });

  test('the dodecahedron is numbered like the printed one', () {
    final d = Dodecahedron.instance;
    for (var f = 1; f <= 12; f++) {
      expect(d.faces[f - 1], hasLength(5), reason: 'face $f');
      final opposite = d.normals[13 - f - 1];
      expect(d.normals[f - 1].dot(opposite), closeTo(-1, 1e-9), reason: 'face $f');
      // Face f up turns its normal to the up direction of the drawing.
      final up = d.orientationFor(f).rotate(d.normals[f - 1]);
      expect(up.dot(Dodecahedron.upInView), closeTo(1, 1e-9), reason: 'face $f');
    }
  });

  Future<CalibrationRecord> writeCalibration(
    DateTime start,
    List<CalibrationDevice> devices, {
    bool complete = true,
  }) async {
    final w = await CalibrationWriter.create(root.path, start);
    await w.log('calibration_start', start);
    for (final d in devices) {
      await w.log('device', start, detail: d.code);
    }
    await w.log('face_start', start.add(const Duration(seconds: 130)), face: 1);
    if (complete) await w.log('calibration_end', start.add(const Duration(minutes: 10)));
    await w.close();
    return (await CalibrationRecord.read(w.file))!;
  }

  test('calibrations are found by device and serial', () async {
    final now = DateTime.now().toUtc();
    final old = await writeCalibration(
        now.subtract(const Duration(days: 2)), [const CalibrationDevice('ax6', 'A1')]);
    final batch1 = await writeCalibration(now.subtract(const Duration(hours: 2)), [
      const CalibrationDevice('ax6', 'A1'),
      const CalibrationDevice('ax3', 'X9'),
    ]);
    await writeCalibration(now.subtract(const Duration(hours: 1)),
        [const CalibrationDevice('ax3', 'X9')], complete: false);

    expect(old.devices.single.code, 'ax6:A1');
    final recent = await CalibrationStore.recentBefore(root.path, now);
    expect(recent.map((r) => r.fileName), [batch1.fileName]);
    expect(CalibrationStore.forDevice(recent, 'ax3', 'X9')!.fileName, batch1.fileName);
    expect(CalibrationStore.forDevice(recent, 'ax3', 'A1'), isNull, reason: 'other type');
    expect(CalibrationStore.forDevice(recent, 'ax6', null), isNull);

  });

  test('a session moves the calibration of each sensor to its participant', () async {
    final now = DateTime.now().toUtc();
    final batch = await writeCalibration(now.subtract(const Duration(hours: 1)), [
      const CalibrationDevice('ax6', 'A1'),
    ]);
    // The free-living set, calibrated apart before the participant came.
    final home = await writeCalibration(now.subtract(const Duration(minutes: 40)), [
      const CalibrationDevice('ax6', 'B2'),
    ]);
    final participants = [
      ParticipantEntry(
        participantId: '001',
        redcapEventName: 'da_0__visita_inici_arm_1',
        sensors: const [
          SessionSensor(
            sensorId: 'ax6_shoe_l',
            type: 'ax6',
            placement: 'shoe',
            serial: 'A1',
            use: SensorUse.both,
            freeLivingSerial: 'B2',
          ),
          SessionSensor(sensorId: 'ax3_wnd', type: 'ax3', placement: 'wrist', serial: 'Z0'),
        ],
      ),
      ParticipantEntry(participantId: '002', redcapEventName: 'da_0__visita_inici_arm_1'),
    ];
    final c = SessionController(
      participants: participants,
      battery: null,
      dataRoot: root.path,
      calibrations: [home, batch],
      clock: FakeSessionClock(),
      importRecords: (_) async => null,
      redcapConfigured: false,
    );
    expect((await c.command('start', {'video': false})).ok, isTrue);
    final dir1 = c.store!.directoryOf('001').path;
    final dir2 = c.store!.directoryOf('002').path;
    expect(File('$dir1/${batch.fileName}').existsSync(), isTrue);
    expect(File('$dir2/${batch.fileName}').existsSync(), isFalse);
    // Moved, not copied: it is only in the participant's folder now.
    expect(batch.file.existsSync(), isFalse);
    expect(File('$dir1/${home.fileName}').existsSync(), isTrue);
    expect(home.file.existsSync(), isFalse);

    final manifest = c.manifestJsonFor(participants.first, status: 'complete');
    final calib = manifest['calibrations'] as List;
    expect(calib.map((e) => e['sensor_id']), ['ax6_shoe_l', 'ax6_shoe_l']);
    expect(calib.map((e) => '${e['set']}:${e['serial']}:${e['file']}'), [
      'lab:A1:${batch.fileName}',
      'free_living:B2:${home.fileName}',
    ]);
    final sensors = manifest['sensors'] as Map;
    expect(sensors['ax6_shoe_l']['free_living_serial'], 'B2');

    final session = c.redcapImports()[1].first;
    expect(session['ws_calibration'], '1');
    expect(session['ws_calib_start'], LabRedCapService.formatRedcapDateTime(batch.start));

    final state = jsonDecode(jsonEncode(c.stateJson()));
    expect((state['calibrations'] as List).map((c) => c['devices']), [
      ['ax6:B2'],
      ['ax6:A1'],
    ]);
    c.dispose();
  });

  test('the final calibration goes to the folders of those who wore the sensors', () async {
    final participants = [
      ParticipantEntry(
        participantId: '001',
        redcapEventName: 'da_0__visita_inici_arm_1',
        sensors: const [
          SessionSensor(
            sensorId: 'ax6_shoe_l',
            type: 'ax6',
            placement: 'shoe',
            serial: 'A1',
            use: SensorUse.both,
            freeLivingSerial: 'B2',
          ),
          SessionSensor(sensorId: 'polar_h10', type: 'polar_h10', placement: 'chest', serial: 'P1'),
        ],
      ),
      ParticipantEntry(
        participantId: '002',
        redcapEventName: 'da_0__visita_inici_arm_1',
        sensors: const [
          SessionSensor(sensorId: 'ax6_shoe_l', type: 'ax6', placement: 'shoe', serial: 'C3'),
        ],
      ),
    ];
    final c = SessionController(
      participants: participants,
      battery: null,
      dataRoot: root.path,
      clock: FakeSessionClock(),
      importRecords: (_) async => null,
      redcapConfigured: false,
    );
    // The lab set only: the free-living AX6 went home, the Polar is live.
    expect(c.labDevices.map((d) => d.code), ['ax6:A1', 'ax6:C3']);
    expect((await c.command('start', {'video': false})).ok, isTrue);
    expect(c.recalibrateAtEnd, isFalse);
    expect((await c.command('finish', {'notes': '', 'recalibrate': true})).ok, isTrue);
    expect(c.recalibrateAtEnd, isTrue);
    for (var i = 0; i < 250 && c.closing != 'saved'; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(c.closing, 'saved');

    final record = await writeCalibration(DateTime.now().toUtc(), [const CalibrationDevice('ax6', 'A1')]);
    final written = await c.keepFinalCalibration(record);
    final dir1 = c.store!.directoryOf('001').path;
    final name = 'calibracion_final_${record.fileName.substring('calibracion_'.length)}';
    expect(written.map((f) => f.path), ['$dir1${Platform.pathSeparator}$name']);
    expect(File('${c.store!.directoryOf('002').path}/$name').existsSync(), isFalse);
    // The original stays for the next session of the day.
    expect(record.file.existsSync(), isTrue);
    c.dispose();
  });

  testWidgets('the calibration screen beeps, says each face and writes its times', (tester) async {
    final clock = FakeSessionClock(DateTime.now().toUtc());
    final audio = SilentAudio();
    final program = CalibrationProgram(faces: 6, faceSeconds: 5, stillSeconds: 5, knockSeconds: 4);
    CalibrationRecord? result;
    var popped = false;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await Navigator.of(context).push<CalibrationRecord>(MaterialPageRoute(
              builder: (_) => CalibrationPage(
                dataRoot: root.path,
                audio: audio,
                clock: clock,
                program: program,
                initialDevices: const [CalibrationDevice('ax6', 'A1'), CalibrationDevice('sens', '')],
              ),
            ));
            popped = true;
          },
          child: const Text('abrir'),
        ),
      ),
    ));
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Antes de que llegue el participante'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('calibration_start')));
    await tester.tap(find.byKey(const Key('calibration_start')));
    for (var i = 0; i < 20 && audio.said.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(audio.said.first, 'Calibración. Cara 1 arriba. En 5 segundos, tres golpes secos.');

    for (var i = 0; i < program.totalSeconds * 10 + 5 && !popped; i++) {
      clock.advance(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      if (i % 20 == 0) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      }
    }
    for (var i = 0; i < 20 && !popped; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
    }
    expect(popped, isTrue);
    expect(result, isNotNull);
    expect(result!.completed, isTrue);
    expect(result!.faces, 6);
    // Only the device with a serial counts.
    expect(result!.devices.map((d) => d.code), ['ax6:A1']);
    expect(audio.said, containsAll(['Cara 1.', 'Cara 6.', 'Tres golpes secos.']));
    // Three beeps before each of the 8 changes of step.
    expect(audio.played.where((s) => s == SessionSound.countdown).length,
        CalibrationProgram.warningBeeps * (program.steps.length - 1));
    final lines = result!.file.readAsLinesSync();
    expect(lines.where((l) => l.startsWith('face_end,')), hasLength(6));
  });
}
