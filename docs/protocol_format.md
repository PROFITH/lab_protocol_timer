# Session setup and protocol file

## Setting up a session

The start screen goes in three numbered steps. Steps 2 and 3 are inactive (dimmed, no taps) until every participant has an ID, so each participant gets their ID before anything is assigned to them:

1. **Participantes**: ID and visit of each participant (IDs cannot repeat).
2. **Protocolo y sensores**: the **Configuración de la sesión** block below, then a card per participant with a serial-number field for every sensor of the protocol (cameras are the session's, not a participant's), and the first activity.
3. **Carpetas de la sesión**: the folder of each participant, proposed as `<data folder>/<study>_<ID>/<visit>` (`R4H_001/D0`) and changeable one by one (**Cambiar**; **Automática** goes back to the proposed one); the data folder itself can be changed too.

The **Configuración de la sesión** block:

1. **Protocolo de actividades**: a list with the base protocols bundled with the app (`assets/protocols/`: RUN4HEALTH, WEARGAP day 0, WEARGAP day 8), the protocols saved on this computer, and "Sin protocolo" (numbered activities that all last the Research Monitor duration, as before). When the visit of the first participant changes, a protocol of the same study meant for that visit replaces the current one (WEARGAP day 0 ↔ day 8).
2. **Editar actividades y sensores** opens an editor with two tabs:
   - *Actividades*: add, remove, duplicate and drag to reorder. Each activity has a name (read aloud), a Compendium code picked from the bundled 2024 Compendium (the MET comes with it), a duration, optional static phases that override the Research Monitor values, and notes for the evaluators. *Añadir caja de calibración* adds a calibration box segment.
   - *Sensores*: type (Axivity AX3/AX6, ActiGraph GT3X, GENEActiv, Parmay Matrix, SENS motion, SensWear, Polar H10, Polar Verity Sense, camera, other), placement with optional dominance (dominant / non-dominant) and side (left / right), serial number, sampling rate, range and whether it stays on for the free-living days. The sensor ID (`ax3_wnd`, `ax3_wnd_r`, `ax6_shoe_l`, `gt3x_hip_r`...) is suggested from type, placement, dominance and side and is the key in the manifest and in file names.
   - *Guardar como protocolo* stores the edited protocol on this computer under a name; *Exportar JSON* writes it to a file for another computer. *Usar en esta sesión* applies the changes to this session only.
3. **Importar JSON** loads a protocol file (format below).

The sensor list of the protocol is the layout every participant wears; the serial numbers are typed per participant in step 2 (a serial set in the editor is only the default for a session with one participant). Starting a session warns if a sensor has no serial number, and remembers the setup of each participant with their own serials. When the same participant ID is typed again (closing visit), their serials come back, and for the first participant also the protocol: with the same protocol, exactly as used; with another protocol of the study, that protocol's sensor list with the serials of the sensors that have the same ID.

## Protocol file

See the base protocols in [`../assets/protocols/`](../assets/protocols/) and [`base_protocols.md`](base_protocols.md) for their sources and open points. [`protocols/example_battery.json`](protocols/example_battery.json) is the older, minimal format, which still loads.

| Field | Required | Content |
|---|---|---|
| `protocol_id` | yes | Identifier written to the session manifest and to `ws_protocol_id` |
| `protocol_version` | no | Version of the battery |
| `title`, `study` | no | Name in the list; study whose protocols replace each other when the visit changes |
| `moments` | no | REDCap events the protocol is meant for (empty: any) |
| `lap_mode` | no | `false`: activities follow one after another and the session waits only before an activity with `wait_before` and after the last one; `true`: it waits after every activity; missing: the Research Monitor setting |
| `activities[]` | yes | In order; activity 1 of the session is the first item |
| `activities[].name` | yes | Read aloud at the start of the activity and shown in the Research Monitor |
| `activities[].kind` | no | `activity` (default) or `calibration` |
| `activities[].compendium_code`, `met` | no | Five-digit 2024 Compendium code and its MET |
| `activities[].duration_seconds` | no | Main-phase duration; when missing, the Research Monitor duration is used |
| `activities[].prep_seconds`, `post_seconds` | no | Static phases before and after; when missing, the Research Monitor values |
| `activities[].wait_before` | no | `true`: the session waits (lap) before this activity until the evaluator starts it, also with `lap_mode` false. For a change of machine or place |
| `activities[].faces` | no | Calibration: box faces announced during the main phase (default 6) |
| `activities[].notes` | no | Notes for the evaluators, not read aloud |
| `sensors[]` | no | `sensor_id`, `type`, `placement`, `dominance`, `side`, `serial`, `sampling_rate_hz`, `range_g`, `free_living` |
| `offline_sensors[]` | no | Older format: `sensor_id`, `device_name`, `placement`, `timestamp_domain` |

`type` is one of `ax3`, `ax6`, `actigraph_gt3x`, `geneactiv`, `matrix`, `sens`, `senswear`, `polar_h10`, `verity_sense`, `camera`, `other`; `placement` one of `wrist`, `upper_arm`, `chest`, `hip`, `thigh`, `ankle`, `shoe`, `room`, `other`; `dominance` `dominant` or `non_dominant` and `side` `left` or `right`, both optional for every placement (leave them out when they do not apply, e.g. the chest strap). Older files with `wrist_non_dominant`, `wrist_dominant`, `shoe_left` or `shoe_right` still load and are split into placement, dominance and side. The manifest writes `placement`, `dominance`, `side` and a readable `placement_label` ("Muñeca no dominante, izquierda").

Activities beyond the end of the list fall back to numbered activities with the Research Monitor duration. The protocol is saved with the local backup, so a resumed session keeps it.

## Calibration box segments

A `calibration` segment runs through the same phases as an activity: the static start phase is the box lying still (2 min in the base protocols) with SINCRONIZAR for the three taps, the main phase announces "Gire la caja. Cara n." on each face, and the static end phase takes the closing taps. Calibration segments are not activities in REDCap: the first one fills `ws_calibration`, `ws_calib_start` and `ws_calib_end`, they get no `lab_activity` instance or `act_<n>` slot, and they count as time between activities in `protocol_feasibility`. They are in the manifest and in `activity_markers.csv` with `activity_kind: calibration`.

## Session output

Each participant's folder contains `session_manifest.json` in the format read by [SAVES](https://github.com/PROFITH/saves_app/blob/main/docs/session_format.md) (version 1.1), `sync_windows.csv` and `activity_markers.csv`. A session with several participants writes one folder per participant: the state, event log, markers and sync windows are the same in all of them, each manifest lists its participant under `participants` (the others under `session_participants`) and that participant's sensors keyed by sensor ID (`polar_h10`, never the monitor's `polar_h10@002`), and the Polar files of each participant's live sensors are in their folder; the videos and the video log of the session are copied to every folder. Sessions started before 1.2.0 keep their single folder. With a protocol, each activity in the manifest carries `activity_name`, `compendium_code`, `planned_duration_seconds` and, when known, `met`; the manifest carries `protocol`; `sensors` lists every configured sensor (the Polar H10 keeps its live entry and gains its serial), with `device_type`, `placement_label`, `serial`, `sampling_rate_hz`, `range_g` and `free_living` as optional additions to the 1.1 fields; cameras go to `video.cameras`. `lab_activity` in REDCap now also receives `la_mets`. Each attempt in the manifest also carries `redcap_instance`, the `lab_activity` instance it was sent to (one per attempt that is not a calibration segment, in the order of the session, skipped attempts included), so SAVES Studio can send the steps and sit-to-stands counted on the video to the same instance.
