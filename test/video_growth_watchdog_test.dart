import 'package:flutter_test/flutter_test.dart';
import 'package:lab_protocol_timer/services/video_growth_watchdog.dart';

void main() {
  final t0 = DateTime(2026, 11, 10, 12, 40);
  DateTime at(int s) => t0.add(Duration(seconds: s));

  test('un vídeo que crece nunca se da por parado', () {
    final w = VideoGrowthWatchdog()..reset(t0);
    for (var s = 5; s <= 120; s += 5) {
      expect(w.update(s * 300000, at(s)), isFalse);
    }
    expect(w.stalled, isFalse);
  });

  test('un archivo que deja de crecer 20 s se da por parado, y vuelve al crecer', () {
    final w = VideoGrowthWatchdog()..reset(t0);
    w.update(440000, at(5));
    expect(w.update(440000, at(10)), isFalse);
    expect(w.update(440000, at(20)), isFalse);
    expect(w.update(440000, at(25)), isTrue);
    expect(w.stalled, isTrue);
    expect(w.secondsSinceGrowth(at(25)), 20);
    expect(w.update(440000, at(30)), isFalse); // sigue parado: no avisa otra vez
    expect(w.update(900000, at(35)), isTrue);
    expect(w.stalled, isFalse);
  });

  test('sin archivo todavía no avisa', () {
    final w = VideoGrowthWatchdog()..reset(t0);
    expect(w.update(null, at(60)), isFalse);
    expect(w.stalled, isFalse);
  });
}
