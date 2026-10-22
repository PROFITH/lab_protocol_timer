# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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
