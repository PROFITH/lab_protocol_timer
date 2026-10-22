# Research Monitor

The second window of lab_protocol_timer: connects the live sensors, shows
their signals and records the video of the session.

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
    last pulse when the firmware provides it. Skin-contact flags of the
    Verity Sense are unreliable (Polar's own note).
  - Heart-rate source: every row of `polar_hr_*` carries `hr_source`
    (`h10_ecg_firmware`: the H10 derives it from the ECG;
    `verity_ppg_firmware`: the Verity Sense from the PPG), and the PPI rows
    `verity_ppi_firmware`. The resting heart rate in `activity_markers.csv`
    keeps its own `method` (`rr` or `hr`).
- **Cameras**: one recorder per camera of the session. The gear button picks
  the Windows camera, the resolution (720p, 1080p by default, 4K) and the
  quality; both are remembered on that computer. Video is recorded with
  audio from the first microphone Windows lists; if it cannot be opened the
  camera records without audio and says so.
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
`activity_index` and `phase_name` first; files without rows are not written:

| File | Columns | Device |
|---|---|---|
| `polar_hr_<id>_<ts>.csv` | `hr_bpm,rr_intervals_ms,hr_source` | H10, Verity |
| `polar_acc_<id>_<ts>.csv` | `acc_x_mg,acc_y_mg,acc_z_mg,sensor_time_ns` | H10, Verity |
| `polar_ecg_<id>_<ts>.csv` | `ecg_uv,sensor_time_ns` | H10 |
| `polar_ppg_<id>_<ts>.csv` | `ppg0,ppg1,ppg2,ambient,sensor_time_ns` (raw 22-bit counts) | Verity |
| `polar_ppi_<id>_<ts>.csv` | `ppi_ms,hr_bpm,error_estimate_ms,blocker,skin_contact,skin_contact_supported,index_in_frame,sensor_time_ns,hr_source` | Verity |
| `polar_gyro_<id>_<ts>.csv` | `gyro_x_dps,gyro_y_dps,gyro_z_dps,sensor_time_ns` | Verity |
| `polar_mag_<id>_<ts>.csv` | `mag_x_gauss,mag_y_gauss,mag_z_gauss,sensor_time_ns` | Verity |
| `polar_clock_<id>_<ts>.csv` | `arrival_utc,stream,frame_sensor_time_ns,offset_us`: one row per PMD frame, for checking the clock mapping | both |
| `polar_connection_events_<id>_<ts>.csv` | `timestamp_utc,event,detail` (a refused stream appears as `sensor_start_failed`) | both |

`sensor_time_ns` is the sensor's own clock before the mapping to the host
clock; `timestamp_iso` is that time mapped. PPI rows without a sensor time
share the arrival time of their batch and `index_in_frame` orders them.
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
lost. Charts repaint once per screen frame, only when new samples arrived,
without rebuilding the window.

## Phone as camera

The app records any camera Windows sees. To use a phone, a webcam app makes
it one, e.g. DroidCam (Android and iPhone; USB or Wi-Fi; client for
Windows). DroidCam lets you choose the ultra-wide lens with the camera
switch in the phone app (Android 11+ also by zooming out; on iPhone 11+
ultra-wide is a Pro feature). Choose the lens on the phone before opening
the camera here. If the webcam app cannot use the ultra-wide lens, record
on the phone itself at 0.6× and synchronise with the claps.
