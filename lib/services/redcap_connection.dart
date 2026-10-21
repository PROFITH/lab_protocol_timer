import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// What REDCap says about the project of a token.
class RedcapProject {
  final String title;
  final bool longitudinal;

  /// Unique event name → label, in the project's order (empty in a project
  /// without events).
  final Map<String, String> events;

  const RedcapProject({required this.title, required this.longitudinal, this.events = const {}});

  bool sameAs(RedcapProject other) =>
      title == other.title && longitudinal == other.longitudinal && mapEquals(events, other.events);

  Map<String, dynamic> toJson() => {
        'project_title': title,
        'is_longitudinal': longitudinal,
        'events': [
          for (final e in events.entries) {'unique_event_name': e.key, 'event_name': e.value},
        ],
      };

  factory RedcapProject.fromJson(Map<String, dynamic> json) => RedcapProject(
        title: json['project_title']?.toString() ?? '',
        longitudinal: json['is_longitudinal'] == true,
        events: {
          for (final e in json['events'] as List? ?? const [])
            (e as Map)['unique_event_name'].toString(): e['event_name'].toString(),
        },
      );
}

/// Why REDCap could not be reached with an address and a token, in words
/// for the evaluator.
class RedcapCheckError implements Exception {
  final String message;
  const RedcapCheckError(this.message);

  @override
  String toString() => message;
}

/// The REDCap project the sessions go to: the API address and the token.
///
/// Both are set in the app («Conexión con REDCap» on the start screen) and
/// kept on this computer, so the same build works with any REDCap project.
/// A token passed when building (`--dart-define=REDCAP_TOKEN=...`) is used
/// while none is set in the app. REDCap is optional: without a token nothing
/// is sent, and every session stays in its folder, ready to be sent later
/// with «Enviar a REDCap una sesión guardada…».
class RedcapConnection {
  /// The UGR's public REDCap. redcap.ugr.es only exists inside the UGR
  /// network (or with its VPN).
  static const defaultUrl = 'https://minerva.ugr.es/api/';
  static const builtInUrl = String.fromEnvironment('REDCAP_URL', defaultValue: defaultUrl);
  static const builtInToken = String.fromEnvironment('REDCAP_TOKEN', defaultValue: '');

  static const urlKey = 'lpt_redcap_url';
  static const tokenKey = 'lpt_redcap_token';
  static const projectKey = 'lpt_redcap_project';

  static String _url = builtInUrl;
  static String _token = builtInToken;
  static bool _tokenFromApp = false;
  static RedcapProject? _project;

  static String get url => _url;
  static String get token => _token;
  static bool get isConfigured => _token.isNotEmpty;

  /// The token was set in the app (and can be removed there).
  static bool get tokenFromApp => _tokenFromApp;

  /// The token came with the build.
  static bool get tokenBuiltIn => !_tokenFromApp && _token.isNotEmpty;

  /// The project of the token as REDCap described it the last time it
  /// answered; null when it is not known yet.
  static RedcapProject? get project => _project;

  /// Events of the project (unique name → label); empty when they are not
  /// known or the project has none.
  static Map<String, String> get events => _project?.events ?? const {};

  /// The project is known to have no events (a classic project), so the
  /// records go without `redcap_event_name`.
  static bool get withoutEvents => _project != null && !_project!.longitudinal;

  /// Changes whenever the connection or its events change.
  static final ValueNotifier<int> changes = ValueNotifier(0);

  static void _changed() => changes.value++;

  /// Reads the connection saved on this computer.
  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final url = prefs.getString(urlKey);
      final token = prefs.getString(tokenKey);
      _url = (url == null || url.isEmpty) ? builtInUrl : url;
      _tokenFromApp = token != null && token.isNotEmpty;
      _token = _tokenFromApp ? token! : builtInToken;
      _project = _decodeProject(prefs.getString(projectKey));
    } catch (e) {
      debugPrint('[REDCAP] No se pudo leer la conexión guardada: $e');
    }
    _changed();
  }

  /// Saves [url] and [token] on this computer. An empty [token] keeps the
  /// one already in use. [project] is what REDCap said of them, if it was
  /// asked.
  static Future<void> save({required String url, String token = '', RedcapProject? project}) async {
    final newToken = token.trim();
    final sameProject = url == _url && (newToken.isEmpty || newToken == _token);
    _url = url;
    if (newToken.isNotEmpty) {
      _token = newToken;
      _tokenFromApp = true;
    }
    _project = project ?? (sameProject ? _project : null);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(urlKey, url);
      if (newToken.isNotEmpty) await prefs.setString(tokenKey, newToken);
      await _saveProject(prefs);
    } catch (e) {
      debugPrint('[REDCAP] No se pudo guardar la conexión: $e');
    }
    _changed();
  }

  /// Removes the token set in the app (the one of the build, if any, is used
  /// again; without one, nothing goes to REDCap).
  static Future<void> forgetToken() async {
    _tokenFromApp = false;
    _token = builtInToken;
    _project = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(tokenKey);
      await prefs.remove(projectKey);
    } catch (e) {
      debugPrint('[REDCAP] No se pudo borrar el token: $e');
    }
    _changed();
  }

  /// Asks REDCap again for the project and its events (kept as they were
  /// if REDCap does not answer, for example without network).
  static Future<void> refreshProject({http.Client? client}) async {
    if (!isConfigured) return;
    final url = _url;
    final token = _token;
    try {
      final project = await check(url: url, token: token, client: client);
      // The connection changed while REDCap answered.
      if (url != _url || token != _token) return;
      if (_project != null && project.sameAs(_project!)) return;
      _project = project;
      final prefs = await SharedPreferences.getInstance();
      await _saveProject(prefs);
      _changed();
    } catch (e) {
      debugPrint('[REDCAP] No se pudo leer el proyecto: $e');
    }
  }

  /// Uses [url], [token] and [project] without saving them (tests).
  @visibleForTesting
  static void use({String url = defaultUrl, String token = '', RedcapProject? project}) {
    _url = url;
    _token = token;
    _tokenFromApp = token.isNotEmpty;
    _project = project;
    _changed();
  }

  static Future<void> _saveProject(SharedPreferences prefs) async {
    final project = _project;
    if (project == null) {
      await prefs.remove(projectKey);
    } else {
      await prefs.setString(projectKey, jsonEncode(project.toJson()));
    }
  }

  static RedcapProject? _decodeProject(String? json) {
    if (json == null || json.isEmpty) return null;
    try {
      return RedcapProject.fromJson(jsonDecode(json) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// A REDCap API token: 32 letters (A-F) and digits.
  static bool isValidToken(String token) => RegExp(r'^[0-9A-Fa-f]{32}$').hasMatch(token.trim());

  /// The token with only its last four characters.
  static String masked(String token) =>
      token.length <= 4 ? '••••' : '••••••••${token.substring(token.length - 4)}';

  /// The API address as typed, ending in `/` (REDCap redirects `…/api` to
  /// `…/api/`, and a redirected POST loses its data); null if it is not a
  /// web address. Empty means the default one.
  static String? normalizeUrl(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return defaultUrl;
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !(uri.isScheme('https') || uri.isScheme('http')) || uri.host.isEmpty) return null;
    return trimmed.endsWith('/') ? trimmed : '$trimmed/';
  }

  /// Asks REDCap for the project of [token] at [url]: its title and, in a
  /// longitudinal project, its events. Throws [RedcapCheckError].
  static Future<RedcapProject> check({required String url, required String token, http.Client? client}) async {
    final c = client ?? http.Client();
    try {
      final info = await _post(c, url, {'token': token, 'content': 'project', 'format': 'json', 'returnFormat': 'json'});
      if (info is! Map) throw const RedcapCheckError('REDCap no devolvió los datos del proyecto.');
      final longitudinal = '${info['is_longitudinal']}' == '1';
      final events = <String, String>{};
      if (longitudinal) {
        final list = await _post(c, url, {'token': token, 'content': 'event', 'format': 'json', 'returnFormat': 'json'});
        final rows = [for (final e in list is List ? list : const []) if (e is Map) e];
        final arms = {for (final e in rows) '${e['arm_num']}'};
        for (final e in rows) {
          final unique = e['unique_event_name']?.toString() ?? '';
          if (unique.isEmpty) continue;
          final label = e['event_name']?.toString() ?? unique;
          events[unique] = arms.length > 1 ? '$label (brazo ${e['arm_num']})' : label;
        }
      }
      return RedcapProject(
        title: info['project_title']?.toString() ?? '',
        longitudinal: longitudinal,
        events: events,
      );
    } finally {
      if (client == null) c.close();
    }
  }

  static Future<Object?> _post(http.Client client, String url, Map<String, String> body) async {
    final http.Response response;
    try {
      response = await client
          .post(Uri.parse(url), headers: {'Content-Type': 'application/x-www-form-urlencoded'}, body: body)
          .timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw RedcapCheckError('REDCap no contesta en $url (¿hay conexión a internet?).');
    } catch (e) {
      throw RedcapCheckError('No se pudo conectar con $url: $e');
    }
    final Object? data;
    try {
      data = jsonDecode(response.body);
    } catch (_) {
      throw RedcapCheckError(response.statusCode == 200
          ? 'En $url no responde la API de REDCap (la dirección suele acabar en /api/).'
          : 'REDCap respondió ${response.statusCode}.');
    }
    final error = data is Map ? data['error']?.toString() : null;
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw RedcapCheckError('REDCap no acepta este token (respuesta ${response.statusCode})'
          '${error == null ? '' : ': $error'}. Comprueba que es el de este proyecto y que tiene permiso de API.');
    }
    if (response.statusCode != 200 || error != null) {
      throw RedcapCheckError('REDCap respondió ${response.statusCode}${error == null ? '' : ': $error'}');
    }
    return data;
  }
}
