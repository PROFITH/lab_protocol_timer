import '../models/activity_battery.dart';
import '../models/device_configuration.dart';
import '../models/protocol_configuration.dart';

/// Devices of the Research Monitor when the session has no sensor list.
const defaultProtocolConfiguration = ProtocolConfiguration(
  devices: [
    DeviceConfiguration(
      deviceId: 'polar_h10',
      deviceName: 'Polar H10',
      placement: 'chest',
      sensors: {
        'heart_rate',
        'rr',
        'acc',
        'ecg',
      },
    ),
    DeviceConfiguration(
      deviceId: 'camera',
      deviceName: 'Cámara',
      sensors: {
        'video',
      },
    ),
  ],
);

/// Signals the Research Monitor can show for each live device type.
///
/// The Verity Sense has no ECG, and its standard heart-rate service sends no
/// RR intervals (it is an optical sensor).
const liveCapabilitiesByType = <String, Set<String>>{
  'polar_h10': {'heart_rate', 'rr', 'acc', 'ecg'},
  'verity_sense': {'heart_rate', 'acc'},
};

/// Devices of the Research Monitor for a session: every sensor chosen in the
/// session setup, in the same order. Live sensors (Polar H10, Verity Sense)
/// and cameras can be connected; offline sensors are listed with their
/// placement and serial but record on their own. Without a sensor list the
/// default configuration (H10 and one camera) is used.
ProtocolConfiguration protocolConfigurationFor(ActivityBattery? battery) {
  final sensors = battery?.sensors ?? const <SessionSensor>[];
  if (sensors.isEmpty) return defaultProtocolConfiguration;

  return ProtocolConfiguration(
    devices: [
      for (final sensor in sensors)
        DeviceConfiguration(
          deviceId: sensor.sensorId,
          deviceName: sensor.deviceName,
          type: sensor.type,
          connection: sensor.connection,
          placement: sensor.placement,
          placementLabel: sensor.placementLabel,
          serial: sensor.hasSerial ? sensor.serial!.trim() : null,
          sensors: switch (sensor.connection) {
            'video' => const {'video'},
            'live' => liveCapabilitiesByType[sensor.type] ?? const {},
            _ => const {},
          },
        ),
    ],
  );
}
