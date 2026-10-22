class DeviceConfiguration {
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

  const DeviceConfiguration({
    required this.deviceId,
    required this.deviceName,
    this.sensors = const {},
    this.placement,
    String? type,
    String? connection,
    this.placementLabel,
    this.serial,
  })  : type = type ?? deviceId,
        connection = connection ??
            (deviceId == 'camera' ? 'video' : 'live');

  bool get isLive => connection == 'live';
  bool get isCamera => connection == 'video';

  bool hasSensor(String sensorId) {
    return sensors.contains(sensorId);
  }

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
    );
  }
}
