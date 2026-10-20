import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lab_protocol_timer/config/default_protocol_configuration.dart';
import 'package:lab_protocol_timer/models/activity_battery.dart';
import 'package:lab_protocol_timer/models/session_manifest.dart';
import 'package:lab_protocol_timer/models/protocol_configuration.dart';
import 'package:lab_protocol_timer/services/polar_ble_service.dart';
import 'package:lab_protocol_timer/windows/live_signal.dart';
import 'package:lab_protocol_timer/windows/sensor_chart_card.dart';

ActivityBattery _asset(String path) =>
    ActivityBattery.parse(File(path).readAsStringSync());

void main() {
  group('Research Monitor devices', () {
    test('lists every sensor of the session; H10 and Verity are live', () {
      final battery = _asset('assets/protocols/run4health_base.json');
      final configuration = protocolConfigurationFor(battery);

      expect(configuration.devices.map((d) => d.deviceId),
          battery.sensors.map((s) => s.sensorId));

      final verity = configuration.deviceById('verity_arm')!;
      expect(verity.isLive, isTrue);
      expect(verity.sensors, {'heart_rate', 'acc'});

      final h10 = configuration.devices.firstWhere((d) => d.type == 'polar_h10');
      expect(h10.sensors, containsAll(['heart_rate', 'rr', 'acc', 'ecg']));

      final offline = configuration.devices.where((d) => !d.isLive && !d.isCamera);
      expect(offline, isNotEmpty);
      expect(offline.every((d) => d.sensors.isEmpty), isTrue);
      expect(configuration.devices.where((d) => d.isCamera), isNotEmpty);
    });

    test('survives the trip to the monitor window', () {
      final configuration =
          protocolConfigurationFor(_asset('assets/protocols/weargap_day0_base.json'));
      final copy = ProtocolConfiguration.fromJson(
        jsonDecode(jsonEncode(configuration.toJson())) as Map<String, dynamic>,
      );
      expect(jsonEncode(copy.toJson()), jsonEncode(configuration.toJson()));
      expect(copy.devices.where((d) => d.isCamera).length, 3);
    });

    test('falls back to H10 and one camera without a sensor list', () {
      expect(protocolConfigurationFor(null), same(defaultProtocolConfiguration));
      expect(defaultProtocolConfiguration.deviceById('polar_h10')!.isLive, isTrue);
      expect(defaultProtocolConfiguration.deviceById('camera')!.isCamera, isTrue);
    });

    test('the manifest lists the Verity Sense as a live sensor', () {
      final battery = _asset('assets/protocols/run4health_base.json');
      final start = DateTime.utc(2026, 10, 27, 8);
      final manifest = buildSessionManifest(
        sessionId: 's',
        sessionStartTime: start,
        sessionEndTime: start.add(const Duration(hours: 1)),
        participants: const [],
        activities: const [],
        syncWindows: const [],
        generatedFiles: const [],
        protocolConfiguration: protocolConfigurationFor(battery),
        battery: battery,
      );
      final sensors = manifest['sensors'] as Map<String, dynamic>;
      expect(sensors['verity_arm']['connection'], 'live');
      expect(sensors['verity_arm']['timestamp_domain'], 'native_plus_host_utc');
      expect(sensors['verity_arm']['device_type'], 'verity_sense');
      final h10Id = battery.sensors.firstWhere((s) => s.type == 'polar_h10').sensorId;
      expect(sensors[h10Id]['connection'], 'live');
      expect(sensors[h10Id]['device_type'], 'polar_h10');
    });
  });

  group('Polar ACC settings', () {
    test('asks the H10 for 200 Hz, 16 bit and 8 G', () {
      // Settings offered by an H10: 25/50/100/200 Hz, 16 bit, 2/4/8 G.
      final offered = PolarBleService.parsePmdSettingOptions(Uint8List.fromList([
        0x00, 0x04, 0x19, 0x00, 0x32, 0x00, 0x64, 0x00, 0xC8, 0x00, //
        0x01, 0x01, 0x10, 0x00, //
        0x02, 0x03, 0x02, 0x00, 0x04, 0x00, 0x08, 0x00,
      ]));
      expect(offered[0], [25, 50, 100, 200]);
      expect(
        PolarBleService.accStartCommandFor(offered),
        [0x02, 0x02, 0x00, 0x01, 0xC8, 0x00, 0x01, 0x01, 0x10, 0x00, 0x02, 0x01, 0x08, 0x00],
      );
    });

    test('asks the Verity Sense for what it offers (52 Hz, 3 channels)', () {
      final offered = PolarBleService.parsePmdSettingOptions(Uint8List.fromList([
        0x00, 0x01, 0x34, 0x00, //
        0x01, 0x01, 0x10, 0x00, //
        0x02, 0x01, 0x08, 0x00, //
        0x04, 0x01, 0x03,
      ]));
      expect(
        PolarBleService.accStartCommandFor(offered),
        [0x02, 0x02, 0x00, 0x01, 0x34, 0x00, 0x01, 0x01, 0x10, 0x00, 0x02, 0x01, 0x08, 0x00, 0x04, 0x01, 0x03],
      );
    });
  });

  group('live charts', () {
    test('keep every sample of the window and drop older ones', () {
      final buffer = SignalBuffer(window: const Duration(seconds: 6), maxRateHz: 140);
      final t0 = DateTime.utc(2026, 10, 27, 8);
      for (var i = 0; i < 130 * 10; i++) {
        buffer.add(t0.add(Duration(microseconds: i * 1000000 ~/ 130)), i.toDouble());
      }
      expect(buffer.length, closeTo(130 * 6, 2));
      expect(buffer.lastValue, 130 * 10 - 1);
    });

    test('a one-sample R peak survives the reduction to pixels', () {
      final buffer = SignalBuffer(window: const Duration(seconds: 6), maxRateHz: 140);
      final t0 = DateTime.utc(2026, 10, 27, 8);
      for (var i = 0; i < 780; i++) {
        // Flat baseline with a single 1500 µV sample every 100 samples.
        buffer.add(t0.add(Duration(microseconds: i * 1000000 ~/ 130)), i % 100 == 50 ? 1500 : 0);
      }
      // 780 samples on 200 pixels: about 4 samples per column.
      final envelope = columnEnvelope(
        buffer,
        columns: 200,
        endMicros: buffer.lastTime!,
        window: buffer.window,
      );
      final peaks = [
        for (var c = 0; c < 200; c++)
          if (envelope.filled[c] == 1 && envelope.max[c] == 1500) c,
      ];
      expect(peaks.length, 8);
      expect(envelope.highest, 1500);
      expect(envelope.lowest, 0);
    });
  });

  testWidgets('the chart card paints and follows the frame clock', (tester) async {
    final buffer = SignalBuffer(window: const Duration(seconds: 6), maxRateHz: 140);
    final clock = LiveFrameClock();
    final t0 = DateTime.utc(2026, 10, 27, 8);
    for (var i = 0; i < 500; i++) {
      buffer.add(t0.add(Duration(microseconds: i * 1000000 ~/ 130)), (i % 60 == 0) ? 1200 : 0);
    }
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 500,
          height: 260,
          child: SensorChartCard(
            title: 'MONITOR 1',
            subtitle: 'ECG · polar_h10',
            icon: Icons.show_chart_rounded,
            currentValue: () => '${buffer.lastValue?.toStringAsFixed(0)}',
            unit: 'µV',
            window: buffer.window,
            clock: clock,
            seriesList: [ChartSeries(buffer: buffer, color: Colors.red, label: 'ECG')],
          ),
        ),
      ),
    ));
    expect(find.text('0'), findsOneWidget);
    buffer.add(t0.add(const Duration(seconds: 4)), 777);
    clock.tick();
    await tester.pump();
    expect(find.text('777'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
