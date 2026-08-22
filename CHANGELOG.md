# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-08-22

Initial release for the PROFITH Research Group laboratory protocol tracking workflow.

This project originated as a fork of `plinkr/training_timer` and has been redesigned for laboratory data collection:

- **Laboratory Protocol UI:** Customized acoustic alarms, voice prompts (`flutter_tts`), station counters, and layout tailored to standardized laboratory exercise and assessment protocols.
- **REDCap API Integration:** Replaced generic workout logging with an automated REDCap batch synchronization service (`lab_redcap_service`) to format and upload session timestamps to facilitate synchronization of sensors and video recording.
- **Multi-Participant Setup:** Added support for simultaneous multi-participant tracking, dynamic participant entries, and individualized starting station offsets.
- **Session Persistence & Recovery:** Implemented state caching using `shared_preferences` to restore in-progress protocol runs after accidental window closure or crashes.
- **Cross-Platform Compilation:** Refactored project architecture to support both Windows Desktop native builds (`.exe`) and Web deployments from a single codebase.
- **Web Exit Confirmation Guard:** Added conditional platform bindings to intercept `beforeunload` events on browsers without conflicting with desktop runtimes.
