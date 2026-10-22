import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/activity_battery.dart';

/// Session setup remembered for a participant, so that the closing visit
/// reuses the sensors (and serials) of the first one.
class RememberedSetup {
  final ActivityBattery battery;
  final String eventName;
  final DateTime savedAt;

  const RememberedSetup({
    required this.battery,
    required this.eventName,
    required this.savedAt,
  });

  Map<String, dynamic> toJson() => {
        'battery': battery.toJson(),
        'event_name': eventName,
        'saved_at': savedAt.toUtc().toIso8601String(),
      };

  factory RememberedSetup.fromJson(Map<String, dynamic> json) =>
      RememberedSetup(
        battery: ActivityBattery.fromJson(
          Map<String, dynamic>.from(json['battery'] as Map),
        ),
        eventName: json['event_name'] as String,
        savedAt: DateTime.parse(json['saved_at'] as String),
      );
}

/// Base protocols bundled with the app, protocols saved on this computer and
/// the last setup of each participant.
class ProtocolLibrary {
  static const builtInAssets = [
    'assets/protocols/run4health_base.json',
    'assets/protocols/weargap_day0_base.json',
    'assets/protocols/weargap_day8_base.json',
  ];

  static const _customKey = 'custom_protocols';
  static const _rememberedKey = 'remembered_setups';
  static const _lastProtocolKey = 'last_protocol_id';

  static Future<List<ActivityBattery>> loadBuiltIns([AssetBundle? bundle]) async {
    final source = bundle ?? rootBundle;
    return [
      for (final path in builtInAssets)
        ActivityBattery.parse(await source.loadString(path)),
    ];
  }

  /// Protocols saved with "Guardar como protocolo", by `protocol_id`.
  static Future<List<ActivityBattery>> loadCustom() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_customKey);
    if (raw == null) return [];
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final protocols = <ActivityBattery>[];
    for (final value in decoded.values) {
      try {
        protocols.add(
          ActivityBattery.fromJson(Map<String, dynamic>.from(value as Map)),
        );
      } on FormatException {
        // A protocol saved by a newer version: skip it rather than lose all.
      }
    }
    return protocols;
  }

  static Future<void> saveCustom(ActivityBattery battery) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_customKey);
    final all = raw == null
        ? <String, dynamic>{}
        : jsonDecode(raw) as Map<String, dynamic>;
    all[battery.protocolId] = battery.toJson();
    await prefs.setString(_customKey, jsonEncode(all));
  }

  static Future<void> deleteCustom(String protocolId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_customKey);
    if (raw == null) return;
    final all = jsonDecode(raw) as Map<String, dynamic>..remove(protocolId);
    await prefs.setString(_customKey, jsonEncode(all));
  }

  /// Setups of every participant, by participant ID.
  static Future<Map<String, RememberedSetup>> loadRemembered() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_rememberedKey);
    if (raw == null) return {};
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final setups = <String, RememberedSetup>{};
    decoded.forEach((id, value) {
      try {
        setups[id] =
            RememberedSetup.fromJson(Map<String, dynamic>.from(value as Map));
      } on Object {
        // Ignore entries that no longer parse.
      }
    });
    return setups;
  }

  static Future<void> remember(
    Iterable<({String participantId, String eventName})> participants,
    ActivityBattery battery,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_rememberedKey);
    final all = raw == null
        ? <String, dynamic>{}
        : jsonDecode(raw) as Map<String, dynamic>;
    final now = DateTime.now();
    for (final p in participants) {
      all[p.participantId] = RememberedSetup(
        battery: battery,
        eventName: p.eventName,
        savedAt: now,
      ).toJson();
    }
    await prefs.setString(_rememberedKey, jsonEncode(all));
    await prefs.setString(_lastProtocolKey, battery.protocolId);
  }

  static Future<String?> lastProtocolId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_lastProtocolKey);
  }

  /// Protocol to use when the visit changes to [moment]: [current] if it
  /// applies, otherwise one of the same study meant for that visit.
  static ActivityBattery? forMoment(
    ActivityBattery current,
    String moment,
    List<ActivityBattery> available,
  ) {
    if (current.appliesTo(moment)) return current;
    if (current.study == null) return null;
    for (final candidate in available) {
      if (candidate.study == current.study &&
          candidate.moments.contains(moment)) {
        return candidate;
      }
    }
    return null;
  }

  /// Setup for a participant who already has [remembered]: the same
  /// protocol comes back as it was used (activities and sensors); another
  /// protocol (e.g. the closing visit of WEARGAP) keeps its own sensor list,
  /// with the serial, sampling rate and range of the sensors with the same
  /// ID.
  static ActivityBattery applyRemembered(
    ActivityBattery protocol,
    RememberedSetup remembered,
  ) {
    if (remembered.battery.protocolId == protocol.protocolId) {
      return remembered.battery;
    }
    return carrySensorDetails(protocol, remembered.battery.sensors);
  }

  /// [protocol] with the serial, sampling rate and range of the sensors of
  /// [previous] that have the same ID and type.
  static ActivityBattery carrySensorDetails(
    ActivityBattery protocol,
    List<SessionSensor> previous,
  ) {
    final byId = {for (final s in previous) s.sensorId: s};
    return protocol.copyWith(
      sensors: [
        for (final sensor in protocol.sensors)
          if (byId[sensor.sensorId] case final old?
              when old.type == sensor.type && old.hasSerial)
            sensor.copyWith(
              serial: old.serial,
              samplingRateHz: old.samplingRateHz,
              rangeG: old.rangeG,
            )
          else
            sensor,
      ],
    );
  }
}
