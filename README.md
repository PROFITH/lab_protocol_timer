# Lab Protocol Timer — Accelerometer & REDCap Sync

**Lab Protocol Timer** is a cross-platform and web application built with Flutter, designed to standardize timing, provide voice-guided transitions, and synchronize laboratory protocols for wearable sensor research (accelerometry).

The app captures high-precision timestamps to isolate active exercise windows from transition and surrounding intervals, guides mechanical sensor impact alignment for clock-drift correction, and exports structured batch data directly to the **REDCap API**.

> **Note:** The in-app interface, visual prompts, and Text-to-Speech voice guidance are in **Spanish (`es-ES`)**.

---

## Features

- **Accelerometer Time-Synchronization:** Visual and acoustic prompts during pre- and post-activity static phases to perform controlled sensor-to-sensor clapping events, facilitating offline clock synchronization.
- **Precise Activity Isolation:** Explicit logging of exact exercise boundaries (`activityStartTime`, `activityEndTime`), separating movement from static baseline and transition intervals.
- **Multi-Participant Setup:** Simultaneous tracking of multiple participants in a single lab trial, allowing individual assignment of Participant IDs and REDCap longitudinal event arms (e.g., *Day 0 — Initial Visit* or *Day 8 — Final Visit*).
- **Aggregated REDCap Batch Export:** Automated flat-record data transfer delivering key aggregated metrics: total protocol duration, total activity duration, total transition time, and total completed stations.
- **Local State Persistence & Recovery:** Automatic local storage (`SharedPreferences`) on every lap/activity to restore interrupted sessions following accidental tab closures or browser reloads.
- **Audio & TTS Voice Prompts:** Integrated audio alerts and Text-to-Speech narration for phase transitions and sensor synchronization commands.

---

## Protocol Structure per Activity

1. **Initial Static Baseline (30 s default):** Subject remains motionless. A 5-second countdown prompts the initial accelerometer synchronization clap.
2. **Main Activity (Configurable duration):** Active exercise phase. Triggers and records `activityStartTime`.
3. **Final Static Baseline (30 s default):** Immediate cessation of movement and logging of `activityEndTime`. The first 5 seconds prompt the final synchronization clap.
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

Set your REDCap endpoint and API credentials in `lib/services/lab_redcap_service.dart`:

```dart
static const String _redcapUrl = '[https://your-redcap-instance.org/api/](https://your-redcap-instance.org/api/)';
static const String _apiToken = 'YOUR_REDCAP_API_TOKEN';
```

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