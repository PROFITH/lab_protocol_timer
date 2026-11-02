import '../models/activity_battery.dart';
import '../models/device_configuration.dart';
import '../models/protocol_configuration.dart';
import '../services/lab_redcap_service.dart';

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

/// Signals recorded from each live device type: every signal the device
/// offers over Bluetooth, so the algorithms can use all of them.
///
/// The H10 gives heart rate with RR intervals (from its ECG), ECG and ACC.
/// The Verity Sense gives heart rate (from its PPG, without RR), ACC, the raw
/// PPG, the pulse-to-pulse intervals of Polar's PPI algorithm, gyroscope and
/// magnetometer. The Research Monitor charts HR, RR, ACC and ECG; the rest
/// only go to the files.
const liveCapabilitiesByType = <String, Set<String>>{
  'polar_h10': {'heart_rate', 'rr', 'acc', 'ecg'},
  'verity_sense': {'heart_rate', 'acc', 'ppg', 'ppi', 'gyro', 'mag'},
};

/// Devices of the Research Monitor for a session: every sensor of the
/// session setup, participant by participant, and the cameras, which the
/// session shares. Live sensors (Polar H10, Verity Sense) and cameras can
/// be connected; offline sensors are listed with their placement and serial
/// but record on their own. Without a sensor list the default configuration
/// (H10 and one camera) is used.
///
/// Without [participants] (or with one) each device keeps its sensor ID.
/// With several, each participant wears the sensors of the layout (or
/// their own list, with their serials) and the device IDs carry the
/// participant (`polar_h10@002`) so the monitor tells them apart; the
/// files and the manifest of each participant keep the plain sensor ID.
ProtocolConfiguration protocolConfigurationFor(
  ActivityBattery? battery, [
  List<ParticipantEntry> participants = const [],
]) {
  // Devices only for the free-living days are not in the session.
  final layout = [
    for (final s in battery?.sensors ?? const <SessionSensor>[])
      if (s.inLab) s,
  ];
  if (layout.isEmpty) return defaultProtocolConfiguration;

  DeviceConfiguration device(SessionSensor sensor, {String? participantId, bool several = false}) =>
      DeviceConfiguration(
        deviceId: several ? '${sensor.sensorId}@$participantId' : sensor.sensorId,
        sensorId: sensor.sensorId,
        participantId: participantId,
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
      );

  if (participants.isEmpty) {
    return ProtocolConfiguration(
      devices: [for (final sensor in layout) device(sensor)],
    );
  }

  final several = participants.length > 1;
  return ProtocolConfiguration(
    devices: [
      for (final participant in participants)
        for (final sensor in participant.sensorsOr(layout))
          if (sensor.inLab)
          device(sensor, participantId: participant.participantId, several: several),
      for (final sensor in layout)
        if (sensor.connection == 'video') device(sensor),
    ],
  );
}
