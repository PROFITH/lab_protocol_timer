import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lab_protocol_timer/models/polar_hr_sample.dart';
import 'package:lab_protocol_timer/services/polar_ble_service.dart';

/// A PMD data notification: type, sensor time of the last sample (ns),
/// frame type byte (0x80 = delta coded) and the payload.
Uint8List frame(int type, int timestampNs, int frameTypeByte, List<int> payload) {
  final header = ByteData(10)
    ..setUint8(0, type)
    ..setUint64(1, timestampNs, Endian.little)
    ..setUint8(9, frameTypeByte);
  return Uint8List.fromList([...header.buffer.asUint8List(), ...payload]);
}

List<int> signedBytes(int value, int bytes) => [for (var b = 0; b < bytes; b++) (value >> (8 * b)) & 0xFF];

/// Delta coded content as the Polar sensors send it: the reference sample
/// (one signed little-endian integer per channel) and one block of deltas
/// of [deltaBits] bits each, packed LSB first.
List<int> deltaContent({
  required List<int> reference,
  required List<List<int>> deltas,
  required int resolutionBits,
  required int deltaBits,
}) {
  final bytesPerChannel = (resolutionBits + 7) ~/ 8;
  final out = <int>[for (final v in reference) ...signedBytes(v, bytesPerChannel)];
  out..add(deltaBits)..add(deltas.length);
  final bits = <int>[];
  for (final sample in deltas) {
    for (final delta in sample) {
      for (var i = 0; i < deltaBits; i++) {
        bits.add((delta >> i) & 1);
      }
    }
  }
  for (var i = 0; i < bits.length; i += 8) {
    var byte = 0;
    for (var b = 0; b < 8 && i + b < bits.length; b++) {
      byte |= bits[i + b] << b;
    }
    out.add(byte);
  }
  return out;
}

/// Parameters of a start response: the "more" flag, then the sample rate
/// and the factor the sensor reports.
Uint8List startResponse({required int sampleRateHz, required double factor}) {
  final f = ByteData(4)..setFloat32(0, factor, Endian.little);
  return Uint8List.fromList([
    0x00,
    PolarBleService.pmdSettingSampleRate, 0x01, ...signedBytes(sampleRateHz, 2),
    PolarBleService.pmdSettingFactor, 0x01, ...f.buffer.asUint8List(),
  ]);
}

void main() {
  const second = 1000000000;

  group('PPG frames of the Verity Sense', () {
    test('raw type 0: four channels of three bytes per sample', () {
      final service = PolarBleService();
      final payload = [
        ...signedBytes(123456, 3), ...signedBytes(-2000, 3), ...signedBytes(7, 3), ...signedBytes(65535, 3),
        ...signedBytes(123460, 3), ...signedBytes(-1990, 3), ...signedBytes(9, 3), ...signedBytes(65530, 3),
      ];
      service.handlePmdDataForTest(frame(PolarBleService.pmdTypePpg, 100 * second, 0x00, payload));

      final samples = service.recordedPpgSamples;
      expect(samples.length, 2);
      expect([samples[0].ppg0, samples[0].ppg1, samples[0].ppg2, samples[0].ambient], [123456, -2000, 7, 65535]);
      expect([samples[1].ppg0, samples[1].ppg1, samples[1].ppg2, samples[1].ambient], [123460, -1990, 9, 65530]);
      // The frame time is that of the last sample; the first is one period before (55 Hz).
      expect(samples[1].sensorTimeNs, 100 * second);
      expect(samples[0].sensorTimeNs, closeTo(100 * second - second / 55, 2));
      // The clock mapper took the frame as an observation.
      expect(service.clockObservations.single.measurementType, PolarBleService.pmdTypePpg);
    });

    test('delta coded type 0: 22-bit reference and 10-bit deltas', () {
      final service = PolarBleService();
      final content = deltaContent(
        reference: [100000, 200000, 300000, 4000],
        deltas: [
          [5, -3, 7, 1],
          [511, -512, 0, 2],
        ],
        resolutionBits: 22,
        deltaBits: 10,
      );
      service.handlePmdDataForTest(frame(PolarBleService.pmdTypePpg, 7 * second, 0x80, content));

      final rows = [for (final s in service.recordedPpgSamples) [s.ppg0, s.ppg1, s.ppg2, s.ambient]];
      expect(rows, [
        [100000, 200000, 300000, 4000],
        [100005, 199997, 300007, 4001],
        [100516, 199485, 300007, 4003],
      ]);
      expect(service.recordedPpgSamples.last.sensorTimeNs, 7 * second);
      expect(PolarPpgSample.csvHeader, contains('ppg0,ppg1,ppg2,ambient,sensor_time_ns'));
      expect(service.recordedPpgSamples.first.toCsvRow(), contains(',100000,200000,300000,4000,'));
    });

    test('other PPG frame types are ignored', () {
      final service = PolarBleService();
      service.handlePmdDataForTest(frame(PolarBleService.pmdTypePpg, second, 0x07, List.filled(24, 0)));
      expect(service.recordedPpgSamples, isEmpty);
    });
  });

  group('gyroscope and magnetometer frames', () {
    test('type 0 deltas times the factor reported at the start', () {
      final service = PolarBleService()
        ..applyStartResponseForTest(PolarBleService.pmdTypeGyro, startResponse(sampleRateHz: 52, factor: 0.061))
        ..applyStartResponseForTest(PolarBleService.pmdTypeMagnetometer, startResponse(sampleRateHz: 50, factor: 0.0015259));
      expect(service.gyroSampleRateHz, 52);
      expect(service.magSampleRateHz, 50);

      service.handlePmdDataForTest(frame(
        PolarBleService.pmdTypeGyro,
        3 * second,
        0x80,
        deltaContent(reference: [1000, -2000, 32767], deltas: [
          [1, -1, 0]
        ], resolutionBits: 16, deltaBits: 4),
      ));
      final gyro = service.recordedGyroSamples;
      expect(gyro.length, 2);
      expect(gyro[0].xDps, closeTo(61.0, 0.001));
      expect(gyro[1].yDps, closeTo(-2001 * 0.061, 0.001));
      expect(gyro[1].zDps, closeTo(32767 * 0.061, 0.01));
      expect(gyro[1].sensorTimeNs, 3 * second);
      expect(gyro[0].sensorTimeNs, closeTo(3 * second - second / 52, 2));

      service.handlePmdDataForTest(frame(
        PolarBleService.pmdTypeMagnetometer,
        4 * second,
        0x80,
        deltaContent(reference: [100, 200, -300], deltas: const [], resolutionBits: 16, deltaBits: 8),
      ));
      final mag = service.recordedMagSamples.single;
      expect(mag.xGauss, closeTo(100 * 0.0015259, 1e-6));
      expect(mag.zGauss, closeTo(-300 * 0.0015259, 1e-6));
      expect(PolarGyroSample.csvHeader, endsWith('gyro_x_dps,gyro_y_dps,gyro_z_dps,sensor_time_ns'));
      expect(PolarMagSample.csvHeader, endsWith('mag_x_gauss,mag_y_gauss,mag_z_gauss,sensor_time_ns'));
    });

    test('magnetometer type 1 comes in milligauss with a calibration channel', () {
      final service = PolarBleService();
      service.handlePmdDataForTest(frame(
        PolarBleService.pmdTypeMagnetometer,
        second,
        0x81,
        deltaContent(reference: [1500, -2500, 500, 2], deltas: const [], resolutionBits: 16, deltaBits: 8),
      ));
      final mag = service.recordedMagSamples.single;
      expect([mag.xGauss, mag.yGauss, mag.zGauss], [1.5, -2.5, 0.5]);
    });

    test('raw (uncompressed) gyro frames are not a Polar format', () {
      final service = PolarBleService();
      service.handlePmdDataForTest(frame(PolarBleService.pmdTypeGyro, second, 0x00, List.filled(6, 1)));
      expect(service.recordedGyroSamples, isEmpty);
    });
  });

  group('PPI frames of the Verity Sense', () {
    final pulses = [
      // hr, ppi ms (LE), error estimate ms (LE), flags
      [70, 0x59, 0x03, 0x0A, 0x00, 0x06],
      [72, 0x41, 0x03, 0x05, 0x00, 0x01],
    ];

    test('without a sensor time the pulses share the arrival and keep their order', () {
      final service = PolarBleService();
      service.handlePmdDataForTest(frame(PolarBleService.pmdTypePpi, 0, 0x00, [for (final p in pulses) ...p]));

      final rows = service.recordedPpiSamples;
      expect(rows.length, 2);
      expect(rows[0].ppiMs, 857);
      expect(rows[0].heartRateBpm, 70);
      expect(rows[0].errorEstimateMs, 10);
      expect(rows[0].blocker, isFalse);
      expect(rows[0].skinContact, isTrue);
      expect(rows[0].skinContactSupported, isTrue);
      expect(rows[1].ppiMs, 833);
      expect(rows[1].blocker, isTrue);
      expect(rows[1].skinContact, isFalse);
      expect([rows[0].indexInFrame, rows[1].indexInFrame], [0, 1]);
      expect(rows[0].sensorTimeNs, isNull);
      expect(rows[0].timestamp, rows[1].timestamp);
      // A buffered stream says nothing about the clocks.
      expect(service.clockObservations, isEmpty);
      expect(rows[0].toCsvRow(), endsWith(',857,70,10,0,1,1,0,,verity_ppi_firmware'));
    });

    test('with a sensor time the last pulse gets it and the others go back by their intervals', () {
      final service = PolarBleService();
      service.handlePmdDataForTest(frame(PolarBleService.pmdTypePpi, 10 * second, 0x00, [for (final p in pulses) ...p]));

      final rows = service.recordedPpiSamples;
      expect(rows[1].sensorTimeNs, 10 * second);
      expect(rows[0].sensorTimeNs, 10 * second - 833 * 1000000);
      expect(rows[1].timestamp.difference(rows[0].timestamp).inMilliseconds, 833);
    });
  });

  group('heart-rate source', () {
    test('named after the device that estimates it', () {
      expect(PolarHrSample.sourceFor(deviceType: 'polar_h10'), 'h10_ecg_firmware');
      expect(PolarHrSample.sourceFor(deviceType: 'verity_sense'), 'verity_ppg_firmware');
      expect(PolarHrSample.sourceFor(deviceName: 'Polar H10 12345678'), 'h10_ecg_firmware');
      expect(PolarHrSample.sourceFor(deviceName: 'Polar Sense 87654321'), 'verity_ppg_firmware');
      expect(PolarHrSample.sourceFor(), 'polar_firmware');

      final service = PolarBleService()..deviceType = 'verity_sense';
      expect(service.hrSource, 'verity_ppg_firmware');
    });

    test('goes in the last column of the HR file and survives JSON', () {
      final sample = PolarHrSample(
        timestamp: DateTime.utc(2026, 10, 22, 9),
        participantId: '001',
        activityIndex: 2,
        phaseName: 'activity_main',
        heartRateBpm: 68,
        rrIntervalsMs: const [880, 890],
        hrSource: 'h10_ecg_firmware',
      );
      expect(PolarHrSample.csvHeader, endsWith(',hr_bpm,rr_intervals_ms,hr_source'));
      expect(sample.toCsvRow(), endsWith(',68,"880;890",h10_ecg_firmware'));
      expect(PolarHrSample.fromJson(sample.toJson()).hrSource, 'h10_ecg_firmware');
      // Rows written before the column existed read as unknown.
      expect(PolarHrSample.fromJson(sample.toJson()..remove('hrSource')).hrSource, 'polar_firmware');
    });
  });

  group('start commands and the clock log', () {
    test('a Verity stream asks for the preferred rate and range it offers', () {
      final offered = {
        PolarBleService.pmdSettingSampleRate: [26, 52, 104],
        PolarBleService.pmdSettingResolution: [16],
        PolarBleService.pmdSettingRange: [250, 500, 1000, 2000],
        PolarBleService.pmdSettingChannels: [3],
      };
      expect(
        PolarBleService.startCommandFor(PolarBleService.pmdTypeGyro, offered,
            preferredRateHz: PolarBleService.defaultGyroSampleRateHz,
            preferredRange: PolarBleService.preferredGyroRangeDps),
        [0x02, 0x05, 0x00, 0x01, 0x34, 0x00, 0x01, 0x01, 0x10, 0x00, 0x02, 0x01, 0xD0, 0x07, 0x04, 0x01, 0x03],
      );
      // Without a preference the highest offered value is taken.
      expect(
        PolarBleService.startCommandFor(PolarBleService.pmdTypeMagnetometer, {
          PolarBleService.pmdSettingSampleRate: [10, 20, 50, 100],
          PolarBleService.pmdSettingRange: [50],
        }, preferredRateHz: PolarBleService.defaultMagSampleRateHz),
        [0x02, 0x06, 0x00, 0x01, 0x32, 0x00, 0x02, 0x01, 0x32, 0x00],
      );
    });

    test('the clock log names every stream', () {
      const observation = PmdClockObservation(
        measurementType: PolarBleService.pmdTypeGyro,
        arrivalHostMicros: 1700000000000000,
        frameSensorNs: 5000000000,
        offsetMicros: 12,
      );
      expect(observation.toCsvRow(), contains(',gyro,5000000000,12'));
      expect(PolarBleService.pmdStreamNames.values, containsAll(['ecg', 'acc', 'ppg', 'ppi', 'gyro', 'mag']));
    });
  });
}
