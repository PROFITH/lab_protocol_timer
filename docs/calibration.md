# Calibration of the offline sensors

The offline sensors (AX3, AX6, SENS motion, Matrix, SensWear…) are calibrated in the 12-face dodecahedron (or a rigid 6-face box) by the technician alone: in the **waiting room**, while the participant fills the questionnaires with another evaluator, and, if wanted, again **after the session**. The app only keeps time: what each sensor felt is in its own file, and the times written here let the analysis find the still segment of every face (for example, GGIR's calibration coefficients).

## In the waiting room

After the session data, **Preparar sesión** opens the waiting room: serial numbers of each participant's sensors (each device ticked as **Inicializado** once set to record), Polar and camera in the Research Monitor, and calibration. **Calibración** opens the calibration screen:

1. Set up and start recording on every offline sensor, put them in the foam of the dodecahedron and close it.
2. Check the list of **devices in the dodecahedron**: type and serial number. It is proposed from the serials already typed for the participants (or from the protocol's offline sensors, without serial); rows can be added and removed. A device without a serial number is not recorded. If they do not all fit, calibrate in batches.
3. Choose **Dodecaedro (12 caras)** or **Caja rígida (6 caras)** and press **Empezar**.

The program (`lib/calibration/calibration_program.dart`):

| Step | Duration |
|---|---|
| Face 1 up, get ready (the last beep marks the knocks) | 0:10 |
| Three sharp knocks | 0:10 |
| Faces 1 to 12, each one up | 0:40 each (1:00 with the 6-face box) |
| Three sharp knocks | 0:10 |

About 8 min 20 s with 12 faces (the 2-min still start became 10 s to get ready in 1.3.1). Three beeps (one per second) come before every change; at the change a go beep sounds and the voice says the new face («Cara 5.»). The drawing turns to the face that goes up, highlighted. Faces are numbered like the printed dodecahedron: 1 on top, 2-6 around it, 7-11 below, 12 at the bottom; opposite faces add up to 13.

Closing the screen during a calibration asks first; what was done is kept but does not count as a calibration.

The waiting room shows the calibrations of today. Going to the session when an offline sensor of a participant has no calibration of today (or has no serial number, so it cannot be matched) asks «¿Seguro que quieres empezar la sesión sin haber calibrado los sensores?» and lists those sensors.

## Files

The app writes no sensor data: each sensor records on its own and is downloaded afterwards. It keeps only when each step happened, on this computer's clock.

While waiting for its session, a calibration is under the parent folder of the sessions:

```
calibraciones/
  calibracion_2026-11-03T08-15-00.csv
```

`calibracion_<local date and time>.csv`, one row per event, written as it happens:

| Column | Content |
|---|---|
| `event` | `calibration_start`, `device`, `still_start`, `knock_start`, `face_start`, `face_end`, `calibration_end`, `cancelled` |
| `face` | Face up (for `face_*`, `still_start` and the knocks) |
| `time_utc`, `time_local` | Time on this computer |
| `detail` | Program for `calibration_start`; `type:serial` for `device` (`ax6:A1B2C3`) |

## In each session

Before the participant arrives, calibrate both sets: the devices worn in the laboratory and those the participant takes home for the free-living days (in the same calibration or in two). The protocol says what each sensor is for (**Uso** in the sensor editor: laboratory, free living or both), and step 2 asks each participant for the serial of each device: the laboratory one and, for the sensors used in free living, the one taken home (**Vida libre**).

When a session starts, each offline sensor of each participant takes the latest complete calibration of the last 12 h that has its type and serial, and so does its free-living device. The calibration **moves** to the participant's folder: each participant whose sensors it has gets a copy (so each folder stands on its own for SAVES), and then it is deleted from `calibraciones/` (unless a copy failed). What stays in `calibraciones/` was not used by any session: a cancelled calibration, or one whose devices did not match. Each participant's folder then has:

- the calibration CSVs of their sensors;
- in `session_manifest.json`, `calibrations`: one entry per calibrated device with `sensor_id`, `device_type`, `serial`, `set` (`lab` or `free_living`), `file`, `start_utc`, `end_utc` and `faces`; each sensor also carries `free_living_serial`;
- in the event log, one `calibration` event per sensor.

### Final calibration

«Finalizar y guardar» in the monitor asks **«¿Volver a calibrar los sensores?»**. With **Sí**, when the session closes («Terminar» in the summary) the main window opens the calibration screen with the laboratory sensors of the session (not the free-living ones, which went home). The result is copied to the folder of each participant whose sensors it has as `calibracion_final_<time>.csv` (to all of them when it matches none), and the original stays in `calibraciones/`: the next session of the day, within 12 h, takes it as its starting calibration. The final calibration is not in the manifest or REDCap, which were written when the session was saved.

REDCap receives `ws_calibration = 1`, `ws_calib_start` (start of the first calibration used) and `ws_calib_end` (end of the last one).

To calibrate a participant's data later: read the serial of each sensor in the manifest, take its calibration file, and compute the coefficients from the sensor's own recording between `face_start` and `face_end` of each face; the knocks are a common mark to align the sensor clock with this computer's. The history of one serial number over time comes from going through the manifests (`calibrations` names the serial of each sensor). The app computes no coefficients, so any method fits.
