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

  /// The devices of one participant and those the session shares (the
  /// cameras), in their order.
  List<DeviceConfiguration> devicesOf(String participantId) => [
        for (final device in devices)
          if (device.participantId == null ||
              device.participantId == participantId)
            device,
      ];

  /// Participants with devices of their own, in the order of the setup.
  List<String> get participantIds {
    final ids = <String>[];
    for (final device in devices) {
      final id = device.participantId;
      if (id != null && !ids.contains(id)) ids.add(id);
    }
    return ids;
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
