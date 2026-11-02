/// One notification of the BLE Heart Rate Service: the heart rate the
/// sensor's firmware estimates and, on the H10, the RR intervals.
///
/// [hrSource] says where that estimate comes from, because every Polar
/// model computes it from a different signal: `h10_ecg_firmware` (the H10
/// derives it from the ECG), `verity_ppg_firmware` (the Verity Sense from
/// the PPG), `polar_firmware` (unknown model). The PPI rows of the Verity
/// carry their own rate, `verity_ppi_firmware`.
class PolarHrSample {
  final DateTime timestamp;
  final String participantId;
  final int activityIndex;
  final String phaseName;
  final int heartRateBpm;
  final List<int> rrIntervalsMs;
  final String hrSource;

  const PolarHrSample({
    required this.timestamp,
    required this.participantId,
    required this.activityIndex,
    required this.phaseName,
    required this.heartRateBpm,
    required this.rrIntervalsMs,
    this.hrSource = unknownSource,
  });

  static const String unknownSource = 'polar_firmware';

  /// Source code for a device type of the session (`polar_h10`,
  /// `verity_sense`) or, without one, for the name the device advertises
  /// (`Polar H10 ABC123`, `Polar Sense ABC123`).
  static String sourceFor({String deviceType = '', String deviceName = ''}) {
    final name = deviceName.toLowerCase();
    if (deviceType == 'polar_h10' || name.contains('h10') || name.contains('h9')) {
      return 'h10_ecg_firmware';
    }
    if (deviceType == 'verity_sense' || name.contains('sense') || name.contains('oh1')) {
      return 'verity_ppg_firmware';
    }
    return unknownSource;
  }

  static const String csvHeader =
      'timestamp_iso,participant_id,activity_index,phase_name,hr_bpm,rr_intervals_ms,hr_source';

  String toCsvRow() {
    final rrFormatted = rrIntervalsMs.isEmpty ? '' : rrIntervalsMs.join(';');
    return '${timestamp.toIso8601String()},$participantId,$activityIndex,$phaseName,$heartRateBpm,"$rrFormatted",$hrSource';
  }

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'participantId': participantId,
        'activityIndex': activityIndex,
        'phaseName': phaseName,
        'heartRateBpm': heartRateBpm,
        'rrIntervalsMs': rrIntervalsMs,
        'hrSource': hrSource,
      };

  factory PolarHrSample.fromJson(Map<String, dynamic> json) => PolarHrSample(
        timestamp: DateTime.parse(json['timestamp']),
        participantId: json['participantId'] ?? '',
        activityIndex: json['activityIndex'] ?? 1,
        phaseName: json['phaseName'] ?? '',
        heartRateBpm: json['heartRateBpm'] ?? 0,
        rrIntervalsMs: List<int>.from(json['rrIntervalsMs'] ?? []),
        hrSource: json['hrSource']?.toString() ?? unknownSource,
      );
}
