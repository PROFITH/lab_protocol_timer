import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'lab_redcap_service.dart';
import 'redcap_connection.dart';

/// What happened with one phone file.
class PhoneFileResult {
  final String path;
  final String participantId;

  /// Rows in the file.
  final int rows;

  /// New rows sent to REDCap.
  final int imported;

  /// Rows REDCap already had (sent before from the phone, or in another
  /// file).
  final int alreadyInRedcap;

  /// Photos and videos sent to REDCap.
  final int filesUploaded;

  /// Photos and videos REDCap already had.
  final int filesAlreadyInRedcap;

  /// Photos and videos the phone no longer had (their rows are sent).
  final int missingFiles;

  /// Photos and videos too big for the Google Drive script: they come with
  /// «Exportar registros a un archivo» on the phone.
  final int skippedFiles;

  /// Null when REDCap has everything in the file.
  final String? error;

  /// The file's new path once sent (`…_enviado_<fecha>.json`).
  final String? sentAs;

  const PhoneFileResult({
    required this.path,
    this.participantId = '',
    this.rows = 0,
    this.imported = 0,
    this.alreadyInRedcap = 0,
    this.filesUploaded = 0,
    this.filesAlreadyInRedcap = 0,
    this.missingFiles = 0,
    this.skippedFiles = 0,
    this.error,
    this.sentAs,
  });

  bool get sent => error == null;

  String get name => PhoneRecordsImport.fileName(path);
}

/// Records exported by healthy_tracker phones (`healthy_tracker_*.json`, format
/// `healthy_tracker_export`, described in healthy_tracker's
/// docs/export_format.md), sent to REDCap from this computer.
///
/// The UGR's REDCap only accepts connections from its network or VPN, so the
/// phones leave these files in the study's Google Drive folder, or they are
/// copied by cable. Their rows have no instance number: each new row gets the
/// next free instance of `healthy_tracker`, and rows REDCap already has (same
/// type and same times, to the minute) are skipped, so sending a file twice,
/// or two files with the same rows, duplicates nothing. A file whose rows and
/// photos are all in REDCap is renamed `…_enviado_<fecha>.json`.
class PhoneRecordsImport {
  static const format = 'healthy_tracker_export';
  static const supportedVersion = 1;
  static const sentMarker = '_enviado_';
  static const batchSize = 100;

  /// Fields that identify a row of each `entry_type`, for files that do not
  /// say (the phone writes them in `match_fields`).
  static const defaultMatchFields = {
    '1': ['non_wear_start', 'non_wear_end'],
    '2': ['act_start', 'act_end', 'act_code'],
    '3': ['sleep_onset', 'sleep_wake'],
    '4': ['meal_time', 'meal_time_end'],
    '5': ['ema_type', 'ema_scheduled'],
  };

  final http.Client? _client;
  final String url;
  final String token;
  final bool withoutEvents;

  /// Sends with the connection of this computer unless told otherwise
  /// (tests).
  PhoneRecordsImport({http.Client? client, String? url, String? token, bool? withoutEvents})
      : _client = client,
        url = url ?? RedcapConnection.url,
        token = token ?? RedcapConnection.token,
        withoutEvents = withoutEvents ?? RedcapConnection.withoutEvents;

  static String fileName(String path) => path.split(RegExp(r'[\\/]')).last;

  /// A file the phone wrote and that is not sent yet.
  static bool isPending(String name) =>
      name.startsWith('healthy_tracker_') && name.endsWith('.json') && !name.contains(sentMarker);

  /// Phone files still to send in [folder] and its subfolders, by name (by
  /// participant, then oldest first).
  static Future<List<File>> pendingFiles(Directory folder) async {
    final files = <File>[];
    await for (final entity in folder.list(recursive: true, followLinks: false).handleError((Object _) {})) {
      if (entity is File && isPending(fileName(entity.path))) files.add(entity);
    }
    files.sort((a, b) => fileName(a.path).compareTo(fileName(b.path)));
    return files;
  }

  /// Sends every pending phone file of [folder]; [onFile] is told which one
  /// is going.
  Future<List<PhoneFileResult>> sendFolder(
    Directory folder, {
    DateTime? now,
    void Function(int index, int total, String name)? onFile,
  }) async {
    final files = await pendingFiles(folder);
    final results = <PhoneFileResult>[];
    for (var i = 0; i < files.length; i++) {
      onFile?.call(i, files.length, fileName(files[i].path));
      results.add(await sendFile(files[i], now: now));
    }
    return results;
  }

  /// Sends the rows and photos of [file] that REDCap does not have yet and,
  /// when it has them all, renames the file.
  Future<PhoneFileResult> sendFile(File file, {DateTime? now}) async {
    final client = _client ?? http.Client();
    try {
      return await _send(client, file, now);
    } finally {
      if (_client == null) client.close();
    }
  }

  Future<PhoneFileResult> _send(http.Client client, File file, DateTime? now) async {
    PhoneFileResult failed(String error) => PhoneFileResult(path: file.path, error: error);

    final Map<String, dynamic> data;
    try {
      data = Map<String, dynamic>.from(jsonDecode(await file.readAsString()) as Map);
    } catch (e) {
      return failed('No se pudo leer el archivo: $e');
    }
    if (data['format'] != format) return failed('No es un archivo de registros de healthy_tracker.');
    final version = data['version'];
    if (version is! int || version > supportedVersion) {
      return failed('Es de una versión de healthy_tracker más nueva (formato $version): actualiza lab_protocol_timer.');
    }
    if (token.isEmpty) {
      return failed('No hay token de REDCap en este ordenador: ponlo en «Conexión con REDCap».');
    }

    final participant = data['participant_id']?.toString() ?? '';
    final instrument = data['instrument']?.toString() ?? 'healthy_tracker';
    final typeField = data['type_field']?.toString() ?? 'entry_type';
    final matchFields = <String, List<String>>{
      for (final entry in ((data['match_fields'] as Map?) ?? defaultMatchFields).entries)
        entry.key.toString(): [for (final field in entry.value as List) field.toString()],
    };
    final rows = [for (final row in data['rows'] as List? ?? const []) Map<String, dynamic>.from(row as Map)];
    final attachments = [for (final f in data['files'] as List? ?? const []) Map<String, dynamic>.from(f as Map)];
    final missing = (data['missing_files'] as List?)?.length ?? 0;
    final skipped = (data['skipped_files'] as List?)?.length ?? 0;
    final fileFields = {
      for (final list in [attachments, data['missing_files'] as List? ?? const [], data['skipped_files'] as List? ?? const []])
        for (final f in list) (f as Map)['field'].toString(),
    };

    String recordOf(Map<String, dynamic> row) => row['record_id']?.toString() ?? participant;
    String eventOf(Map<String, dynamic> row) => withoutEvents ? '' : (row['redcap_event_name']?.toString() ?? '');

    // Rows by record and event: each has its own instance numbers.
    final groups = <String, List<int>>{};
    for (var i = 0; i < rows.length; i++) {
      groups.putIfAbsent('${recordOf(rows[i])}|${eventOf(rows[i])}', () => []).add(i);
    }

    var imported = 0, already = 0;
    final instances = <int, int>{};
    final inRedcap = <int, Set<String>>{};
    PhoneFileResult partial(String error) => PhoneFileResult(
          path: file.path,
          participantId: participant,
          rows: rows.length,
          imported: imported,
          alreadyInRedcap: already,
          missingFiles: missing,
          skippedFiles: skipped,
          error: error,
        );

    for (final group in groups.values) {
      final record = recordOf(rows[group.first]);
      final event = eventOf(rows[group.first]);
      final List<Map<String, dynamic>> existing;
      try {
        if (!await _recordExists(client, record)) {
          return partial('En REDCap no existe el participante «$record»: créalo (o revisa el código puesto en '
              'el móvil) y vuelve a enviar.');
        }
        final types = {for (final i in group) rows[i][typeField]?.toString() ?? ''};
        existing = await _export(client, record, event, {
          'record_id',
          typeField,
          for (final type in types) ...?matchFields[type],
          ...fileFields,
        });
      } on _RedcapError catch (e) {
        return partial(e.message);
      }

      final known = <String, Map<String, dynamic>>{};
      var last = 0;
      for (final row in existing) {
        if (row['redcap_repeat_instrument']?.toString() != instrument) continue;
        last = math.max(last, int.tryParse('${row['redcap_repeat_instance']}') ?? 0);
        final key = _key(row, typeField, matchFields);
        if (key != null) known.putIfAbsent(key, () => row);
      }

      final toImport = <Map<String, dynamic>>[];
      for (final i in group) {
        final key = _key(rows[i], typeField, matchFields);
        final match = key == null ? null : known[key];
        if (match != null) {
          already++;
          instances[i] = int.tryParse('${match['redcap_repeat_instance']}') ?? 0;
          inRedcap[i] = {for (final f in fileFields) if ((match[f]?.toString() ?? '').isNotEmpty) f};
          continue;
        }
        final instance = ++last;
        instances[i] = instance;
        inRedcap[i] = {};
        final row = {...rows[i], 'redcap_repeat_instrument': instrument, 'redcap_repeat_instance': instance};
        toImport.add(row);
        // Two equal rows in the file go once.
        if (key != null) known[key] = {...row, 'redcap_repeat_instance': '$instance'};
      }

      for (var start = 0; start < toImport.length; start += batchSize) {
        final batch = toImport.sublist(start, math.min(start + batchSize, toImport.length));
        final error = await _import(client, batch);
        if (error != null) {
          return partial(LabRedCapService.explainImportError(error, batch,
              retry: '«Enviar a REDCap los registros del móvil» (no se repite lo ya enviado)'));
        }
        imported += batch.length;
      }
    }

    var uploaded = 0, filesAlready = 0;
    final done = <String>{};
    for (final attachment in attachments) {
      final index = (attachment['row'] as num?)?.toInt() ?? -1;
      if (index < 0 || index >= rows.length) continue;
      final field = attachment['field'].toString();
      final row = rows[index];
      final instance = instances[index]!;
      final target = '${recordOf(row)}|${eventOf(row)}|$instance|$field';
      if (inRedcap[index]!.contains(field) || !done.add(target)) {
        filesAlready++;
        continue;
      }
      final error = await _upload(
        client,
        record: recordOf(row),
        event: eventOf(row),
        field: field,
        instance: instance,
        name: _uploadName(field, recordOf(row), instance, attachment['name']?.toString() ?? ''),
        bytes: base64.decode(attachment['data'].toString()),
      );
      if (error != null) {
        return PhoneFileResult(
          path: file.path,
          participantId: participant,
          rows: rows.length,
          imported: imported,
          alreadyInRedcap: already,
          filesUploaded: uploaded,
          filesAlreadyInRedcap: filesAlready,
          missingFiles: missing,
          skippedFiles: skipped,
          error: 'Los registros están en REDCap, pero no la foto o el vídeo de la instancia $instance: $error',
        );
      }
      uploaded++;
    }

    return PhoneFileResult(
      path: file.path,
      participantId: participant,
      rows: rows.length,
      imported: imported,
      alreadyInRedcap: already,
      filesUploaded: uploaded,
      filesAlreadyInRedcap: filesAlready,
      missingFiles: missing,
      skippedFiles: skipped,
      sentAs: await _markSent(file, now),
    );
  }

  /// The result of [sendFolder] in words, for the evaluator.
  static ({String title, String message}) describe(List<PhoneFileResult> results, String folder) {
    if (results.isEmpty) {
      return (
        title: 'Nada que enviar',
        message: 'En $folder no hay archivos de healthy_tracker por enviar (healthy_tracker_….json, también en '
            'subcarpetas). Los ya enviados llevan «$sentMarker» en el nombre.',
      );
    }
    String count(int n, String one, String many) => n == 1 ? '1 $one' : '$n $many';
    final lines = <String>[];
    for (final r in results) {
      if (r.sent) {
        final files = r.filesUploaded == 0 ? '' : ' y ${count(r.filesUploaded, 'foto o vídeo', 'fotos o vídeos')}';
        lines.add(r.imported == 0
            ? '✓ ${r.name}: ${r.rows == 1 ? 'su registro ya estaba' : 'sus ${r.rows} registros ya estaban'} en REDCap'
                '${r.filesUploaded == 0 ? '' : '; se ${r.filesUploaded == 1 ? 'ha añadido 1 foto o vídeo que faltaba' : 'han añadido ${r.filesUploaded} fotos o vídeos que faltaban'}'}.'
            : '✓ ${r.name}: ${count(r.imported, 'registro nuevo', 'registros nuevos')}$files'
                '${r.alreadyInRedcap == 0 ? '' : ' (${r.alreadyInRedcap == 1 ? 'otro ya estaba' : 'otros ${r.alreadyInRedcap} ya estaban'} en REDCap)'}.');
      } else {
        lines.add('✗ ${r.name}: ${r.error}'
            '${r.imported == 0 ? '' : ' Antes del error llegaron ${count(r.imported, 'registro nuevo', 'registros nuevos')}, que no se repetirán.'}');
      }
      if (r.missingFiles > 0) {
        lines.add('   ${r.missingFiles == 1 ? 'Falta 1 foto o vídeo que ya no estaba' : 'Faltan ${r.missingFiles} fotos o vídeos que ya no estaban'} '
            'en el móvil; sus registros van igual.');
      }
      if (r.skippedFiles > 0) {
        lines.add('   ${r.skippedFiles == 1 ? '1 foto o vídeo era demasiado grande' : '${r.skippedFiles} fotos o vídeos eran demasiado grandes'} '
            'para Google Drive: llegará${r.skippedFiles == 1 ? '' : 'n'} con «Exportar registros a un archivo» en el móvil.');
      }
    }
    final failed = results.where((r) => !r.sent).length;
    if (failed > 0) {
      lines.add('\n${failed == 1 ? 'El archivo que no se envió se queda' : 'Los archivos que no se enviaron se quedan'} como '
          'estaba${failed == 1 ? '' : 'n'}: vuelve a pulsar el botón cuando esté resuelto (lo ya enviado no se repite).');
    }
    return (
      title: failed == 0
          ? 'Registros del móvil enviados a REDCap'
          : failed == results.length
              ? 'No se pudo enviar'
              : 'Algunos archivos no se enviaron',
      message: lines.join('\n'),
    );
  }

  /// What identifies [row]: its type and its times (to the minute; REDCap
  /// may give the seconds or not), or null for a type without match fields.
  static String? _key(Map<String, dynamic> row, String typeField, Map<String, List<String>> matchFields) {
    final type = row[typeField]?.toString() ?? '';
    final fields = matchFields[type];
    if (fields == null || fields.isEmpty) return null;
    String norm(Object? value) {
      final text = (value ?? '').toString().trim();
      final time = RegExp(r'^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2})').firstMatch(text);
      return time == null ? text : '${time[1]} ${time[2]}';
    }

    return [type, for (final field in fields) norm(row[field])].join('|');
  }

  /// Names like the phone gives them when it sends them itself.
  static String _uploadName(String field, String record, int instance, String original) {
    final dot = original.lastIndexOf('.');
    final extension = dot < 0 ? '' : original.substring(dot + 1).toLowerCase();
    return switch (field) {
      'meal_photo' => 'meal_${record}_inst$instance.${extension.isEmpty ? 'jpg' : extension}',
      'act_video' => 'activity_${record}_inst$instance.${extension.isEmpty ? 'mp4' : extension}',
      _ => original.isEmpty ? '${field}_${record}_inst$instance' : original,
    };
  }

  /// Renames [file] `…_enviado_<fecha>.json`; null if it could not be renamed
  /// (sending it again does no harm).
  static Future<String?> _markSent(File file, DateTime? now) async {
    final t = (now ?? DateTime.now()).toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}${two(t.second)}';
    final base = file.path.substring(0, file.path.length - '.json'.length);
    try {
      return (await file.rename('$base$sentMarker$stamp.json')).path;
    } on FileSystemException {
      return null;
    }
  }

  Future<bool> _recordExists(http.Client client, String record) async {
    final rows = await _post(client, {
      'content': 'record',
      'format': 'json',
      'type': 'flat',
      'records[0]': record,
      'fields[0]': 'record_id',
      'returnFormat': 'json',
    });
    return rows is List && rows.isNotEmpty;
  }

  Future<List<Map<String, dynamic>>> _export(http.Client client, String record, String event, Set<String> fields) async {
    final list = fields.toList();
    final rows = await _post(client, {
      'content': 'record',
      'format': 'json',
      'type': 'flat',
      'records[0]': record,
      for (var i = 0; i < list.length; i++) 'fields[$i]': list[i],
      if (event.isNotEmpty) 'events[0]': event,
      'returnFormat': 'json',
    });
    return [for (final row in rows is List ? rows : const []) if (row is Map) Map<String, dynamic>.from(row)];
  }

  /// Null when REDCap took [records], or what it said.
  Future<String?> _import(http.Client client, List<Map<String, dynamic>> records) async {
    try {
      await _post(client, {
        'content': 'record',
        'format': 'json',
        'type': 'flat',
        'overwriteBehavior': 'normal',
        'data': jsonEncode(LabRedCapService.forProject(records, withoutEvents: withoutEvents)),
        'returnContent': 'count',
        'returnFormat': 'json',
      });
      return null;
    } on _RedcapError catch (e) {
      return e.message;
    }
  }

  Future<String?> _upload(
    http.Client client, {
    required String record,
    required String event,
    required String field,
    required int instance,
    required String name,
    required List<int> bytes,
  }) async {
    final request = http.MultipartRequest('POST', Uri.parse(url))
      ..fields.addAll({
        'token': token,
        'content': 'file',
        'action': 'import',
        'record': record,
        'field': field,
        if (event.isNotEmpty) 'event': event,
        'repeat_instance': '$instance',
        'returnFormat': 'json',
      })
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: name));
    try {
      final response = await http.Response.fromStream(await client.send(request).timeout(const Duration(minutes: 5)));
      if (response.statusCode == 200) return null;
      return 'REDCap respondió ${response.statusCode}: ${response.body}';
    } on TimeoutException {
      return 'REDCap no contesta en $url.';
    } catch (e) {
      return 'No se pudo conectar con $url: $e';
    }
  }

  Future<Object?> _post(http.Client client, Map<String, String> body) async {
    final http.Response response;
    try {
      response = await client
          .post(Uri.parse(url), headers: {'Content-Type': 'application/x-www-form-urlencoded'}, body: {'token': token, ...body})
          .timeout(const Duration(seconds: 60));
    } on TimeoutException {
      throw _RedcapError('REDCap no contesta en $url (¿hay conexión con la red de la UGR o la VPN?).');
    } catch (e) {
      throw _RedcapError('No se pudo conectar con $url (¿hay conexión con la red de la UGR o la VPN?): $e');
    }
    Object? data;
    try {
      data = jsonDecode(response.body);
    } catch (_) {
      data = null;
    }
    final error = data is Map ? data['error']?.toString() : null;
    if (response.statusCode != 200 || error != null) {
      throw _RedcapError('REDCap respondió ${response.statusCode}: ${error ?? response.body}');
    }
    return data;
  }
}

class _RedcapError implements Exception {
  final String message;
  const _RedcapError(this.message);
}
