class SyncWindow {
  final String eventId;

  /// `auto_sync` (the timer gave the cue), `manual_sync` (the operator
  /// asked for it) or older types.
  final String eventType;
  final int activityIndex;
  final String phase;
  final DateTime windowStart;
  final DateTime windowEnd;

  /// `clap` or `jump`; null in sessions saved before it was recorded.
  final String? syncKind;

  /// When the participant was told to clap or jump (the go after 3-2-1).
  /// The impact comes a reaction time later.
  final DateTime? cueTime;

  const SyncWindow({
    required this.eventId,
    required this.eventType,
    required this.activityIndex,
    required this.phase,
    required this.windowStart,
    required this.windowEnd,
    this.syncKind,
    this.cueTime,
  });

  Duration get duration => windowEnd.difference(windowStart);

  Map<String, dynamic> toJson() {
    return {
      'event_id': eventId,
      'event_type': eventType,
      'activity_index': activityIndex,
      'phase': phase,
      'window_start_time_utc': windowStart.toUtc().toIso8601String(),
      'window_end_time_utc': windowEnd.toUtc().toIso8601String(),
      if (syncKind != null) 'sync_kind': syncKind,
      if (cueTime != null) 'cue_time_utc': cueTime!.toUtc().toIso8601String(),
    };
  }

  factory SyncWindow.fromJson(Map<String, dynamic> json) {
    return SyncWindow(
      eventId: json['event_id'] as String,
      eventType: json['event_type'] as String,
      activityIndex: json['activity_index'] as int,
      phase: json['phase'] as String,
      // Sessions saved before manifest 1.1 use window_start / window_end.
      windowStart: DateTime.parse(
        (json['window_start_time_utc'] ?? json['window_start']) as String,
      ).toUtc(),
      windowEnd: DateTime.parse(
        (json['window_end_time_utc'] ?? json['window_end']) as String,
      ).toUtc(),
      syncKind: json['sync_kind'] as String?,
      cueTime: json['cue_time_utc'] == null
          ? null
          : DateTime.parse(json['cue_time_utc'] as String).toUtc(),
    );
  }

  static const String csvHeader =
      'event_id,event_type,activity_index,phase,'
      'window_start_time_utc,window_end_time_utc,sync_kind,cue_time_utc';

  String toCsvRow() {
    return [
      eventId,
      eventType,
      activityIndex,
      phase,
      windowStart.toUtc().toIso8601String(),
      windowEnd.toUtc().toIso8601String(),
      syncKind ?? '',
      cueTime?.toUtc().toIso8601String() ?? '',
    ].join(',');
  }
}
