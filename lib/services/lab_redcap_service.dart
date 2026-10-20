import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class ParticipantEntry {
  final String participantId;
  final String redcapEventName;

  ParticipantEntry({
    required this.participantId,
    required this.redcapEventName,
  });

  Map<String, dynamic> toJson() => {
        'participant_id': participantId,
        'redcap_event_name': redcapEventName,
      };

  factory ParticipantEntry.fromJson(Map<String, dynamic> json) =>
      ParticipantEntry(
        participantId: json['participant_id'] as String,
        redcapEventName: json['redcap_event_name'] as String,
      );
}

/// How an activity attempt ended, as `la_completed` in REDCap.
class ActivityCompletion {
  static const complete = 'complete';
  static const partial = 'partial';
  static const skipped = 'skipped';

  /// REDCap code of `la_completed` (1 Completa, 2 Parcial, 3 No realizada).
  static String redcapCode(String completion) => switch (completion) {
        partial => '2',
        skipped => '3',
        _ => '1',
      };

  static String label(String completion) => switch (completion) {
        partial => 'Parcial',
        skipped => 'No realizada',
        _ => 'Completa',
      };
}

/// One attempt at an activity of the session: its main phase, how it ended
/// and what the evaluator noted about it.
class ActivityLog {
  /// Activity index
  final int activityIndex;

  /// Start/end of the main activity itself.
  final DateTime activityStartTime;
  final DateTime activityEndTime;

  /// Duration of the main activity in seconds, without pauses.
  final double durationSeconds;

  /// Activity metadata from the protocol battery, when one was loaded.
  final String? activityName;
  final String? compendiumCode;
  final int? plannedDurationSeconds;
  final double? met;

  /// Position of the activity in the battery not counting calibration box
  /// segments (`act_<n>_start_time` in REDCap). Null without a battery, when
  /// it equals [activityIndex].
  final int? labIndex;

  /// `activity` or `calibration` (see [ActivityKind]).
  final String activityKind;

  /// 1 for the first time the activity is done, 2 when it is repeated...
  final int attempt;

  /// [ActivityCompletion.complete], `partial` or `skipped`.
  final String completion;

  /// Why the main phase ended: `timer`, `early` (the evaluator ended it),
  /// `repeat`, `finish` (end of session), `interrupted` (the app closed) or
  /// `skipped`.
  final String endReason;

  /// Seconds the main phase was paused (not counted in [durationSeconds]).
  final double pausedSeconds;

  /// Effort (0-10) after and, when the protocol asks for it, before.
  final int? rpe;
  final int? rpeBefore;

  /// Free text typed by the evaluator.
  final String? incident;

  /// Values of the activity's REDCap fields (repetitions, laps...).
  final Map<String, String> fieldValues;

  /// Resting heart rate measured during this activity (`resting_hr`).
  final int? restingHrBpm;
  final DateTime? restingHrTime;

  bool get isCalibration => activityKind == 'calibration';
  bool get isSkipped => completion == ActivityCompletion.skipped;

  ActivityLog({
    required this.activityIndex,
    required this.activityStartTime,
    required this.activityEndTime,
    required this.durationSeconds,
    this.activityName,
    this.compendiumCode,
    this.plannedDurationSeconds,
    this.met,
    this.labIndex,
    this.activityKind = 'activity',
    this.attempt = 1,
    this.completion = ActivityCompletion.complete,
    this.endReason = 'timer',
    this.pausedSeconds = 0,
    this.rpe,
    this.rpeBefore,
    this.incident,
    this.fieldValues = const {},
    this.restingHrBpm,
    this.restingHrTime,
  });

  ActivityLog copyWith({
    String? completion,
    String? endReason,
    int? rpe,
    int? rpeBefore,
    String? incident,
    Map<String, String>? fieldValues,
    int? restingHrBpm,
    DateTime? restingHrTime,
    bool clearRpe = false,
    bool clearRpeBefore = false,
    bool clearIncident = false,
    bool clearRestingHr = false,
  }) =>
      ActivityLog(
        activityIndex: activityIndex,
        activityStartTime: activityStartTime,
        activityEndTime: activityEndTime,
        durationSeconds: durationSeconds,
        activityName: activityName,
        compendiumCode: compendiumCode,
        plannedDurationSeconds: plannedDurationSeconds,
        met: met,
        labIndex: labIndex,
        activityKind: activityKind,
        attempt: attempt,
        completion: completion ?? this.completion,
        endReason: endReason ?? this.endReason,
        pausedSeconds: pausedSeconds,
        rpe: clearRpe ? null : rpe ?? this.rpe,
        rpeBefore: clearRpeBefore ? null : rpeBefore ?? this.rpeBefore,
        incident: clearIncident ? null : incident ?? this.incident,
        fieldValues: fieldValues ?? this.fieldValues,
        restingHrBpm: clearRestingHr ? null : restingHrBpm ?? this.restingHrBpm,
        restingHrTime:
            clearRestingHr ? null : restingHrTime ?? this.restingHrTime,
      );

  Map<String, dynamic> toJson() => {
        'activity_index': activityIndex,
        'activity_start_time_utc': activityStartTime.toUtc().toIso8601String(),
        'activity_end_time_utc': activityEndTime.toUtc().toIso8601String(),
        'duration_seconds': durationSeconds,
        if (activityName != null) 'activity_name': activityName,
        if (compendiumCode != null) 'compendium_code': compendiumCode,
        if (plannedDurationSeconds != null)
          'planned_duration_seconds': plannedDurationSeconds,
        if (met != null) 'met': met,
        if (labIndex != null && labIndex != activityIndex) 'lab_index': labIndex,
        if (activityKind != 'activity') 'activity_kind': activityKind,
        if (attempt != 1) 'attempt': attempt,
        if (completion != ActivityCompletion.complete) 'completion': completion,
        if (endReason != 'timer') 'end_reason': endReason,
        if (pausedSeconds > 0) 'paused_seconds': pausedSeconds,
        if (rpe != null) 'rpe': rpe,
        if (rpeBefore != null) 'rpe_before': rpeBefore,
        if (incident != null && incident!.isNotEmpty) 'incident': incident,
        if (fieldValues.isNotEmpty) 'redcap_fields': fieldValues,
        if (restingHrBpm != null) 'resting_hr_bpm': restingHrBpm,
        if (restingHrTime != null)
          'resting_hr_time_utc': restingHrTime!.toUtc().toIso8601String(),
      };

  factory ActivityLog.fromJson(Map<String, dynamic> json) => ActivityLog(
        activityIndex: json['activity_index'] as int,
        activityStartTime: DateTime.parse(
          json['activity_start_time_utc'] ?? json['activity_start_time'],
        ).toUtc(),
        activityEndTime: DateTime.parse(
          json['activity_end_time_utc'] ?? json['activity_end_time'],
        ).toUtc(),
        durationSeconds: (json['duration_seconds'] as num).toDouble(),
        activityName: json['activity_name'] as String?,
        compendiumCode: json['compendium_code']?.toString(),
        plannedDurationSeconds:
            (json['planned_duration_seconds'] as num?)?.round(),
        met: (json['met'] as num?)?.toDouble(),
        labIndex: json['lab_index'] as int? ?? json['activity_index'] as int,
        activityKind: json['activity_kind'] as String? ?? 'activity',
        attempt: json['attempt'] as int? ?? 1,
        completion:
            json['completion'] as String? ?? ActivityCompletion.complete,
        endReason: json['end_reason'] as String? ?? 'timer',
        pausedSeconds: (json['paused_seconds'] as num?)?.toDouble() ?? 0,
        rpe: json['rpe'] as int?,
        rpeBefore: json['rpe_before'] as int?,
        incident: json['incident'] as String?,
        fieldValues: {
          for (final e
              in (json['redcap_fields'] as Map? ?? const {}).entries)
            e.key.toString(): e.value.toString(),
        },
        restingHrBpm: json['resting_hr_bpm'] as int?,
        restingHrTime: json['resting_hr_time_utc'] == null
            ? null
            : DateTime.parse(json['resting_hr_time_utc'] as String).toUtc(),
      );
}

class LabRedCapService {
  static const String _redcapUrl = String.fromEnvironment(
    'REDCAP_URL',
    defaultValue: 'https://redcap.ugr.es/api/',
  );

  static const String _apiToken = String.fromEnvironment(
    'REDCAP_TOKEN',
    defaultValue: '',
  );

  /// Activities with start/end fields in the REDCap instrument
  /// (`act_1_start_time` ... `act_10_end_time`).
  static const int maxRedcapActivities = 10;

  static bool get isConfigured => _apiToken.isNotEmpty;

  /// REDCap `datetime_seconds_ymd` value in the computer's local time.
  static String formatRedcapDateTime(DateTime time) {
    final t = time.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  /// One flat record per participant for the `protocol_feasibility` form.
  /// [totalStations] and the totals are expected without calibration box
  /// segments.
  static List<Map<String, dynamic>> buildFlatProtocolRecords({
    required List<ParticipantEntry> participants,
    required DateTime sessionStartTime,
    required DateTime sessionEndTime,
    required List<ActivityLog> activities,
    required double totalProtocolSeconds,
    required double totalActivitySeconds,
    required double totalTransitionSeconds,
    required int totalStations,
  }) {
    final records = <Map<String, dynamic>>[];

    for (final participant in participants) {
      final Map<String, dynamic> recordData = {
        'record_id': participant.participantId,
        'redcap_event_name': participant.redcapEventName,
        'session_start_time': formatRedcapDateTime(sessionStartTime),
        'session_end_time': formatRedcapDateTime(sessionEndTime),
        'lab_total_stations': totalStations.toString(),
        'total_protocol_seconds': totalProtocolSeconds.toStringAsFixed(2),
        'total_activity_seconds': totalActivitySeconds.toStringAsFixed(2),
        'total_transition_seconds': totalTransitionSeconds.toStringAsFixed(2),
        'protocol_feasibility_complete': '2',
      };

      for (final act in activities) {
        // Calibration box segments are not activities.
        if (act.isCalibration) continue;
        final idx = act.labIndex ?? act.activityIndex;
        // REDCap rejects the whole import if a field does not exist.
        if (idx < 1 || idx > maxRedcapActivities) continue;
        recordData['act_${idx}_start_time'] = formatRedcapDateTime(act.activityStartTime);
        recordData['act_${idx}_end_time'] = formatRedcapDateTime(act.activityEndTime);
      }

      records.add(recordData);
    }
    return records;
  }

  /// Per-activity detail for the repeating `lab_activity` instrument (one
  /// instance per activity, so the 10-activity limit does not apply) plus the
  /// session link in `wearable_session`.
  ///
  /// Calibration box segments are not activities: the first one fills
  /// `ws_calibration`, `ws_calib_start` and `ws_calib_end`, and the rest stay
  /// in the session manifest.
  static List<Map<String, dynamic>> buildLabActivityRecords({
    required List<ParticipantEntry> participants,
    required String sessionId,
    String? protocolId,
    required List<ActivityLog> activities,
  }) {
    final records = <Map<String, dynamic>>[];
    final calibration =
        activities.where((a) => a.isCalibration).firstOrNull;
    final labActivities = activities.where((a) => !a.isCalibration).toList();

    for (final participant in participants) {
      records.add({
        'record_id': participant.participantId,
        'redcap_event_name': participant.redcapEventName,
        'ws_session_id': sessionId,
        if (protocolId != null) 'ws_protocol_id': protocolId,
        if (calibration != null) ...{
          'ws_calibration': '1',
          'ws_calib_start':
              formatRedcapDateTime(calibration.activityStartTime),
          'ws_calib_end': formatRedcapDateTime(calibration.activityEndTime),
        },
      });

      for (var i = 0; i < labActivities.length; i++) {
        final act = labActivities[i];
        records.add({
          'record_id': participant.participantId,
          'redcap_event_name': participant.redcapEventName,
          'redcap_repeat_instrument': 'lab_activity',
          'redcap_repeat_instance': (i + 1).toString(),
          'la_order': (i + 1).toString(),
          'la_session_id': sessionId,
          if (act.compendiumCode != null) 'la_code': act.compendiumCode,
          'la_name': act.activityName ?? 'Actividad ${act.activityIndex}',
          if (act.met != null) 'la_mets': _formatMet(act.met!),
          'la_start': formatRedcapDateTime(act.activityStartTime),
          'la_end': formatRedcapDateTime(act.activityEndTime),
          if (act.plannedDurationSeconds != null)
            'la_planned_s': act.plannedDurationSeconds.toString(),
          'la_completed': '1',
          'lab_activity_complete': '2',
        });
      }
    }
    return records;
  }

  static String _formatMet(double met) =>
      met == met.roundToDouble() ? met.toStringAsFixed(1) : met.toString();

  /// Sends [records] to REDCap. Returns null on success or the error message.
  static Future<String?> importRecords(List<Map<String, dynamic>> records) async {
    if (!isConfigured) {
      return 'Falta el token de REDCap (compila con --dart-define=REDCAP_TOKEN=...)';
    }

    final Map<String, String> body = {
      'token': _apiToken,
      'content': 'record',
      'format': 'json',
      'type': 'flat',
      'overwriteBehavior': 'normal',
      'data': jsonEncode(records),
      'returnContent': 'count',
      'returnFormat': 'json',
    };

    try {
      final response = await http
          .post(
            Uri.parse(_redcapUrl),
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: body,
          )
          .timeout(const Duration(seconds: 30));

      debugPrint('[REDCAP] HTTP ${response.statusCode}: ${response.body}');
      if (response.statusCode == 200) return null;
      return 'REDCap respondió ${response.statusCode}: ${response.body}';
    } catch (e) {
      debugPrint('[REDCAP] Excepción: $e');
      return 'No se pudo conectar con REDCap: $e';
    }
  }
}
