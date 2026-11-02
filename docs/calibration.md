# Calibration of the offline sensors

The offline sensors (AX3, AX6, SENS motion, Matrix, SensWear…) are calibrated in the 12-face dodecahedron (or a rigid 6-face box) by the technician alone, **before the participants arrive or after they leave**. The app only keeps time: what each sensor felt is in its own file, and the times written here let the analysis find the still segment of every face (for example, GGIR's calibration coefficients).

## On the start screen

**Calibración** (under the REDCap card) opens the calibration screen:

1. Set up and start recording on every offline sensor, put them in the foam of the dodecahedron and close it.
2. Check the list of **devices in the dodecahedron**: type and serial number. It is proposed from the serials already typed for the participants (or from the protocol's offline sensors, without serial); rows can be added and removed. A device without a serial number is not recorded. If they do not all fit, calibrate in batches.
3. Choose **Dodecaedro (12 caras)** or **Caja rígida (6 caras)** and press **Empezar**.

The program (`lib/calibration/calibration_program.dart`):

| Step | Duration |
|---|---|
| Still, face 1 up | 2:00 |
| Three sharp knocks | 0:10 |
| Faces 1 to 12, each one up | 0:40 each (1:00 with the 6-face box) |
| Three sharp knocks | 0:10 |

About 10 min with 12 faces. Three beeps (one per second) come before every change; at the change a go beep sounds and the voice says the new face («Cara 5.»). The drawing turns to the face that goes up, highlighted. Faces are numbered like the printed dodecahedron: 1 on top, 2-6 around it, 7-11 below, 12 at the bottom; opposite faces add up to 13.

Closing the screen during a calibration asks first; what was done is kept but does not count as a calibration.

The start screen shows the calibrations of today. Starting a session when an offline sensor of a participant has no calibration of today (or has no serial number, so it cannot be matched) asks «¿Seguro que quieres empezar la sesión sin haber calibrado los sensores?» and lists those sensors.

## Files

Under the parent folder of the sessions:

```
calibraciones/
  calibracion_2026-11-03T08-15-00.csv
  calibracion_2026-11-03T08-30-12.csv
  calibraciones_dispositivos.csv
```

`calibracion_<local date and time>.csv`, one row per event, written as it happens:

| Column | Content |
|---|---|
| `event` | `calibration_start`, `device`, `still_start`, `knock_start`, `face_start`, `face_end`, `calibration_end`, `cancelled` |
| `face` | Face up (for `face_*`, `still_start` and the knocks) |
| `time_utc`, `time_local` | Time on this computer |
| `detail` | Program for `calibration_start`; `type:serial` for `device` (`ax6:A1B2C3`) |

`calibraciones_dispositivos.csv`, one row per device and complete calibration, to follow each serial number over time (the coefficients of the same device are expected to be stable):

```
calibration_file,device_type,serial,start_utc,end_utc,faces,completed
calibracion_2026-11-03T08-15-00.csv,ax6,A1B2C3,2026-11-03T07:15:00.000Z,2026-11-03T07:25:20.000Z,12,1
```

## In each session

When a session starts, each offline sensor of each participant takes the latest complete calibration of the last 12 h that has its type and serial. Each participant's folder gets:

- a copy of the calibration CSVs of their sensors;
- in `session_manifest.json`, `calibrations`: one entry per calibrated sensor with `sensor_id`, `device_type`, `serial`, `file`, `start_utc`, `end_utc` and `faces`;
- in the event log, one `calibration` event per sensor.

REDCap receives `ws_calibration = 1`, `ws_calib_start` (start of the first calibration used) and `ws_calib_end` (end of the last one).

To calibrate a participant's data later: read the serial of each sensor in the manifest, take its calibration file, and compute the coefficients from the sensor's own recording between `face_start` and `face_end` of each face (or look the serial up in `calibraciones_dispositivos.csv` for its whole history). The sensor clocks are not corrected here: SAVES aligns them with the session.
