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
  - Verity Sense: HR and ACC (the rate the sensor offers, 52 Hz). It has no
    ECG, and its heart-rate service sends no RR intervals.
  - ACC settings are first asked to the sensor (PMD «get settings») and the
    start command is built from them; without an answer the H10 command is
    sent.
- **Cameras**: one recorder per camera of the session. The gear button picks
  the Windows camera and the resolution (720p, 1080p by default, 4K). Video
  is recorded with audio from the first microphone Windows lists; if it
  cannot be opened the camera records without audio and says so.
- **Offline sensors** (Axivity, ActiGraph, GENEActiv, Matrix, SENS,
  SensWear): listed only; they record on their own clock.

## Files at the end of the session

Per live device, with its sensor ID (SAVES matches files by it):
`polar_hr_<id>_<ts>.csv`, `polar_acc_<id>_<ts>.csv`,
`polar_ecg_<id>_<ts>.csv`. One `video_sync_session_<ts>.csv` for every
video of every camera (last column `camera_id`), and the videos
`video_session_<participants>_<camera>_<ts>.mp4`.

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
