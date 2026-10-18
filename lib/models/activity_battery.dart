import 'dart:convert';

/// One activity of a protocol battery.
class BatteryActivity {
  final String name;

  /// Code of the activity in the Adult Compendium of Physical Activities.
  final String? compendiumCode;

  /// Planned duration of the main phase. When null the timer uses the
  /// activity duration set in the Research Monitor.
  final int? durationSeconds;

  const BatteryActivity({
    required this.name,
    this.compendiumCode,
    this.durationSeconds,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        if (compendiumCode != null) 'compendium_code': compendiumCode,
        if (durationSeconds != null) 'duration_seconds': durationSeconds,
      };

  factory BatteryActivity.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    if (name is! String || name.trim().isEmpty) {
      throw const FormatException('Cada actividad necesita un "name".');
    }

    final duration = json['duration_seconds'];
    if (duration != null && (duration is! num || duration <= 0)) {
      throw FormatException(
        'La actividad "$name" tiene una duración no válida.',
      );
    }

    return BatteryActivity(
      name: name.trim(),
      compendiumCode: json['compendium_code']?.toString(),
      durationSeconds: (duration as num?)?.round(),
    );
  }
}

/// Offline sensor worn during the session (not connected to the app).
///
/// It is only written to the session manifest so that SAVES knows which
/// files to expect and which clock each one follows.
class OfflineSensor {
  static const timestampDomains = {
    'device_clock_utc',
    'device_clock_local',
    'video_relative',
    'unknown',
  };

  final String sensorId;
  final String deviceName;
  final String? placement;

  /// `device_clock_utc` or `device_clock_local` (see SAVES session format).
  final String timestampDomain;

  const OfflineSensor({
    required this.sensorId,
    required this.deviceName,
    this.placement,
    this.timestampDomain = 'unknown',
  });

  Map<String, dynamic> toJson() => {
        'sensor_id': sensorId,
        'device_name': deviceName,
        if (placement != null) 'placement': placement,
        'timestamp_domain': timestampDomain,
      };

  factory OfflineSensor.fromJson(Map<String, dynamic> json) {
    final sensorId = json['sensor_id'];
    if (sensorId is! String || sensorId.trim().isEmpty) {
      throw const FormatException(
        'Cada sensor offline necesita un "sensor_id".',
      );
    }

    final timestampDomain = json['timestamp_domain']?.toString() ?? 'unknown';
    if (!timestampDomains.contains(timestampDomain)) {
      throw FormatException(
        'El sensor "$sensorId" tiene un timestamp_domain no válido: '
        '$timestampDomain.',
      );
    }

    return OfflineSensor(
      sensorId: sensorId.trim(),
      deviceName: json['device_name']?.toString() ?? sensorId,
      placement: json['placement']?.toString(),
      timestampDomain: timestampDomain,
    );
  }
}

/// Ordered list of activities of a laboratory protocol, loaded from JSON.
///
/// Activity indices in the timer are 1-based, so activity `i` of the session
/// is `activities[i - 1]`.
class ActivityBattery {
  final String protocolId;
  final String? protocolVersion;
  final List<BatteryActivity> activities;
  final List<OfflineSensor> offlineSensors;

  const ActivityBattery({
    required this.protocolId,
    this.protocolVersion,
    required this.activities,
    this.offlineSensors = const [],
  });

  BatteryActivity? activityAt(int activityIndex) {
    if (activityIndex < 1 || activityIndex > activities.length) {
      return null;
    }
    return activities[activityIndex - 1];
  }

  Map<String, dynamic> toJson() => {
        'protocol_id': protocolId,
        if (protocolVersion != null) 'protocol_version': protocolVersion,
        'activities': activities.map((a) => a.toJson()).toList(),
        if (offlineSensors.isNotEmpty)
          'offline_sensors': offlineSensors.map((s) => s.toJson()).toList(),
      };

  factory ActivityBattery.fromJson(Map<String, dynamic> json) {
    final protocolId = json['protocol_id'];
    if (protocolId is! String || protocolId.trim().isEmpty) {
      throw const FormatException('Falta "protocol_id".');
    }

    final rawActivities = json['activities'];
    if (rawActivities is! List || rawActivities.isEmpty) {
      throw const FormatException('"activities" debe ser una lista no vacía.');
    }

    final rawSensors = json['offline_sensors'] as List<dynamic>? ?? const [];

    return ActivityBattery(
      protocolId: protocolId.trim(),
      protocolVersion: json['protocol_version']?.toString(),
      activities: rawActivities
          .map((a) => BatteryActivity.fromJson(Map<String, dynamic>.from(a as Map)))
          .toList(),
      offlineSensors: rawSensors
          .map((s) => OfflineSensor.fromJson(Map<String, dynamic>.from(s as Map)))
          .toList(),
    );
  }

  static ActivityBattery parse(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('El protocolo debe ser un objeto JSON.');
    }
    return ActivityBattery.fromJson(Map<String, dynamic>.from(decoded));
  }
}
