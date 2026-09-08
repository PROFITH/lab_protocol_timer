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
}