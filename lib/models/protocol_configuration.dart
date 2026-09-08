import 'device_configuration.dart';

class ProtocolConfiguration {
  final List<DeviceConfiguration> devices;

  const ProtocolConfiguration({
    this.devices = const [],
  });

  DeviceConfiguration? deviceById(String deviceId) {
    for (final device in devices) {
      if (device.deviceId == deviceId) {
        return device;
      }
    }

    return null;
  }

  Map<String, dynamic> toJson() {
    return {
      'devices': devices
          .map((device) => device.toJson())
          .toList(),
    };
  }

  factory ProtocolConfiguration.fromJson(
    Map<String, dynamic> json,
  ) {
    final rawDevices =
        json['devices'] as List<dynamic>? ?? const [];

    return ProtocolConfiguration(
      devices: rawDevices
          .map(
            (device) => DeviceConfiguration.fromJson(
              Map<String, dynamic>.from(
                device as Map,
              ),
            ),
          )
          .toList(),
    );
  }
}