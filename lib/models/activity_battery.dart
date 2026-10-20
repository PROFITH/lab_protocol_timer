import 'dart:convert';

import 'session_sensor.dart';

export 'session_sensor.dart';

/// What a segment of the battery is.
enum ActivityKind {
  /// An activity done by the participant.
  activity,

  /// Calibration box: the offline sensors lie still on each face of a rigid
  /// box. The taps on the box are a sync mark common to all sensors.
  calibration;

  static ActivityKind parse(Object? value) {
    if (value == null) return ActivityKind.activity;
    for (final kind in values) {
      if (kind.name == value) return kind;
    }
    throw FormatException('Tipo de actividad desconocido: $value.');
  }
}

/// One activity of a protocol battery.
class BatteryActivity {
  final String name;
  final ActivityKind kind;

  /// Code of the activity in the Adult Compendium of Physical Activities.
  final String? compendiumCode;

  /// MET value of [compendiumCode] in the 2024 Compendium.
  final double? met;

  /// Planned duration of the main phase. When null the timer uses the
  /// activity duration set in the Research Monitor.
  final int? durationSeconds;

  /// Static phases before and after the main phase. When null the timer uses
  /// the values set in the Research Monitor.
  final int? prepSeconds;
  final int? postSeconds;

  /// Calibration only: number of box faces, announced one by one during the
  /// main phase.
  final int? faces;

  /// Notes for the evaluators (material, speed, load...). Not read aloud.
  final String? notes;

  const BatteryActivity({
    required this.name,
    this.kind = ActivityKind.activity,
    this.compendiumCode,
    this.met,
    this.durationSeconds,
    this.prepSeconds,
    this.postSeconds,
    this.faces,
    this.notes,
  });

  bool get isCalibration => kind == ActivityKind.calibration;

  BatteryActivity copyWith({
    String? name,
    ActivityKind? kind,
    String? compendiumCode,
    double? met,
    int? durationSeconds,
    int? prepSeconds,
    int? postSeconds,
    int? faces,
    String? notes,
    bool clearCompendium = false,
    bool clearDuration = false,
    bool clearPrep = false,
    bool clearPost = false,
    bool clearFaces = false,
    bool clearNotes = false,
  }) =>
      BatteryActivity(
        name: name ?? this.name,
        kind: kind ?? this.kind,
        compendiumCode:
            clearCompendium ? null : compendiumCode ?? this.compendiumCode,
        met: clearCompendium ? null : met ?? this.met,
        durationSeconds:
            clearDuration ? null : durationSeconds ?? this.durationSeconds,
        prepSeconds: clearPrep ? null : prepSeconds ?? this.prepSeconds,
        postSeconds: clearPost ? null : postSeconds ?? this.postSeconds,
        faces: clearFaces ? null : faces ?? this.faces,
        notes: clearNotes ? null : notes ?? this.notes,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        if (kind != ActivityKind.activity) 'kind': kind.name,
        if (compendiumCode != null) 'compendium_code': compendiumCode,
        if (met != null) 'met': met,
        if (durationSeconds != null) 'duration_seconds': durationSeconds,
        if (prepSeconds != null) 'prep_seconds': prepSeconds,
        if (postSeconds != null) 'post_seconds': postSeconds,
        if (faces != null) 'faces': faces,
        if (notes != null) 'notes': notes,
      };

  factory BatteryActivity.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    if (name is! String || name.trim().isEmpty) {
      throw const FormatException('Cada actividad necesita un "name".');
    }

    int? seconds(String key, {bool allowZero = false}) {
      final value = json[key];
      if (value == null) return null;
      if (value is! num || value < 0 || (!allowZero && value == 0)) {
        throw FormatException(
          'La actividad "$name" tiene un "$key" no válido.',
        );
      }
      return value.round();
    }

    final met = json['met'];
    if (met != null && (met is! num || met <= 0)) {
      throw FormatException('La actividad "$name" tiene un MET no válido.');
    }

    return BatteryActivity(
      name: name.trim(),
      kind: ActivityKind.parse(json['kind']),
      compendiumCode: json['compendium_code']?.toString(),
      met: (met as num?)?.toDouble(),
      durationSeconds: seconds('duration_seconds'),
      prepSeconds: seconds('prep_seconds', allowZero: true),
      postSeconds: seconds('post_seconds', allowZero: true),
      faces: seconds('faces'),
      notes: json['notes']?.toString(),
    );
  }
}

/// Ordered list of activities of a laboratory protocol, with the sensors
/// worn in the session.
///
/// Activity indices in the timer are 1-based, so activity `i` of the session
/// is `activities[i - 1]`.
class ActivityBattery {
  final String protocolId;
  final String? protocolVersion;

  /// Name shown in the protocol list.
  final String? title;

  /// Study the protocol belongs to (`RUN4HEALTH`, `WEARGAP`). Protocols of
  /// the same study replace each other when the visit changes.
  final String? study;

  /// REDCap events (visits) the protocol is meant for; empty means any.
  final List<String> moments;

  final List<BatteryActivity> activities;
  final List<SessionSensor> sensors;

  const ActivityBattery({
    required this.protocolId,
    this.protocolVersion,
    this.title,
    this.study,
    this.moments = const [],
    required this.activities,
    this.sensors = const [],
  });

  String get displayName => title ?? protocolId;

  /// Sensors that record on their own and are not cameras.
  List<SessionSensor> get offlineSensors =>
      sensors.where((s) => s.connection == 'offline').toList();

  bool appliesTo(String moment) => moments.isEmpty || moments.contains(moment);

  /// Planned length of the whole battery with [defaultPrep], [defaultMain]
  /// and [defaultPost] for the phases an activity leaves open (waits
  /// between activities excluded).
  int plannedSeconds({
    int defaultPrep = 30,
    int defaultMain = 600,
    int defaultPost = 30,
  }) =>
      activities.fold(
        0,
        (sum, a) =>
            sum +
            (a.prepSeconds ?? defaultPrep) +
            (a.durationSeconds ?? defaultMain) +
            (a.postSeconds ?? defaultPost),
      );

  BatteryActivity? activityAt(int activityIndex) {
    if (activityIndex < 1 || activityIndex > activities.length) {
      return null;
    }
    return activities[activityIndex - 1];
  }

  ActivityBattery copyWith({
    String? protocolId,
    String? protocolVersion,
    String? title,
    String? study,
    List<String>? moments,
    List<BatteryActivity>? activities,
    List<SessionSensor>? sensors,
  }) =>
      ActivityBattery(
        protocolId: protocolId ?? this.protocolId,
        protocolVersion: protocolVersion ?? this.protocolVersion,
        title: title ?? this.title,
        study: study ?? this.study,
        moments: moments ?? this.moments,
        activities: activities ?? this.activities,
        sensors: sensors ?? this.sensors,
      );

  Map<String, dynamic> toJson() => {
        'protocol_id': protocolId,
        if (protocolVersion != null) 'protocol_version': protocolVersion,
        if (title != null) 'title': title,
        if (study != null) 'study': study,
        if (moments.isNotEmpty) 'moments': moments,
        'activities': activities.map((a) => a.toJson()).toList(),
        if (sensors.isNotEmpty)
          'sensors': sensors.map((s) => s.toJson()).toList(),
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

    // Protocol files written before sensors were configurable list the
    // offline sensors under "offline_sensors".
    final rawSensors = <dynamic>[
      ...json['sensors'] as List<dynamic>? ?? const [],
      ...json['offline_sensors'] as List<dynamic>? ?? const [],
    ];

    final sensors = rawSensors
        .map((s) => SessionSensor.fromJson(Map<String, dynamic>.from(s as Map)))
        .toList();
    final ids = <String>{};
    for (final sensor in sensors) {
      if (!ids.add(sensor.sensorId)) {
        throw FormatException('El sensor "${sensor.sensorId}" está repetido.');
      }
    }

    return ActivityBattery(
      protocolId: protocolId.trim(),
      protocolVersion: json['protocol_version']?.toString(),
      title: json['title']?.toString(),
      study: json['study']?.toString(),
      moments: (json['moments'] as List<dynamic>? ?? const [])
          .map((m) => m.toString())
          .toList(),
      activities: rawActivities
          .map((a) => BatteryActivity.fromJson(Map<String, dynamic>.from(a as Map)))
          .toList(),
      sensors: sensors,
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
