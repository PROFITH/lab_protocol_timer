class PolarAccSample {
  final DateTime timestamp;
  final String participantId;
  final String stationName;
  final int activityIndex;
  final int x; // en milli-g (mg)
  final int y;
  final int z;

  PolarAccSample({
    required this.timestamp,
    required this.participantId,
    required this.stationName,
    required this.activityIndex,
    required this.x,
    required this.y,
    required this.z,
  });

  static String get csvHeader =>
      'timestamp_iso,participant_id,station_name,activity_index,acc_x_mg,acc_y_mg,acc_z_mg';

  String toCsvRow() {
    return '${timestamp.toIso8601String()},$participantId,$stationName,$activityIndex,$x,$y,$z';
  }
}