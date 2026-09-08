class DeviceConfiguration {
  final String deviceId;
  final String deviceName;

  /// Sensors/capabilities that should be acquired from this device.
  final Set<String> sensors;

  const DeviceConfiguration({
    required this.deviceId,
    required this.deviceName,
    this.sensors = const {},
  });

  bool hasSensor(String sensorId) {
    return sensors.contains(sensorId);
  }

  Map<String, dynamic> toJson() {
    return {
      'deviceId': deviceId,
      'deviceName': deviceName,
      'sensors': sensors.toList(),
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
    );
  }
}