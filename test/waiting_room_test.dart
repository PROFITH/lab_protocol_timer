import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lab_protocol_timer/ui/app_theme.dart';
import 'package:lab_protocol_timer/windows/monitor_session.dart';
import 'package:lab_protocol_timer/windows/session_console.dart';

void main() {
  setUp(() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.views.first.physicalSize = const Size(1600, 1000);
    binding.platformDispatcher.views.first.devicePixelRatio = 1.0;
  });

  Widget app(Widget child) => MaterialApp(theme: AppTheme.dark, home: Scaffold(body: child));

  testWidgets('the monitor waits for the waiting room before a session can start', (tester) async {
    final session = MonitorSession();
    var starts = 0;
    Future<Map<String, dynamic>> send(String command, [Map<String, dynamic> args = const {}]) async => {'ok': true};
    await tester.pumpWidget(app(SingleChildScrollView(
      child: SessionConsole(session: session, send: send, onStart: () async => starts++),
    )));
    expect(find.text('SALA DE ESPERA'), findsOneWidget);
    expect(find.text('EMPEZAR SESIÓN'), findsNothing);

    session.setInfo({'participants': 'P01', 'settings': <String, dynamic>{}});
    await tester.pump();
    expect(find.text('EMPEZAR SESIÓN'), findsOneWidget);
    session.clear();
    await tester.pump();
    expect(find.text('SALA DE ESPERA'), findsOneWidget);
  });

  testWidgets('finishing asks whether to calibrate again', (tester) async {
    for (final yes in [true, false]) {
      Map<String, dynamic>? sent;
      Future<Map<String, dynamic>> send(String command, [Map<String, dynamic> args = const {}]) async {
        if (command == 'finish') sent = args;
        return {'ok': true};
      }

      final session = MonitorSession()..setInfo({'participants': 'P01', 'settings': <String, dynamic>{}});
      await tester.pumpWidget(app(Builder(
        builder: (context) => TextButton(
          onPressed: () => confirmFinish(context, session, send),
          child: const Text('fin'),
        ),
      )));
      await tester.tap(find.text('fin'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Finalizar y guardar'));
      await tester.pumpAndSettle();
      expect(find.text('¿Volver a calibrar los sensores?'), findsOneWidget);
      await tester.tap(find.byKey(Key(yes ? 'recalibrate_yes' : 'recalibrate_no')));
      await tester.pumpAndSettle();
      expect(sent?['recalibrate'], yes);
    }
  });
}
