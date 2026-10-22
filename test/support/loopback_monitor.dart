import 'package:lab_protocol_timer/session/session_controller.dart';
import 'package:lab_protocol_timer/windows/monitor_session.dart';
import 'package:lab_protocol_timer/windows/window_messages.dart';

/// The Research Monitor side, without windows: the messages of the session
/// go straight into a [MonitorSession], as the real monitor does.
class LoopbackMonitor implements MonitorLink {
  LoopbackMonitor(this.session);

  final MonitorSession session;
  final List<String> methods = [];
  int? restingHr = 54;

  @override
  Future<dynamic> send(String method, [dynamic arguments]) async {
    methods.add(method);
    final args = arguments is Map ? arguments : const <String, dynamic>{};
    switch (method) {
      case WindowMessages.sessionInfo:
        session.setInfo(args);
        return true;
      case WindowMessages.sessionSnapshot:
        session.setSnapshot(args);
        return true;
      case WindowMessages.sessionStarted:
        session.setStarted(args);
        return true;
      case WindowMessages.sessionStopping:
        return {'video_files': <String>[], 'files': <String>[], 'cameras': 0};
      case WindowMessages.sessionSuspending:
        session.clear();
        return {'video_files': <String>[], 'files': <String>[], 'cameras': 0};
      case WindowMessages.sessionSaved:
        session.setSaved(args);
        return true;
      case WindowMessages.sessionCancelled:
        session.setCancelled(args);
        return true;
      case WindowMessages.restingHrRequested:
        final bpm = restingHr;
        return bpm == null ? null : {'bpm': bpm, 'method': 'rr', 'n': 140, 'device': 'polar_h10'};
    }
    return null;
  }
}

