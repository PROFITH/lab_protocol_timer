# Session setup and protocol file

## Setting up a session

The participant screen has a **Configuración de la sesión** block under the participants:

1. **Protocolo de actividades**: a list with the base protocols bundled with the app (`assets/protocols/`: RUN4HEALTH, WEARGAP day 0, WEARGAP day 8), the protocols saved on this computer, and "Sin protocolo" (numbered activities that all last the Research Monitor duration, as before). When the visit of the first participant changes, a protocol of the same study meant for that visit replaces the current one (WEARGAP day 0 ↔ day 8).
2. **Editar actividades y sensores** opens an editor with two tabs:
   - *Actividades*: add, remove, duplicate and drag to reorder. Each activity has a name (read aloud), a Compendium code picked from the bundled 2024 Compendium (the MET comes with it), a duration, optional static phases that override the Research Monitor values, and notes for the evaluators. *Añadir caja de calibración* adds a calibration box segment.
   - *Sensores*: type (Axivity AX3/AX6, ActiGraph GT3X, GENEActiv, Parmay Matrix, SENS motion, SensWear, Polar H10, Polar Verity Sense, camera, other), placement with optional dominance (dominant / non-dominant) and side (left / right), serial number, sampling rate, range and whether it stays on for the free-living days. The sensor ID (`ax3_wnd`, `ax3_wnd_r`, `ax6_shoe_l`, `gt3x_hip_r`...) is suggested from type, placement, dominance and side and is the key in the manifest and in file names.
   - *Guardar como protocolo* stores the edited protocol on this computer under a name; *Exportar JSON* writes it to a file for another computer. *Usar en esta sesión* applies the changes to this session only.
3. **Importar JSON** loads a protocol file (format below).

Starting a session warns if a sensor has no serial number, and remembers the setup for each participant. When the same participant ID is typed again (closing visit), its sensors and serials come back: with the same protocol, exactly as used; with another protocol of the study, that protocol's sensor list with the serials of the sensors that have the same ID.

## Protocol file

See the base protocols in [`../assets/protocols/`](../assets/protocols/) and [`base_protocols.md`](base_protocols.md) for their sources and open points. [`protocols/example_battery.json`](protocols/example_battery.json) is the older, minimal format, which still loads.

| Field | Required | Content |
|---|---|---|
| `protocol_id` | yes | Identifier written to the session manifest and to `ws_protocol_id` |
| `protocol_version` | no | Version of the battery |
| `title`, `study` | no | Name in the list; study whose protocols replace each other when the visit changes |
| `moments` | no | REDCap events the protocol is meant for (empty: any) |
| `activities[]` | yes | In order; activity 1 of the session is the first item |
| `activities[].name` | yes | Read aloud at the start of the activity and shown in the Research Monitor |
| `activities[].kind` | no | `activity` (default) or `calibration` |
| `activities[].compendium_code`, `met` | no | Five-digit 2024 Compendium code and its MET |
| `activities[].duration_seconds` | no | Main-phase duration; when missing, the Research Monitor duration is used |
| `activities[].prep_seconds`, `post_seconds` | no | Static phases before and after; when missing, the Research Monitor values |
| `activities[].faces` | no | Calibration: box faces announced during the main phase (default 6) |
| `activities[].notes` | no | Notes for the evaluators, not read aloud |
| `sensors[]` | no | `sensor_id`, `type`, `placement`, `dominance`, `side`, `serial`, `sampling_rate_hz`, `range_g`, `free_living` |
| `offline_sensors[]` | no | Older format: `sensor_id`, `device_name`, `placement`, `timestamp_domain` |

`type` is one of `ax3`, `ax6`, `actigraph_gt3x`, `geneactiv`, `matrix`, `sens`, `senswear`, `polar_h10`, `verity_sense`, `camera`, `other`; `placement` one of `wrist`, `upper_arm`, `chest`, `hip`, `thigh`, `ankle`, `shoe`, `room`, `other`; `dominance` `dominant` or `non_dominant` and `side` `left` or `right`, both optional for every placement (leave them out when they do not apply, e.g. the chest strap). Older files with `wrist_non_dominant`, `wrist_dominant`, `shoe_left` or `shoe_right` still load and are split into placement, dominance and side. The manifest writes `placement`, `dominance`, `side` and a readable `placement_label` ("Muñeca no dominante, izquierda").

Activities beyond the end of the list fall back to numbered activities with the Research Monitor duration. The protocol is saved with the local backup, so a resumed session keeps it.

## Calibration box segments

A `calibration` segment runs through the same phases as an activity: the static start phase is the box lying still (2 min in the base protocols) with SINCRONIZAR for the three taps, the main phase announces "Gire la caja. Cara n." on each face, and the static end phase takes the closing taps. Calibration segments are not activities in REDCap: the first one fills `ws_calibration`, `ws_calib_start` and `ws_calib_end`, they get no `lab_activity` instance or `act_<n>` slot, and they count as time between activities in `protocol_feasibility`. They are in the manifest and in `activity_markers.csv` with `activity_kind: calibration`.

## Session output

The session folder contains `session_manifest.json` in the format read by [SAVES](https://github.com/PROFITH/saves_app/blob/main/docs/session_format.md) (version 1.1), `sync_windows.csv` and `activity_markers.csv`. With a protocol, each activity in the manifest carries `activity_name`, `compendium_code`, `planned_duration_seconds` and, when known, `met`; the manifest carries `protocol`; `sensors` lists every configured sensor (the Polar H10 keeps its live entry and gains its serial), with `device_type`, `placement_label`, `serial`, `sampling_rate_hz`, `range_g` and `free_living` as optional additions to the 1.1 fields; cameras go to `video.cameras`. `lab_activity` in REDCap now also receives `la_mets`.
