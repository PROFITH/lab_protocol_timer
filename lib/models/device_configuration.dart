class DeviceConfiguration {
  /// Unique in the session. It is the sensor ID of the session setup, with
  /// the participant appended (`polar_h10@002`) when several participants
  /// wear the same layout.
  final String deviceId;
  final String deviceName;

  /// Sensors/capabilities that should be acquired from this device.
  final Set<String> sensors;

  /// Body placement written to the session manifest (e.g. `chest`).
  final String? placement;

  /// Key of `sensorTypes` (`polar_h10`, `verity_sense`, `camera`, `ax3`...).
  /// Devices of older configurations carry their ID as type.
  final String type;

  /// `live` (connected to the Research Monitor), `video` or `offline`
  /// (records on its own; shown in the list but not connectable).
  final String connection;

  /// Placement as shown to the team («Muñeca no dominante»).
  final String? placementLabel;

  final String? serial;

  /// ID of the sensor in the session setup (`polar_h10`): the key of the
  /// participant's manifest and the part of the file names SAVES matches.
  /// Equals [deviceId] unless the session has several participants.
  final String sensorId;

  /// Participant who wears the device. Null for the devices the session
  /// shares (cameras) and for sessions without participant assignment.
  final String? participantId;

  /// An offline device ticked as initialized in the waiting room.
  final bool initialized;

  const DeviceConfiguration({
    required this.deviceId,
    required this.deviceName,
    this.sensors = const {},
    this.placement,
    String? type,
    String? connection,
    this.placementLabel,
    this.serial,
    String? sensorId,
    this.participantId,
    this.initialized = false,
  })  : type = type ?? deviceId,
        connection = connection ??
            (deviceId == 'camera' ? 'video' : 'live'),
        sensorId = sensorId ?? deviceId;

  bool get isLive => connection == 'live';
  bool get isCamera => connection == 'video';

  bool hasSensor(String sensorId) {
    return sensors.contains(sensorId);
  }

  /// Name, placement and, when the session has several participants, whose
  /// device it is («Polar H10 · Pecho · 002»).
  String get label => [
        deviceName,
        if (placementLabel != null) placementLabel!,
        if (participantId != null && sensorId != deviceId) participantId!,
      ].join(' · ');

  Map<String, dynamic> toJson() {
    return {
      'deviceId': deviceId,
      'deviceName': deviceName,
      'sensors': sensors.toList(),
      if (placement != null) 'placement': placement,
      'type': type,
      'connection': connection,
      if (placementLabel != null) 'placementLabel': placementLabel,
      if (serial != null) 'serial': serial,
      if (sensorId != deviceId) 'sensorId': sensorId,
      if (participantId != null) 'participantId': participantId,
      if (initialized) 'initialized': true,
    };
  }

  factory DeviceConfiguration.fromJson(
    Map<String, dynamic> json,
  ) {
    return DeviceConfiguration(
      deviceId: json['deviceId'] as String,
      deviceName: json['deviceName'] as String,
      sensors: Set<String>.from(
        json['sensors'] as List<dynamic>? ?? const [],
      ),
      placement: json['placement'] as String?,
      type: json['type'] as String?,
      connection: json['connection'] as String?,
      placementLabel: json['placementLabel'] as String?,
      serial: json['serial'] as String?,
      sensorId: json['sensorId'] as String?,
      participantId: json['participantId'] as String?,
      initialized: json['initialized'] == true,
    );
  }
}
