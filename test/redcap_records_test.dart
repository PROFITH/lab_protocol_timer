import 'package:flutter_test/flutter_test.dart';
import 'package:lab_protocol_timer/services/lab_redcap_service.dart';

void main() {
  final start = DateTime.utc(2026, 10, 27, 8, 30);

  List<Map<String, dynamic>> build(int nActivities) {
    final activities = [
      for (var i = 1; i <= nActivities; i++)
        ActivityLog(
          activityIndex: i,
          activityStartTime: start.add(Duration(minutes: 5 * i)),
          activityEndTime: start.add(Duration(minutes: 5 * i + 3)),
          durationSeconds: 180,
        ),
    ];
    return LabRedCapService.buildFlatProtocolRecords(
      participants: [
        ParticipantEntry(participantId: '1', redcapEventName: 'da_0__visita_inici_arm_1'),
        ParticipantEntry(participantId: '2', redcapEventName: 'da_8__visita_final_arm_1'),
      ],
      sessionStartTime: start,
      sessionEndTime: start.add(const Duration(hours: 1)),
      activities: activities,
      totalProtocolSeconds: 3600,
      totalActivitySeconds: 180.0 * nActivities,
      totalTransitionSeconds: 3600 - 180.0 * nActivities,
      totalStations: nActivities,
    );
  }

  final redcapDateTime = RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$');

  test('one record per participant with REDCap datetime_seconds_ymd values', () {
    final records = build(2);

    expect(records.map((r) => r['record_id']), ['1', '2']);
    expect(records[1]['redcap_event_name'], 'da_8__visita_final_arm_1');
    for (final key in ['session_start_time', 'session_end_time', 'act_1_start_time', 'act_2_end_time']) {
      expect(records[0][key], matches(redcapDateTime));
    }
    expect(records[0]['lab_total_stations'], '2');
  });

  test('skips activities without a REDCap field', () {
    final record = build(12).first;

    expect(record.containsKey('act_10_end_time'), isTrue);
    expect(record.containsKey('act_11_start_time'), isFalse);
    expect(record['lab_total_stations'], '12');
  });

  test('formats local time to the second', () {
    final local = DateTime(2026, 10, 27, 9, 5, 7, 999);
    expect(LabRedCapService.formatRedcapDateTime(local), '2026-10-27 09:05:07');
  });
}
