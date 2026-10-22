/// Messages between the participant window (main) and the Research Monitor.
class WindowMessages {
  // ===========================================================================
  // Main -> monitor
  // ===========================================================================

  /// The session started (or was resumed): its folder and the stamp of the
  /// Polar and video file names. The monitor writes the Polar files there.
  static const String sessionStarted = 'session_started';

  /// Protocol, participants and settings of the session (sent when they
  /// change, not every second).
  static const String sessionInfo = 'session_info';

  /// State of the timer, several times a second.
  static const String sessionSnapshot = 'session_snapshot';

  /// The session is ending: the monitor stops the cameras, moves the videos
  /// into the session folder, closes the Polar files and answers with the
  /// files it wrote.
  static const String sessionStopping = 'session_stopping';

  /// The app is closing in the middle of a session: the monitor flushes
  /// its files and stops the cameras so the videos are kept.
  static const String sessionSuspending = 'session_suspending';

  /// The session was saved: summary for the evaluator.
  static const String sessionSaved = 'session_saved';

  /// The session was cancelled.
  static const String sessionCancelled = 'session_cancelled';

  /// Mean heart rate of a time span (resting heart rate).
  static const String restingHrRequested = 'resting_hr_requested';

  /// Asks the monitor to stop the camera and Bluetooth before its window is
  /// hidden at the end of an evaluation.
  static const String releaseResources = 'release_resources';

  /// Rebuilds the hidden monitor from scratch for a new evaluation.
  static const String resetMonitor = 'reset_monitor';

  static const String protocolConfiguration = 'protocol_configuration';

  // ===========================================================================
  // Monitor -> main
  // ===========================================================================

  static const String researchMonitorReady = 'research_monitor_ready';

  /// A command of the evaluator: `{'command': 'start' | 'pause' | ...}`.
  /// The answer is `{'ok': bool, 'message': String?}`.
  static const String sessionCommand = 'session_command';
}
