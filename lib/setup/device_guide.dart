import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/app_theme.dart';

/// Guide of each sensor type (key of the sensor editor), in
/// `docs/device_guides/` (bundled as assets).
const deviceGuideFiles = <String, String>{
  'ax3': 'axivity.md',
  'ax6': 'axivity.md',
  'matrix': 'matrix.md',
  'sens': 'sens.md',
  'polar_h10': 'polar_h10.md',
  'verity_sense': 'verity_sense.md',
  'senswear': 'senswear.md',
};

/// Folder, under the parent folder of the sessions, whose `<type>.md`
/// replaces the guide of the app for that type.
const deviceGuideOverrideFolder = 'guias_dispositivos';

/// The initialization guide of [type]: the study's own
/// (`<dataRoot>/guias_dispositivos/<type>.md`) or the app's; null when
/// there is none.
Future<String?> loadDeviceGuide(String type, {String? dataRoot, AssetBundle? bundle}) async {
  if (dataRoot != null) {
    final own = File('$dataRoot${Platform.pathSeparator}$deviceGuideOverrideFolder${Platform.pathSeparator}$type.md');
    try {
      if (await own.exists()) return await own.readAsString();
    } catch (_) {}
  }
  final file = deviceGuideFiles[type];
  if (file == null) return null;
  try {
    return await (bundle ?? rootBundle).loadString('docs/device_guides/$file');
  } catch (_) {
    return null;
  }
}

/// Shows the initialization guide of [type] in a dialog.
Future<void> showDeviceGuide(BuildContext context,
    {required String type, required String title, String? dataRoot}) async {
  final text = await loadDeviceGuide(type, dataRoot: dataRoot);
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: context.pal.surface,
      title: Row(
        children: [
          Icon(Icons.menu_book_rounded, color: context.pal.accent),
          const SizedBox(width: 10),
          Expanded(child: Text(title)),
        ],
      ),
      content: SizedBox(
        width: 640,
        height: 520,
        child: text == null
            ? Text(
                'Todavía no hay guía para este dispositivo. Se puede añadir como '
                '$deviceGuideOverrideFolder/$type.md en la carpeta madre de las sesiones.',
                style: TextStyle(color: context.pal.on70),
              )
            : SingleChildScrollView(child: SimpleMarkdown(text)),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cerrar')),
      ],
    ),
  );
}

/// The small Markdown of the guides: headings, paragraphs, quotes,
/// numbered and dashed lists (indented too) and **bold**.
class SimpleMarkdown extends StatelessWidget {
  const SimpleMarkdown(this.text, {super.key});

  final String text;

  static final _numbered = RegExp(r'^(\s*)(\d+)\.\s+(.*)$');
  static final _bullet = RegExp(r'^(\s*)[-*]\s+(.*)$');
  static final _heading = RegExp(r'^(#{1,6})\s+(.*)$');

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final base = TextStyle(color: pal.on, fontSize: 14, height: 1.45);
    final blocks = <Widget>[];
    final paragraph = <String>[];

    void flush() {
      if (paragraph.isEmpty) return;
      blocks.add(Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text.rich(TextSpan(children: inline(paragraph.join(' '), base))),
      ));
      paragraph.clear();
    }

    for (final raw in text.split('\n')) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        flush();
        continue;
      }
      final h = _heading.firstMatch(line);
      if (h != null) {
        flush();
        final level = h.group(1)!.length;
        blocks.add(Padding(
          padding: EdgeInsets.only(top: level == 1 ? 0 : 10, bottom: 6),
          child: Text(
            h.group(2)!,
            style: base.copyWith(
              fontSize: level == 1 ? 20 : (level == 2 ? 16 : 14),
              fontWeight: FontWeight.w800,
              color: level == 1 ? pal.on : pal.accent,
            ),
          ),
        ));
        continue;
      }
      final n = _numbered.firstMatch(line);
      final b = n == null ? _bullet.firstMatch(line) : null;
      if (n != null || b != null) {
        flush();
        final indent = (n ?? b)!.group(1)!.length ~/ 2;
        final marker = n != null ? '${n.group(2)}.' : '•';
        final body = n != null ? n.group(3)! : b!.group(2)!;
        blocks.add(Padding(
          padding: EdgeInsets.only(left: 6.0 + 22 * indent, bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 24, child: Text(marker, style: base.copyWith(color: pal.on60))),
              Expanded(child: Text.rich(TextSpan(children: inline(body, base)))),
            ],
          ),
        ));
        continue;
      }
      if (line.startsWith('>')) {
        flush();
        blocks.add(Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          decoration: BoxDecoration(
            color: pal.warn.withAlpha(30),
            border: Border(left: BorderSide(color: pal.warn, width: 3)),
          ),
          child: Text.rich(TextSpan(children: inline(line.substring(1).trim(), base))),
        ));
        continue;
      }
      paragraph.add(line.trim());
    }
    flush();
    return SelectionArea(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: blocks),
    );
  }

  /// Text with **bold** and `code`.
  static List<InlineSpan> inline(String text, TextStyle base) {
    final spans = <InlineSpan>[];
    final pattern = RegExp(r'\*\*(.+?)\*\*|`(.+?)`');
    var at = 0;
    for (final m in pattern.allMatches(text)) {
      if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start), style: base));
      spans.add(m.group(1) != null
          ? TextSpan(text: m.group(1), style: base.copyWith(fontWeight: FontWeight.w800))
          : TextSpan(text: m.group(2), style: base.copyWith(fontFamily: 'monospace')));
      at = m.end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at), style: base));
    return spans;
  }
}
