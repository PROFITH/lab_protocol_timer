import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/activity_battery.dart';
import 'redcap_connection.dart';

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
  /// Activities with start/end fields in the REDCap instrument
  /// (`act_1_start_time` ... `act_10_end_time`).
  static const int maxRedcapActivities = 10;

  /// A token is set (in the app or in the build); see [RedcapConnection].
  static bool get isConfigured => RedcapConnection.isConfigured;

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
  /// instance per attempt, so the 10-activity limit does not apply) plus the
  /// session link in `wearable_session`.
  ///
  /// Calibration box segments are not activities: the first one fills
  /// `ws_calibration`, `ws_calib_start` and `ws_calib_end`, and the rest stay
  /// in the session manifest. Skipped attempts and the activities of the
  /// protocol that were never reached ([notDone]) are sent as "No
  /// realizada" without times. Calculated fields (`la_duration_s`,
  /// `ws_bmi`...) are never sent: REDCap rejects the whole import.
  static List<Map<String, dynamic>> buildLabActivityRecords({
    required List<ParticipantEntry> participants,
    required String sessionId,
    String? protocolId,
    required List<ActivityLog> activities,
    List<ActivityLog> notDone = const [],
    DateTime? sessionStartTime,
    int? cameras,
    String? operator,
    String? notes,
  }) {
    final records = <Map<String, dynamic>>[];
    final calibration = activities
        .where((a) => a.isCalibration && !a.isSkipped)
        .firstOrNull;
    final instances = labActivityInstances([...activities, ...notDone]);
    final labActivities = instances.keys.toList();
    final resting = activities
        .where((a) => a.restingHrBpm != null && !a.isSkipped)
        .lastOrNull;

    for (final participant in participants) {
      records.add({
        'record_id': participant.participantId,
        'redcap_event_name': participant.redcapEventName,
        'ws_session_id': sessionId,
        if (protocolId != null) 'ws_protocol_id': protocolId,
        if (sessionStartTime != null)
          'ws_date': formatRedcapDate(sessionStartTime),
        if (operator != null && operator.trim().isNotEmpty)
          'ws_operator': operator.trim(),
        if (cameras != null) 'ws_video_cameras': cameras.toString(),
        if (notes != null && notes.trim().isNotEmpty)
          'ws_incidents': notes.trim(),
        if (calibration != null) ...{
          'ws_calibration': '1',
          'ws_calib_start':
              formatRedcapDateTime(calibration.activityStartTime),
          'ws_calib_end': formatRedcapDateTime(calibration.activityEndTime),
        },
        if (resting != null) ...{
          'ws_hr_rest': resting.restingHrBpm.toString(),
          'ws_hr_rest_method': '1',
          'ws_hr_rest_time': formatRedcapDateTime(
            resting.restingHrTime ?? resting.activityEndTime,
          ),
        },
      });

      for (final act in labActivities) {
        final timed = !act.isSkipped;
        final incident = [
          if (act.incident != null && act.incident!.trim().isNotEmpty)
            act.incident!.trim(),
          if (_endNote(act) != null) _endNote(act)!,
        ].join('. ');
        records.add({
          'record_id': participant.participantId,
          'redcap_event_name': participant.redcapEventName,
          'redcap_repeat_instrument': 'lab_activity',
          'redcap_repeat_instance': instances[act].toString(),
          'la_order': instances[act].toString(),
          'la_session_id': sessionId,
          if (act.compendiumCode != null) 'la_code': act.compendiumCode,
          'la_name': act.activityName ?? 'Actividad ${act.activityIndex}',
          if (act.met != null) 'la_mets': _formatMet(act.met!),
          if (timed) 'la_start': formatRedcapDateTime(act.activityStartTime),
          if (timed) 'la_end': formatRedcapDateTime(act.activityEndTime),
          if (act.plannedDurationSeconds != null)
            'la_planned_s': act.plannedDurationSeconds.toString(),
          'la_completed': ActivityCompletion.redcapCode(act.completion),
          if (act.rpe != null) 'la_rpe': act.rpe.toString(),
          if (incident.isNotEmpty) 'la_incident': incident,
          'lab_activity_complete': '2',
        });
      }
    }
    return records;
  }

  /// Instance of `lab_activity` of each attempt of [logs]: one per attempt
  /// that is not a calibration segment, numbered in the order of the
  /// session. The manifest records it (`redcap_instance`), so SAVES can send
  /// what it counts on the video to the same instance.
  static Map<ActivityLog, int> labActivityInstances(Iterable<ActivityLog> logs) {
    final instances = Map<ActivityLog, int>.identity();
    for (final log in logs) {
      if (log.isCalibration) continue;
      instances[log] = instances.length + 1;
    }
    return instances;
  }

  /// Why an attempt is not complete, for `la_incident`.
  static String? _endNote(ActivityLog act) {
    if (act.completion == ActivityCompletion.complete) return null;
    return switch (act.endReason) {
      'early' => 'Terminada antes de tiempo',
      'repeat' => 'Interrumpida para repetirla',
      'finish' => 'Interrumpida al finalizar la sesión',
      'interrupted' => 'Interrumpida: la aplicación se cerró',
      'skipped' => 'Saltada por el evaluador',
      'not_reached' => 'La sesión terminó antes de llegar a ella',
      _ => null,
    };
  }

  /// Attempt that counts for each activity: the last one done (complete or
  /// partial), or the last skipped one when none was done.
  static Map<int, ActivityLog> effectiveAttempts(List<ActivityLog> logs) {
    final result = <int, ActivityLog>{};
    for (final log in logs) {
      final previous = result[log.activityIndex];
      if (previous == null || !log.isSkipped || previous.isSkipped) {
        result[log.activityIndex] = log;
      }
    }
    return result;
  }

  /// Fields of the visit record that the protocol activities fill (the
  /// fitness tests of `physical_fitness`): done, start, effort before and
  /// after and the values typed by the evaluator.
  static List<Map<String, dynamic>> buildMappedFieldRecords({
    required List<ParticipantEntry> participants,
    required ActivityBattery battery,
    required List<ActivityLog> logs,
    Map<int, int> pendingRpeBefore = const {},
  }) {
    final effective = effectiveAttempts(logs);
    final values = <String, String>{};
    for (var index = 1; index <= battery.activities.length; index++) {
      final mapping = battery.activityAt(index)!.redcap;
      if (mapping == null) continue;
      final log = effective[index];
      final done = log != null && !log.isSkipped;
      if (mapping.doneField != null) values[mapping.doneField!] = done ? '1' : '0';
      if (!done) continue;
      if (mapping.startField != null) {
        values[mapping.startField!] = formatRedcapDateTime(log.activityStartTime);
      }
      final before = log.rpeBefore ?? pendingRpeBefore[index];
      if (mapping.rpeBeforeField != null && before != null) {
        values[mapping.rpeBeforeField!] = before.toString();
      }
      if (mapping.rpeAfterField != null && log.rpe != null) {
        values[mapping.rpeAfterField!] = log.rpe.toString();
      }
      for (final field in mapping.fields) {
        final typed = log.fieldValues[field.field];
        final value = typed ?? field.defaultValue;
        if (value == null || value.trim().isEmpty) continue;
        if (field.validate(value) != null) continue;
        values[field.field] = field.normalize(value);
      }
    }
    if (values.isEmpty) return const [];
    return [
      for (final participant in participants)
        {
          'record_id': participant.participantId,
          'redcap_event_name': participant.redcapEventName,
          ...values,
        },
    ];
  }

  /// Everything a session sends to REDCap, in four imports so that one
  /// that fails (an instrument not set up for the event) does not stop the
  /// others: the protocol summary, the session, one `lab_activity` per
  /// attempt (a repeating instrument) and the fields of the fitness tests.
  /// [notReached] are the activities of the protocol the session never got
  /// to, as skipped logs.
  static List<List<Map<String, dynamic>>> buildSessionImports({
    required List<ParticipantEntry> participants,
    required String sessionId,
    required ActivityBattery? battery,
    required DateTime sessionStartTime,
    required DateTime sessionEndTime,
    required List<ActivityLog> logs,
    List<ActivityLog> notReached = const [],
    int? cameras,
    String? notes,
    String? operator,
    Map<int, int> pendingRpeBefore = const {},
  }) {
    final effective = effectiveAttempts(logs)
        .values
        .where((l) => !l.isSkipped && !l.isCalibration)
        .toList()
      ..sort((a, b) => a.activityStartTime.compareTo(b.activityStartTime));
    final totalProtocol =
        sessionEndTime.difference(sessionStartTime).inMilliseconds / 1000.0;
    final totalActivity =
        effective.fold<double>(0, (sum, l) => sum + l.durationSeconds);

    final summary = buildFlatProtocolRecords(
      participants: participants,
      sessionStartTime: sessionStartTime,
      sessionEndTime: sessionEndTime,
      activities: effective,
      totalProtocolSeconds: totalProtocol,
      totalActivitySeconds: totalActivity,
      totalTransitionSeconds:
          (totalProtocol - totalActivity).clamp(0.0, double.infinity),
      totalStations: effective.length,
    );

    final detail = buildLabActivityRecords(
      participants: participants,
      sessionId: sessionId,
      protocolId: battery?.protocolId,
      activities: logs,
      notDone: notReached,
      sessionStartTime: sessionStartTime,
      cameras: cameras,
      operator: operator,
      notes: notes,
    );

    final mapped = battery == null
        ? const <Map<String, dynamic>>[]
        : buildMappedFieldRecords(
            participants: participants,
            battery: battery,
            logs: logs,
            pendingRpeBefore: pendingRpeBefore,
          );

    bool repeating(Map<String, dynamic> r) => r.containsKey('redcap_repeat_instrument');
    return [
      summary,
      [for (final r in detail) if (!repeating(r)) r],
      [for (final r in detail) if (repeating(r)) r],
      mapped,
    ];
  }

  /// Names of the imports of [buildSessionImports], for the evaluator.
  static const sessionImportNames = [
    'Resumen del protocolo (protocol_feasibility)',
    'Sesión (wearable_session)',
    'Actividades (lab_activity)',
    'Condición física',
  ];

  /// [error] of an import of [records], with what to change in the REDCap
  /// project when the cause is known and the button that sends it again.
  static String explainImportError(String error, List<Map<String, dynamic>> records,
      {String retry = '«Reintentar REDCap»'}) {
    final repeating = {
      for (final r in records)
        if (r['redcap_repeat_instrument'] != null) r['redcap_repeat_instrument'].toString(),
    };
    if (repeating.isNotEmpty && RegExp('repeat|repet', caseSensitive: false).hasMatch(error)) {
      final events = {for (final r in records) r['redcap_event_name']?.toString() ?? ''}..remove('');
      return 'En REDCap, ${repeating.map((f) => '«$f»').join(' y ')} tiene que ser un instrumento '
          'repetible en ${events.isEmpty ? 'el evento' : events.join(', ')} '
          '(Project Setup → Repeating instruments and events). Después pulsa $retry. '
          'Respuesta de REDCap: $error';
    }
    return error;
  }

  /// REDCap `date_ymd` value in the computer's local time.
  static String formatRedcapDate(DateTime time) {
    final t = time.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}';
  }

  static String _formatMet(double met) =>
      met == met.roundToDouble() ? met.toStringAsFixed(1) : met.toString();

  /// [records] as the project takes them: without `redcap_event_name` in a
  /// project without events (or when a record has none).
  static List<Map<String, dynamic>> forProject(List<Map<String, dynamic>> records, {required bool withoutEvents}) => [
        for (final r in records)
          if (r.containsKey('redcap_event_name') &&
              (withoutEvents || (r['redcap_event_name']?.toString() ?? '').isEmpty))
            (Map.of(r)..remove('redcap_event_name'))
          else
            r,
      ];

  /// Sends [records] to REDCap. Returns null on success or the error message.
  static Future<String?> importRecords(List<Map<String, dynamic>> records) async {
    if (!isConfigured) {
      return 'No hay token de REDCap: ponlo en «Conexión con REDCap» de la pantalla de inicio.';
    }

    final Map<String, String> body = {
      'token': RedcapConnection.token,
      'content': 'record',
      'format': 'json',
      'type': 'flat',
      'overwriteBehavior': 'normal',
      'data': jsonEncode(forProject(records, withoutEvents: RedcapConnection.withoutEvents)),
      'returnContent': 'count',
      'returnFormat': 'json',
    };

    try {
      final response = await http
          .post(
            Uri.parse(RedcapConnection.url),
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
