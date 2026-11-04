import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Colours of the operator's screens (setup, protocol editor, calibration,
/// Research Monitor) in the dark and the light theme. The participant's
/// screen keeps its own dark colours: the phase colours are what it says.
///
/// `on*` is the ink over the background: white in the dark theme and slate
/// in the light one, at the opacities the dark screens always used.
@immutable
class Palette extends ThemeExtension<Palette> {
  const Palette({
    required this.dark,
    required this.on,
    required this.canvas,
    required this.canvasMain,
    required this.panel,
    required this.panelDeep,
    required this.surface,
    required this.border,
    required this.accent,
    required this.good,
    required this.warn,
    required this.bad,
    required this.cyan,
    required this.orange,
  });

  final bool dark;
  final Color on;

  /// The palette of the theme in use, for colours read outside a widget's
  /// build (file-level constants of a page). [ThemeScope] rebuilds every
  /// widget when it changes.
  static Palette current = darkPalette;

  /// Background of the Research Monitor.
  final Color canvas;

  /// Background of the participant window's setup.
  final Color canvasMain;
  final Color panel;
  final Color panelDeep;

  /// Cards and dialogs.
  final Color surface;
  final Color border;
  final Color accent;
  final Color good;
  final Color warn;
  final Color bad;
  final Color cyan;
  final Color orange;

  /// Ink over the accent and the other filled colours.
  Color get onAccent => dark ? Colors.black : Colors.white;

  Color get on70 => on.withValues(alpha: 0.70);
  Color get on60 => on.withValues(alpha: 0.60);
  Color get on54 => on.withValues(alpha: dark ? 0.54 : 0.62);
  Color get on38 => on.withValues(alpha: dark ? 0.38 : 0.50);
  Color get on30 => on.withValues(alpha: dark ? 0.30 : 0.40);
  Color get on24 => on.withValues(alpha: dark ? 0.24 : 0.30);
  Color get on12 => on.withValues(alpha: dark ? 0.12 : 0.16);
  Color get on10 => on.withValues(alpha: dark ? 0.10 : 0.12);

  static const darkPalette = Palette(
    dark: true,
    on: Colors.white,
    canvas: Color(0xFF07090E),
    canvasMain: Color(0xFF0B0F19),
    panel: Color(0xFF0F172A),
    panelDeep: Color(0xFF0B1220),
    surface: Color(0xFF1E293B),
    border: Color(0xFF334155),
    accent: Color(0xFF38BDF8),
    good: Color(0xFF34D399),
    warn: Color(0xFFFBBF24),
    bad: Color(0xFFF87171),
    cyan: Color(0xFF22D3EE),
    orange: Colors.orangeAccent,
  );

  static const lightPalette = Palette(
    dark: false,
    on: Color(0xFF0F172A),
    canvas: Color(0xFFE8EDF3),
    canvasMain: Color(0xFFF8FAFC),
    panel: Color(0xFFF1F5F9),
    panelDeep: Color(0xFFE2E8F0),
    surface: Color(0xFFFFFFFF),
    border: Color(0xFFCBD5E1),
    accent: Color(0xFF0369A1),
    good: Color(0xFF047857),
    warn: Color(0xFFB45309),
    bad: Color(0xFFB91C1C),
    cyan: Color(0xFF0E7490),
    orange: Color(0xFFC2410C),
  );

  @override
  Palette copyWith() => this;

  @override
  Palette lerp(ThemeExtension<Palette>? other, double t) =>
      other is Palette && t >= 0.5 ? other : this;
}

extension PaletteOf on BuildContext {
  Palette get pal => Theme.of(this).extension<Palette>() ?? Palette.darkPalette;
}

class AppTheme {
  static ThemeData of(Palette p) {
    final base = p.dark ? ThemeData.dark() : ThemeData.light();
    final scheme = p.dark
        ? ColorScheme.dark(primary: p.accent, surface: p.surface)
        : ColorScheme.light(primary: p.accent, surface: p.surface);
    return base.copyWith(
      scaffoldBackgroundColor: p.canvasMain,
      colorScheme: scheme,
      cardColor: p.surface,
      dividerColor: p.on12,
      dialogTheme: DialogThemeData(backgroundColor: p.surface),
      extensions: [p],
    );
  }

  static final ThemeData dark = of(Palette.darkPalette);
  static final ThemeData light = of(Palette.lightPalette);
}

/// Light or dark, chosen with the sun/moon button of the setup page or the
/// monitor and remembered on this computer. Both windows follow it: the one
/// where it changed tells the other.
class ThemeController {
  static final ValueNotifier<ThemeMode> mode = ValueNotifier(ThemeMode.dark);

  static const _key = 'theme_mode';

  static bool get isDark => mode.value != ThemeMode.light;

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString(_key) == 'light' ? ThemeMode.light : ThemeMode.dark;
      Palette.current = value == ThemeMode.light ? Palette.lightPalette : Palette.darkPalette;
      mode.value = value;
    } catch (e) {
      debugPrint('[THEME] No se pudo leer el tema: $e');
    }
  }

  /// Sets the theme here (and remembers it) without telling the other
  /// window; [onToggle] is how a window tells the other.
  static Future<void> set(ThemeMode value) async {
    Palette.current = value == ThemeMode.light ? Palette.lightPalette : Palette.darkPalette;
    mode.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, value == ThemeMode.light ? 'light' : 'dark');
    } catch (e) {
      debugPrint('[THEME] No se pudo guardar el tema: $e');
    }
  }

  /// Called after a toggle with the new mode (the window sends it to the
  /// other one).
  static void Function(ThemeMode mode)? onToggle;

  static Future<void> toggle() async {
    final next = isDark ? ThemeMode.light : ThemeMode.dark;
    await set(next);
    onToggle?.call(next);
  }
}

/// Sun or moon: switches between the light and the dark theme.
class ThemeToggleButton extends StatelessWidget {
  const ThemeToggleButton({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.mode,
      builder: (context, mode, _) {
        final dark = mode != ThemeMode.light;
        return IconButton(
          key: const Key('theme_toggle'),
          tooltip: dark ? 'Tema claro' : 'Tema oscuro',
          icon: Icon(dark ? Icons.light_mode_rounded : Icons.dark_mode_rounded),
          onPressed: ThemeController.toggle,
        );
      },
    );
  }
}

/// The root of a window's app: builds it with the theme in use and, when the
/// theme changes, rebuilds every widget below (the colours some pages keep
/// at file level do not depend on the theme) without losing their state.
class ThemeScope extends StatefulWidget {
  const ThemeScope({super.key, required this.builder});

  final Widget Function(BuildContext context, ThemeMode mode) builder;

  @override
  State<ThemeScope> createState() => _ThemeScopeState();
}

class _ThemeScopeState extends State<ThemeScope> {
  @override
  void initState() {
    super.initState();
    ThemeController.mode.addListener(_changed);
  }

  @override
  void dispose() {
    ThemeController.mode.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    void rebuild(Element element) {
      element.markNeedsBuild();
      element.visitChildren(rebuild);
    }

    (context as Element).visitChildren(rebuild);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, ThemeController.mode.value);
}

/// The participant's screen keeps its dark colours in either theme.
class AlwaysDark extends StatelessWidget {
  const AlwaysDark({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Theme(data: AppTheme.dark, child: child);
}
