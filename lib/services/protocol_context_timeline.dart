/// Participant, activity and phase of the protocol at one moment.
class ProtocolContext {
  const ProtocolContext(this.participantId, this.activityIndex, this.phaseName);

  final String participantId;
  final int activityIndex;
  final String phaseName;

  static const idle = ProtocolContext('', 1, 'idle');

  bool sameAs(ProtocolContext other) =>
      participantId == other.participantId &&
      activityIndex == other.activityIndex &&
      phaseName == other.phaseName;
}

/// When each phase of the protocol started, on the host clock, so that a
/// sample gets the phase of the moment it was measured and not of the
/// moment it arrived: a Bluetooth link that falls behind delivers samples
/// seconds late, and labelling them on arrival put the end of one phase in
/// the next.
class ProtocolContextTimeline {
  ProtocolContextTimeline({this.keep = const Duration(minutes: 10)});

  /// How far back changes are kept (samples are never later than this).
  final Duration keep;

  final List<(int, ProtocolContext)> _changes = [];

  ProtocolContext get current => _changes.isEmpty ? ProtocolContext.idle : _changes.last.$2;

  /// The context became [context] at [hostMicros] (UTC µs).
  void update(int hostMicros, ProtocolContext context) {
    if (_changes.isNotEmpty) {
      if (_changes.last.$2.sameAs(context)) return;
      // The clock of the host never goes back, but keep the list sorted.
      if (hostMicros < _changes.last.$1) hostMicros = _changes.last.$1;
    }
    _changes.add((hostMicros, context));
    final oldest = hostMicros - keep.inMicroseconds;
    // Keep the change in force at [oldest] and those after it.
    var drop = 0;
    while (drop + 1 < _changes.length && _changes[drop + 1].$1 <= oldest) {
      drop++;
    }
    if (drop > 0) _changes.removeRange(0, drop);
  }

  /// Context at [hostMicros]: the last change at or before it, or the
  /// first known one for a time before all of them.
  ProtocolContext at(int hostMicros) {
    if (_changes.isEmpty) return ProtocolContext.idle;
    // Most samples belong to the last change.
    if (hostMicros >= _changes.last.$1) return _changes.last.$2;
    var lo = 0;
    var hi = _changes.length - 1;
    if (hostMicros < _changes[0].$1) return _changes[0].$2;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_changes[mid].$1 <= hostMicros) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return _changes[lo].$2;
  }

  void clear() => _changes.clear();
}
