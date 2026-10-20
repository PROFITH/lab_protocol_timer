# Base protocols

Three protocols ship in `assets/protocols/`. Codes and METs are from the 2024 Adult Compendium bundled in `assets/compendium/compendium_2024.csv`; `test/session_setup_test.dart` checks that every code exists with that MET. Points marked **[revisar]** are defaults chosen here, not taken from the sources. Edit them in the app and save the result as a new protocol rather than changing the base files.

Every protocol starts with a calibration box (2 min still with three taps, six faces of 60 s, three taps) and the day-0 and RUN4HEALTH protocols end with another one after the sensors are removed. **[revisar]** In the RUN4HEALTH guide (Protocol 4.1) the first box is done during consent, before the session starts; inside the session the camera already records during that box. Remove the segment if the box stays outside the session.

## RUN4HEALTH (`run4health_base`, day 0 and day 8)

Source: *Protocolos RUN4HEALTH: recogida y sincronización v1* (Protocols 4-6) and the pilot note.

| # | Activity | Code | MET | Duration |
|---|---|---|---|---|
| | Calibration box | | | 6 × 60 s |
| 1 | Tumbado en reposo | 07011 | 1.0 | 5:00 |
| 2 | De pie quieto | 07040 | 1.3 | 4:00 |
| 3 | Sentado escribiendo en el ordenador | 09040 | 1.3 | 4:00 |
| 4 | Caminar despacio con bolsas de la compra | 05054 | 3.5 | 4:00 |
| 5 | Barrer | 05010 | 3.3 | 4:00 |
| 6 | Subir escaleras | 17131 | 6.8 | 4:00 |
| 7 | Trotar a ritmo propio | 12020 | 7.5 | 4:00 |
| 8 | Sentarse y levantarse 30 s | 02344 | 4.0 | 0:30 |
| 9 | Marcha de 6 minutos | 17220 | 5.5 | 6:00 |
| | Calibration box | | | 6 × 60 s |

- Resting first (300 s, resting HR) and the two fitness tests last follow the guide's recommendation.
- **[revisar]** Activities 2-7: the guide leaves the list pending ("5-10 activities chosen from the 16 of WEARGAP"). These six are among those the WEARGAP proposal names; 4 min each is a default for a steady heart rate.
- **[revisar]** 02344 (sit to stand, 18-24/min) is the closest code to a 30-s maximal test; 17220 (6.4-7.1 km/h) assumes runners walk fast. Check against the measured speed.
- Sensors from the guide's table: Matrix (non-dominant wrist, free living), AX3 non-dominant wrist, AX3 dominant wrist, SENS (thigh, free living), AX3 thigh, Polar H10 (chest, live), Verity Sense (arm, live in the lab and free living), fixed camera. AX3 at 100 Hz and ±8 g as the guide's default. **[revisar]** Thigh AX3 marked as not staying in free living (guide default); the optional shoe AX3s are not in the list.

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
