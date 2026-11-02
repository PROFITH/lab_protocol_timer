import 'package:flutter/services.dart';

/// One activity of the 2024 Adult Compendium of Physical Activities.
class CompendiumEntry {
  final String code;
  final String heading;
  final String description;
  final double met;
  final String _searchText;

  CompendiumEntry({
    required this.code,
    required this.heading,
    required this.description,
    required this.met,
    required String searchText,
  }) : _searchText = searchText;
}

/// The Compendium bundled as `assets/compendium/compendium_2024.csv`
/// (columns `code,major_heading,major_heading_es,met,description_en,
/// description_es`), loaded once and searched in memory.
class Compendium {
  static const assetPath = 'assets/compendium/compendium_2024.csv';

  final List<CompendiumEntry> entries;
  final Map<String, CompendiumEntry> _byCode;

  Compendium(this.entries) : _byCode = {for (final e in entries) e.code: e};

  static Future<Compendium>? _loading;

  static Future<Compendium> load([AssetBundle? bundle]) {
    return _loading ??= (bundle ?? rootBundle)
        .loadString(assetPath)
        .then(Compendium.fromCsv)
        .catchError((Object e) {
      _loading = null;
      throw e;
    });
  }

  factory Compendium.fromCsv(String csv) {
    final rows = parseCsv(csv);
    if (rows.isEmpty) return Compendium(const []);
    final header = rows.first;
    int col(String name) => header.indexOf(name);
    final iCode = col('code'), iHeading = col('major_heading_es');
    final iMet = col('met'), iEs = col('description_es');
    final iEn = col('description_en');

    return Compendium([
      for (final r in rows.skip(1))
        if (r.length == header.length && double.tryParse(r[iMet]) != null)
          CompendiumEntry(
            code: r[iCode].trim(),
            heading: r[iHeading].trim(),
            description: (r[iEs].trim().isNotEmpty ? r[iEs] : r[iEn]).trim(),
            met: double.parse(r[iMet]),
            searchText:
                normalize('${r[iCode]} ${r[iHeading]} ${r[iEs]} ${r[iEn]}'),
          ),
    ]);
  }

  CompendiumEntry? byCode(String? code) =>
      code == null ? null : _byCode[code.trim()];

  /// Entries containing every word of [query], in any order, ignoring
  /// accents and case, in Spanish or English.
  List<CompendiumEntry> search(String query, {int limit = 80}) {
    final words =
        normalize(query).split(' ').where((w) => w.isNotEmpty).toList();
    return entries
        .where((e) => words.every(e._searchText.contains))
        .take(limit)
        .toList();
  }

  static String normalize(String text) {
    const from = 'áàäâéèëêíìïîóòöôúùüûñç';
    const to = 'aaaaeeeeiiiioooouuuunc';
    final buffer = StringBuffer();
    for (final char in text.toLowerCase().split('')) {
      final i = from.indexOf(char);
      buffer.write(
        i >= 0 ? to[i] : (RegExp(r'[a-z0-9.]').hasMatch(char) ? char : ' '),
      );
    }
    return buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// CSV reader with quoted fields (RFC 4180).
  static List<List<String>> parseCsv(String text) {
    final rows = <List<String>>[];
    var row = <String>[];
    final field = StringBuffer();
    var quoted = false;
    for (var i = 0; i < text.length; i++) {
      final c = text[i];
      if (quoted) {
        if (c == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            quoted = false;
          }
        } else {
          field.write(c);
        }
      } else if (c == '"') {
        quoted = true;
      } else if (c == ',') {
        row.add(field.toString());
        field.clear();
      } else if (c == '\n' || c == '\r') {
        if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
        row.add(field.toString());
        field.clear();
        if (row.length > 1 || row.first.isNotEmpty) rows.add(row);
        row = <String>[];
      } else {
        field.write(c);
      }
    }
    if (field.isNotEmpty || row.isNotEmpty) {
      row.add(field.toString());
      rows.add(row);
    }
    if (rows.isNotEmpty && rows.first.isNotEmpty) {
      rows.first[0] = rows.first[0].replaceFirst('﻿', '');
    }
    return rows;
  }
}
