import '../services/lab_redcap_service.dart';
import 'activity_battery.dart';
import 'device_configuration.dart';
import 'protocol_configuration.dart';
import 'sync_window.dart';

/// Version of the session manifest read by SAVES
/// (https://github.com/PROFITH/saves_app/blob/main/docs/session_format.md).
const String sessionManifestSchemaVersion = '1.1';

const _videoExtensions = ['.mp4', '.mov', '.avi'];

/// Builds the `session_manifest.json` content of one laboratory session.
///
/// Live devices come from [protocolConfiguration] (the camera is listed under
/// `video`, not under `sensors`); the sensors set up for the session, their
/// serials and placements, and the activity metadata come from [battery].
/// Fields beyond the SAVES 1.1 list (`device_type`, `serial`...) are optional
/// additions, which keep the schema version. Each activity carries the
/// instance of `lab_activity` it was sent to in REDCap ([redcapInstances]).
///
/// With [participantId] the manifest is the one of that participant's
/// folder: their own sensors (and the cameras the session shares), keyed by
/// sensor ID, and only them under `participants`; the other participants of
/// the session go to `session_participants`.
Map<String, dynamic> buildSessionManifest({
  required String sessionId,
  required DateTime sessionStartTime,
  required DateTime sessionEndTime,
  required List<ParticipantEntry> participants,
  required List<ActivityLog> activities,
  required List<SyncWindow> syncWindows,
  required List<String> generatedFiles,
  required ProtocolConfiguration protocolConfiguration,
  ActivityBattery? battery,
  Map<ActivityLog, int> redcapInstances = const {},
  String? participantId,
}) {
  final sensors = <String, dynamic>{};

  ParticipantEntry? own;
  for (final p in participants) {
    if (participantId != null && p.participantId == participantId) own = p;
  }
  final devices = participantId == null
      ? protocolConfiguration.devices
      : protocolConfiguration.devicesOf(participantId);

  for (final device in devices) {
    final liveSensors = device.sensors.difference({'video'});
    if (!device.isLive || liveSensors.isEmpty) continue;

    // The signals asked to the device and the files that got rows, so SAVES
    // knows what to look for (`polar_<signal>_<sensor>_<stamp>.csv`).
    final files = [
      for (final path in generatedFiles)
        path.split(RegExp(r'[\\/]')).last,
    ].where((name) => name.startsWith('polar_') && name.contains('_${device.sensorId}_')).toList()
      ..sort();
    sensors[device.sensorId] = {
      'present': true,
      'timestamp_domain': 'native_plus_host_utc',
      'device_name': device.deviceName,
      if (device.placement != null) 'placement': device.placement,
      'connection': 'live',
      'signals': liveSensors.toList()..sort(),
      'files': files,
    };
  }

  final cameras = <Map<String, dynamic>>[];

  // The sensors of the folder: the participant's own, with the cameras of
  // the session, or the whole layout.
  final layout = battery?.sensors ?? const <SessionSensor>[];
  final listed = own != null && own.sensors.isNotEmpty
      ? [
          ...own.sensorsOr(layout),
          for (final sensor in layout)
            if (sensor.connection == 'video') sensor,
        ]
      : layout;

  for (final sensor in listed) {
    final details = <String, dynamic>{
      if (sensor.type != 'other') 'device_type': sensor.type,
      if (sensor.dominance != null) 'dominance': sensor.dominance,
      if (sensor.side != null) 'side': sensor.side,
      if (sensor.placementLabel != null &&
          sensor.placementLabel != sensor.placement)
        'placement_label': sensor.placementLabel,
      if (sensor.hasSerial) 'serial': sensor.serial!.trim(),
      if (sensor.samplingRateHz != null)
        'sampling_rate_hz': sensor.samplingRateHz,
      if (sensor.rangeG != null) 'range_g': sensor.rangeG,
      if (sensor.freeLiving) 'free_living': true,
    };

    if (sensor.connection == 'video') {
      cameras.add({
        'camera_id': sensor.sensorId,
        if (sensor.placement != null) 'placement': sensor.placement,
        ...details,
      });
      continue;
    }

    // A live device of the Research Monitor (Polar H10, Verity Sense) keeps
    // its entry; the session setup adds its serial and placement. Sessions
    // with a sensor list name the device by its sensor ID; the default
    // configuration names it by type.
    DeviceConfiguration? liveDevice(String id) {
      for (final device in devices) {
        if (device.isLive && device.sensorId == id) return device;
      }
      return null;
    }

    final live = sensor.connection == 'live'
        ? liveDevice(sensor.sensorId) ?? liveDevice(sensor.type)
        : null;
    if (live != null && sensors.containsKey(live.sensorId)) {
      final entry = sensors[live.sensorId] as Map<String, dynamic>;
      if (sensor.placement != null) entry['placement'] = sensor.placement;
      entry.addAll(details);
      continue;
    }

    sensors[sensor.sensorId] = {
      'present': true,
      'timestamp_domain': sensor.timestampDomain,
      'device_name': sensor.deviceName,
      if (sensor.placement != null) 'placement': sensor.placement,
      'connection': sensor.connection,
      ...details,
    };
  }

  return {
    'schema_version': sessionManifestSchemaVersion,
    'session_id': sessionId,
    'created_by': 'lab_protocol_timer',
    'session_start_time_utc': sessionStartTime.toUtc().toIso8601String(),
    'session_end_time_utc': sessionEndTime.toUtc().toIso8601String(),
    if (battery != null)
      'protocol': {
        'protocol_id': battery.protocolId,
        if (battery.protocolVersion != null)
          'protocol_version': battery.protocolVersion,
      },
    'participants': [
      for (final p in own == null ? participants : [own]) p.manifestJson(),
    ],
    if (own != null && participants.length > 1)
      'session_participants': [for (final p in participants) p.participantId],
    'activities': [
      for (final a in activities)
        {
          ...a.toJson(),
          if (redcapInstances[a] != null) 'redcap_instance': redcapInstances[a],
        },
    ],
    'sync_windows': syncWindows.map((w) => w.toJson()).toList(),
    'video': {
      'files': generatedFiles
          .where(
            (path) => _videoExtensions.any(path.toLowerCase().endsWith),
          )
          .map((path) => path.split(RegExp(r'[\\/]')).last)
          .toList(),
      if (cameras.isNotEmpty) 'cameras': cameras,
    },
    'sensors': sensors,
  };
}
