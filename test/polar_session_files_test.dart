import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lab_protocol_timer/models/polar_hr_sample.dart';
import 'package:lab_protocol_timer/services/polar_ble_service.dart';
import 'package:lab_protocol_timer/windows/polar_session_files.dart';

PolarHrSample hr(DateTime t, int bpm, [List<int> rr = const []]) => PolarHrSample(
      timestamp: t,
      participantId: '001',
      activityIndex: 1,
      phaseName: 'activity_main',
      heartRateBpm: bpm,
      rrIntervalsMs: rr,
    );

void main() {
  group('resting heart rate', () {
    final t0 = DateTime.utc(2026, 10, 21, 9);

    test('from the RR intervals, without artefacts', () {
      final samples = [
        for (var i = 0; i < 100; i++) hr(t0.add(Duration(seconds: i)), 61, [1000 + (i % 5) * 4 - 8]),
        // A missed beat and an extra one.
        hr(t0.add(const Duration(seconds: 101)), 61, [2000]),
        hr(t0.add(const Duration(seconds: 102)), 61, [450]),
      ];
      final result = RestingHeartRate.compute(samples)!;
      expect(result.method, 'rr');
      expect(result.bpm, 60);
      expect(result.count, 100);
    });

    test('from the heart rate when the sensor sends no RR', () {
      final samples = [for (var i = 0; i < 30; i++) hr(t0.add(Duration(seconds: i)), 55 + i % 3)];
      final result = RestingHeartRate.compute(samples)!;
      expect(result.method, 'hr');
      expect(result.bpm, 56);
    });

    test('nothing with too few data', () {
      expect(RestingHeartRate.compute([hr(t0, 60, [1000])]), isNull);
      expect(RestingHeartRate.compute(const []), isNull);
    });
  });

  test('the Verity Sense streams get their own files', () async {
    final dir = await Directory.systemTemp.createTemp('lpt_polar_');
    final service = PolarBleService();
    final files = PolarSessionFiles(directory: dir.path, stamp: '20261022_100000', deviceId: 'verity_arm', service: service)
      ..start();
    final now = DateTime.now().toUtc();
    service.recordedPpgSamples.add(PolarPpgSample(
      timestamp: now, participantId: '001', activityIndex: 1, phaseName: 'activity_main',
      ppg0: 100000, ppg1: 100100, ppg2: 100200, ambient: 4000, sensorTimeNs: 5000000000,
    ));
    service.recordedPpiSamples.add(PolarPpiSample(
      timestamp: now, participantId: '001', activityIndex: 1, phaseName: 'activity_main',
      ppiMs: 850, heartRateBpm: 70, errorEstimateMs: 8, blocker: false, skinContact: true,
      skinContactSupported: true, indexInFrame: 0,
    ));
    service.recordedGyroSamples.add(PolarGyroSample(
      timestamp: now, participantId: '001', activityIndex: 1, phaseName: 'activity_main',
      xDps: 1.5, yDps: -2.5, zDps: 0.25, sensorTimeNs: 5000000000,
    ));
    service.recordedMagSamples.add(PolarMagSample(
      timestamp: now, participantId: '001', activityIndex: 1, phaseName: 'activity_main',
      xGauss: 0.1, yGauss: 0.2, zGauss: -0.3, sensorTimeNs: 5000000000,
    ));
    files.drain();
    expect(service.recordedPpgSamples, isEmpty);
    expect(service.recordedGyroSamples, isEmpty);
    expect([files.ppgRows, files.ppiRows, files.gyroRows, files.magRows], [1, 1, 1, 1]);

    final written = (await files.stop()).map((p) => p.split(Platform.pathSeparator).last).toList();
    expect(written, containsAll([
      'polar_ppg_verity_arm_20261022_100000.csv',
      'polar_ppi_verity_arm_20261022_100000.csv',
      'polar_gyro_verity_arm_20261022_100000.csv',
      'polar_mag_verity_arm_20261022_100000.csv',
    ]));
    expect(written.where((n) => n.startsWith('polar_hr_') || n.startsWith('polar_acc_') || n.startsWith('polar_ecg_')), isEmpty);
    final ppi = File('${dir.path}${Platform.pathSeparator}polar_ppi_verity_arm_20261022_100000.csv').readAsLinesSync();
    expect(ppi.first, PolarPpiSample.csvHeader);
    expect(ppi[1], endsWith(',850,70,8,0,1,1,0,,verity_ppi_firmware'));
    final gyro = File('${dir.path}${Platform.pathSeparator}polar_gyro_verity_arm_20261022_100000.csv').readAsLinesSync();
    expect(gyro[1], endsWith(',1.5,-2.5,0.25,5000000000'));
    await dir.delete(recursive: true);
  });

  test('the files of a session get the samples once and in order', () async {
    final dir = await Directory.systemTemp.createTemp('lpt_polar_');
    final service = PolarBleService();
    // Before the session: not part of it.
    service.recordedSamples.add(hr(DateTime.now().toUtc(), 70, [850]));
    final files = PolarSessionFiles(directory: dir.path, stamp: '20261021_090000', deviceId: 'polar_h10', service: service)
      ..start();
    expect(service.recordedSamples, isEmpty);

    final now = DateTime.now().toUtc();
    for (var i = 0; i < 40; i++) {
      service.recordedSamples.add(hr(now.add(Duration(milliseconds: 900 * i)), 66, [900, 905]));
    }
    for (var i = 0; i < 200; i++) {
      service.recordedAccelerationSamples.add(PolarAccelerationSample(
        timestamp: now.add(Duration(milliseconds: 5 * i)),
        participantId: '001',
        activityIndex: 1,
        phaseName: 'activity_main',
        xMg: 1,
        yMg: -2,
        zMg: 1000,
        sensorTimeNs: 1000000000 + 5000000 * i,
      ));
    }
    files.drain();
    expect(service.recordedSamples, isEmpty);
    expect(service.recordedAccelerationSamples, isEmpty);
    files.drain();

    final resting = files.restingHeartRate(now.subtract(const Duration(seconds: 1)), now.add(const Duration(minutes: 1)));
    expect(resting!.method, 'rr');
    expect(resting.bpm, 66);

    final written = await files.stop();
    expect(written.map((p) => p.split(Platform.pathSeparator).last),
        containsAll(['polar_hr_polar_h10_20261021_090000.csv', 'polar_acc_polar_h10_20261021_090000.csv']));
    final hrLines = File('${dir.path}/polar_hr_polar_h10_20261021_090000.csv').readAsLinesSync();
    expect(hrLines.first, PolarHrSample.csvHeader);
    expect(hrLines, hasLength(41));
    final accLines = File('${dir.path}/polar_acc_polar_h10_20261021_090000.csv').readAsLinesSync();
    expect(accLines.first, endsWith('sensor_time_ns'));
    expect(accLines, hasLength(201));
    expect(accLines[1], endsWith(',1000000000'));
    // Nothing more after the end.
    service.recordedSamples.add(hr(now, 66, [900]));
    files.drain();
    expect(File('${dir.path}/polar_hr_polar_h10_20261021_090000.csv').readAsLinesSync(), hasLength(41));
    await dir.delete(recursive: true);
  });
}
