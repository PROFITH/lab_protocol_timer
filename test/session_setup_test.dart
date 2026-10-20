import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lab_protocol_timer/config/default_protocol_configuration.dart';
import 'package:lab_protocol_timer/models/activity_battery.dart';
import 'package:lab_protocol_timer/models/session_manifest.dart';
import 'package:lab_protocol_timer/services/compendium.dart';
import 'package:lab_protocol_timer/services/lab_redcap_service.dart';
import 'package:lab_protocol_timer/services/protocol_library.dart';
import 'package:lab_protocol_timer/setup/setup_format.dart';

const _day0 = 'da_0__visita_inici_arm_1';
const _day8 = 'da_8__visita_final_arm_1';

ActivityBattery _asset(String path) =>
    ActivityBattery.parse(File(path).readAsStringSync());

List<ActivityBattery> _builtIns() =>
    ProtocolLibrary.builtInAssets.map(_asset).toList();

Compendium _compendium() => Compendium.fromCsv(
      File('assets/compendium/compendium_2024.csv').readAsStringSync(),
    );

void main() {
  group('base protocols', () {
    final compendium = _compendium();

    test('the Compendium asset is complete', () {
      expect(compendium.entries, hasLength(1111));
    });

    for (final protocol in _builtIns()) {
      group(protocol.protocolId, () {
        test('every code exists in the 2024 Compendium with its MET', () {
          for (final a in protocol.activities.where((a) => !a.isCalibration)) {
            if (a.compendiumCode == null) continue;
            final entry = compendium.byCode(a.compendiumCode);
            expect(entry, isNotNull, reason: '${a.name}: ${a.compendiumCode}');
            expect(a.met, entry!.met, reason: a.name);
          }
        });

        test('has durations, calibration boxes and unique sensors', () {
          expect(protocol.title, isNotNull);
          expect(protocol.study, isNotNull);
          expect(protocol.moments, isNotEmpty);
          expect(protocol.activities.every((a) => a.durationSeconds != null),
              isTrue);
          expect(protocol.activities.first.isCalibration, isTrue);
          for (final box in protocol.activities.where((a) => a.isCalibration)) {
            expect(box.faces, 6);
            expect(box.compendiumCode, isNull);
          }
          final ids = protocol.sensors.map((s) => s.sensorId).toList();
          expect(ids.toSet(), hasLength(ids.length));
          expect(protocol.sensors.any((s) => s.type == 'other'), isFalse);
          for (final s in protocol.sensors) {
            expect(sensorPlacementByKey(s.placement), isNotNull,
                reason: s.sensorId);
          }
        });

        test('survives the JSON round trip', () {
          final again = ActivityBattery.parse(jsonEncode(protocol.toJson()));
          expect(again.toJson(), protocol.toJson());
        });
      });
    }

    test('RUN4HEALTH follows its collection protocol', () {
      final r4h = _asset('assets/protocols/run4health_base.json');
      final lab = r4h.activities.where((a) => !a.isCalibration).toList();

      expect(r4h.moments, [_day0, _day8]);
      expect(lab.first.name, 'Tumbado en reposo');
      expect(lab.first.durationSeconds, 300);
      expect(lab[lab.length - 2].durationSeconds, 30);
      expect(lab.last.name, 'Marcha de 6 minutos');
      expect(lab.last.durationSeconds, 360);
      expect(r4h.activities.last.isCalibration, isTrue);
      // No SensWear or portable calorimeter in the pilot.
      expect(r4h.sensors.map((s) => s.type), isNot(contains('senswear')));
      expect(
        r4h.sensors.where((s) => s.freeLiving).map((s) => s.sensorId),
        unorderedEquals(['matrix_wnd', 'sens_thigh', 'verity_arm']),
      );
    });

    test('WEARGAP has a day 0 and a day 8 protocol', () {
      final all = _builtIns();
      final day0 = all.firstWhere((p) => p.protocolId == 'weargap_day0_base');
      expect(ProtocolLibrary.forMoment(day0, _day8, all)?.protocolId,
          'weargap_day8_base');
      expect(day0.sensors.where((s) => s.type == 'camera'), hasLength(3));
      expect(day0.sensors.where((s) => s.type == 'ax6'), hasLength(2));
    });
  });

  group('ProtocolLibrary', () {
    final all = _builtIns();
    final r4h = all.firstWhere((p) => p.protocolId == 'run4health_base');
    final w0 = all.firstWhere((p) => p.protocolId == 'weargap_day0_base');
    final w8 = all.firstWhere((p) => p.protocolId == 'weargap_day8_base');

    List<SessionSensor> withSerials(ActivityBattery p) => [
          for (final s in p.sensors) s.copyWith(serial: 'SN-${s.sensorId}'),
        ];

    test('keeps a protocol that applies to the visit', () {
      expect(ProtocolLibrary.forMoment(r4h, _day8, all), same(r4h));
      expect(ProtocolLibrary.forMoment(w8, _day0, all), same(w0));
    });

    test('the same protocol comes back as it was used', () {
      final used = r4h.copyWith(
        activities: r4h.activities.sublist(0, 3),
        sensors: withSerials(r4h),
      );
      final remembered = RememberedSetup(
        battery: used,
        eventName: _day0,
        savedAt: DateTime(2026, 10, 26, 9),
      );

      final day8 = ProtocolLibrary.applyRemembered(r4h, remembered);
      expect(day8.toJson(), used.toJson());
    });

    test('the WEARGAP closing visit keeps its sensors with day 0 serials', () {
      final remembered = RememberedSetup(
        battery: w0.copyWith(sensors: withSerials(w0)),
        eventName: _day0,
        savedAt: DateTime(2026, 10, 26, 9),
      );

      final day8 = ProtocolLibrary.applyRemembered(w8, remembered);
      expect(day8.protocolId, 'weargap_day8_base');
      expect(day8.sensors.map((s) => s.sensorId),
          w8.sensors.map((s) => s.sensorId));
      expect(
        day8.sensors.firstWhere((s) => s.sensorId == 'ax3_wd').serial,
        'SN-ax3_wd',
      );
    });

    test('remembered setups survive the JSON round trip', () {
      final remembered = RememberedSetup(
        battery: r4h,
        eventName: _day0,
        savedAt: DateTime.utc(2026, 10, 26, 9),
      );
      final again = RememberedSetup.fromJson(
        jsonDecode(jsonEncode(remembered.toJson())) as Map<String, dynamic>,
      );
      expect(again.battery.toJson(), r4h.toJson());
      expect(again.savedAt, remembered.savedAt);
    });
  });

  group('session sensors in the manifest', () {
    final start = DateTime.utc(2026, 10, 27, 8, 30);

    Map<String, dynamic> manifest(ActivityBattery battery) => jsonDecode(
          jsonEncode(buildSessionManifest(
            sessionId: 's',
            sessionStartTime: start,
            sessionEndTime: start.add(const Duration(hours: 1)),
            participants: [
              ParticipantEntry(participantId: '3', redcapEventName: _day0),
            ],
            activities: const [],
            syncWindows: const [],
            generatedFiles: const [],
            protocolConfiguration: defaultProtocolConfiguration,
            battery: battery,
          )),
        ) as Map<String, dynamic>;

    final battery = _asset('assets/protocols/run4health_base.json').copyWith(
      sensors: [
        const SessionSensor(
          sensorId: 'ax3_wnd',
          type: 'ax3',
          placement: 'wrist_non_dominant',
          serial: '41234',
          samplingRateHz: 100,
          rangeG: 8,
        ),
        const SessionSensor(
          sensorId: 'sens_thigh',
          type: 'sens',
          placement: 'thigh',
          freeLiving: true,
        ),
        const SessionSensor(
          sensorId: 'polar_h10',
          type: 'polar_h10',
          placement: 'chest',
          serial: 'A1B2C3',
        ),
        const SessionSensor(sensorId: 'cam_room', type: 'camera', placement: 'room'),
      ],
    );

    test('offline sensors carry type, placement, serial and settings', () {
      final ax3 = manifest(battery)['sensors']['ax3_wnd'] as Map<String, dynamic>;
      expect(ax3, {
        'present': true,
        'timestamp_domain': 'device_clock_local',
        'device_name': 'Axivity AX3',
        'placement': 'wrist_non_dominant',
        'connection': 'offline',
        'device_type': 'ax3',
        'placement_label': 'Muñeca no dominante',
        'serial': '41234',
        'sampling_rate_hz': 100.0,
        'range_g': 8.0,
      });
      expect(manifest(battery)['sensors']['sens_thigh']['free_living'], isTrue);
    });

    test('the H10 keeps its live entry and gains the serial', () {
      final sensors = manifest(battery)['sensors'] as Map<String, dynamic>;
      expect(sensors.keys.where((k) => k.contains('h10')), ['polar_h10']);
      expect(sensors['polar_h10']['connection'], 'live');
      expect(sensors['polar_h10']['timestamp_domain'], 'native_plus_host_utc');
      expect(sensors['polar_h10']['serial'], 'A1B2C3');
    });

    test('cameras go under video, not sensors', () {
      final m = manifest(battery);
      expect((m['sensors'] as Map).containsKey('cam_room'), isFalse);
      expect(m['video']['cameras'], [
        {
          'camera_id': 'cam_room',
          'placement': 'room',
          'device_type': 'camera',
          'placement_label': 'Fija en la sala',
        },
      ]);
    });

    test('protocol files with offline_sensors still load', () {
      final legacy = ActivityBattery.parse(jsonEncode({
        'protocol_id': 'old',
        'activities': [
          {'name': 'A'},
        ],
        'offline_sensors': [
          {
            'sensor_id': 'ax3_wrist_nd',
            'device_name': 'Axivity AX3',
            'placement': 'non-dominant wrist',
            'timestamp_domain': 'device_clock_local',
          },
        ],
      }));
      final ax3 = manifest(legacy)['sensors']['ax3_wrist_nd'] as Map;
      expect(ax3.keys, {
        'present',
        'timestamp_domain',
        'device_name',
        'placement',
        'connection',
      });
      expect(ax3['placement'], 'non-dominant wrist');
    });

    test('rejects repeated sensor IDs and unknown types', () {
      expect(
        () => ActivityBattery.parse(jsonEncode({
          'protocol_id': 'x',
          'activities': [
            {'name': 'A'},
          ],
          'sensors': [
            {'sensor_id': 's', 'type': 'ax3'},
            {'sensor_id': 's', 'type': 'ax6'},
          ],
        })),
        throwsFormatException,
      );
      expect(
        () => SessionSensor.fromJson({'sensor_id': 's', 'type': 'actigraph'}),
        throwsFormatException,
      );
    });

    test('suggests IDs from type and placement', () {
      expect(SessionSensor.suggestId('ax3', 'wrist_dominant'), 'ax3_wd');
      expect(SessionSensor.suggestId('ax6', 'shoe_left'), 'ax6_shoe_l');
      expect(
        SessionSensor.suggestId('camera', 'room', ['cam_room', 'cam_room_2']),
        'cam_room_3',
      );
    });
  });

  group('calibration box segments', () {
    final start = DateTime.utc(2026, 10, 27, 8, 30);
    final participants = [
      ParticipantEntry(participantId: '3', redcapEventName: _day0),
    ];

    ActivityLog log(int index, {String kind = 'activity', int? labIndex, double? met}) =>
        ActivityLog(
          activityIndex: index,
          activityStartTime: start.add(Duration(minutes: 10 * index)),
          activityEndTime: start.add(Duration(minutes: 10 * index + 5)),
          durationSeconds: 300,
          activityName: kind == 'calibration' ? 'Caja' : 'Actividad $index',
          activityKind: kind,
          labIndex: labIndex,
          met: met,
        );

    final activities = [
      log(1, kind: 'calibration'),
      log(2, labIndex: 1, met: 1.0),
      log(3, labIndex: 2, met: 7.5),
      log(4, kind: 'calibration'),
    ];

    test('fill ws_calib_* and stay out of lab_activity', () {
      final records = LabRedCapService.buildLabActivityRecords(
        participants: participants,
        sessionId: 's',
        protocolId: 'run4health_base',
        activities: activities,
      );

      expect(records, hasLength(3));
      expect(records.first['ws_calibration'], '1');
      expect(records.first['ws_calib_start'],
          LabRedCapService.formatRedcapDateTime(activities.first.activityStartTime));
      expect(records[1]['la_order'], '1');
      expect(records[1]['la_mets'], '1.0');
      expect(records[2]['la_mets'], '7.5');
    });

    test('do not take an act_N slot in protocol_feasibility', () {
      final record = LabRedCapService.buildFlatProtocolRecords(
        participants: participants,
        sessionStartTime: start,
        sessionEndTime: start.add(const Duration(hours: 1)),
        activities: activities,
        totalProtocolSeconds: 3600,
        totalActivitySeconds: 600,
        totalTransitionSeconds: 3000,
        totalStations: 2,
      ).single;

      expect(record['act_1_start_time'],
          LabRedCapService.formatRedcapDateTime(activities[1].activityStartTime));
      expect(record.containsKey('act_3_start_time'), isFalse);
    });

    test('kind, MET and position survive the local backup', () {
      for (final a in activities) {
        final again = ActivityLog.fromJson(
          jsonDecode(jsonEncode(a.toJson())) as Map<String, dynamic>,
        );
        expect(again.toJson(), a.toJson());
        expect(again.isCalibration, a.isCalibration);
      }
    });

    test('battery activities read kind, MET and phase overrides', () {
      final a = BatteryActivity.fromJson({
        'name': 'Caja',
        'kind': 'calibration',
        'duration_seconds': 360,
        'prep_seconds': 120,
        'post_seconds': 0,
        'faces': 6,
      });
      expect(a.isCalibration, isTrue);
      expect(a.prepSeconds, 120);
      expect(a.postSeconds, 0);
      expect(BatteryActivity.fromJson(a.toJson()).toJson(), a.toJson());
      expect(
        () => BatteryActivity.fromJson({'name': 'A', 'kind': 'pause'}),
        throwsFormatException,
      );
      expect(
        () => BatteryActivity.fromJson({'name': 'A', 'met': 0}),
        throwsFormatException,
      );
    });
  });

  group('editor helpers', () {
    test('read durations as seconds or m:ss', () {
      expect(parseSeconds('90'), 90);
      expect(parseSeconds('4:00'), 240);
      expect(parseSeconds('1:00:00'), 3600);
      expect(parseSeconds(''), isNull);
      expect(parseSeconds('4 min'), isNull);
      expect(formatSeconds(240), '4:00');
      expect(formatSeconds(3725), '1:02:05');
    });

    test('make protocol IDs from names', () {
      expect(protocolIdFromName('RUN4HEALTH v2 (piloto)'),
          'custom_run4health_v2_piloto');
      expect(protocolIdFromName('Batería días'), 'custom_bateria_dias');
      expect(protocolIdFromName('  '), 'custom_protocolo');
    });

    test('Compendium search ignores accents, case and word order', () {
      final c = _compendium();
      expect(c.search('BICICLETA estatica 50').map((e) => e.code),
          contains('01214'));
      expect(c.search('escaleras subir').map((e) => e.code), contains('17131'));
      expect(c.byCode('07011')?.met, 1.0);
    });
  });
}
