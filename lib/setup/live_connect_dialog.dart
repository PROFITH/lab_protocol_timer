import 'dart:async';

import 'package:flutter/material.dart';

import '../session/session_controller.dart';
import '../ui/app_theme.dart';
import '../windows/window_messages.dart';

/// How a live device (Polar) of the session is linked, as the Research
/// Monitor tells the waiting room.
class LiveDeviceState {
  const LiveDeviceState({
    required this.deviceId,
    required this.sensorId,
    this.participantId,
    required this.state,
    this.message = '',
    this.name,
    this.hr = 0,
  });

  final String deviceId;
  final String sensorId;
  final String? participantId;

  /// `disconnected`, `connecting`, `pairing`, `configuring`, `connected`,
  /// `reconnecting` or `error`.
  final String state;
  final String message;
  final String? name;
  final int hr;

  bool get connected => state == 'connected';
  bool get busy => const {'connecting', 'pairing', 'configuring', 'reconnecting'}.contains(state);

  static LiveDeviceState? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['device_id']?.toString();
    final sensor = json['sensor_id']?.toString();
    if (id == null || sensor == null) return null;
    return LiveDeviceState(
      deviceId: id,
      sensorId: sensor,
      participantId: json['participant_id']?.toString(),
      state: json['state']?.toString() ?? 'disconnected',
      message: json['message']?.toString() ?? '',
      name: json['name']?.toString(),
      hr: (json['hr'] as num?)?.toInt() ?? 0,
    );
  }

  /// The devices the monitor has; null when it does not answer.
  static Future<List<LiveDeviceState>?> query(MonitorLink monitor) async {
    final answer = await monitor.send(WindowMessages.liveDevices);
    if (answer is! List) return null;
    return [
      for (final d in answer)
        if (fromJson(d) case final state?) state,
    ];
  }
}

/// Searches the Bluetooth for [device] through the monitor and links the
/// unit chosen. Returns the monitor's message, or null when closed.
Future<String?> showLiveConnectDialog(
  BuildContext context, {
  required MonitorLink monitor,
  required String deviceId,
  required String title,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _LiveConnectDialog(monitor: monitor, deviceId: deviceId, title: title),
  );
}

class _LiveConnectDialog extends StatefulWidget {
  const _LiveConnectDialog({required this.monitor, required this.deviceId, required this.title});

  final MonitorLink monitor;
  final String deviceId;
  final String title;

  @override
  State<_LiveConnectDialog> createState() => _LiveConnectDialogState();
}

class _LiveConnectDialogState extends State<_LiveConnectDialog> {
  List<Map<String, dynamic>> _found = const [];
  Timer? _poll;
  String? _connecting;

  @override
  void initState() {
    super.initState();
    unawaited(_scan('start'));
    _poll = Timer.periodic(const Duration(milliseconds: 700), (_) => unawaited(_scan('results')));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _scan(String action) async {
    final answer = await widget.monitor.send(WindowMessages.liveScan, {
      'device_id': widget.deviceId,
      'action': action,
    });
    if (!mounted || _connecting != null || answer is! List) return;
    setState(() => _found = [
          for (final d in answer)
            if (d is Map) Map<String, dynamic>.from(d),
        ]);
  }

  Future<void> _close() async {
    _poll?.cancel();
    await widget.monitor.send(WindowMessages.liveScan, {'device_id': widget.deviceId, 'action': 'stop'});
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _link(Map<String, dynamic> unit) async {
    _poll?.cancel();
    setState(() => _connecting = unit['name']?.toString() ?? '');
    final answer = await widget.monitor.send(WindowMessages.liveConnect, {
      'device_id': widget.deviceId,
      'ble_id': unit['id'],
    });
    if (!mounted) return;
    final message = answer is Map ? answer['message']?.toString() : null;
    Navigator.of(context).pop(message ?? 'El monitor no respondió');
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    Widget body;
    if (_connecting != null) {
      body = Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircularProgressIndicator(color: pal.accent),
          const SizedBox(height: 16),
          Text('Conectando con $_connecting…', style: TextStyle(color: pal.on70)),
          const SizedBox(height: 6),
          Text('Puede tardar hasta un minuto.', style: TextStyle(color: pal.on38, fontSize: 12)),
        ]),
      );
    } else if (_found.isEmpty) {
      body = Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircularProgressIndicator(color: pal.accent),
          const SizedBox(height: 16),
          Text('Buscando dispositivos Bluetooth…', style: TextStyle(color: pal.on54)),
        ]),
      );
    } else {
      body = ListView(
        children: [
          for (final unit in _found)
            ListTile(
              key: ValueKey('ble-${unit['id']}'),
              leading: Icon(
                unit['match'] == 0 ? Icons.verified_rounded : Icons.favorite,
                color: (unit['match'] as num? ?? 3) <= 1 ? pal.bad : pal.on24,
              ),
              title: Text(
                unit['name']?.toString() ?? '',
                style: TextStyle(
                  color: (unit['match'] as num? ?? 3) <= 1 ? pal.on : pal.on54,
                  fontWeight: FontWeight.bold,
                ),
              ),
              subtitle: Text(
                unit['match'] == 0 ? 'Coincide el número de serie' : unit['id']?.toString() ?? '',
                style: TextStyle(color: pal.on38, fontSize: 11),
              ),
              trailing: FilledButton(onPressed: () => _link(unit), child: const Text('Vincular')),
            ),
        ],
      );
    }
    return AlertDialog(
      backgroundColor: pal.surface,
      title: Row(children: [
        Icon(Icons.bluetooth_searching_rounded, color: pal.accent),
        const SizedBox(width: 10),
        Expanded(child: Text('Conectar ${widget.title}')),
      ]),
      content: SizedBox(width: 440, height: 320, child: body),
      actions: [
        if (_connecting == null) TextButton(onPressed: _close, child: const Text('Cerrar')),
      ],
    );
  }
}
