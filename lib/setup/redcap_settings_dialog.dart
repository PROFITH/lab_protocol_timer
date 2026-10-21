import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/redcap_connection.dart';

/// Opens «Conexión con REDCap». Returns true when the connection changed.
Future<bool> showRedcapSettingsDialog(BuildContext context, {http.Client? client}) async {
  final changed = await showDialog<bool>(
    context: context,
    builder: (_) => RedcapSettingsDialog(client: client),
  );
  return changed == true;
}

/// The REDCap project of the sessions: the API address and the token, kept
/// on this computer. REDCap is optional: without a token every session is
/// saved only in its folder.
class RedcapSettingsDialog extends StatefulWidget {
  const RedcapSettingsDialog({super.key, this.client});

  /// REDCap's client (tests).
  final http.Client? client;

  @override
  State<RedcapSettingsDialog> createState() => _RedcapSettingsDialogState();
}

class _RedcapSettingsDialogState extends State<RedcapSettingsDialog> {
  static const _green = Color(0xFF22C55E);
  static const _red = Color(0xFFF87171);

  final _formKey = GlobalKey<FormState>();
  late final _url = TextEditingController(text: RedcapConnection.url);
  final _token = TextEditingController();
  bool _showToken = false;
  bool _checking = false;

  /// What REDCap said of [_checked] (address and token), or why it failed.
  RedcapProject? _project;
  String? _checkError;
  String? _checked;

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  /// The token the fields stand for: the one typed, or the one in use.
  String get _tokenToUse => _token.text.trim().isEmpty ? RedcapConnection.token : _token.text.trim();

  String _key(String url, String token) => '$url|$token';

  Future<void> _check() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final url = RedcapConnection.normalizeUrl(_url.text)!;
    final token = _tokenToUse;
    if (token.isEmpty) {
      setState(() {
        _project = null;
        _checked = null;
        _checkError = 'Escribe el token del proyecto para probar la conexión.';
      });
      return;
    }
    setState(() {
      _checking = true;
      _checkError = null;
    });
    try {
      final project = await RedcapConnection.check(url: url, token: token, client: widget.client);
      if (!mounted) return;
      setState(() {
        _project = project;
        _checked = _key(url, token);
      });
    } on RedcapCheckError catch (e) {
      if (!mounted) return;
      setState(() {
        _project = null;
        _checked = null;
        _checkError = e.message;
      });
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final url = RedcapConnection.normalizeUrl(_url.text)!;
    final token = _token.text.trim();
    final tested = _checked == _key(url, _tokenToUse) ? _project : null;
    await RedcapConnection.save(url: url, token: token, project: tested);
    // Not tried here: REDCap is asked in the background, and the visits of
    // the project show up when it answers.
    if (tested == null) unawaited(RedcapConnection.refreshProject(client: widget.client));
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _forget() async {
    await RedcapConnection.forgetToken();
    if (mounted) Navigator.of(context).pop(true);
  }

  String get _current {
    final token = RedcapConnection.token;
    if (RedcapConnection.tokenFromApp) {
      final title = RedcapConnection.project?.title ?? '';
      return 'Token guardado en este ordenador: ${RedcapConnection.masked(token)}'
          '${title.isEmpty ? '' : ' (proyecto «$title»)'}.';
    }
    if (RedcapConnection.tokenBuiltIn) {
      return 'Esta versión de la app trae un token (${RedcapConnection.masked(token)}). '
          'Uno escrito aquí lo sustituye en este ordenador.';
    }
    return 'Ahora no hay token: las sesiones se guardan solo en su carpeta.';
  }

  String _describe(RedcapProject project) {
    final title = project.title.isEmpty ? 'el proyecto' : '«${project.title}»';
    if (!project.longitudinal) {
      return 'Conectado con $title. Es un proyecto sin eventos: la visita solo da nombre a la carpeta.';
    }
    final events = project.events.values.toList();
    return 'Conectado con $title. Visitas (eventos): '
        '${events.isEmpty ? 'ninguna' : events.join(', ')}.';
  }

  InputDecoration _decoration(String label, {String? hint, String? helper, Widget? suffix}) => InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        helperMaxLines: 3,
        labelStyle: const TextStyle(color: Colors.white60, fontSize: 12),
        hintStyle: const TextStyle(color: Colors.white24),
        helperStyle: const TextStyle(color: Colors.white38, fontSize: 11),
        filled: true,
        fillColor: const Color(0xFF0F172A),
        suffixIcon: suffix,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      );

  @override
  Widget build(BuildContext context) {
    final hasToken = RedcapConnection.isConfigured;
    return AlertDialog(
      backgroundColor: const Color(0xFF1E293B),
      title: const Text('Conexión con REDCap'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Opcional. Con el token de un proyecto, cada sesión se envía a ese proyecto al terminar. '
                  'Sin token, todo se guarda en la carpeta de la sesión y se puede enviar después con '
                  '«Enviar a REDCap una sesión guardada…».',
                  style: TextStyle(color: Colors.white70, height: 1.4),
                ),
                const SizedBox(height: 10),
                Text(_current, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 16),
                TextFormField(
                  key: const ValueKey('redcap_url'),
                  controller: _url,
                  style: const TextStyle(color: Colors.white),
                  decoration: _decoration(
                    'DIRECCIÓN DE LA API',
                    hint: RedcapConnection.defaultUrl,
                    helper: 'La de REDCap de la UGR es ${RedcapConnection.defaultUrl}',
                  ),
                  validator: (value) => RedcapConnection.normalizeUrl(value ?? '') == null
                      ? 'Tiene que ser una dirección web (https://…/api/)'
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const ValueKey('redcap_token'),
                  controller: _token,
                  obscureText: !_showToken,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: const TextStyle(color: Colors.white, fontFamily: 'monospace'),
                  decoration: _decoration(
                    'TOKEN DE LA API',
                    hint: hasToken ? 'Vacío: se mantiene el actual' : '32 letras y números',
                    helper: 'En REDCap: API → el token de tu usuario en este proyecto (con permiso de '
                        'importar datos). Se guarda solo en este ordenador.',
                    suffix: IconButton(
                      tooltip: _showToken ? 'Ocultar' : 'Mostrar',
                      icon: Icon(_showToken ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                          color: Colors.white54),
                      onPressed: () => setState(() => _showToken = !_showToken),
                    ),
                  ),
                  validator: (value) {
                    final text = value?.trim() ?? '';
                    if (text.isEmpty || RedcapConnection.isValidToken(text)) return null;
                    return 'Un token de REDCap tiene 32 letras (A-F) y números';
                  },
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _checking ? null : _check,
                      icon: _checking
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.wifi_tethering_rounded, size: 18),
                      label: Text(_checking ? 'Probando…' : 'Probar conexión'),
                    ),
                  ],
                ),
                if (_project != null) ...[
                  const SizedBox(height: 10),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.cloud_done_rounded, color: _green, size: 18),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_describe(_project!), style: const TextStyle(height: 1.3))),
                    ],
                  ),
                ],
                if (_checkError != null) ...[
                  const SizedBox(height: 10),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.cloud_off_rounded, color: _red, size: 18),
                      const SizedBox(width: 8),
                      Expanded(child: SelectableText(_checkError!, style: const TextStyle(height: 1.3))),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        if (RedcapConnection.tokenFromApp)
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            onPressed: _forget,
            child: const Text('Quitar token'),
          ),
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancelar')),
        FilledButton(onPressed: _checking ? null : _save, child: const Text('Guardar')),
      ],
    );
  }
}
