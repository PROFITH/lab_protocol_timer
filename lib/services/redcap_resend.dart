import 'dart:convert';
import 'dart:io';

import 'lab_redcap_service.dart';

/// Records of a saved session that did not reach REDCap.
///
/// When sending fails, the session folder keeps what would have been sent in
/// `redcap_records.json`. It can be sent again later from the start screen,
/// also after the app was closed; once REDCap accepts it, the file is
/// renamed `redcap_records_enviados_<fecha>.json`, so a pending file always
/// means data still missing in REDCap.
class SavedSessionRedcap {
  static const pendingFile = 'redcap_records.json';

  static File pending(Directory folder) => File('${folder.path}${Platform.pathSeparator}$pendingFile');

  /// The imports REDCap accepts for [records]: instances of repeating
  /// instruments apart, and never two rows of the same record and event in
  /// one import (the session's summary, detail and fitness rows share them).
  static List<List<Map<String, dynamic>>> importsFromRecords(List<Map<String, dynamic>> records) {
    bool repeating(Map<String, dynamic> r) =>
        (r['redcap_repeat_instrument']?.toString() ?? '').isNotEmpty;
    String key(Map<String, dynamic> r) => '${r['record_id']}|${r['redcap_event_name'] ?? ''}';

    final plain = <List<Map<String, dynamic>>>[];
    final repeated = <Map<String, dynamic>>[];
    for (final record in records) {
      if (repeating(record)) {
        repeated.add(record);
        continue;
      }
      final k = key(record);
      var batch = plain.where((b) => !b.any((r) => key(r) == k)).firstOrNull;
      if (batch == null) {
        batch = <Map<String, dynamic>>[];
        plain.add(batch);
      }
      batch.add(record);
    }
    return [...plain, if (repeated.isNotEmpty) repeated];
  }

  /// Sends the pending records of [folder]. Returns null when REDCap took
  /// them all, or what went wrong, for the evaluator.
  static Future<String?> send(
    Directory folder, {
    Future<String?> Function(List<Map<String, dynamic>>) importRecords = LabRedCapService.importRecords,
    DateTime? now,
  }) async {
    final file = pending(folder);
    if (!await file.exists()) {
      return 'En esta carpeta no hay nada pendiente de enviar ($pendingFile). Ese archivo solo se '
          'guarda cuando el envío a REDCap falla; elige la carpeta de la visita, por ejemplo R4H_001${Platform.pathSeparator}D0.';
    }
    final List<Map<String, dynamic>> records;
    try {
      records = [
        for (final r in jsonDecode(await file.readAsString()) as List) Map<String, dynamic>.from(r as Map),
      ];
    } catch (e) {
      return 'No se pudo leer $pendingFile: $e';
    }
    final imports = importsFromRecords(records);
    final errors = <String>[];
    for (var i = 0; i < imports.length; i++) {
      final error = await importRecords(imports[i]);
      if (error == null) continue;
      errors.add('Envío ${i + 1} de ${imports.length}: '
          '${LabRedCapService.explainImportError(error, imports[i], retry: '«Enviar a REDCap una sesión guardada»')}');
    }
    if (errors.isNotEmpty) return errors.join('\n');
    await markSent(folder, now: now);
    return null;
  }

  /// Renames the pending records once REDCap has them.
  static Future<void> markSent(Directory folder, {DateTime? now}) async {
    final file = pending(folder);
    if (!await file.exists()) return;
    final t = (now ?? DateTime.now()).toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}${two(t.second)}';
    try {
      await file.rename('${folder.path}${Platform.pathSeparator}redcap_records_enviados_$stamp.json');
    } on FileSystemException {
      // Kept as it is: sending it again does no harm.
    }
  }
}
