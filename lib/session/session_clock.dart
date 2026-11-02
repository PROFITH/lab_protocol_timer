/// Time source of a session.
///
/// Phase deadlines run on a monotonic clock, so a change of the computer's
/// clock (an internet time sync in the middle of a session) cannot shorten
/// or stretch a phase. Timestamps written to the files are wall-clock UTC,
/// the same clock the Research Monitor uses for the Polar samples and the
/// video, so all of them stay comparable.
abstract class SessionClock {
  /// Monotonic time since an arbitrary origin.
  Duration get elapsed;

  /// Wall-clock time in UTC.
  DateTime nowUtc();
}

class SystemSessionClock implements SessionClock {
  final Stopwatch _stopwatch = Stopwatch()..start();

  @override
  Duration get elapsed => _stopwatch.elapsed;

  @override
  DateTime nowUtc() => DateTime.now().toUtc();
}

/// Clock moved by hand, for tests.
class FakeSessionClock implements SessionClock {
  FakeSessionClock([DateTime? start])
      : _start = (start ?? DateTime.utc(2026, 10, 21, 9)).toUtc();

  final DateTime _start;
  Duration _elapsed = Duration.zero;

  /// Extra wall-clock shift, to test clock jumps.
  Duration wallShift = Duration.zero;

  @override
  Duration get elapsed => _elapsed;

  @override
  DateTime nowUtc() => _start.add(_elapsed).add(wallShift);

  void advance(Duration step) => _elapsed += step;
}
