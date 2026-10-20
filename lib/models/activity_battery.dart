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

/// What the participant does at a sync cue.
enum SyncKind {
  /// Wrist-to-wrist clap and a fist on the thigh sensor.
  clap,

  /// A jump on the spot: every sensor on the body feels the landing.
  jump;

  static SyncKind parse(Object? value) {
    for (final kind in values) {
      if (kind.name == value) return kind;
    }
    return SyncKind.clap;
  }

  String get label => this == SyncKind.clap ? 'Palmada' : 'Salto';
}

/// When the timer gives a sync cue by itself.
enum AutoSync {
  /// In the initial and final static phase of every activity.
  everyStatic('every_static'),

  /// In the initial static phase of the first activity and the final one of
  /// the last activity.
  firstLast('first_last'),

  /// Only when the evaluator presses SINCRONIZAR.
  manual('manual');

  final String key;
  const AutoSync(this.key);

  static AutoSync parse(Object? value) {
    for (final mode in values) {
      if (mode.key == value) return mode;
    }
    return AutoSync.everyStatic;
  }

  String get label => switch (this) {
        AutoSync.everyStatic => 'En cada fase estática',
        AutoSync.firstLast => 'Solo al principio y al final',
        AutoSync.manual => 'Solo con el botón',
      };
}

/// Sync cues of a protocol.
class SyncSettings {
  final SyncKind kind;
  final AutoSync auto;

  const SyncSettings({this.kind = SyncKind.clap, this.auto = AutoSync.everyStatic});

  SyncSettings copyWith({SyncKind? kind, AutoSync? auto}) =>
      SyncSettings(kind: kind ?? this.kind, auto: auto ?? this.auto);

  Map<String, dynamic> toJson() => {'kind': kind.name, 'auto': auto.key};

  factory SyncSettings.fromJson(Object? json) {
    if (json is! Map) return const SyncSettings();
    return SyncSettings(
      kind: SyncKind.parse(json['kind']),
      auto: AutoSync.parse(json['auto']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SyncSettings && other.kind == kind && other.auto == auto;

  @override
  int get hashCode => Object.hash(kind, auto);
}

/// A value the evaluator types in the Research Monitor after an activity
/// (repetitions, laps...), sent to a field of the visit's REDCap record.
class RecordField {
  /// REDCap field name.
  final String field;
  final String label;

  /// `integer`, `number`, `text` or `choice`.
  final String type;
  final num? min;
  final num? max;

  /// REDCap codes and labels of a `choice` field, in order.
  final Map<String, String> choices;

  /// Value shown before the evaluator types anything.
  final String? defaultValue;

  const RecordField({
    required this.field,
    required this.label,
    this.type = 'text',
    this.min,
    this.max,
    this.choices = const {},
    this.defaultValue,
  });

  bool get isNumeric => type == 'integer' || type == 'number';

  /// Error message for [value], or null when it can be sent.
  String? validate(String value) {
    final v = value.trim();
    if (v.isEmpty) return null;
    if (type == 'choice') {
      return choices.containsKey(v) ? null : 'Elige una opción';
    }
    if (!isNumeric) return null;
    final n = type == 'integer'
        ? int.tryParse(v)
        : double.tryParse(v.replaceAll(',', '.'));
    if (n == null) return type == 'integer' ? 'Número entero' : 'Número';
    if (min != null && n < min!) return 'Mínimo ${_num(min!)}';
    if (max != null && n > max!) return 'Máximo ${_num(max!)}';
    return null;
  }

  /// [value] as REDCap expects it (decimal point, trimmed).
  String normalize(String value) {
    final v = value.trim();
    return type == 'number' ? v.replaceAll(',', '.') : v;
  }

  static String _num(num n) => n == n.roundToDouble() ? n.round().toString() : n.toString();

  Map<String, dynamic> toJson() => {
        'field': field,
        'label': label,
        'type': type,
        if (min != null) 'min': min,
        if (max != null) 'max': max,
        if (choices.isNotEmpty) 'choices': choices,
        if (defaultValue != null) 'default': defaultValue,
      };

  factory RecordField.fromJson(Map<String, dynamic> json) {
    final field = json['field'];
    if (field is! String || field.trim().isEmpty) {
      throw const FormatException('Cada campo de REDCap necesita un "field".');
    }
    final type = json['type']?.toString() ?? 'text';
    if (!const ['integer', 'number', 'text', 'choice'].contains(type)) {
      throw FormatException('El campo "$field" tiene un tipo no válido: $type.');
    }
    final rawChoices = json['choices'];
    return RecordField(
      field: field.trim(),
      label: json['label']?.toString() ?? field,
      type: type,
      min: json['min'] as num?,
      max: json['max'] as num?,
      choices: rawChoices is Map
          ? {for (final e in rawChoices.entries) e.key.toString(): e.value.toString()}
          : const {},
      defaultValue: json['default']?.toString(),
    );
  }
}

/// Fields of the visit's REDCap record that an activity fills (a fitness
/// test in `physical_fitness`, for instance) besides its `lab_activity`
/// instance.
class ActivityRecordMapping {
  /// yes/no field: 1 when the activity was done (even partly), 0 if skipped.
  final String? doneField;

  /// Date-time field with the start of the main phase.
  final String? startField;

  /// Integer fields with the effort (0-10) before and after the activity.
  final String? rpeBeforeField;
  final String? rpeAfterField;

  /// Values typed in the Research Monitor.
  final List<RecordField> fields;

  const ActivityRecordMapping({
    this.doneField,
    this.startField,
    this.rpeBeforeField,
    this.rpeAfterField,
    this.fields = const [],
  });

  Map<String, dynamic> toJson() => {
        if (doneField != null) 'done_field': doneField,
        if (startField != null) 'start_field': startField,
        if (rpeBeforeField != null) 'rpe_before_field': rpeBeforeField,
        if (rpeAfterField != null) 'rpe_after_field': rpeAfterField,
        if (fields.isNotEmpty) 'fields': fields.map((f) => f.toJson()).toList(),
      };

  factory ActivityRecordMapping.fromJson(Map<String, dynamic> json) =>
      ActivityRecordMapping(
        doneField: json['done_field']?.toString(),
        startField: json['start_field']?.toString(),
        rpeBeforeField: json['rpe_before_field']?.toString(),
        rpeAfterField: json['rpe_after_field']?.toString(),
        fields: (json['fields'] as List<dynamic>? ?? const [])
            .map((f) => RecordField.fromJson(Map<String, dynamic>.from(f as Map)))
            .toList(),
      );
}

/// Movements of the figure shown to the participant during an activity.
const List<String> activityAnimations = [
  'lie',
  'stand',
  'sit',
  'type',
  'walk',
  'walk_bags',
  'walk_fast',
  'run',
  'stairs',
  'uphill',
  'sweep',
  'dishes',
  'cycle',
  'sit_to_stand',
  'treadmill',
];

/// Spanish names of [activityAnimations] for the protocol editor.
const Map<String, String> animationLabels = {
  'lie': 'Tumbado',
  'stand': 'De pie',
  'sit': 'Sentado',
  'type': 'Escribiendo sentado',
  'walk': 'Caminando',
  'walk_bags': 'Caminando con bolsas',
  'walk_fast': 'Marcha rápida',
  'run': 'Corriendo',
  'stairs': 'Subiendo escaleras',
  'uphill': 'Cuesta arriba',
  'sweep': 'Barriendo',
  'dishes': 'Fregando',
  'cycle': 'Bicicleta',
  'sit_to_stand': 'Sentarse y levantarse',
  'treadmill': 'Cinta',
};

/// Animation for an activity without one in its protocol, guessed from its
/// name.
String guessAnimation(String name) {
  final n = name.toLowerCase();
  bool has(String word) => n.contains(word);
  if (has('tumbad') || has('acostad') || has('reposo')) return 'lie';
  if (has('levantarse') || has('sentarse y')) return 'sit_to_stand';
  if (has('escrib') || has('ordenador') || has('teclado')) return 'type';
  if (has('sentad')) return 'sit';
  if (has('escalera')) return 'stairs';
  if (has('cuesta') || has('pendiente')) return 'uphill';
  if (has('bicicleta') || has('cicl') || has('pedale')) return 'cycle';
  if (has('barr')) return 'sweep';
  if (has('freg') || has('platos')) return 'dishes';
  if (has('cinta') || has('esfuerzo')) return 'treadmill';
  if (has('trot') || has('corr')) return 'run';
  if (has('bolsa')) return 'walk_bags';
  if (has('6 minutos') || has('rápid') || has('marcha')) return 'walk_fast';
  if (has('camin') || has('andar')) return 'walk';
  return 'stand';
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

  /// What the participant has to do, shown on the timer screen.
  final String? instructions;

  /// Movement of the figure on the timer screen (see [activityAnimations]).
  /// When null it is guessed from the name.
  final String? animation;

  /// Resting heart rate: the mean of the last minutes of this activity goes
  /// to `ws_hr_rest`.
  final bool restingHr;

  /// Fields of the visit's REDCap record that this activity fills.
  final ActivityRecordMapping? redcap;

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
    this.instructions,
    this.animation,
    this.restingHr = false,
    this.redcap,
  });

  bool get isCalibration => kind == ActivityKind.calibration;

  /// [animation], or the one guessed from the name.
  String get animationOrGuess =>
      animation ?? (isCalibration ? 'stand' : guessAnimation(name));

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
    String? instructions,
    String? animation,
    bool? restingHr,
    ActivityRecordMapping? redcap,
    bool clearCompendium = false,
    bool clearDuration = false,
    bool clearPrep = false,
    bool clearPost = false,
    bool clearFaces = false,
    bool clearNotes = false,
    bool clearInstructions = false,
    bool clearAnimation = false,
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
        instructions:
            clearInstructions ? null : instructions ?? this.instructions,
        animation: clearAnimation ? null : animation ?? this.animation,
        restingHr: restingHr ?? this.restingHr,
        redcap: redcap ?? this.redcap,
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
        if (instructions != null) 'instructions': instructions,
        if (animation != null) 'animation': animation,
        if (restingHr) 'resting_hr': true,
        if (redcap != null) 'redcap': redcap!.toJson(),
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
      instructions: json['instructions']?.toString(),
      animation: json['animation']?.toString(),
      restingHr: json['resting_hr'] == true,
      redcap: json['redcap'] is Map
          ? ActivityRecordMapping.fromJson(
              Map<String, dynamic>.from(json['redcap'] as Map))
          : null,
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

  /// Sync cues given by the timer.
  final SyncSettings sync;

  /// Asks the effort (0-10) after every activity.
  final bool askRpe;

  const ActivityBattery({
    required this.protocolId,
    this.protocolVersion,
    this.title,
    this.study,
    this.moments = const [],
    required this.activities,
    this.sensors = const [],
    this.sync = const SyncSettings(),
    this.askRpe = true,
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
    SyncSettings? sync,
    bool? askRpe,
  }) =>
      ActivityBattery(
        protocolId: protocolId ?? this.protocolId,
        protocolVersion: protocolVersion ?? this.protocolVersion,
        title: title ?? this.title,
        study: study ?? this.study,
        moments: moments ?? this.moments,
        activities: activities ?? this.activities,
        sensors: sensors ?? this.sensors,
        sync: sync ?? this.sync,
        askRpe: askRpe ?? this.askRpe,
      );

  Map<String, dynamic> toJson() => {
        'protocol_id': protocolId,
        if (protocolVersion != null) 'protocol_version': protocolVersion,
        if (title != null) 'title': title,
        if (study != null) 'study': study,
        if (moments.isNotEmpty) 'moments': moments,
        'sync': sync.toJson(),
        'ask_rpe': askRpe,
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
      sync: SyncSettings.fromJson(json['sync']),
      askRpe: json['ask_rpe'] as bool? ?? true,
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
