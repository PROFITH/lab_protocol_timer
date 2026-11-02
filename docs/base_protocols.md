# Base protocols

Five protocols ship in `assets/protocols/`. Codes and METs are from the 2024 Adult Compendium bundled in `assets/compendium/compendium_2024.csv`; `test/session_setup_test.dart` checks that every code exists with that MET. Points marked **[revisar]** are defaults chosen here, not taken from the sources. Edit them in the app and save the result as a new protocol rather than changing the base files.

The WEARGAP protocols start with a calibration box (2 min still with three taps, six faces of 60 s, three taps) and the day-0 protocol ends with another one after the sensors are removed. The RUN4HEALTH protocols start and end with the 12-face dodecahedron (protocol v2, 2026-11-01).

Protocol files can also say, for the timer screen and REDCap:

- `instructions` (what the participant sees under the activity name) and `animation` (the figure: `lie`, `stand`, `sit`, `type`, `walk`, `walk_bags`, `walk_fast`, `run`, `stairs`, `uphill`, `sweep`, `dishes`, `cycle`, `sit_to_stand`, `treadmill`; guessed from the name when missing).
- `sync`: `kind` (`clap` or `jump`) and `auto` (`every_static`, `first_last` or `manual`): when the timer gives the sync cue by itself. The cue is a 3-2-1 countdown with a short go beep (0.15 s, so it never covers the impact in the video's sound). A clap is one sharp wrist-to-wrist clap with the lower wrist resting on the thigh, so the wrist and thigh sensors feel the same impact; a jump is one countermovement jump, landing on both feet, which every sensor on the body feels. With `jump`, the activities done lying, sitting or cycling, and the sit-to-stand test, keep the clap (figures `lie`, `sit`, `type`, `cycle`, `sit_to_stand`). The automatic cue puts the go in the middle of the static phase, with stillness on both sides. The event log keeps the cue (`sync_cue`) and the go (`sync_go`), and `sync_windows.csv` the kind and the go time (`sync_kind`, `cue_time_utc`), which SAVES uses to look for each impact.
- `ask_rpe`: ask the effort (0-10) after every activity, for `la_rpe`.
- `resting_hr`: the mean heart rate of the last 2 min of that activity goes to `ws_hr_rest` (method 1). **[revisar]** 2 min is the default of the RUN4HEALTH guide.
- `lap_mode` (protocol) and `wait_before` (activity): see [`protocol_format.md`](protocol_format.md). RUN4HEALTH (base) uses `lap_mode: false` and waits only where the participant changes machine or place.
- `redcap`: fields of the visit's record that the activity fills: `done_field` (yes/no), `start_field`, `rpe_before_field`, `rpe_after_field` and `fields` typed in the Research Monitor (repetitions, laps...).

## RUN4HEALTH (base), day 0 (`run4health_base`)

Source: lab battery agreed with Jairo on 2026-11-02 (TFG/TFM document). Participants come two by two (several treadmills); each visit uses freshly charged sensors, swapped when they leave on day 0 and again at the start of day 8. Running is on day 0 and Cooper on day 8, never on the same day. About 88 min including waits.

`lap_mode` is `false`: the activities follow one after another and the timer waits («lap») only before the steps marked ⏸ (a change of machine or place). On the treadmill blocks the stages have no preparation or static phase between them, so the evaluator presses «lap» at the moment the treadmill starts its programme; the last stage keeps 30 s still on the stopped belt for the clap.

| # | Activity | Code | MET | Duration |
|---|---|---|---|---|
| 1 | Dodecaedro de calibración inicial (12 caras) | – | – | 8:00 |
| 2 | ⏸ Tumbado en reposo (resting HR) | 07011 | 1.0 | 5:00 |
| 3 | De pie sin desplazarse | 07041 | | 3:00 |
| 4 | Sentado libre | 09055 | | 4:00 |
| 5-11 | Sentarse y levantarse 5 veces (×2) and 30 s (×2), each attempt a step with «Pausa sentado» 1:00 between them | 02344 / 07021 | | 0:30 each |
| 12 | Sentado quieto tras las pruebas | 07021 | | 2:00 |
| 13 | Sentado, golpeando con el talón | 07023 | | 2:00 |
| 14 | De pie, golpeando con la puntera | 07041 | | 2:00 |
| 15-22 | ⏸ Treadmill walking, 2:00 each: 3.0, 4.5, 6.0 km/h; 4.5 km/h at 5 % and 10 %; 4.5 km/h with a kettlebell in each hand; typing on the phone; holding the handrail | 17346… | | 16:00 |
| 23-24 | ⏸ Bicicleta 60 rpm and 90 rpm, 1 W/kg body mass (easy; only pedal cycles are counted) | 01216 | | 4:00 |
| 25 | ⏸ Descanso sentado | 07021 | | 3:00 |
| 26-30 | ⏸ Treadmill running, 2:00 each: 8, 10, 12, 14 km/h; 10 km/h at 5 % | 12030… | | 10:00 |
| 31 | ⏸ Recuperación sentado | 07021 | | 3:00 |
| 32 | ⏸ Dodecaedro de calibración final | – | – | 8:00 |

- The sit-to-stand fills `chairstand_*` from the first 30-s attempt only.
- Kettlebells: 4 kg in each hand (3 kg if there are none of 4), like a shopping bag. 01216 (60 W) is the closest code to 1 W/kg for most runners.
- Sensors as in RUN4HEALTH (WEARGAP): Matrix (non-dominant wrist, free living), AX3 on both wrists, AX3 thigh and AX6 on both shoes (free living), Polar H10, Verity Sense (arm), room camera. No SENS and no SensWear.

## RUN4HEALTH (base), day 8 (`run4health_day8_base`)

Calibration, ⏸ lying rest (resting HR), the same sit-to-stand block, ⏸ the pairs knee-tag game (3:00, only with two participants; warm-up for Cooper) and ⏸ the final calibration. Cooper runs outside between the game and the final calibration, guided by healthy_tracker on the participant's phone with the Polar connected, so the timer waits until the participant is back. About 39 min plus Cooper.

`ProtocolLibrary.forMoment` picks this protocol when the visit is day 8 and the day-0 one on day 0, because each visit's own protocol comes first in `builtInAssets`.

## WEARGAP day 0 (`weargap_day0_base`)

Source: proposal v15, *Day 0 (laboratory)*.

| # | Activity | Code | MET | Duration |
|---|---|---|---|---|
| | Calibration box | | | 6 × 60 s |
| 1 | Reposo tumbado en la cámara de calorimetría | 07011 | 1.0 | 30:00 |
| 2 | Escribir en el ordenador | 09040 | 1.3 | 10:00 |
| 3 | De pie quieto | 07040 | 1.3 | 10:00 |
| 4 | Caminar despacio con bolsas de la compra | 05054 | 3.5 | 10:00 |
| 5 | Caminar cuesta arriba | 17035 | 7.0 | 10:00 |
| 6 | Subir escaleras | 17131 | 6.8 | 10:00 |
| 7 | Barrer | 05010 | 3.3 | 10:00 |
| 8 | Fregar los platos | 05041 | 2.0 | 10:00 |
| 9 | Bicicleta estática, carga baja | 01214 | 4.0 | 10:00 |
| 10 | Bicicleta estática, carga alta | 01220 | 6.0 | 10:00 |
| 11 | Trotar (si puede) | 12020 | 7.5 | 10:00 |
| 12 | Marcha de 6 minutos | 17200 | 4.8 | 6:00 |
| 13 | Prueba de esfuerzo en cinta con gases | | | 12:00 |
| | Calibration box | | | 6 × 60 s |

- Resting 30 min supine in the chamber with the portable calorimeter, the 6-minute walk, and the exercise test last come from the proposal. Anthropometry, bioimpedance and skin tone happen in the wait between activities 1 and 2.
- **[revisar]** The proposal names only these activities of the 16 ("e.g., typing, standing, slow walking with shopping bags, uphill walking, stairs, sweeping, dish-washing, cycling at two loads, jogging if able"); 6 are missing and are not invented here.
- **[revisar]** 10 min per activity until IMUDS confirms how long the chamber needs to stabilise; loads (50 W, 90-100 W), slope (6-10 %) and walking speeds are defaults.
- **[revisar]** The exercise test is a ramp to exhaustion with no fixed length: the timer cannot yet end an activity early, so 12 min is a placeholder, and it has no Compendium code.
- Sensors: AX3 on both wrists, SensWear and AX3 on the non-dominant wrist, thigh AX3, AX6 on each shoe, Polar H10, three fixed cameras. SensWear, thigh AX3 and AX6 stay on for the free-living days. **[revisar]** The SensWear clock is `unknown` in the manifest until its file format is known; the Verity Sense is live (`native_plus_host_utc`).

## WEARGAP day 8 (`weargap_day8_base`)

Source: proposal v15, *Day 8 (closing visit)*: static calibration, device return and the supervised walk test with SensWear and an AX3 on each wrist.

| # | Activity | Code | MET | Duration |
|---|---|---|---|---|
| | Calibration box | | | 6 × 60 s |
| 1 | Marcha de 6 minutos | 17200 | 4.8 | 6:00 |

Sensors: SensWear and AX3 on the non-dominant wrist, AX3 on the dominant wrist, fixed camera. Serials come from the participant's day-0 setup for the sensors with the same ID. **[revisar]** Thigh AX3 and shoe AX6 are returned at this visit and are not listed; add them if their files should be synchronised with this session.
