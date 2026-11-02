/// `m:ss` (or `h:mm:ss`) for a number of seconds.
String formatSeconds(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

/// Reads `90`, `1:30` or `1:00:00` as seconds; null when empty or invalid.
int? parseSeconds(String text) {
  final value = text.trim();
  if (value.isEmpty) return null;
  final parts = value.split(':');
  if (parts.length > 3) return null;
  var total = 0;
  for (final part in parts) {
    final n = int.tryParse(part.trim());
    if (n == null || n < 0) return null;
    total = total * 60 + n;
  }
  return total;
}

/// Number with a decimal comma or point; null when empty or invalid.
double? parseDecimal(String text) {
  final value = text.trim().replaceAll(',', '.');
  if (value.isEmpty) return null;
  return double.tryParse(value);
}

String formatDecimal(double? value) {
  if (value == null) return '';
  return value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toString();
}

/// Protocol ID made from a name typed by the user (`custom_mi_bateria`).
String protocolIdFromName(String name) {
  const from = 'áàäâéèëêíìïîóòöôúùüûñç';
  const to = 'aaaaeeeeiiiioooouuuunc';
  final buffer = StringBuffer();
  for (final char in name.toLowerCase().split('')) {
    final i = from.indexOf(char);
    final c = i >= 0 ? to[i] : char;
    buffer.write(RegExp(r'[a-z0-9]').hasMatch(c) ? c : '_');
  }
  final slug = buffer
      .toString()
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
  return 'custom_${slug.isEmpty ? 'protocolo' : slug}';
}
