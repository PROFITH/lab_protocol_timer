import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lab_protocol_timer/config/default_protocol_configuration.dart';
import 'package:lab_protocol_timer/models/activity_battery.dart';
import 'package:lab_protocol_timer/models/session_manifest.dart';
import 'package:lab_protocol_timer/models/sync_window.dart';
import 'package:lab_protocol_timer/services/lab_redcap_service.dart';

/// Example manifest copied from SAVES (docs/examples/session_manifest.v1.1.json).
Map<String, dynamic> _savesExample() => jsonDecode(
      File('test/fixtures/saves_session_manifest.v1.1.json').readAsStringSync(),
    ) as Map<String, dynamic>;

ActivityBattery _exampleBattery() => ActivityBattery.parse(
      File('docs/protocols/example_battery.json').readAsStringSync(),
    );

final _timestampPattern = RegExp(
  r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$',
);

Map<String, dynamic> _buildManifest({ActivityBattery? battery}) {
  final start = DateTime.utc(2026, 10, 27, 8, 30);
  final activityStart = start.add(const Duration(seconds: 40));

  final manifest = buildSessionManifest(
    sessionId: 'session_test',
    sessionStartTime: start,
    sessionEndTime: start.add(const Duration(minutes: 4)),
    participants: [
      ParticipantEntry(
        participantId: 'R4H001',
        redcapEventName: 'da_0__visita_inici_arm_1',
      ),
    ],
    activities: [
      ActivityLog(
        activityIndex: 1,
        activityStartTime: activityStart,
        activityEndTime: activityStart.add(const Duration(seconds: 120)),
        durationSeconds: 120.0,
        activityName: battery?.activityAt(1)?.name,
        compendiumCode: battery?.activityAt(1)?.compendiumCode,
        plannedDurationSeconds: battery?.activityAt(1)?.durationSeconds,
      ),
    ],
    syncWindows: [
      SyncWindow(
        eventId: 'sync_1',
        eventType: 'manual_sync',
        activityIndex: 1,
        phase: 'static_prep',
        windowStart: start.add(const Duration(seconds: 20)),
        windowEnd: start.add(const Duration(seconds: 30)),
      ),
    ],
    generatedFiles: [
      r'C:\data\session_test\session_test_cam1.mp4',
      '/data/session_test/polar_acc.csv',
    ],
    protocolConfiguration: defaultProtocolConfiguration,
    battery: battery,
  );

  // Round trip through JSON, as the file on disk.
  return jsonDecode(jsonEncode(manifest)) as Map<String, dynamic>;
}

void _expectSameKeys(Map<String, dynamic> actual, Map<String, dynamic> expected) {
  expect(actual.keys.toSet(), expected.keys.toSet());
}

void main() {
  group('session manifest 1.1', () {
    test('uses the keys of the SAVES example', () {
      final manifest = _buildManifest(battery: _exampleBattery());
      final example = _savesExample();

      expect(manifest['schema_version'], example['schema_version']);
      _expectSameKeys(manifest, example);
      _expectSameKeys(
        manifest['activities'][0] as Map<String, dynamic>,
        example['activities'][0] as Map<String, dynamic>,
      );
      _expectSameKeys(
        manifest['sync_windows'][0] as Map<String, dynamic>,
        example['sync_windows'][0] as Map<String, dynamic>,
      );
      _expectSameKeys(
        manifest['sensors']['polar_h10'] as Map<String, dynamic>,
        example['sensors']['polar_h10'] as Map<String, dynamic>,
      );
      _expectSameKeys(
        manifest['sensors']['ax3_wrist_nd'] as Map<String, dynamic>,
        example['sensors']['ax3_wrist_nd'] as Map<String, dynamic>,
      );
    });

    test('writes UTC timestamps that SAVES accepts', () {
      final manifest = _buildManifest();
      final window = manifest['sync_windows'][0] as Map<String, dynamic>;

      for (final value in [
        manifest['session_start_time_utc'],
        manifest['session_end_time_utc'],
        window['window_start_time_utc'],
        window['window_end_time_utc'],
      ]) {
        expect(value, matches(_timestampPattern));
      }
      expect(window.containsKey('window_start'), isFalse);
    });

    test('lists live devices, offline sensors and video file names', () {
      final manifest = _buildManifest(battery: _exampleBattery());
      final sensors = manifest['sensors'] as Map<String, dynamic>;

      expect(sensors.containsKey('camera'), isFalse);
      expect(sensors['polar_h10']['connection'], 'live');
      expect(sensors['polar_h10']['timestamp_domain'], 'native_plus_host_utc');
      expect(sensors['ax3_wrist_nd']['connection'], 'offline');
      expect(sensors['ax3_wrist_nd']['timestamp_domain'], 'device_clock_local');
      expect(sensors['matrix_wrist_nd']['timestamp_domain'], 'device_clock_utc');
      expect(manifest['video']['files'], ['session_test_cam1.mp4']);
      expect(manifest['protocol']['protocol_id'], 'run4health_day0_example');
    });

    test('omits protocol and activity metadata without a battery', () {
      final manifest = _buildManifest();
      final activity = manifest['activities'][0] as Map<String, dynamic>;

      expect(manifest.containsKey('protocol'), isFalse);
      expect(activity.containsKey('activity_name'), isFalse);
      expect((manifest['sensors'] as Map).keys, ['polar_h10']);
    });
  });

  group('SyncWindow', () {
    test('reads windows saved before 1.1', () {
      final window = SyncWindow.fromJson({
        'event_id': 'sync_1',
        'event_type': 'manual_sync',
        'activity_index': 1,
        'phase': 'static_prep',
        'window_start': '2026-10-27T08:30:20.000Z',
        'window_end': '2026-10-27T08:30:30.000Z',
      });

      expect(window.duration, const Duration(seconds: 10));
      expect(window.toJson()['window_start_time_utc'], '2026-10-27T08:30:20.000Z');
    });

    test('CSV header matches the JSON keys', () {
      expect(SyncWindow.csvHeader, contains('window_start_time_utc'));
      expect(SyncWindow.csvHeader.split(',').length,
          SyncWindow.fromJson(_savesExample()['sync_windows'][0] as Map<String, dynamic>)
              .toCsvRow()
              .split(',')
              .length);
    });
  });

  group('ActivityBattery', () {
    test('parses the example protocol', () {
      final battery = _exampleBattery();

      expect(battery.activities, hasLength(5));
      expect(battery.activityAt(1)?.name, 'Tumbado en reposo');
      expect(battery.activityAt(4)?.compendiumCode, '17200');
      expect(battery.activityAt(0), isNull);
      expect(battery.activityAt(6), isNull);
      expect(battery.offlineSensors.map((s) => s.sensorId), contains('ax3_thigh'));
    });

    test('survives the local backup round trip', () {
      final battery = _exampleBattery();
      final restored = ActivityBattery.parse(jsonEncode(battery.toJson()));

      expect(restored.toJson(), battery.toJson());
    });

    test('rejects invalid files with a readable message', () {
      expect(
        () => ActivityBattery.parse('{"protocol_id": "x", "activities": []}'),
        throwsFormatException,
      );
      expect(
        () => ActivityBattery.parse(
          '{"protocol_id": "x", "activities": [{"name": "A", "duration_seconds": 0}]}',
        ),
        throwsFormatException,
      );
      expect(
        () => ActivityBattery.parse(
          '{"protocol_id": "x", "activities": [{"name": "A"}], '
          '"offline_sensors": [{"sensor_id": "s", "timestamp_domain": "local"}]}',
        ),
        throwsFormatException,
      );
    });
  });

  test('ActivityLog keeps battery metadata through the local backup', () {
    final log = ActivityLog(
      activityIndex: 2,
      activityStartTime: DateTime.utc(2026, 10, 27, 8, 31),
      activityEndTime: DateTime.utc(2026, 10, 27, 8, 33),
      durationSeconds: 120.0,
      activityName: 'Caminar',
      compendiumCode: '17200',
      plannedDurationSeconds: 120,
    );

    final restored = ActivityLog.fromJson(jsonDecode(jsonEncode(log.toJson())));
    expect(restored.toJson(), log.toJson());
  });
}
