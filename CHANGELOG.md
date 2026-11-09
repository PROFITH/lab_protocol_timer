# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.4.2] - 2026-11-09

### Changed

- **«RUN4HEALTH (demostración, 25 min)»:** rewritten to practise programming the treadmill and the bike: lying 5 min (resting HR), sitting 3 min, standing 2 min, treadmill walking at 3.0, 4.5 and 6.0 km/h (2 min stages in a row), bike at 60 and 90 rpm with a light load (2 min stages in a row) and the 30 s sit-to-stand. Claps instead of jumps, as in RUN4HEALTH (base); same sensors as day 0.

## [1.4.1] - 2026-11-09

### Added

- **«RUN4HEALTH (demostración, 8 min)»:** protocol for training evaluators and students: standing still, walking up and down the room, very slow walking, single steps and turns, jogging on the spot, heel tapping while seated, five sit-to-stands and sitting still, each with 15 s still before and after and a jump (a clap when seated). It has the same sensors as RUN4HEALTH day 0.
- **Windows release:** `.github/workflows/release-windows.yml` builds the app on GitHub, makes an installer (`lab_protocol_timer_setup_<version>.exe`, Inno Setup) and a portable `.zip`, and attaches both to the release of the tag (`v*`), or of the tag typed when it is run by hand.

### Fixed

- **Voice between activities without a still phase:** walking straight into the next speed (`prep_seconds` and `post_seconds` 0) no longer says «Para. Quédate quieto.» and «… Quédate quieto.» nor beeps the end in between: the next activity is announced as it starts («Actividad 3 de 5: caminar rápido. ¡Empieza!»).
- **H10 stuck behind:** in the test of 05/11, after the Verity Sense paired and reconnected on the same adapter, the H10 sent every frame 17 s late for the rest of the session and dropped 48 % of its ACC frames, even at 100 Hz (ECG complete; times right, checked against the Verity). When a Polar has been more than 5 s behind for 10 s, the app now stops and restarts its streams to empty the sensor's queue (at most once a minute), keeps its clock, and logs `pmd_flush` (or `pmd_flush_failed`) in its connection events.

### Changed

- **H10 accelerometer at 100 Hz** (was 200 Hz). In the test of 04/11 afternoon, with a Verity Sense on the same Bluetooth adapter, the H10 lost 76 % of its ACC frames from the moment the Verity connected (48.8 samples/s arrived out of 200; its ECG and every Verity stream were complete and the times were right). 100 Hz halves the data and is enough for steps and activity; it did not stop the losses on its own (see «H10 stuck behind»).
- **Devices ticked in the waiting room:** each offline device ticked as initialized shows a green dot in the monitor's device tab («Inicializado en la sala de espera; graba por su cuenta»), and the participant's manifest and session state keep it (`initialized`, `free_living_initialized`).
- **Device tab:** the cameras first, since they are what is left to connect in the monitor.
- **RUN4HEALTH sensors:** day 0 and day 8 list an AX6 on each ankle as well as on each shoe. The shoe AX6 are laboratory only; the ankle AX6 go home with the thigh SENS motion and the Matrix of the non-dominant wrist.

## [1.4.0] - 2026-11-03

### Added

- **Several evaluators per session:** the start page has two «EVALUADOR/A» fields and «Añadir evaluador/a» for more (the extra ones can be removed). Blank fields and repeated names are left out, and this computer remembers the last ones. The session state and each participant's manifest have the new list `operators` (`["JHM", "MDF"]`); `operator` stays, with all of them in one text (`JHM, MDF`), and so does REDCap's `ws_operator` (no change to the data dictionary). The monitor shows «Evaluadores: JHM, MDF».
- **Light and dark theme:** a sun/moon button at the top right of the start page and next to «FINALIZAR Y GUARDAR» in the monitor. Both windows follow it and this computer remembers it. The participant's screen stays dark (its phase colours are what it says).
- **Monitors in their own window:** each chart of the monitor has a button (↗) that opens it in a window of its own, which can be moved to another screen and resized; the grid shows «Monitor N en otra ventana» with «Mostrar ventana» and «Traer aquí». Closing that window puts the chart back in the grid. The window gets every sample of the chart about 20 times a second and follows the sensor, the VM/XYZ mode and the theme of the grid. Video stays in the monitor; any monitor, video included, can instead take the whole monitoring area (⤢ button).

- **Waiting room:** the start page now ends in «PREPARAR SESIÓN», which opens the Research Monitor and goes to a waiting room. There, while the participant fills the questionnaires with one evaluator, another one types each participant's serial numbers (moved here from step 2), ticks each device as **Inicializado** (offline sensors) or **Preparado** (Polar) as a to-do list («3/9 inicializados»), connects the Polar and the camera in the monitor («Mostrar monitor») and runs the calibration (moved here from the start page). «PASAR A LA SESIÓN» asks about devices not ticked, sensors without calibration and missing serials, as before, and goes to the participant's screen; the session is started in the monitor as before. «Volver a los datos de la sesión» goes back. Until then the monitor shows «SALA DE ESPERA» instead of «EMPEZAR SESIÓN».
- **Initialization guides:** an «i» next to each device of the waiting room opens how to initialize it (Axivity AX3/AX6, Parmay Matrix, SENS motion, Polar H10, Polar Verity Sense, SensWear), from the RUN4HEALTH protocols 14 to 17. They are Markdown files in `docs/device_guides/`, bundled with the app; a study can use its own without a new version by putting `guias_dispositivos/<type>.md` in the parent folder of the sessions.
- **Polar linked from the waiting room:** each Polar of the laboratory shows there whether it is linked («Conectado · Polar H10 … · 72 lpm») with «Conectar» / «Desconectar»; «Conectar» searches the Bluetooth (the unit with the serial on top) and links it. The link lives in the monitor, which keeps it when the session starts; its device bar is still there to reconnect during the session. A linked Polar counts as ready in «N/M listos». Showing the monitor again from the waiting room, and going on to the session, no longer rebuilds it (that would have dropped the links).
- **Final calibration:** «Finalizar y guardar» then asks «¿Volver a calibrar los sensores?» (Sí/No). With «Sí», when the session closes («Terminar» in the summary, or «Volver al inicio») the main window opens the calibration with the laboratory sensors of the session (the free-living ones went home). It is copied to the folder of each participant whose sensors it has as `calibracion_final_<time>.csv`, and the original stays in `calibraciones/`, so the next session of the day can use it as its starting calibration. It is not in the manifest (that was written when the session was saved).

### Fixed

- **Times of the Verity Sense ACC:** it streams at 52 Hz, but its samples were spread 5 ms apart as if at 200 Hz (the rate was only taken from the sensor's answer, which the Verity does not give): each frame of about 1.9 s took 0.5 s and `polar_acc` looked 74 % empty, with «frames lost» in the monitor, while every sample was there (tests of 04/11). The samples are now spread at the rate asked for, and the Verity is asked for 52 Hz explicitly; the H10 keeps 200 Hz.
- **Smooth live charts:** every chart of a Polar is drawn 2.5 s behind the computer's clock (the same for all devices, so they stay aligned) and scrolls every frame; the Verity Sense sends its frames about every 2 s and its charts moved in jumps.
- **Lost frames:** counted from the samples of each frame, not from the shortest gap between frames; the Verity Sense sends frames of different sizes and its gyroscope was reported with 27-39 % lost while the file had no gap.

### Changed

- Sessions saved by 1.3.x, with one `operator`, resume with that evaluator; the single evaluator remembered by an older version fills the first field.

## [1.3.3] - 2026-11-02

### Fixed

- **Polar times when the Bluetooth link falls behind:** in a test with the H10 the frames arrived up to 17 s late, twice, and the clock mapper took that delay for a change of the offset (it started again when a frame was more than 5 s above the minimum of the last 30 s): `timestamp_iso` moved by up to 13.6 s. The offset is now the lower envelope of `arrival - sensor time`, rising at most 150 ppm and coming down at most 90 % as fast as the sensor time; replaying the frames of that test it stays within 19 ms of the best frame seen.
- **Phase of each sample:** `activity_index` and `phase_name` are those of the moment the sample was measured, not of its arrival (late frames put the end of a phase in the next one).
- **Samples of a frame:** spread between consecutive frame times as the Polar SDK does; the H10 accelerometer runs at about 203 Hz and 5 ms steps overlapped each frame with the one before by 2.5 ms.
- **Heart rate:** its time is the arrival less the delay of the PMD frames at that moment, in the new last column `ble_delay_ms`.
- A device without the Polar data service (a Garmin HRM-Pro+ was retried 21 times) is not retried; the panel says to choose the H10 or the Verity Sense.
- **Verity Sense:** the device panel showed PPG, PPI, GYRO and MAG as stopped while they recorded (only ACC was checked); a stream now shows as receiving when its frames arrive. The data-loss watchdog tore down a Verity whose frames came 2-9 s late after 6 s without data, and reconnecting it on Windows failed for two minutes; it now waits 20 s, or 60 s while the heart rate keeps arriving.

### Added

- Live charts of the Verity Sense PPG (first green channel) and gyroscope.
- The device panel of the monitor warns when the link is more than 2 s behind and of the frames each stream lost (`ACC: 27 % de paquetes perdidos`); the connection events log `frames_lost`, `link_behind` and `link_caught_up`.

## [1.3.2] - 2026-11-02

### Added

- **Use of each sensor in the protocol:** the sensor editor has «Uso»: Laboratorio, Vida libre or Ambos (`use` in the protocol file: `lab`, `free_living`, `both`; an older `free_living: true` reads as `both`). Step 2 asks each participant for the serials the protocol needs: the laboratory one for laboratory sensors and the one taken home for free-living sensors (the «Vida libre» field is no longer shown for every offline sensor). A sensor only for free living is not in the session (not in the monitor, nor under `sensors` of the manifest) and is listed under `free_living_devices`.
- **Built-in protocols:** day 0 has the free-living set as `use: both`: RUN4HEALTH (v5) Matrix, SENS motion and both AX6; WEARGAP (v4) SensWear, thigh AX3, both AX6 and the Polar H10. Day 8 protocols are laboratory only.
- The session summary says to download every laboratory sensor and to put on the free-living set.

## [1.3.1] - 2026-11-02

### Added

- **Free-living serials:** in step 2, each offline sensor has an optional «Vida libre» field for the serial of the device the participant takes home. Its calibration (done before the participant arrives, with the lab set or apart) moves to the participant's folder too; the manifest lists it under `calibrations` with `set: free_living`, and each sensor carries `free_living_serial`. The warning before starting includes free-living devices without a calibration of today, and the calibration screen proposes them.

### Changed

- **Calibration without the 2-min still start:** 10 s to get ready with face 1 up (three beeps announce the knocks), three knocks, the faces and the closing knocks; about 8 min 20 s with 12 faces.

## [1.3.0] - 2026-11-02

### Added

- **Calibración:** a button of the start screen opens the calibration of the offline sensors, done by the technician before the participants arrive or after they leave (the instructions are addressed to them). A drawing of the dodecahedron turns to the face that goes up, three beeps come before each turn and the face is said aloud: 2 min still with face 1 up, three knocks, faces 1 to 12 for 40 s each (or a 6-face box, 60 s each), three knocks; about 10 min. Cancelling asks first.
- **Calibration by device:** the screen lists the devices in the dodecahedron with their serial numbers (proposed from the serials typed for the participants). Each calibration is a CSV `calibracion_<date>.csv` with the times of every face (no sensor data), waiting in `calibraciones/` until its session. When a session starts, it moves to the folder of each participant whose sensors it has (a copy in each) and leaves `calibraciones/`; the manifest lists the calibration of each sensor (`calibrations`: sensor ID, type, serial, file, start, end, faces) and REDCap gets `ws_calibration`, `ws_calib_start` and `ws_calib_end`. Calibrating in batches works: each sensor takes the latest calibration of the last 12 h with its serial.
- **Warning before an uncalibrated session:** «¿Seguro que quieres empezar la sesión sin haber calibrado los sensores?», listing the offline sensors of each participant without a calibration of today.
- **Proposed settings:** the sensor editor proposes the sampling rate and range from the device and its place: AX3 100 Hz ±8 g, AX6 and anything on a shoe 100 Hz ±16 g, Matrix 25 Hz ±8 g (with a note: gyroscope, real-time heart rate and temperature on, about 7 days and 8 h), SENS motion fixed at 12.5 Hz and not editable.

### Changed

- **Folders:** step 3 chooses only the parent folder and lists below it, in small type, the folder each participant gets (`<parent>/<study>_<ID>/<visit>`). Choosing a folder per participant is gone.
- **Sensor editor:** no serial number (they are typed per participant) and no «sigue puesto en vida libre» switch: every device is downloaded after the visit and replaced by the free-living ones, each with its own serial. The session summary says so.
- **Built-in protocols:** no calibration segments (the «Dodecaedro de calibración» activities are gone, and the editor no longer adds a calibration box); no sensor marked as free living. RUN4HEALTH has SENS motion on the thigh instead of the AX3. Versions: RUN4HEALTH day 0 v4, day 8 v2, WEARGAP day 0 and day 8 v3.

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
