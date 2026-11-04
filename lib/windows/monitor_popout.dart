import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:multi_window_manager/multi_window_manager.dart';

import '../ui/app_theme.dart';
import 'live_signal.dart';
import 'sensor_chart_card.dart';
import 'window_messages.dart';

/// Argument of a window that shows one monitor of the Research Monitor:
/// `monitor_popout|<id of the Research Monitor's window>`.
///
/// One argument only: the plugin puts the window id in front with
/// `std::merge`, which needs both lists sorted. With three arguments the
/// debug build of the plugin stopped on «sequence not ordered» (04/11/2026),
/// and a release build could reorder them.
const String monitorPopoutArg = 'monitor_popout';

String monitorPopoutArgument(int ownerWindowId) => '$monitorPopoutArg|$ownerWindowId';

/// The id of the Research Monitor's window in the arguments of a monitor
/// window, or null when they are not those of a monitor window.
int? monitorPopoutOwner(List<String> args) {
  for (final arg in args) {
    if (arg.startsWith('$monitorPopoutArg|')) {
      return int.tryParse(arg.substring(monitorPopoutArg.length + 1));
    }
  }
  return null;
}

/// What a chart of the Research Monitor shows, for its copy in another
/// window. Built with the chart, so it follows the sensor, the VM/XYZ mode
/// and the theme of the grid.
class PopoutSource {
  PopoutSource({
    required this.title,
    required this.subtitle,
    required this.unit,
    required this.visualization,
    required this.window,
    required this.series,
    required this.currentValue,
    this.lag,
  });

  final String title;
  final String subtitle;
  final String unit;

  /// `MonitorVisualization.name`: picks the icon in the other window.
  final String visualization;
  final Duration window;
  final List<ChartSeries> series;
  final String Function() currentValue;
  final Duration? lag;

  /// Changes when the other window has to start again from the whole
  /// buffers (another sensor, mode or theme).
  String get key => [
        title,
        subtitle,
        unit,
        visualization,
        window.inMilliseconds,
        lag?.inMilliseconds,
        Palette.current.dark,
        for (final s in series) '${s.label}/${s.color.toARGB32()}/${identityHashCode(s.buffer)}',
      ].join('|');
}

class _Popped {
  _Popped(this.windowId);

  final int windowId;
  PopoutSource? source;
  String? sentKey;
  List<double> lastSent = const [];
  String? lastValue;
}

/// The monitors of the Research Monitor opened in their own window, which
/// the evaluator can move to another screen and resize.
///
/// Each window keeps a copy of the chart's buffers, fed about 20 times a
/// second with the samples that arrived. Closing it hides it (destroying a
/// secondary window takes the app down on Windows) and the monitor goes back
/// to the grid; a hidden window is reused for the next one.
class MonitorPopouts {
  MonitorPopouts({required this.onChanged});

  /// A monitor went back to the grid (its window was closed).
  final VoidCallback onChanged;

  /// Hidden windows, kept while the Research Monitor lives (its state is
  /// rebuilt for each evaluation, the windows are not).
  static final List<int> _pool = [];
  static final Set<int> _ready = {};

  final Map<int, _Popped> _popped = {};
  Timer? _timer;
  bool _pumping = false;
  bool _disposed = false;

  bool isPopped(int slotId) => _popped.containsKey(slotId);

  /// Called while building the chart of a popped monitor.
  void register(int slotId, PopoutSource source) {
    _popped[slotId]?.source = source;
  }

  /// Opens monitor [slotId] in its own window (a hidden one if there is).
  Future<void> popOut(int slotId) async {
    if (_popped.containsKey(slotId) || _disposed) return;
    int? windowId;
    try {
      final alive = await MultiWindowManager.getAllAliveEngineIds();
      _pool.removeWhere((id) => !alive.contains(id));
    } catch (_) {}
    if (_pool.isNotEmpty) {
      windowId = _pool.removeLast();
      _popped[slotId] = _Popped(windowId);
      onChanged();
      try {
        final window = MultiWindowManager.fromWindowId(windowId);
        await window.show();
        await window.focus();
      } catch (e) {
        debugPrint('[POPOUT] No se pudo mostrar la ventana $windowId: $e');
      }
    } else {
      final window = await MultiWindowManager.createWindow([
        monitorPopoutArgument(MultiWindowManager.current.id),
      ]);
      if (window == null) {
        debugPrint('[POPOUT] No se pudo crear la ventana del monitor $slotId.');
        return;
      }
      if (_disposed) {
        _pool.add(window.id);
        unawaited(window.hide().catchError((Object _) {}));
        return;
      }
      windowId = window.id;
      _popped[slotId] = _Popped(windowId);
      onChanged();
    }
    _timer ??= Timer.periodic(const Duration(milliseconds: 50), (_) => _pump());
  }

  /// Shows the window of monitor [slotId] again (it may be behind others).
  Future<void> focus(int slotId) async {
    final popped = _popped[slotId];
    if (popped == null) return;
    try {
      final window = MultiWindowManager.fromWindowId(popped.windowId);
      await window.show();
      await window.focus();
    } catch (_) {}
  }

  /// Hides the window of monitor [slotId] and puts the monitor back in the
  /// grid.
  void bringBack(int slotId) {
    final popped = _popped.remove(slotId);
    if (popped == null) return;
    _pool.add(popped.windowId);
    unawaited(MultiWindowManager.fromWindowId(popped.windowId).hide().catchError((Object _) {}));
    if (_popped.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
    onChanged();
  }

  /// The messages of the windows; null when the message is not theirs.
  Future<dynamic> handleEvent(String eventName, int fromWindowId, dynamic arguments) async {
    switch (eventName) {
      case WindowMessages.popoutReady:
        _ready.add(fromWindowId);
        return true;
      case WindowMessages.popoutClosed:
        final entry = _popped.entries.where((e) => e.value.windowId == fromWindowId).firstOrNull;
        if (entry != null) {
          _popped.remove(entry.key);
          if (_popped.isEmpty) {
            _timer?.cancel();
            _timer = null;
          }
          onChanged();
        }
        if (!_pool.contains(fromWindowId)) _pool.add(fromWindowId);
        return true;
    }
    return null;
  }

  /// Hides every window (the monitor is rebuilt or closed).
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    for (final popped in _popped.values) {
      _pool.add(popped.windowId);
      unawaited(MultiWindowManager.fromWindowId(popped.windowId).hide().catchError((Object _) {}));
    }
    _popped.clear();
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      for (final entry in _popped.entries.toList()) {
        final popped = entry.value;
        final source = popped.source;
        if (source == null || !_ready.contains(popped.windowId)) continue;
        if (popped.sentKey != source.key) {
          await _sendConfig(entry.key, popped, source);
        } else {
          await _sendSamples(entry.key, popped, source);
        }
      }
    } catch (e) {
      debugPrint('[POPOUT] Error enviando datos: $e');
    } finally {
      _pumping = false;
    }
  }

  static Map<String, Object> _samples(SignalBuffer buffer, int from) {
    final n = buffer.length - from;
    final t = Float64List(n < 0 ? 0 : n);
    final v = Float64List(n < 0 ? 0 : n);
    for (var i = 0; i < n; i++) {
      t[i] = buffer.timeAt(from + i);
      v[i] = buffer.valueAt(from + i);
    }
    return {'t': t, 'v': v};
  }

  Future<void> _sendConfig(int slotId, _Popped popped, PopoutSource source) async {
    final key = source.key;
    final value = source.currentValue();
    final ok = await _invoke(popped.windowId, WindowMessages.popoutConfig, {
      'slot': slotId,
      'title': source.title,
      'subtitle': source.subtitle,
      'unit': source.unit,
      'visualization': source.visualization,
      'windowMs': source.window.inMilliseconds,
      if (source.lag != null) 'lagMs': source.lag!.inMilliseconds,
      'dark': Palette.current.dark,
      'value': value,
      'series': [
        for (final s in source.series)
          {
            'label': s.label,
            'color': s.color.toARGB32(),
            'capacity': s.buffer.capacity,
            ..._samples(s.buffer, 0),
          },
      ],
    });
    if (!ok) return;
    popped.sentKey = key;
    popped.lastValue = value;
    popped.lastSent = [for (final s in source.series) s.buffer.lastTime ?? double.negativeInfinity];
  }

  Future<void> _sendSamples(int slotId, _Popped popped, PopoutSource source) async {
    final series = <Map<String, Object>>[];
    var any = false;
    final lastSent = List<double>.of(popped.lastSent);
    for (var i = 0; i < source.series.length; i++) {
      final buffer = source.series[i].buffer;
      final last = buffer.lastTime ?? double.negativeInfinity;
      if (last < lastSent[i]) {
        // The trace restarted (clock correction or cleared buffer).
        series.add({'reset': true, ..._samples(buffer, 0)});
        any = true;
      } else {
        var from = buffer.length;
        while (from > 0 && buffer.timeAt(from - 1) > lastSent[i]) {
          from--;
        }
        final samples = _samples(buffer, from);
        if ((samples['t'] as Float64List).isNotEmpty) any = true;
        series.add({'reset': false, ...samples});
      }
      lastSent[i] = last;
    }
    final value = source.currentValue();
    if (!any && value == popped.lastValue) return;
    final ok = await _invoke(popped.windowId, WindowMessages.popoutSamples, {
      'value': value,
      'series': series,
    });
    if (!ok) return;
    popped.lastSent = lastSent;
    popped.lastValue = value;
  }

  Future<bool> _invoke(int windowId, String method, Object arguments) async {
    try {
      final result = await MultiWindowManager.current
          .invokeMethodToWindow(windowId, method, arguments)
          .timeout(const Duration(seconds: 2), onTimeout: () => null);
      return result == true;
    } catch (e) {
      debugPrint('[POPOUT] Error enviando "$method" a la ventana $windowId: $e');
      return false;
    }
  }
}

// =============================================================================
// The window of one monitor
// =============================================================================

const Map<String, IconData> _icons = {
  'heartRate': Icons.favorite_rounded,
  'rr': Icons.timeline_rounded,
  'acceleration': Icons.sensors_rounded,
  'ecg': Icons.show_chart_rounded,
  'ppg': Icons.fingerprint_rounded,
  'gyro': Icons.threesixty_rounded,
};

/// The app of a window that shows one monitor of the Research Monitor
/// ([ownerWindowId]), at the size the evaluator gives it.
class MonitorPopoutApp extends StatelessWidget {
  const MonitorPopoutApp({super.key, required this.ownerWindowId});

  final int ownerWindowId;

  @override
  Widget build(BuildContext context) {
    return ThemeScope(
      builder: (context, mode) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Monitor',
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: mode,
        home: _MonitorPopoutPage(ownerWindowId: ownerWindowId),
      ),
    );
  }
}

class _MonitorPopoutPage extends StatefulWidget {
  const _MonitorPopoutPage({required this.ownerWindowId});

  final int ownerWindowId;

  @override
  State<_MonitorPopoutPage> createState() => _MonitorPopoutPageState();
}

class _MonitorPopoutPageState extends State<_MonitorPopoutPage>
    with WindowListener, SingleTickerProviderStateMixin {
  final LiveFrameClock _clock = LiveFrameClock();
  late final Ticker _ticker = createTicker((_) => _clock.tick());
  Duration? _lag;

  int? _slot;
  String _title = '';
  String _subtitle = '';
  String _unit = '';
  String _visualization = '';
  Duration _window = const Duration(seconds: 10);
  List<ChartSeries> _series = const [];
  String _value = '--';

  @override
  void initState() {
    super.initState();
    final manager = MultiWindowManager.current;
    manager.addListener(this);
    unawaited(manager.setPreventClose(true).catchError((Object _) {}));
    unawaited(
      manager.invokeMethodToWindow(widget.ownerWindowId, WindowMessages.popoutReady).catchError((Object e) {
        debugPrint('[POPOUT] No se pudo avisar al Research Monitor: $e');
        return null;
      }),
    );
  }

  @override
  void dispose() {
    MultiWindowManager.current.removeListener(this);
    _ticker.dispose();
    _clock.dispose();
    super.dispose();
  }

  @override
  void onWindowClose([int? windowId]) {
    if (windowId != null && windowId != MultiWindowManager.current.id) return;
    unawaited(MultiWindowManager.current.hide().catchError((Object _) {}));
    unawaited(
      MultiWindowManager.current
          .invokeMethodToWindow(widget.ownerWindowId, WindowMessages.popoutClosed, {'slot': _slot})
          .catchError((Object _) => null),
    );
  }

  static void _addAll(SignalBuffer buffer, Map map) {
    final t = map['t'];
    final v = map['v'];
    if (t is! List || v is! List) return;
    for (var i = 0; i < t.length && i < v.length; i++) {
      buffer.addMicros((t[i] as num).toDouble(), (v[i] as num).toDouble());
    }
  }

  @override
  Future<dynamic> onEventFromWindow(String eventName, int fromWindowId, dynamic arguments) async {
    if (fromWindowId != widget.ownerWindowId || arguments is! Map) return null;
    switch (eventName) {
      case WindowMessages.popoutConfig:
        final window = Duration(milliseconds: (arguments['windowMs'] as num?)?.toInt() ?? 10000);
        final series = <ChartSeries>[];
        for (final raw in (arguments['series'] as List? ?? const [])) {
          if (raw is! Map) continue;
          final buffer = SignalBuffer.sized(
            window: window,
            capacity: (raw['capacity'] as num?)?.toInt() ?? 2000,
          );
          _addAll(buffer, raw);
          series.add(ChartSeries(
            buffer: buffer,
            color: Color((raw['color'] as num?)?.toInt() ?? 0xFF38BDF8),
            label: raw['label']?.toString() ?? '',
          ));
        }
        final dark = arguments['dark'] != false;
        if (dark != ThemeController.isDark) {
          await ThemeController.set(dark ? ThemeMode.dark : ThemeMode.light);
        }
        if (!mounted) return true;
        setState(() {
          _slot = (arguments['slot'] as num?)?.toInt();
          _title = arguments['title']?.toString() ?? '';
          _subtitle = arguments['subtitle']?.toString() ?? '';
          _unit = arguments['unit']?.toString() ?? '';
          _visualization = arguments['visualization']?.toString() ?? '';
          _window = window;
          _series = series;
          _value = arguments['value']?.toString() ?? '--';
          final lagMs = (arguments['lagMs'] as num?)?.toInt();
          _lag = lagMs == null ? null : Duration(milliseconds: lagMs);
        });
        // A chart with a lag scrolls with the clock: repaint every frame.
        if (_lag != null && !_ticker.isActive) _ticker.start();
        if (_lag == null && _ticker.isActive) _ticker.stop();
        unawaited(
          MultiWindowManager.current.setTitle('$_title · $_subtitle').catchError((Object _) {}),
        );
        return true;

      case WindowMessages.popoutSamples:
        final list = arguments['series'] as List? ?? const [];
        for (var i = 0; i < list.length && i < _series.length; i++) {
          final raw = list[i];
          if (raw is! Map) continue;
          if (raw['reset'] == true) _series[i].buffer.clear();
          _addAll(_series[i].buffer, raw);
        }
        _value = arguments['value']?.toString() ?? _value;
        _clock.tick();
        return true;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.pal.canvas,
      body: Padding(
        padding: const EdgeInsets.all(10),
        child: _series.isEmpty
            ? Center(
                child: Text(
                  'Esperando datos del Research Monitor…',
                  style: TextStyle(color: context.pal.on54),
                ),
              )
            : SensorChartCard(
                title: _title,
                subtitle: _subtitle,
                icon: _icons[_visualization] ?? Icons.show_chart_rounded,
                currentValue: () => _value,
                unit: _unit,
                seriesList: _series,
                window: _window,
                clock: _clock,
                lag: _lag,
              ),
      ),
    );
  }
}
