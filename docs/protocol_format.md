# Protocol file

A protocol file is an optional JSON file loaded on the participant screen ("Cargar protocolo de actividades"). It names each activity of the battery, its Compendium code and its duration, and lists the offline sensors worn in the session. Without a protocol file the timer works as before: activities are numbered and all last the duration set in the Research Monitor.

See [`protocols/example_battery.json`](protocols/example_battery.json). The activities and codes there are an example; check codes against the current Adult Compendium of Physical Activities before using them.

| Field | Required | Content |
|---|---|---|
| `protocol_id` | yes | Identifier written to the session manifest |
| `protocol_version` | no | Version of the battery |
| `activities[]` | yes | In order; activity 1 of the session is the first item |
| `activities[].name` | yes | Read aloud at the start of the activity and shown in the Research Monitor |
| `activities[].compendium_code` | no | Five-digit Compendium code |
| `activities[].duration_seconds` | no | Main-phase duration; when missing, the Research Monitor duration is used |
| `offline_sensors[]` | no | `sensor_id`, `device_name`, `placement`, `timestamp_domain` (`device_clock_utc`, `device_clock_local`, `video_relative` or `unknown`) |

Activities beyond the end of the list fall back to numbered activities with the Research Monitor duration. The protocol is saved with the local backup, so a resumed session keeps it.

## Session output

The session folder contains `session_manifest.json` in the format read by [SAVES](https://github.com/PROFITH/saves_app/blob/main/docs/session_format.md) (version 1.1), `sync_windows.csv` and `activity_markers.csv`. With a protocol file, each activity in the manifest and in `activity_markers.csv` carries `activity_name`, `compendium_code` and `planned_duration_seconds`, the manifest carries `protocol`, and `sensors` lists the offline sensors next to the live ones.
