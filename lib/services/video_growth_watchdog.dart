/// Tells when a video being recorded stops growing on disk.
///
/// On Windows the camera writes the video to a file of the Videos folder
/// while it records. If the camera stops giving frames to the recorder (the
/// preview can keep working), that file stops growing and, at the end, the
/// video lasts only until that moment. This class only decides, from the
/// sizes it is given, whether the file has stopped growing.
class VideoGrowthWatchdog {
  VideoGrowthWatchdog({this.threshold = const Duration(seconds: 20)});

  /// Time without growing after which the video counts as stopped.
  final Duration threshold;

  int? _lastSize;
  DateTime? _lastGrowth;
  bool _stalled = false;

  /// True while the file has not grown for [threshold].
  bool get stalled => _stalled;

  /// Seconds since the file last grew (0 if it is growing or unknown).
  int secondsSinceGrowth(DateTime now) =>
      _lastGrowth == null ? 0 : now.difference(_lastGrowth!).inSeconds;

  void reset(DateTime now) {
    _lastSize = null;
    _lastGrowth = now;
    _stalled = false;
  }

  /// Feeds the size of the file at [now] (null: file not found yet, which
  /// says nothing). Returns true when [stalled] changes.
  bool update(int? size, DateTime now) {
    _lastGrowth ??= now;
    final before = _stalled;
    if (size != null && (_lastSize == null || size > _lastSize!)) {
      _lastSize = size;
      _lastGrowth = now;
      _stalled = false;
    } else if (size != null && now.difference(_lastGrowth!) >= threshold) {
      _stalled = true;
    }
    return _stalled != before;
  }
}
