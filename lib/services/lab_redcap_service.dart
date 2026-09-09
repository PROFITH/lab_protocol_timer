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

class ActivityLog {
  /// Activity index
  final int activityIndex;

  /// Start/end of the main activity itself.
  final DateTime activityStartTime;
  final DateTime activityEndTime;

  /// Duration of the main activity in seconds.
  final double durationSeconds;

  ActivityLog({
    required this.activityIndex,
    required this.activityStartTime,
    required this.activityEndTime,
    required this.durationSeconds,
  });

  Map<String, dynamic> toJson() => {
        'activity_index': activityIndex,
        'activity_start_time_utc': activityStartTime.toUtc().toIso8601String(),
        'activity_end_time_utc': activityEndTime.toUtc().toIso8601String(),
        'duration_seconds': durationSeconds,
      };

  factory ActivityLog.fromJson(Map<String, dynamic> json) => ActivityLog(
        activityIndex: json['activity_index'] as int,
        activityStartTime: 
            DateTime.parse(
              json['activity_start_time_utc'] ??
                  json['activity_start_time'],
            ).toUtc(),
       activityEndTime:
            DateTime.parse(
              json['activity_end_time_utc'] ??
                  json['activity_end_time'],
            ).toUtc(),
        durationSeconds: (json['duration_seconds'] as num).toDouble(),
      );
}

class LabRedCapService {
  static const String _redcapUrl = String.fromEnvironment(
    'REDCAP_URL',
    defaultValue: 'https://tu-instancia-redcap.org/api/',
  );

  static const String _apiToken = String.fromEnvironment(
    'REDCAP_TOKEN',
    defaultValue: '',
  );

  static Future<bool> sendFlatProtocolSession({
    required List<ParticipantEntry> participants,
    required DateTime sessionStartTime,
    required DateTime sessionEndTime,
    required List<ActivityLog> activities,
    required double totalProtocolSeconds,
    required double totalActivitySeconds,
    required double totalTransitionSeconds,
    required int totalStations,
  }) async {
    // 1. Create a registry per participant (shared timings - parallel assessment)
    final List<Map<String, dynamic>> records = [];

    for (final participant in participants) {
      final Map<String, dynamic> recordData = {
        'record_id': participant.participantId,
        'redcap_event_name': participant.redcapEventName,
        'session_start_time': sessionStartTime.toUtc().toIso8601String(),
        'session_end_time': sessionEndTime.toUtc().toIso8601String(),
        'lab_total_stations': totalStations,
        'total_protocol_seconds': totalProtocolSeconds.toStringAsFixed(2),
        'total_activity_seconds': totalActivitySeconds.toStringAsFixed(2),
        'total_transition_seconds': totalTransitionSeconds.toStringAsFixed(2),
        'protocol_feasibility_complete': '2',
      };

      for (final act in activities) {
        final idx = act.activityIndex;
        recordData['act_${idx}_start_time'] =
            act.activityStartTime.toUtc().toIso8601String();
        recordData['act_${idx}_end_time'] =
            act.activityEndTime.toUtc().toIso8601String();
      }

      records.add(recordData);
    }

    // 2. Batch call parameters
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
      final response = await http.post(
        Uri.parse(_redcapUrl),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: body,
      );

      if (response.statusCode == 200) {
        if (kDebugMode) {
          debugPrint('Sincronización Batch exitosa: ${response.body}');
        }
        return true;
      } else {
        if (kDebugMode) {
          debugPrint(
              'Error en REDCap HTTP ${response.statusCode}: ${response.body}');
        }
        return false;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Excepción al conectar con REDCap: $e');
      }
      return false;
    }
  }
}