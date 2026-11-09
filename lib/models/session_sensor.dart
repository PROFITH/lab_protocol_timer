/// What a sensor of the protocol is for.
class SensorUse {
  SensorUse._();

  static const lab = 'lab';
  static const freeLiving = 'free_living';
  static const both = 'both';
  static const values = [lab, freeLiving, both];

  static String label(String use) => switch (use) {
        freeLiving => 'Vida libre',
        both => 'Laboratorio y vida libre',
        _ => 'Laboratorio',
      };
}

/// Kind of device that can be worn or used in a laboratory session.
class SensorType {
  final String key;
  final String label;

  /// `live` (streamed to this app), `offline` (records on its own clock) or
  /// `video` (camera, listed under `video` in the manifest).
  final String connection;

  /// Clock followed by the device files (see the SAVES session format).
  final String timestampDomain;

  /// Prefix of the sensor ID, also used in file names (`ax3_wnd`).
  final String idPrefix;

  /// Code of the device in the REDCap `sensor_log` instrument (`sl_device`).
  final String redcapCode;

  final double? defaultSamplingRateHz;
  final double? defaultRangeG;

  /// The device records at its own fixed rate and range (SENS motion).
  final bool fixedSettings;

  /// What else to set up on the device, shown in the protocol editor.
  final String? setupNote;

  const SensorType({
    required this.key,
    required this.label,
    required this.connection,
    required this.timestampDomain,
    required this.idPrefix,
    required this.redcapCode,
    this.defaultSamplingRateHz,
    this.defaultRangeG,
    this.fixedSettings = false,
    this.setupNote,
  });
}

/// Body location of a sensor (or the room, for cameras). Dominance and side
/// are chosen apart ([SensorDominance], [SensorSide]) and are optional.
class SensorPlacement {
  final String key;
  final String label;

  /// Short code used in sensor IDs and file names. SAVES Studio recognises
  /// `wnd`, `wd`, `thigh`, `chest`, `arm` and `shoe` in file names.
  final String short;

  /// Code of the location in the REDCap `sensor_log` instrument
  /// (`sl_location`). Wrists use [SensorDominance] to pick 1 or 2.
  final String redcapCode;

  const SensorPlacement({
    required this.key,
    required this.label,
    required this.short,
    required this.redcapCode,
  });
}

const sensorTypes = <SensorType>[
  SensorType(
    key: 'ax3',
    label: 'Axivity AX3',
    connection: 'offline',
    timestampDomain: 'device_clock_local',
    idPrefix: 'ax3',
    redcapCode: '1',
    defaultSamplingRateHz: 100,
    defaultRangeG: 8,
  ),
  SensorType(
    key: 'ax6',
    label: 'Axivity AX6',
    connection: 'offline',
    timestampDomain: 'device_clock_local',
    idPrefix: 'ax6',
    redcapCode: '2',
    defaultSamplingRateHz: 100,
    defaultRangeG: 16,
  ),
  SensorType(
    key: 'actigraph_gt3x',
    label: 'ActiGraph GT3X',
    connection: 'offline',
    timestampDomain: 'device_clock_local',
    idPrefix: 'gt3x',
    redcapCode: '10',
    defaultSamplingRateHz: 30,
    defaultRangeG: 8,
  ),
  SensorType(
    key: 'geneactiv',
    label: 'GENEActiv',
    connection: 'offline',
    timestampDomain: 'device_clock_local',
    idPrefix: 'geneactiv',
    redcapCode: '11',
    defaultSamplingRateHz: 100,
    defaultRangeG: 8,
  ),
  SensorType(
    key: 'matrix',
    label: 'Parmay Matrix',
    connection: 'offline',
    timestampDomain: 'device_clock_utc',
    idPrefix: 'matrix',
    redcapCode: '3',
    // 25 Hz and ±8 g give 7 days and 8 h of recording; more and it falls
    // under 7 days (Jairo, 2026-11-02).
    defaultSamplingRateHz: 25,
    defaultRangeG: 8,
    setupNote: 'Acelerómetro y giroscopio a 25 Hz y ±8 g, frecuencia cardiaca en tiempo real '
        '(realTime) y temperatura activada: unos 7 días y 8 h de registro. '
        'Con más frecuencia baja de 7 días.',
  ),
  SensorType(
    key: 'sens',
    label: 'SENS motion',
    connection: 'offline',
    timestampDomain: 'device_clock_utc',
    idPrefix: 'sens',
    redcapCode: '4',
    defaultSamplingRateHz: 12.5,
    defaultRangeG: 2,
    fixedSettings: true,
    setupNote: 'No se configura: graba a 12,5 Hz (rango ±2 g según el laboratorio; '
        'comprobar en la ficha del fabricante). Se descarga después.',
  ),
  SensorType(
    key: 'senswear',
    label: 'SensWear',
    connection: 'offline',
    timestampDomain: 'unknown',
    idPrefix: 'senswear',
    redcapCode: '7',
  ),
  SensorType(
    key: 'polar_h10',
    label: 'Polar H10',
    connection: 'live',
    timestampDomain: 'native_plus_host_utc',
    idPrefix: 'polar_h10',
    redcapCode: '5',
  ),
  SensorType(
    key: 'verity_sense',
    label: 'Polar Verity Sense',
    connection: 'live',
    timestampDomain: 'native_plus_host_utc',
    idPrefix: 'verity',
    redcapCode: '6',
  ),
  SensorType(
    key: 'camera',
    label: 'Cámara de vídeo',
    connection: 'video',
    timestampDomain: 'video_relative',
    idPrefix: 'cam',
    redcapCode: '8',
  ),
  SensorType(
    key: 'other',
    label: 'Otro',
    connection: 'offline',
    timestampDomain: 'unknown',
    idPrefix: 'sensor',
    redcapCode: '9',
  ),
];

const sensorPlacements = <SensorPlacement>[
  SensorPlacement(
      key: 'wrist', label: 'Muñeca', short: 'wrist', redcapCode: '1'),
  SensorPlacement(
      key: 'upper_arm', label: 'Brazo', short: 'arm', redcapCode: '5'),
  SensorPlacement(
      key: 'chest', label: 'Pecho', short: 'chest', redcapCode: '4'),
  SensorPlacement(key: 'hip', label: 'Cadera', short: 'hip', redcapCode: '7'),
  SensorPlacement(
      key: 'thigh', label: 'Muslo', short: 'thigh', redcapCode: '3'),
  SensorPlacement(
      key: 'ankle', label: 'Tobillo', short: 'ankle', redcapCode: '11'),
  SensorPlacement(
      key: 'shoe', label: 'Calzado', short: 'shoe', redcapCode: '6'),
  SensorPlacement(
      key: 'room', label: 'Fija en la sala', short: 'room', redcapCode: '8'),
  SensorPlacement(key: 'other', label: 'Otra', short: 'other', redcapCode: '9'),
];

/// Dominant or non-dominant side, for any placement (empty when it does not
/// apply, e.g. the chest strap).
class SensorDominance {
  static const dominant = 'dominant';
  static const nonDominant = 'non_dominant';
  static const values = [dominant, nonDominant];
  static const labels = {dominant: 'dominante', nonDominant: 'no dominante'};
  static const shorts = {dominant: 'd', nonDominant: 'nd'};
}

/// Left or right side, for any placement (empty when it does not apply).
class SensorSide {
  static const left = 'left';
  static const right = 'right';
  static const values = [left, right];
  static const labels = {left: 'izquierda', right: 'derecha'};
  static const shorts = {left: 'l', right: 'r'};
}

/// Placement keys of protocol files written before dominance and side were
/// separate fields.
const _legacyPlacements = <String, (String, String?, String?)>{
  'wrist_non_dominant': ('wrist', SensorDominance.nonDominant, null),
  'wrist_dominant': ('wrist', SensorDominance.dominant, null),
  'shoe_left': ('shoe', null, SensorSide.left),
  'shoe_right': ('shoe', null, SensorSide.right),
};

/// Label such as «Muñeca no dominante, izquierda».
String placementLabelOf(String? placement, String? dominance, String? side) {
  final base = sensorPlacementByKey(placement)?.label ?? placement;
  final parts = [
    if (base != null) base,
    if (dominance != null) SensorDominance.labels[dominance] ?? dominance,
  ];
  if (parts.isEmpty && side == null) return '';
  final label = parts.join(' ');
  if (side == null) return label;
  final sideLabel = SensorSide.labels[side] ?? side;
  return label.isEmpty ? sideLabel : '$label, $sideLabel';
}

/// Short code for IDs and file names: `wnd`, `wd`, `thigh_nd`, `shoe_l`,
/// `wnd_r`… (wrists keep the codes SAVES Studio already recognises).
String placementShortOf(String? placement, String? dominance, String? side) {
  final base = sensorPlacementByKey(placement)?.short;
  final dom = SensorDominance.shorts[dominance];
  final parts = <String>[
    if (base == 'wrist' && dom != null)
      'w$dom'
    else ...[
      if (base != null) base,
      if (dom != null) dom,
    ],
    if (SensorSide.shorts[side] != null) SensorSide.shorts[side]!,
  ];
  return parts.join('_');
}

/// Sampling rate and range proposed for a new sensor, from its type and
/// where it goes: Axivity at 100 Hz (±8 g; ±16 g on the shoe, where impacts
/// are larger and steps are lost at 50 Hz). Live sensors (Polar) and cameras
/// get null: the app negotiates the Polar settings itself.
({double? samplingRateHz, double? rangeG}) proposedSettings(
    String type, String? placement) {
  final t = sensorTypeByKey(type);
  if (t.connection != 'offline') return (samplingRateHz: null, rangeG: null);
  if (type == 'ax3' || type == 'ax6') {
    return (
      samplingRateHz: 100,
      rangeG: placement == 'shoe' || type == 'ax6' ? 16 : 8,
    );
  }
  return (samplingRateHz: t.defaultSamplingRateHz, rangeG: t.defaultRangeG);
}

SensorType sensorTypeByKey(String key) => sensorTypes.firstWhere(
      (t) => t.key == key,
      orElse: () => sensorTypes.last,
    );

/// Catalog placement for [key], or null for a free-text placement written by
/// an older protocol file.
SensorPlacement? sensorPlacementByKey(String? key) {
  for (final placement in sensorPlacements) {
    if (placement.key == key) return placement;
  }
  return null;
}

/// One sensor or camera configured for a session.
class SessionSensor {
  static const timestampDomains = {
    'native_plus_host_utc',
    'device_clock_utc',
    'device_clock_local',
    'video_relative',
    'unknown',
  };

  final String sensorId;

  /// Key of [sensorTypes].
  final String type;

  /// Key of [sensorPlacements] (older files may carry free text).
  final String? placement;

  /// [SensorDominance] value, or null when it does not apply.
  final String? dominance;

  /// [SensorSide] value, or null when it does not apply.
  final String? side;

  final String? serial;
  final double? samplingRateHz;
  final double? rangeG;

  /// What the sensor is for in the protocol: [SensorUse.lab] (worn in the
  /// laboratory session), [SensorUse.freeLiving] (a device taken home for
  /// the free-living days) or [SensorUse.both] (one of each, with their own
  /// serial numbers: every device is downloaded after the visit and
  /// replaced).
  final String use;

  bool get inLab => use != SensorUse.freeLiving;
  bool get inFreeLiving => use != SensorUse.lab;

  /// Serial of the device taken home for the free-living days ([serial] is
  /// the one worn in the laboratory).
  final String? freeLivingSerial;

  bool get hasFreeLivingSerial => freeLivingSerial?.trim().isNotEmpty ?? false;

  /// The evaluator ticked the laboratory device as initialized in the
  /// waiting room (offline sensors), and the free-living one.
  final bool initialized;
  final bool freeLivingInitialized;

  /// Overrides the device label of the type (needed for `other`).
  final String? deviceNameOverride;

  /// Overrides the clock of the type.
  final String? timestampDomainOverride;

  const SessionSensor({
    required this.sensorId,
    required this.type,
    this.placement,
    this.dominance,
    this.side,
    this.serial,
    this.samplingRateHz,
    this.rangeG,
    this.use = SensorUse.lab,
    this.freeLivingSerial,
    this.initialized = false,
    this.freeLivingInitialized = false,
    this.deviceNameOverride,
    this.timestampDomainOverride,
  });

  SensorType get sensorType => sensorTypeByKey(type);

  String get deviceName => deviceNameOverride ?? sensorType.label;

  String get timestampDomain =>
      timestampDomainOverride ?? sensorType.timestampDomain;

  String get connection => sensorType.connection;

  String? get placementLabel {
    final label = placementLabelOf(placement, dominance, side);
    return label.isEmpty ? null : label;
  }

  /// Code of the location in REDCap `sl_location` (wrists: 1 non-dominant,
  /// 2 dominant, 10 without dominance). Dominance and side go to
  /// `sl_dominance` and `sl_side`.
  String? get redcapLocationCode {
    final p = sensorPlacementByKey(placement);
    if (p == null) return null;
    if (p.key == 'wrist') {
      return switch (dominance) {
        SensorDominance.dominant => '2',
        SensorDominance.nonDominant => '1',
        _ => '10',
      };
    }
    return p.redcapCode;
  }

  bool get hasSerial => serial != null && serial!.trim().isNotEmpty;

  /// Device and place, for lists read by the evaluator.
  String get displayName =>
      placementLabel == null ? deviceName : '$deviceName · $placementLabel';

  /// ID made of the type prefix and the placement code (`ax3_wnd`), with a
  /// number when [taken] already has it.
  static String suggestId(
    String type,
    String? placement, {
    String? dominance,
    String? side,
    Iterable<String> taken = const [],
  }) {
    final prefix = sensorTypeByKey(type).idPrefix;
    final short = placementShortOf(placement, dominance, side);
    final base = short.isEmpty ? prefix : '${prefix}_$short';
    final used = taken.toSet();
    if (!used.contains(base)) return base;
    var n = 2;
    while (used.contains('${base}_$n')) {
      n++;
    }
    return '${base}_$n';
  }

  SessionSensor copyWith({
    String? sensorId,
    String? type,
    String? placement,
    String? dominance,
    String? side,
    String? serial,
    double? samplingRateHz,
    double? rangeG,
    String? use,
    String? freeLivingSerial,
    bool clearFreeLivingSerial = false,
    bool clearSerial = false,
    bool clearSamplingRate = false,
    bool clearRange = false,
    bool? initialized,
    bool? freeLivingInitialized,
  }) =>
      SessionSensor(
        sensorId: sensorId ?? this.sensorId,
        type: type ?? this.type,
        placement: placement ?? this.placement,
        dominance: dominance ?? this.dominance,
        side: side ?? this.side,
        serial: clearSerial ? null : serial ?? this.serial,
        samplingRateHz:
            clearSamplingRate ? null : samplingRateHz ?? this.samplingRateHz,
        rangeG: clearRange ? null : rangeG ?? this.rangeG,
        use: use ?? this.use,
        freeLivingSerial: clearFreeLivingSerial ? null : freeLivingSerial ?? this.freeLivingSerial,
        initialized: initialized ?? this.initialized,
        freeLivingInitialized: freeLivingInitialized ?? this.freeLivingInitialized,
        deviceNameOverride: deviceNameOverride,
        timestampDomainOverride: timestampDomainOverride,
      );

  Map<String, dynamic> toJson() => {
        'sensor_id': sensorId,
        'type': type,
        if (placement != null) 'placement': placement,
        if (dominance != null) 'dominance': dominance,
        if (side != null) 'side': side,
        if (hasSerial) 'serial': serial!.trim(),
        if (samplingRateHz != null) 'sampling_rate_hz': samplingRateHz,
        if (rangeG != null) 'range_g': rangeG,
        if (use != SensorUse.lab) 'use': use,
        if (hasFreeLivingSerial) 'free_living_serial': freeLivingSerial!.trim(),
        if (initialized) 'initialized': true,
        if (freeLivingInitialized) 'free_living_initialized': true,
        if (deviceNameOverride != null) 'device_name': deviceNameOverride,
        if (timestampDomainOverride != null)
          'timestamp_domain': timestampDomainOverride,
      };

  /// Reads a `sensors[]` item, or an `offline_sensors[]` item of protocol
  /// files written before sensors were configurable (no `type`).
  factory SessionSensor.fromJson(Map<String, dynamic> json) {
    final sensorId = json['sensor_id'];
    if (sensorId is! String || sensorId.trim().isEmpty) {
      throw const FormatException('Cada sensor necesita un "sensor_id".');
    }

    final timestampDomain = json['timestamp_domain']?.toString();
    if (timestampDomain != null &&
        !timestampDomains.contains(timestampDomain)) {
      throw FormatException(
        'El sensor "$sensorId" tiene un timestamp_domain no válido: '
        '$timestampDomain.',
      );
    }

    final rawType = json['type']?.toString();
    if (rawType != null && !sensorTypes.any((t) => t.key == rawType)) {
      throw FormatException(
        'El sensor "$sensorId" tiene un tipo desconocido: $rawType.',
      );
    }
    final type = rawType ?? 'other';
    final deviceName = json['device_name']?.toString();

    double? number(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is! num || value <= 0) {
        throw FormatException(
            'El sensor "$sensorId" tiene un "$key" no válido.');
      }
      return value.toDouble();
    }

    String? choice(String key, List<String> allowed) {
      final value = json[key]?.toString();
      if (value == null || value.isEmpty) return null;
      if (!allowed.contains(value)) {
        throw FormatException(
            'El sensor "$sensorId" tiene un "$key" no válido: $value.');
      }
      return value;
    }

    var placement = json['placement']?.toString();
    var dominance = choice('dominance', SensorDominance.values);
    var side = choice('side', SensorSide.values);
    final legacy = _legacyPlacements[placement];
    if (legacy != null) {
      placement = legacy.$1;
      dominance ??= legacy.$2;
      side ??= legacy.$3;
    }

    return SessionSensor(
      sensorId: sensorId.trim(),
      type: type,
      placement: placement,
      dominance: dominance,
      side: side,
      serial: json['serial']?.toString(),
      samplingRateHz: number('sampling_rate_hz'),
      rangeG: number('range_g'),
      // Older files: `free_living: true` was a sensor that stayed on.
      use: choice('use', SensorUse.values) ??
          (json['free_living'] == true ? SensorUse.both : SensorUse.lab),
      freeLivingSerial: json['free_living_serial']?.toString(),
      initialized: json['initialized'] == true,
      freeLivingInitialized: json['free_living_initialized'] == true,
      // Older files name the device and its clock themselves.
      deviceNameOverride:
          type == 'other' ? (deviceName ?? sensorId.trim()) : null,
      timestampDomainOverride:
          rawType == null ? (timestampDomain ?? 'unknown') : timestampDomain,
    );
  }
}

/// What the evaluator does with the sensors once the session is saved,
/// before the participant leaves. Offline devices are downloaded and their
/// files go to the session folder; those that stay on for the free-living
/// days are then started again (an Axivity has to stop recording to be
/// downloaded). A live one that stays on only starts its free-living
/// recording: its laboratory data is already in the folder.
class SensorsAfterSession {
  SensorsAfterSession(Iterable<SessionSensor> sensors)
      : download = [
          for (final s in sensors)
            if (s.connection == 'offline' && s.inLab) s,
        ],
        downloadAndRestart = const [],
        // The free-living set: other devices, each with its own serial.
        startFreeLiving = [
          for (final s in sensors)
            if (s.inFreeLiving && s.connection != 'video') s,
        ];

  final List<SessionSensor> download;
  final List<SessionSensor> downloadAndRestart;
  final List<SessionSensor> startFreeLiving;

  bool get isEmpty =>
      download.isEmpty && downloadAndRestart.isEmpty && startFreeLiving.isEmpty;

  /// Downloaded sensors without a serial number: SAVES finds their files by
  /// the sensor ID in the file name.
  List<SessionSensor> get withoutSerial => [
        for (final s in [...download, ...downloadAndRestart])
          if (!s.hasSerial) s,
      ];

  /// File name (without extension) for a sensor without a serial number,
  /// from the session folder (`…/R4H_001/D0` → `R4H_001_D0_matrix_wnd`).
  static String? fileNameFor(SessionSensor sensor, String? sessionDir) {
    if (sessionDir == null) return null;
    final parts =
        sessionDir.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).toList();
    if (parts.length < 2) return null;
    return '${parts[parts.length - 2]}_${parts.last}_${sensor.sensorId}';
  }
}
