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
}