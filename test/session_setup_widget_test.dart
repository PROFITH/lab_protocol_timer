import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lab_protocol_timer/models/activity_battery.dart';
import 'package:lab_protocol_timer/setup/protocol_editor_page.dart';
import 'package:lab_protocol_timer/setup/session_setup_card.dart';

ActivityBattery _r4h() => ActivityBattery.parse(
      File('assets/protocols/run4health_base.json').readAsStringSync(),
    );

Widget _app(Widget child) => MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  setUp(() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.views.first.physicalSize = const Size(1600, 1000);
    binding.platformDispatcher.views.first.devicePixelRatio = 1.0;
  });

  testWidgets('setup card summarises the protocol and missing serials',
      (tester) async {
    String? selected = 'none';
    final battery = _r4h();
    await tester.pumpWidget(_app(SessionSetupCard(
      protocols: [battery],
      battery: battery,
      modified: false,
      note: null,
      loading: false,
      onSelect: (id) => selected = id,
      onEdit: () {},
      onImport: () {},
    )));

    expect(find.text('RUN4HEALTH (base)'), findsOneWidget);
    expect(find.textContaining('9 actividades · '),
        findsOneWidget);
    expect(find.text('7 sensores sin número de serie'), findsOneWidget);
    expect(find.text('Editar actividades y sensores'), findsOneWidget);

    await tester.tap(find.text('RUN4HEALTH (base)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sin protocolo (actividades numeradas)').last);
    await tester.pumpAndSettle();
    expect(selected, isNull);
  });

  testWidgets('editor removes an activity and returns the edited protocol',
      (tester) async {
    ActivityBattery? result;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await Navigator.of(context).push<ActivityBattery>(
              MaterialPageRoute(
                builder: (_) => ProtocolEditorPage(initial: _r4h()),
              ),
            );
          },
          child: const Text('abrir'),
        ),
      ),
    ));
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();

    expect(find.textContaining('ACTIVIDADES (9'), findsOneWidget);
    expect(find.text('Tumbado en reposo'), findsOneWidget);

    await tester.tap(find.byTooltip('Eliminar').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('ACTIVIDADES (8'), findsOneWidget);

    await tester.tap(find.text('Tumbado en reposo'));
    await tester.pumpAndSettle();
    expect(find.text('Editar actividad'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Tumbado en reposo'), 'Tumbado');
    await tester.tap(find.text('Aceptar'));
    await tester.pumpAndSettle();
    expect(find.text('Tumbado'), findsOneWidget);

    await tester.tap(find.text('SENSORES (8)'));
    await tester.pumpAndSettle();
    expect(find.text('Polar H10 · Pecho'), findsOneWidget);

    await tester.tap(find.text('Polar H10 · Pecho'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Número de serie'), 'C0FFEE');
    await tester.tap(find.text('Aceptar'));
    await tester.pumpAndSettle();
    expect(find.textContaining('nº C0FFEE'), findsOneWidget);

    await tester.tap(find.text('Usar en esta sesión'));
    await tester.pumpAndSettle();
    expect(result?.activities, hasLength(8));
    expect(result?.activities.first.name, 'Tumbado');
    expect(result?.activities.first.compendiumCode, '07011');
    // Editing keeps what the dialog does not show.
    expect(result?.activities.first.restingHr, isTrue);
    expect(result?.activities.first.animation, 'lie');
    expect(result?.activities.first.instructions, isNotNull);
    expect(result?.activities.last.redcap?.doneField, 'chairstand_realiza');
    expect(result?.sensors, hasLength(8));
    expect(result?.sensors.firstWhere((s) => s.type == 'polar_h10').serial,
        'C0FFEE');
    expect(result?.sensors.firstWhere((s) => s.type == 'polar_h10').sensorId,
        'polar_h10');
  });
}
