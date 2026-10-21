# Lab Protocol Timer — Accelerometer & REDCap Sync

**Lab Protocol Timer** is a cross-platform and web application built with Flutter, designed to standardize timing, provide voice-guided transitions, and synchronize laboratory protocols for wearable sensor research (accelerometry).

The app captures high-precision timestamps to isolate active exercise windows from transition and surrounding intervals, guides mechanical sensor impact alignment for clock-drift correction, and exports structured batch data directly to the **REDCap API**.

> **Note:** The in-app interface, visual prompts, and Text-to-Speech voice guidance are in **Spanish (`es-ES`)**.

---

## Features

- **Accelerometer Time-Synchronization:** Visual and acoustic prompts during pre- and post-activity static phases for a sharp clap or a jump that every sensor feels, so SAVES can synchronize the offline sensors and the video.
- **Precise Activity Isolation:** Explicit logging of exact exercise boundaries (`activityStartTime`, `activityEndTime`), separating movement from static baseline and transition intervals.
- **Multi-Participant Setup:** Simultaneous tracking of multiple participants in a single lab trial, allowing individual assignment of Participant IDs and REDCap longitudinal event arms (e.g., *Day 0 — Initial Visit* or *Day 8 — Final Visit*).
- **Aggregated REDCap Batch Export:** Automated flat-record data transfer delivering key aggregated metrics: total protocol duration, total activity duration, total transition time, and total completed stations.
- **Local State Persistence & Recovery:** Automatic local storage (`SharedPreferences`) on every lap/activity to restore interrupted sessions following accidental tab closures or browser reloads.
- **Audio & TTS Voice Prompts:** Integrated audio alerts and Text-to-Speech narration for phase transitions and sensor synchronization commands.
- **Session Setup:** Pick a base protocol (RUN4HEALTH, WEARGAP day 0 and day 8) or a saved one, edit its activities (order, 2024 Compendium code and MET, durations, calibration box segments) and sensors (type, including ActiGraph GT3X and GENEActiv; placement with optional dominance and side; serial), and save it under a name; the closing visit reuses each participant's sensors. JSON import and export remain; see [docs/protocol_format.md](docs/protocol_format.md) and [docs/base_protocols.md](docs/base_protocols.md).
- **SAVES Session Output:** Each session folder holds `session_manifest.json` (format 1.1), `sync_windows.csv` and `activity_markers.csv`, read by [SAVES](https://github.com/PROFITH/saves_app) to synchronize offline sensors and video.

---

## Protocol Structure per Activity

1. **Initial Static Baseline (30 s default):** Subject remains motionless. A 3-2-1 countdown puts the go for the synchronization clap or jump in the middle of the phase (15 s into a 30-s phase).
2. **Main Activity (Configurable duration):** Active exercise phase. Triggers and records `activityStartTime`.
3. **Final Static Baseline (30 s default):** Immediate cessation of movement and logging of `activityEndTime`, with a second clap or jump after the same countdown.
4. **Lap / Transition Mode:** Manual pause interval for station rotation or protocol completion.

---

## Getting Started

Ensure you have the [Flutter SDK](https://docs.flutter.dev/get-started/install) installed.

1. **Clone the repository:**
   ```sh
   git clone [https://github.com/PROFITH/lab_protocol_timer.git](https://github.com/PROFITH/lab_protocol_timer.git)
   cd lab_protocol_timer
   ```

2. **Install dependencies**:
    ```sh
    flutter pub get
    ```

3. **Run the app**:
    ```sh
    flutter run --release
    ```

## REDCap Configuration

REDCap is optional. On the start screen, **REDCap (opcional) → Conectar** asks for the API address (default `https://redcap.ugr.es/api/`) and the project's API token, tries them (**Probar conexión** shows the project title and its events) and keeps them on this computer. The same build works with any REDCap project: the visit list shows the events of the project the token belongs to (RUN4HEALTH's Day 0 and Day 8 until REDCap has answered once), and in a project without events the records go without `redcap_event_name`. **Quitar token** removes it.

Without a token, nothing is sent: each session is saved only in its folder, with the records in `redcap_records.json`, and **Enviar a REDCap una sesión guardada…** sends them once a token is set.

The token is never written in the code. A build can still bring one, used while none is set in the app:

```sh
flutter build windows --release --dart-define=REDCAP_TOKEN=<project token>
# another REDCap: --dart-define=REDCAP_URL=https://your-redcap-instance.org/api/
build\windows\x64\runner\Release\lab_protocol_timer.exe
```

Another project needs the same instruments and fields (below); if one is missing, REDCap refuses that import and the console says which.

At the end of a session the app sends three imports, so one that fails does not stop the others: the protocol summary (`protocol_feasibility`, fields below), the session (`wearable_session`) with one instance of the repeating instrument `lab_activity` per attempt, and the fitness-test fields of `physical_fitness`. `lab_activity` must be enabled as a repeating instrument in the visit events. If an import fails, the console shows why and **Reintentar REDCap** sends it again.

### Required REDCap Data Dictionary Fields

Ensure your REDCap project instrument contains the following field variables to properly receive the batch sync payload:

| Variable Name | Field Type | Validation / Format | Description |
| :--- | :--- | :--- | :--- |
| `record_id` | Text Box | — | Unique Participant ID / Record Identifier |
| `redcap_event_name` | System / Event | — | Target longitudinal arm (`da_0__visita_inici_arm_1` / `da_8__visita_final_arm_1`) |
| `session_start_time` | Text Box | Datetime (Y-M-D H:M:S) or ISO-8601 | Global protocol session start timestamp |
| `session_end_time` | Text Box | Datetime (Y-M-D H:M:S) or ISO-8601 | Global protocol session end timestamp |
| `lab_total_stations` | Text Box | Integer | Total count of completed activities / stations |
| `total_protocol_seconds` | Text Box | Number (2 decimal places) | Total duration of the test session in seconds |
| `total_activity_seconds` | Text Box | Number (2 decimal places) | Aggregated time spent performing activities in seconds |
| `total_transition_seconds` | Text Box | Number (2 decimal places) | Total transition / baseline interval time in seconds |
| `act_{N}_start_time` | Text Box | Datetime (Y-M-D H:M:S) or ISO-8601 | Start timestamp for activity *N* (e.g., `act_1_start_time`, `act_2_start_time`) |
| `act_{N}_end_time` | Text Box | Datetime (Y-M-D H:M:S) or ISO-8601 | End timestamp for activity *N* (e.g., `act_1_end_time`, `act_2_end_time`) |

> **Note:** Define as many `act_{N}_start_time` and `act_{N}_end_time` pairs in your REDCap instrument as the maximum number of stations/activities planned in your lab protocol.

---

## Funding & Acknowledgments

This software was developed as part of the **RUN4HEALTH** research project, funded by the **Universidad de Granada (UGR)**.

- **Lead Developer & Protocol Adaptation:** Jairo Hidalgo Migueles (Universidad de Granada).
- **RUN4HEALTH Co-PI:** Marta de la Flor Alemany (Universidad de Granada)
- **Base Upstream Project:** Forked and extended from [plinkr/training_timer](https://github.com/plinkr/training_timer) by Aliet Expósito García (licensed under the MIT License).

---

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.