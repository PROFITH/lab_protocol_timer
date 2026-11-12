import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lab_protocol_timer/models/session_sensor.dart';
import 'package:lab_protocol_timer/services/device_inventory.dart';
import 'package:lab_protocol_timer/services/lab_redcap_service.dart';
import 'package:lab_protocol_timer/setup/device_sheet_dialog.dart';
import 'package:lab_protocol_timer/ui/app_theme.dart';

void main() {
  const event = 'da_0__visita_inici_arm_1';
  final now = DateTime(2026, 11, 12, 10, 30);

  // RUN4HEALTH Day 0: AX6 on the shoes in the laboratory, on the ankles at
  // home; Matrix and SENS both; H10 only in the laboratory.
  final sensors = [
    const SessionSensor(
        sensorId: 'matrix_wnd', type: 'matrix', placement: 'wrist', dominance: SensorDominance.nonDominant,
        serial: 'M-11', freeLivingSerial: 'M-22', use: SensorUse.both, samplingRateHz: 25, rangeG: 8,
        initialized: true, freeLivingInitialized: true),
    const SessionSensor(
        sensorId: 'sens_thigh', type: 'sens', placement: 'thigh', serial: 'S-1', freeLivingSerial: 'S-2',
        use: SensorUse.both, samplingRateHz: 12.5),
    const SessionSensor(
        sensorId: 'ax6_shoe_l', type: 'ax6', placement: 'shoe', side: SensorSide.left, serial: '6011'),
    const SessionSensor(
        sensorId: 'ax6_ankle_l', type: 'ax6', placement: 'ankle', side: SensorSide.left,
        freeLivingSerial: '6021', use: SensorUse.freeLiving, samplingRateHz: 100, rangeG: 16),
    const SessionSensor(
        sensorId: 'ax6_ankle_r', type: 'ax6', placement: 'ankle', side: SensorSide.right,
        serial: '6022', use: SensorUse.freeLiving),
    const SessionSensor(sensorId: 'polar_h10', type: 'polar_h10', placement: 'chest', serial: 'H10-A'),
    const SessionSensor(sensorId: 'cam_room', type: 'camera', placement: 'room'),
  ];

  test('each device of the laboratory and of the free-living days, with its own serial', () {
    final devices = deviceEntriesOf(sensors);
    expect([for (final d in devices) '${d.period}:${d.sensor.sensorId}:${d.serial}'], [
      'lab:matrix_wnd:M-11',
      'lab:sens_thigh:S-1',
      'lab:ax6_shoe_l:6011',
      'lab:polar_h10:H10-A',
      'free_living:matrix_wnd:M-22',
      'free_living:sens_thigh:S-2',
      'free_living:ax6_ankle_l:6021',
      // Only for the free-living days, typed in the serial field.
      'free_living:ax6_ankle_r:6022',
    ], reason: 'cameras are left out');
    expect(devices.first.place, 'Muñeca no dominante');
    expect(devices.first.settings, '25 Hz · ±8 g');
    expect(devices[1].settings, '12,5 Hz');
    expect(devices[6].place, 'Tobillo, izquierda');
  });

  test('onboarding_config gets the free-living devices and the whole list, apart', () {
    final participant = ParticipantEntry(participantId: 'R4H_007', redcapEventName: event, sensors: sensors);
    final r = OnboardingDevices.records([participant], const [], now: now);

    final base = r.base.single;
    expect(base, {
      'record_id': 'R4H_007',
      'redcap_event_name': event,
      'device_1': 'Muñeca no dominante',
      'ref_dispositivo1': 'Parmay Matrix · nº M-22 · matrix_wnd',
      'device_2': 'Muslo',
      'device2_ref': 'SENS motion · nº S-2 · sens_thigh',
      'device_3': 'Tobillo, izquierda',
      'device_3_ref': 'Axivity AX6 · nº 6021 · ax6_ankle_l',
      'device_4': 'Tobillo, derecha',
      'device_4_ref': 'Axivity AX6 · nº 6022 · ax6_ankle_r',
    });

    final extended = r.extended.single;
    expect(extended.keys.where((k) => k.startsWith('device_')), isEmpty, reason: 'only four devices');
    expect((extended['devices_lab'] as String).split('\n'), [
      'Parmay Matrix | Muñeca no dominante | matrix_wnd | nº M-11 | 25 Hz · ±8 g | inicializado',
      'SENS motion | Muslo | sens_thigh | nº S-1 | 12,5 Hz | sin marcar como inicializado',
      'Axivity AX6 | Calzado, izquierda | ax6_shoe_l | nº 6011 | sin marcar como inicializado',
      'Polar H10 | Pecho | polar_h10 | nº H10-A | en directo',
    ]);
    expect((extended['devices_free_living'] as String).split('\n'), hasLength(4));
    expect(extended['devices_updated'], '2026-11-12 10:30:00');
  });

  test('a fifth and sixth device go to the v10 fields, more to the list only', () {
    final many = [
      for (var i = 1; i <= 7; i++)
        SessionSensor(sensorId: 'ax3_$i', type: 'ax3', placement: 'thigh', serial: 'A$i', use: SensorUse.freeLiving),
    ];
    final r = OnboardingDevices.records(
      [ParticipantEntry(participantId: 'P', redcapEventName: event, sensors: many)],
      const [],
      now: now,
    );
    expect(r.base.single.keys.where((k) => RegExp(r'^device_\d$').hasMatch(k)).length, 4);
    // Same place twice: the device is added to tell them apart.
    expect(r.base.single['device_1'], 'Muslo (Axivity AX3)');
    final extended = r.extended.single;
    expect(extended['device_5'], 'Muslo (Axivity AX3)');
    expect(extended['device_6_ref'], 'Axivity AX3 · nº A6 · ax3_6');
    expect(extended.containsKey('device_7'), isFalse);
    expect(extended['devices_free_living'], contains('Sin hueco en device_1-device_6: Muslo (Axivity AX3): Axivity AX3 · nº A7 · ax3_7'));
  });

  test('a visit without free-living devices sends nothing to onboarding_config', () {
    final r = OnboardingDevices.records(
      [ParticipantEntry(participantId: 'P', redcapEventName: 'dia_8_arm_1', sensors: [sensors[2], sensors[5]])],
      const [],
      now: now,
    );
    expect(r.base, isEmpty);
    expect(r.extended, isEmpty);
  });

  test('the protocol sensors count when the participant has none of their own', () {
    final r = OnboardingDevices.records(
      [ParticipantEntry(participantId: 'P', redcapEventName: event)],
      sensors,
      now: now,
    );
    expect(r.base.single['device_4'], 'Tobillo, derecha');
  });

  test('the sheet opens in Excel in columns and quotes what needs it', () {
    final csv = DeviceSheet.csv('R4H_007', deviceEntriesOf([
      const SessionSensor(sensorId: 'x', type: 'other', placement: 'other', serial: 'a;b', use: SensorUse.lab),
    ]));
    expect(csv, startsWith('﻿participante;periodo;'));
    expect(csv.split('\r\n')[1], 'R4H_007;Laboratorio;Otro;Otra;x;"a;b";;;Graba por su cuenta;No');
  });

  test('a project without dictionary v10 is told what to upload', () {
    final records = [
      {'record_id': 'P', 'devices_free_living': 'x'},
    ];
    final message = LabRedCapService.explainImportError(
        'The following fields were not found in the project as real data fields: devices_lab, devices_free_living', records);
    expect(message, contains('diccionario v10'));
  });

  testWidgets('the evaluator sees where each device goes, with what is missing', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDeviceSheetDialog(
              context,
              participants: [ParticipantEntry(participantId: 'R4H_007', redcapEventName: event, sensors: sensors)],
              layout: const [],
            ),
            child: const Text('ficha'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('ficha'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('device_sheet_dialog')), findsOneWidget);
    expect(find.text('R4H_007'), findsOneWidget);
    expect(find.text('Tobillo, derecha'), findsOneWidget);
    expect(find.text('6021'), findsOneWidget);
    expect(find.text('Vida libre'), findsNWidgets(4));
    expect(find.text('cam_room'), findsNothing);
  });
}
