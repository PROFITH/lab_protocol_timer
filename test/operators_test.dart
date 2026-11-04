import 'package:flutter_test/flutter_test.dart';
import 'package:lab_protocol_timer/session/session_controller.dart';
import 'package:lab_protocol_timer/windows/monitor_session.dart';

void main() {
  group('evaluators of a session', () {
    test('are trimmed, without blanks or repeated names', () {
      expect(SessionController.cleanOperators([' JHM ', '', 'MDF', 'JHM', '  ']), ['JHM', 'MDF']);
    });

    test('are read from the list, or from the single operator of older sessions', () {
      expect(SessionController.operatorsFromJson({'operators': ['JHM', 'MDF'], 'operator': 'JHM, MDF'}),
          ['JHM', 'MDF']);
      // Saved by 1.3.x: one text, kept whole (it may hold a comma).
      expect(SessionController.operatorsFromJson({'operator': 'Ana, técnica'}), ['Ana, técnica']);
      expect(SessionController.operatorsFromJson({}), isEmpty);
    });

    test('the monitor shows all of them, also from an older session', () {
      final s = MonitorSession();
      s.setInfo({'operator': 'JHM, MDF', 'operators': ['JHM', 'MDF']});
      expect(s.operators, ['JHM', 'MDF']);
      expect(s.operator, 'JHM, MDF');
      s.setInfo({'operator': 'JHM'});
      expect(s.operators, ['JHM']);
      s.setInfo({});
      expect(s.operators, isEmpty);
    });
  });
}
