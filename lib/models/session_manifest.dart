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
/// `video`, not under `sensors`); offline sensors and activity metadata come
/// from [battery] when a protocol file was loaded.
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
    if (liveSensors.isEmpty) continue;

    sensors[device.deviceId] = {
      'present': true,
      'timestamp_domain': 'native_plus_host_utc',
      'device_name': device.deviceName,
      if (device.placement != null) 'placement': device.placement,
      'connection': 'live',
    };
  }

  for (final sensor in battery?.offlineSensors ?? const <OfflineSensor>[]) {
    sensors[sensor.sensorId] = {
      'present': true,
      'timestamp_domain': sensor.timestampDomain,
      'device_name': sensor.deviceName,
      if (sensor.placement != null) 'placement': sensor.placement,
      'connection': 'offline',
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
    },
    'sensors': sensors,
  };
}
