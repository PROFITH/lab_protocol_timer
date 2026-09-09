import '../models/device_configuration.dart';
import '../models/protocol_configuration.dart';

const defaultProtocolConfiguration = ProtocolConfiguration(
  devices: [
    DeviceConfiguration(
      deviceId: 'polar_h10',
      deviceName: 'Polar H10',
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