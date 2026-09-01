class PolarHrSample {
  final DateTime timestamp;
  final String participantId;
  final int activityIndex;
  final String phaseName;
  final int heartRateBpm;
  final List<int> rrIntervalsMs;

  const PolarHrSample({
    required this.timestamp,
    required this.participantId,
    required this.activityIndex,
    required this.phaseName,
    required this.heartRateBpm,
    required this.rrIntervalsMs,
  });

  static const String csvHeader =
      'timestamp_iso,participant_id,activity_index,phase_name,hr_bpm,rr_intervals_ms';

  String toCsvRow() {
    final rrFormatted = rrIntervalsMs.isEmpty ? '' : rrIntervalsMs.join(';');
    return '${timestamp.toIso8601String()},$participantId,$activityIndex,$phaseName,$heartRateBpm,"$rrFormatted"';
  }

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'participantId': participantId,
        'activityIndex': activityIndex,
        'phaseName': phaseName,
        'heartRateBpm': heartRateBpm,
        'rrIntervalsMs': rrIntervalsMs,
      };

  factory PolarHrSample.fromJson(Map<String, dynamic> json) => PolarHrSample(
        timestamp: DateTime.parse(json['timestamp']),
        participantId: json['participantId'] ?? '',
        activityIndex: json['activityIndex'] ?? 1,
        phaseName: json['phaseName'] ?? '',
        heartRateBpm: json['heartRateBpm'] ?? 0,
        rrIntervalsMs: List<int>.from(json['rrIntervalsMs'] ?? []),
      );
}