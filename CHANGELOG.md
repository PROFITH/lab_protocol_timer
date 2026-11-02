# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] - 2026-11-02

### Changed

- **Participants first:** the start screen goes in three steps. 1 Participantes (ID and visit); 2 Protocolo y sensores, with a serial-number field for every sensor of the protocol **per participant** (cameras are the session's); 3 Carpetas de la sesión, one folder per participant, proposed as `<data folder>/<study>_<ID>/<visit>` and changeable one by one. Steps 2 and 3 are inactive until every participant has an ID, and IDs cannot repeat. Serials typed in the protocol editor are only the default for a session with one participant.
- **One folder per participant:** a session with several participants writes a folder for each one (before, one folder `R4H_001+002/D0` for all). Every folder holds the session state, event log, activity markers and sync windows; each manifest lists its participant (the others under `session_participants`) and that participant's sensors and serials, keyed by sensor ID; the Polar files of a participant's live sensors go to their folder, with `participant_id` set to that participant (before, `001;002`); the videos and the video log are copied to every folder. SAVES opens any folder on its own, and each one is uploaded separately. The Research Monitor tells the devices of different participants apart as `polar_h10@002`. Cancelling renames every folder; a session is resumed from any of its folders and listed once.
- **Remembered setups** keep the sensors and serials of each participant separately.
- **Built-in protocols:** «RUN4HEALTH (base)» brings the pilot batteries for day 0 and day 8; «RUN4HEALTH (WEARGAP)» is removed, so the app offers one pilot battery per visit.

## [1.1.0] - 2026-11-02

### Added

- **Microphone of the video:** the camera dialog of the Research Monitor has a «Micrófono» list. By default the video records the Windows default recording device (before, the first microphone Windows listed, which with DroidCam could be its virtual microphone); another one can be chosen and is remembered on that computer. It needs the vendored `camera_windows` in `packages/camera_windows` (0.2.6+5 with the choice of audio device).
- **Every signal of the Polar Verity Sense:** besides heart rate and ACC, the Research Monitor now records the raw PPG (`polar_ppg_*`, three channels plus ambient light, 55 Hz), the pulse-to-pulse intervals of Polar's PPI algorithm (`polar_ppi_*`, with its heart rate, error estimate and flags), the gyroscope (`polar_gyro_*`, dps) and the magnetometer (`polar_mag_*`, gauss), each with the sensor's own time and mapped to the host clock like ACC and ECG. The settings of each stream are negotiated with the sensor as the Polar SDK does.
- **Heart-rate source:** `polar_hr_*` files carry `hr_source` (`h10_ecg_firmware`, `verity_ppg_firmware`), and the PPI rows `verity_ppi_firmware`, so an analysis always knows which device and signal produced an estimate.
- **Manifest:** each live sensor lists its requested `signals` and the `files` that got rows (optional fields, format 1.1).
- **PPG rate of older firmware:** a Verity Sense with firmware 1.1.5 to 2.1.0 reports a PPG rate of 135 Hz while sampling at 55 Hz (Polar's known issue); the Research Monitor uses the real rate for the sample timestamps and notes it in `polar_connection_events_*` (`ppg_rate_corrected`).

## [1.0.0] - 2026-08-22

Initial release for the PROFITH Research Group laboratory protocol tracking workflow.

This project originated as a fork of `plinkr/training_timer` and has been redesigned for laboratory data collection:

- **Laboratory Protocol UI:** Customized acoustic alarms, voice prompts (`flutter_tts`), station counters, and layout tailored to standardized laboratory exercise and assessment protocols.
- **REDCap API Integration:** Replaced generic workout logging with an automated REDCap batch synchronization service (`lab_redcap_service`) to format and upload session timestamps to facilitate synchronization of sensors and video recording.
- **Multi-Participant Setup:** Added support for simultaneous multi-participant tracking, dynamic participant entries, and individualized starting station offsets.
- **Session Persistence & Recovery:** Implemented state caching using `shared_preferences` to restore in-progress protocol runs after accidental window closure or crashes.
- **Cross-Platform Compilation:** Refactored project architecture to support both Windows Desktop native builds (`.exe`) and Web deployments from a single codebase.
- **Web Exit Confirmation Guard:** Added conditional platform bindings to intercept `beforeunload` events on browsers without conflicting with desktop runtimes.
