# Research Monitor

The second window of lab_protocol_timer: connects the live sensors, shows
their signals and records the video of the session.

It opens with «Preparar sesión» on the start page, while the main window is
in the waiting room: the Polar and the cameras can be connected then. Until
the main window goes on («Pasar a la sesión») the start button reads
«SALA DE ESPERA» and does nothing; then it becomes «EMPEZAR SESIÓN». When
the session closes the monitor forgets it, so the next one starts again in
the waiting room.

## Devices

The list under «Dispositivos y sensores» is the sensor list of the session
(«Editar actividades y sensores»), in the same order, with placement and
serial. Without a sensor list it shows the Polar H10 and one camera.

- **Live** (Polar H10, Polar Verity Sense): the gear button scans Bluetooth
  and links the device. The sensor whose name carries the serial of the
  setup goes first, then those of the same type. Connecting is optional.
  - H10: HR, RR, ACC (200 Hz, ±8 G) and ECG (130 Hz).
  - Verity Sense: HR, ACC (52 Hz, ±8 G), raw PPG (55 Hz: three green
    channels and the ambient light, 22 bit), PPI (Polar's pulse-to-pulse
    intervals, with the heart rate it derives from them and an error
    estimate), gyroscope (52 Hz, ±2000 dps) and magnetometer (50 Hz, ±50
    gauss). It has no ECG, and its heart-rate service sends no RR intervals.
    Everything the device offers is recorded so the algorithms can use any
    of it; only HR, RR, ACC and ECG are charted.
  - The settings of every PMD stream are first asked to the sensor («get
    settings») and the start command is built from them (preferred rate and
    range if offered, else the highest; highest resolution; most channels);
    without an answer the H10 ACC command is sent. The rate and the factor
    the sensor answers with are kept for its frames.
  - PPI: Polar's PPI algorithm is separate from its HR one. While PPI runs,
    the heart rate of the HR service is updated only every 5 s, and the
    first batch of pulses arrives about 25 s after the start; the sensor
    then sends them in batches, each stamped with the sensor time of its
    last pulse when the firmware provides it. Polar's notes: the PPI is only
    accurate at complete rest (during movement `blocker` is 1 and the heart
    rate of the PPI rows is held at the last reliable value), and the
    skin-contact flags of the Verity Sense are unreliable.
  - PPG rate of older firmware: a Verity Sense with firmware 1.1.5 to 2.1.0
    offers a single PPG rate of 135 Hz while it samples at 55 Hz (Polar's
    known issue). The sample timestamps use the real rate, and the
    connection log notes it (`ppg_rate_corrected`).
  - Heart-rate source: every row of `polar_hr_*` carries `hr_source`
    (`h10_ecg_firmware`: the H10 derives it from the ECG;
    `verity_ppg_firmware`: the Verity Sense from the PPG), and the PPI rows
    `verity_ppi_firmware`. The resting heart rate in `activity_markers.csv`
    keeps its own `method` (`rr` or `hr`).
- **Cameras**: one recorder per camera of the session. The gear button picks
  the Windows camera, the resolution (720p, 1080p by default, 4K), the
  quality and the microphone; all are remembered on that computer. Video is
  recorded with audio from the Windows default recording device unless
  another microphone is chosen (one choice for every camera of the
  computer; a chosen microphone that is no longer connected falls back to
  the default). If it cannot be opened the camera records without audio and
  says so. The choice needs the vendored `packages/camera_windows`, since
  the published plugin always takes the first microphone Windows lists.
  - Windows encodes H.264 at a constant rate, so a file weighs the bitrate
    times its duration. The bitrate follows the size the camera really gives
    (a laptop camera asked for 1080p gives 720p): 0.09 bits per pixel and
    frame at 30 frames/s for Normal, twice that for Alta and half for Ahorro
    de espacio.

    | Quality | 720p | 1080p |
    |---|---|---|
    | Alta | 5.0 Mbit/s, ≈2.2 GB/h | 11.2 Mbit/s, ≈4.8 GB/h |
    | Normal (default) | 2.5 Mbit/s, ≈1.1 GB/h | 5.6 Mbit/s, ≈2.4 GB/h |
    | Ahorro de espacio | 1.2 Mbit/s, ≈0.6 GB/h | 2.8 Mbit/s, ≈1.3 GB/h |

    Before, every 1080p camera got 12 Mbit/s, also when it gave 720p (1 GB
    in 13 minutes). The start check shows each camera's bitrate and how many
    hours of video fit on the disk.
  - The audio bitrate is left to the AAC encoder: camera_windows writes it as
    bytes per second, and the encoder only accepts 12000-24000.
- **Offline sensors** (Axivity, ActiGraph, GENEActiv, Matrix, SENS,
  SensWear): listed only; they record on their own clock.

## Files at the end of the session

Per live device, with its sensor ID (SAVES matches files by it), one CSV
per signal, all with `timestamp_iso` (host clock, UTC), `participant_id`,
`activity_index` and `phase_name` first; files without rows are not written.
In a session with several participants each device belongs to one of them
(the monitor lists it as `polar_h10@002`): its files go to that
participant's folder, named by the plain sensor ID, and `participant_id`
carries that participant. The videos and `video_sync_session_<ts>.csv` are
written to the first participant's folder and copied to the others when the
session ends.

| File | Columns | Device |
|---|---|---|
| `polar_hr_<id>_<ts>.csv` | `hr_bpm,rr_intervals_ms,hr_source,ble_delay_ms` | H10, Verity |
| `polar_acc_<id>_<ts>.csv` | `acc_x_mg,acc_y_mg,acc_z_mg,sensor_time_ns` | H10, Verity |
| `polar_ecg_<id>_<ts>.csv` | `ecg_uv,sensor_time_ns` | H10 |
| `polar_ppg_<id>_<ts>.csv` | `ppg0,ppg1,ppg2,ambient,sensor_time_ns` (raw 22-bit counts) | Verity |
| `polar_ppi_<id>_<ts>.csv` | `ppi_ms,hr_bpm,error_estimate_ms,blocker,skin_contact,skin_contact_supported,index_in_frame,sensor_time_ns,hr_source` | Verity |
| `polar_gyro_<id>_<ts>.csv` | `gyro_x_dps,gyro_y_dps,gyro_z_dps,sensor_time_ns` | Verity |
| `polar_mag_<id>_<ts>.csv` | `mag_x_gauss,mag_y_gauss,mag_z_gauss,sensor_time_ns` | Verity |
| `polar_clock_<id>_<ts>.csv` | `arrival_utc,stream,frame_sensor_time_ns,offset_us`: one row per PMD frame, for checking the clock mapping | both |
| `polar_connection_events_<id>_<ts>.csv` | `timestamp_utc,event,detail` (a refused stream appears as `sensor_start_failed`; `frames_lost` when the sensor dropped frames, `link_behind` / `link_caught_up` when the link fell more than 2 s behind and caught up) | both |

`sensor_time_ns` is the sensor's own clock before the mapping to the host
clock; `timestamp_iso` is that time mapped. PPI rows without a sensor time
share the arrival time of their batch and `index_in_frame` orders them.

### When the Bluetooth link falls behind

A Polar sensor keeps its frames when the link cannot send them as fast as
it measures (radio interference, another strap nearby, video over the same
wifi), sends them seconds late and, if the link stays behind, drops some
(in a test on 02/11/2026 the H10 lost 27 % of its accelerometer frames and no ECG). The live charts
then stop: they show what has arrived. The files stay right:

- **Times:** the sensor time of each frame is mapped with the lower
  envelope of `arrival - sensor time` (`lib/services/pmd_clock.dart`): a late
  frame does not move it, it rises only as fast as two clocks can drift
  (150 ppm) and comes down at most 90 % as fast as the sensor time runs, so
  times always increase.
- **Samples of a frame:** spread evenly between its time and that of the
  frame before when it is the one just before (the H10 accelerometer set to
  200 Hz runs at about 203 Hz); after lost frames, with the period measured
  last.
- **Phase:** `activity_index` and `phase_name` are those at `timestamp_iso`
  (when the sample was measured), not at its arrival.
- **Heart rate** has no sensor time: `timestamp_iso` is the arrival less the
  delay of the PMD frames of the same link at that moment, written in
  `ble_delay_ms` (empty when no PMD stream told it).
- **Lost frames** are missing from the files; `frames_lost` in the
  connection events says how many and when.

The device panel of the monitor warns while it happens: «Bluetooth con 17 s
de retraso» and «ACC: 27 % de paquetes perdidos».

The data-loss watchdog reconnects a device whose PMD streams send nothing for 20 s (60 s while the heart rate keeps arriving): reconnecting a Verity Sense on Windows can fail for minutes, so a late link is not torn down.

A device without the Polar data service (another brand's strap, such as a
Garmin HRM-Pro+) is not retried: the panel says to choose the H10 or the
Verity Sense.
The manifest lists, for each live device, the `signals` requested and the
`files` that got rows.

One `video_sync_session_<ts>.csv` for every video of every camera (last
column `camera_id`), and the videos
`video_session_<participants>_<camera>_<ts>.mp4`.

The summary shown after «FINALIZAR Y GUARDAR» also lists what to do with
the sensors before the participant leaves: download the offline ones and
copy their files to the session folder; download those that stay on for the
free-living days and initialise them again (an Axivity has to stop
recording to be downloaded); start the free-living recording of a live one
that stays on. Sensors without a serial number get the file name SAVES
recognises (`R4H_001_D0_matrix_wnd` plus the extension).

## Live charts

Every sample is kept for the window of the chart (ECG 6 s, ACC 10 s, HR and
RR 2 min) with the sensor's own timestamps; nothing is downsampled on
arrival. When painted, each pixel column draws from the lowest to the
highest sample that falls in it, so a one-sample R peak or impact is never
lost. Charts repaint once per screen frame without rebuilding the window. Every
chart of a Polar is drawn 2.5 s behind the computer's clock, the same for
all devices: the Verity Sense sends a frame of ACC, gyroscope or
magnetometer about every 2 s, and with that delay its traces scroll as
smoothly as the H10's. If the link falls further behind, the chart waits
at the newest sample.

### A chart in its own window

The ↗ button of a chart opens it in a window of its own, to move it to
another screen or make it bigger. That window keeps a copy of the chart's
samples: the monitor sends it the ones that arrived about 20 times a second,
and the whole window again when the sensor of that monitor, the VM/XYZ mode
or the theme change. Closing it (or «Traer aquí» in the grid) hides it and
the chart goes back to the grid; the hidden window is reused for the next
one, because destroying a secondary window takes the app down on Windows.
The windows are hidden when the evaluation ends. Video cannot be moved out.

## Light and dark theme

The sun/moon button (start page and monitor) switches both windows and is
remembered on this computer (`theme_mode` in the app's preferences). The
participant's screen is always dark.

## Phone as camera

The app records any camera Windows sees. To use a phone, a webcam app makes
it one, e.g. DroidCam (Android and iPhone; USB or Wi-Fi; client for
Windows). DroidCam lets you choose the ultra-wide lens with the camera
switch in the phone app (Android 11+ also by zooming out; on iPhone 11+
ultra-wide is a Pro feature). Choose the lens on the phone before opening
the camera here. If the webcam app cannot use the ultra-wide lens, record
on the phone itself at 0.6× and synchronise with the claps.
