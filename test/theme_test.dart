// Light and dark theme. With FIGURES_OUT=/some/dir the setup page and a
// live chart are also written to PNG in both themes for a visual check.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lab_protocol_timer/session/session_controller.dart';
import 'package:lab_protocol_timer/setup/participant_setup_page.dart';
import 'package:lab_protocol_timer/ui/app_theme.dart';
import 'package:lab_protocol_timer/windows/live_signal.dart';
import 'package:lab_protocol_timer/windows/monitor_popout.dart';
import 'package:lab_protocol_timer/windows/sensor_chart_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'tools/render_participant_test.dart' show loadFonts;

/// Reads the palette outside the widget tree, like the file-level colours
/// of the pages.
class _Probe extends StatelessWidget {
  const _Probe();

  static int builds = 0;

  @override
  Widget build(BuildContext context) {
    builds++;
    return ColoredBox(color: Palette.current.panel, child: const SizedBox(width: 10, height: 10));
  }
}

void main() {
  final out = Platform.environment['FIGURES_OUT'];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ThemeController.set(ThemeMode.dark);
  });

  test('the theme is remembered and sets the palette', () async {
    await ThemeController.set(ThemeMode.light);
    expect(Palette.current.dark, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme_mode'), 'light');

    ThemeController.mode.value = ThemeMode.dark;
    await ThemeController.load();
    expect(ThemeController.mode.value, ThemeMode.light);
    expect(Palette.current, same(Palette.lightPalette));
  });

  test('a toggle tells the other window', () async {
    ThemeMode? told;
    ThemeController.onToggle = (mode) => told = mode;
    await ThemeController.toggle();
    expect(told, ThemeMode.light);
    await ThemeController.toggle();
    expect(told, ThemeMode.dark);
    ThemeController.onToggle = null;
  });

  testWidgets('a toggle rebuilds the widgets that read the palette, keeping their state', (tester) async {
    final field = TextEditingController();
    await tester.pumpWidget(ThemeScope(
      builder: (context, mode) => MaterialApp(
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: mode,
        home: Scaffold(
          body: Column(children: [
            const _Probe(),
            TextField(controller: field),
            const ThemeToggleButton(),
          ]),
        ),
      ),
    ));
    await tester.enterText(find.byType(TextField), 'ID 001');
    final before = _Probe.builds;
    await tester.tap(find.byKey(const Key('theme_toggle')));
    await tester.pumpAndSettle();
    expect(ThemeController.isDark, isFalse);
    expect(_Probe.builds, greaterThan(before));
    final box = tester.widget<ColoredBox>(find.descendant(of: find.byType(_Probe), matching: find.byType(ColoredBox)));
    expect(box.color, Palette.lightPalette.panel);
    expect(find.text('ID 001'), findsOneWidget);
    expect(Theme.of(tester.element(find.byType(_Probe))).extension<Palette>()!.dark, isFalse);
  });

  testWidgets('the participant screen stays dark in the light theme', (tester) async {
    await ThemeController.set(ThemeMode.light);
    late BuildContext inner;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: AlwaysDark(child: Builder(builder: (context) {
        inner = context;
        return const SizedBox();
      })),
    ));
    expect(inner.pal.dark, isTrue);
  });

  test('the copy of a monitor starts again when the sensor, the mode or the theme change', () async {
    final buffer = SignalBuffer(window: const Duration(seconds: 10), maxRateHz: 200);
    PopoutSource source(Color color) => PopoutSource(
          title: 'MONITOR 1',
          subtitle: 'ACC · h10',
          unit: 'mg',
          visualization: 'acceleration',
          window: buffer.window,
          series: [ChartSeries(buffer: buffer, color: color, label: 'VM')],
          currentValue: () => '--',
        );
    final key = source(Colors.blue).key;
    expect(source(Colors.blue).key, key);
    expect(source(Colors.red).key, isNot(key));
    await ThemeController.set(ThemeMode.light);
    expect(source(Colors.blue).key, isNot(key));

    final copy = SignalBuffer.sized(window: buffer.window, capacity: buffer.capacity);
    expect(copy.capacity, buffer.capacity);
  });

  test('a monitor window gets its owner in one argument', () {
    // The plugin merges the window id with std::merge, which needs sorted
    // lists: three arguments stopped the debug build (04/11/2026).
    final arg = monitorPopoutArgument(1);
    expect(monitorPopoutOwner(['3', arg]), 1);
    expect(monitorPopoutOwner(['1', 'research_monitor']), isNull);
  });

  testWidgets('render the setup page and a chart in both themes', (tester) async {
    if (out == null) return;
    await tester.runAsync(loadFonts);
    await tester.binding.setSurfaceSize(const Size(1400, 1100));
    final key = GlobalKey();
    final buffers = [
      for (var i = 0; i < 3; i++) SignalBuffer(window: const Duration(seconds: 10), maxRateHz: 200),
    ];
    final t0 = DateTime.utc(2026, 11, 4).microsecondsSinceEpoch.toDouble();
    for (var s = 0; s < 2000; s++) {
      for (var i = 0; i < 3; i++) {
        buffers[i].addMicros(t0 + s * 5000, 1000 * (i == 2 ? 1 : 0) + 300 * ((s + 70 * i) % 200 < 100 ? 1 : -1) * (s % 37) / 37);
      }
    }
    final clock = LiveFrameClock();

    for (final mode in [ThemeMode.dark, ThemeMode.light]) {
      await ThemeController.set(mode);
      await tester.pumpWidget(ThemeScope(
        builder: (context, mode) => MaterialApp(
          theme: AppTheme.light.copyWith(textTheme: AppTheme.light.textTheme.apply(fontFamily: 'Roboto')),
          darkTheme: AppTheme.dark.copyWith(textTheme: AppTheme.dark.textTheme.apply(fontFamily: 'Roboto')),
          themeMode: mode,
          home: RepaintBoundary(
            key: key,
            child: Row(children: [
              Expanded(
                child: ParticipantSetupPage(
                  onStart: (_) async {},
                  monitor: NoMonitor(),
                  audioFactory: SilentAudio.new,
                  checkUnfinished: false,
                ),
              ),
              SizedBox(
                width: 560,
                child: Container(
                  color: Palette.current.canvas,
                  padding: const EdgeInsets.all(12),
                  child: Builder(builder: (context) {
                    return Column(children: [
                      SizedBox(
                        height: 300,
                        child: SensorChartCard(
                          title: 'MONITOR 1',
                          subtitle: 'ACC · h10_pecho',
                          icon: Icons.sensors_rounded,
                          currentValue: () => '1012.0',
                          unit: 'mg',
                          seriesList: [
                            ChartSeries(buffer: buffers[0], color: Colors.redAccent, label: 'X'),
                            ChartSeries(buffer: buffers[1], color: context.pal.good, label: 'Y'),
                            ChartSeries(buffer: buffers[2], color: context.pal.accent, label: 'Z'),
                          ],
                          window: const Duration(seconds: 10),
                          clock: clock,
                          onPopOut: () {},
                        ),
                      ),
                    ]);
                  }),
                ),
              ),
            ]),
          ),
        ),
      ));
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 0.8);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('$out/theme_${mode.name}.png').writeAsBytes(bytes!.buffer.asUint8List());
      });
      // The waiting room, after «Preparar sesión».
      // (The page keeps its state across themes: in the waiting room already.)
      if (find.byKey(const Key('prepare_session')).evaluate().isNotEmpty) {
        await tester.enterText(find.byType(TextFormField).first, 'P01');
        await tester.pump();
        await tester.ensureVisible(find.byKey(const Key('prepare_session')));
        await tester.tap(find.byKey(const Key('prepare_session')));
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.tap(find.byType(Checkbox).first);
        await tester.pump();
      }
      await tester.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 0.8);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('$out/waiting_room_${mode.name}.png').writeAsBytes(bytes!.buffer.asUint8List());
      });
    }
  });
}
