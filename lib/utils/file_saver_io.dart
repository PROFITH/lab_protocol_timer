import 'dart:io';

Future<void> saveCsvFile(String filename, String content) async {
  try {
    final file = File(filename);
    await file.writeAsString(content);
  } catch (e) {
    // Manejo de error silencioso o log
  }
}