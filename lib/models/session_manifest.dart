import '../services/lab_redcap_service.dart';
import 'activity_battery.dart';
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
/// additions, which keep the schema version.
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
}) {
  final sensors = <String, dynamic>{};

  for (final device in protocolConfiguration.devices) {
    final liveSensors = device.sensors.difference({'video'});
    if (!device.isLive || liveSensors.isEmpty) continue;

    sensors[device.deviceId] = {
      'present': true,
      'timestamp_domain': 'native_plus_host_utc',
      'device_name': device.deviceName,
      if (device.placement != null) 'placement': device.placement,
      'connection': 'live',
    };
  }

  final cameras = <Map<String, dynamic>>[];

  for (final sensor in battery?.sensors ?? const <SessionSensor>[]) {
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
    final live = sensor.connection == 'live'
        ? protocolConfiguration.deviceById(sensor.sensorId) ??
            protocolConfiguration.deviceById(sensor.type)
        : null;
    if (live != null && sensors.containsKey(live.deviceId)) {
      final entry = sensors[live.deviceId] as Map<String, dynamic>;
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
    'participants': participants.map((p) => p.toJson()).toList(),
    'activities': activities.map((a) => a.toJson()).toList(),
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
