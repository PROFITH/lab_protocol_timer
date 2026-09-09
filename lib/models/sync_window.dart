class SyncWindow {
  final String eventId;
  final String eventType;
  final int activityIndex;
  final String phase;
  final DateTime windowStart;
  final DateTime windowEnd;

  const SyncWindow({
    required this.eventId,
    required this.eventType,
    required this.activityIndex,
    required this.phase,
    required this.windowStart,
    required this.windowEnd,
  });

  Duration get duration => windowEnd.difference(windowStart);

  Map<String, dynamic> toJson() {
    return {
      'event_id': eventId,
      'event_type': eventType,
      'activity_index': activityIndex,
      'phase': phase,
      'window_start': windowStart.toUtc().toIso8601String(),
      'window_end': windowEnd.toUtc().toIso8601String(),
    };
  }

  factory SyncWindow.fromJson(Map<String, dynamic> json) {
    return SyncWindow(
      eventId: json['event_id'] as String,
      eventType: json['event_type'] as String,
      activityIndex: json['activity_index'] as int,
      phase: json['phase'] as String,
      windowStart: DateTime.parse(
        json['window_start'] as String,
      ).toUtc(),
      windowEnd: DateTime.parse(
        json['window_end'] as String,
      ).toUtc(),
    );
  }

  static const String csvHeader =
      'event_id,event_type,activity_index,phase,'
      'window_start,window_end';

  String toCsvRow() {
    return [
      eventId,
      eventType,
      activityIndex,
      phase,
      windowStart.toUtc().toIso8601String(),
      windowEnd.toUtc().toIso8601String(),
    ].join(',');
  }
}