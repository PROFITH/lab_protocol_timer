import '../models/session_sensor.dart';
import 'lab_redcap_service.dart';

/// One device a participant wears: in the laboratory session or taken home
/// for the free-living days. A sensor of the protocol used for both gives
/// two devices, each with its own serial number.
class DeviceEntry {
  final SessionSensor sensor;

  /// [SensorUse.lab] or [SensorUse.freeLiving].
  final String period;

  final String? serial;
  final bool initialized;

  const DeviceEntry({
    required this.sensor,
    required this.period,
    this.serial,
    this.initialized = false,
  });

  bool get isFreeLiving => period == SensorUse.freeLiving;

  String get periodLabel => isFreeLiving ? 'Vida libre' : 'Laboratorio';

  /// Where it goes («Tobillo, izquierda»), or the device when no place was set.
  String get place => sensor.placementLabel == null ? sensor.deviceName : _capitalized(sensor.placementLabel!);

  /// «100 Hz · ±16 g», or empty.
  String get settings => [
        if (sensor.samplingRateHz != null) '${_number(sensor.samplingRateHz!)} Hz',
        if (sensor.rangeG != null) '±${_number(sensor.rangeG!)} g',
      ].join(' · ');

  /// «Axivity AX6 · nº 12345 · ax6_ankle_l»: what goes in the reference
  /// field of `onboarding_config`.
  String get reference => [
        sensor.deviceName,
        serial == null ? 'sin nº de serie' : 'nº $serial',
        sensor.sensorId,
      ].join(' · ');

  /// One line of the summary fields of `onboarding_config`.
  String get line => [
        sensor.deviceName,
        place,
        sensor.sensorId,
        serial == null ? 'sin nº de serie' : 'nº $serial',
        if (settings.isNotEmpty) settings,
        if (sensor.connection == 'live') 'en directo' else if (initialized) 'inicializado' else 'sin marcar como inicializado',
      ].join(' | ');

  static String _capitalized(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  static String _number(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString().replaceAll('.', ',');
}

/// The devices of a participant (their sensors, without the cameras of the
/// session): laboratory first, then free-living, in protocol order.
List<DeviceEntry> deviceEntriesOf(Iterable<SessionSensor> sensors) {
  String? clean(String? s) => s == null || s.trim().isEmpty ? null : s.trim();
  final worn = [for (final s in sensors) if (s.connection != 'video') s];
  return [
    for (final s in worn)
      if (s.inLab) DeviceEntry(sensor: s, period: SensorUse.lab, serial: clean(s.serial), initialized: s.initialized),
    for (final s in worn)
      if (s.inFreeLiving)
        DeviceEntry(
          sensor: s,
          period: SensorUse.freeLiving,
          // A device only for the free-living days may carry its serial in
          // either field (protocol files written by hand).
          serial: clean(s.freeLivingSerial) ?? (s.inLab ? null : clean(s.serial)),
          initialized: s.freeLivingInitialized,
        ),
  ];
}

/// The device sheet of a participant's folder (`dispositivos.csv`), for the
/// evaluator placing the devices. Semicolons and a BOM, so Excel in Spanish
/// opens it in columns with the accents right.
class DeviceSheet {
  static const fileName = 'dispositivos.csv';

  static const header = [
    'participante',
    'periodo',
    'dispositivo',
    'lugar',
    'codigo',
    'numero_serie',
    'frecuencia_hz',
    'rango_g',
    'conexion',
    'inicializado',
  ];

  static String csv(String participantId, List<DeviceEntry> devices) {
    String cell(Object? v) {
      final s = v?.toString() ?? '';
      return s.contains(RegExp('[;"\n\r]')) ? '"${s.replaceAll('"', '""')}"' : s;
    }

    final buffer = StringBuffer('﻿')..write('${header.join(';')}\r\n');
    for (final d in devices) {
      final s = d.sensor;
      buffer.write([
        participantId,
        d.periodLabel,
        s.deviceName,
        d.place,
        s.sensorId,
        d.serial ?? '',
        s.samplingRateHz == null ? '' : DeviceEntry._number(s.samplingRateHz!),
        s.rangeG == null ? '' : DeviceEntry._number(s.rangeG!),
        s.connection == 'live' ? 'En directo' : 'Graba por su cuenta',
        s.connection == 'live' ? '' : (d.initialized ? 'Sí' : 'No'),
      ].map(cell).join(';'));
      buffer.write('\r\n');
    }
    return buffer.toString();
  }
}

/// What lab_protocol_timer writes in the `onboarding_config` instrument of
/// the visit that hands out the free-living devices, so nobody types them:
/// the devices healthy_tracker shows in the non-wear log (`device_N` and
/// its reference) and the whole list of the visit.
class OnboardingDevices {
  /// Device fields of the dictionary up to v9; healthy_tracker reads them.
  static const maxBaseDevices = 4;

  /// With the fields of dictionary v10 (`device_5`, `device_6`).
  static const maxDevices = 6;

  /// Reference field of each `device_N` (the names are not regular).
  static const referenceFields = {
    1: 'ref_dispositivo1',
    2: 'device2_ref',
    3: 'device_3_ref',
    4: 'device_4_ref',
    5: 'device_5_ref',
    6: 'device_6_ref',
  };

  /// Free-living devices as healthy_tracker names them (the place, with the
  /// device when two share it).
  static List<({String name, String reference})> freeLivingSlots(List<DeviceEntry> devices) {
    final home = [for (final d in devices) if (d.isFreeLiving) d];
    final counts = <String, int>{};
    for (final d in home) {
      counts[d.place] = (counts[d.place] ?? 0) + 1;
    }
    return [
      for (final d in home)
        (
          name: (counts[d.place] ?? 0) > 1 && d.place != d.sensor.deviceName ? '${d.place} (${d.sensor.deviceName})' : d.place,
          reference: d.reference,
        ),
    ];
  }

  /// Two records per participant who takes devices home, sent apart: the
  /// fields that exist since dictionary v1 (`device_1`-`device_4` and their
  /// references), and the fields of dictionary v10 (`device_5`-`device_6`,
  /// `devices_lab`, `devices_free_living`, `devices_updated`), so a project
  /// without v10 still gets the first ones. Participants without
  /// free-living devices (the day 8 visit) get only the list of the
  /// laboratory devices, in the `onboarding_config` of their own event.
  static ({List<Map<String, dynamic>> base, List<Map<String, dynamic>> extended}) records(
    List<ParticipantEntry> participants,
    List<SessionSensor> layout, {
    required DateTime now,
  }) {
    final base = <Map<String, dynamic>>[];
    final extended = <Map<String, dynamic>>[];
    for (final p in participants) {
      final devices = deviceEntriesOf(p.sensorsOr(layout));
      final slots = freeLivingSlots(devices);
      if (devices.isEmpty) continue;
      final key = {'record_id': p.participantId, 'redcap_event_name': p.redcapEventName};
      final fields = <String, dynamic>{};
      for (var i = 0; i < slots.length && i < maxDevices; i++) {
        fields['device_${i + 1}'] = slots[i].name;
        fields[referenceFields[i + 1]!] = slots[i].reference;
      }
      if (slots.isNotEmpty) base.add({
        ...key,
        for (final e in fields.entries)
          if (_slotOf(e.key) <= maxBaseDevices) e.key: e.value,
      });
      String lines(String period) => [
            for (final d in devices)
              if (d.period == period) d.line,
          ].join('\n');
      final overflow = [
        for (var i = maxDevices; i < slots.length; i++) '${slots[i].name}: ${slots[i].reference}',
      ];
      extended.add({
        ...key,
        for (final e in fields.entries)
          if (_slotOf(e.key) > maxBaseDevices) e.key: e.value,
        if (lines(SensorUse.lab).isNotEmpty) 'devices_lab': lines(SensorUse.lab),
        if (slots.isNotEmpty)
          'devices_free_living': [
            lines(SensorUse.freeLiving),
            if (overflow.isNotEmpty) 'Sin hueco en device_1-device_$maxDevices: ${overflow.join('; ')}',
          ].join('\n'),
        'devices_updated': LabRedCapService.formatRedcapDateTime(now),
      });
    }
    return (base: base, extended: extended);
  }

  static int _slotOf(String field) {
    for (final e in referenceFields.entries) {
      if (e.value == field || field == 'device_${e.key}') return e.key;
    }
    return 0;
  }
}
