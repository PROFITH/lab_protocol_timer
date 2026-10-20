import 'package:flutter/material.dart';

import '../models/activity_battery.dart';
import 'setup_format.dart';

const _accent = Color(0xFF38BDF8);

/// "Configuración de la sesión" block of the participant screen: protocol
/// list, what the chosen protocol contains and the buttons to edit it.
class SessionSetupCard extends StatelessWidget {
  /// Base protocols and protocols saved on this computer.
  final List<ActivityBattery> protocols;

  /// Protocol of this session, possibly edited; null for numbered
  /// activities without a protocol.
  final ActivityBattery? battery;

  /// The chosen protocol differs from the saved one with the same ID.
  final bool modified;

  /// Line about what was loaded automatically (remembered sensors...).
  final String? note;

  final bool loading;
  final ValueChanged<String?> onSelect;
  final VoidCallback onEdit;
  final VoidCallback onImport;
  final VoidCallback? onReset;
  final VoidCallback? onDeleteCustom;

  const SessionSetupCard({
    super.key,
    required this.protocols,
    required this.battery,
    required this.modified,
    required this.note,
    required this.loading,
    required this.onSelect,
    required this.onEdit,
    required this.onImport,
    this.onReset,
    this.onDeleteCustom,
  });

  @override
  Widget build(BuildContext context) {
    final current = battery;
    final ids = protocols.map((p) => p.protocolId).toSet();
    final items = <DropdownMenuItem<String?>>[
      for (final p in protocols)
        DropdownMenuItem(
          value: p.protocolId,
          child: Text(
            p.protocolId == current?.protocolId && modified
                ? '${p.displayName} (modificado)'
                : p.displayName,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      if (current != null && !ids.contains(current.protocolId))
        DropdownMenuItem(
          value: current.protocolId,
          child: Text(
            '${current.displayName} (importado)',
            overflow: TextOverflow.ellipsis,
          ),
        ),
      const DropdownMenuItem(
        value: null,
        child: Text('Sin protocolo (actividades numeradas)'),
      ),
    ];

    final missingSerials = current?.sensors
            .where((s) => s.connection != 'video' && !s.hasSerial)
            .length ??
        0;
    final calibrations =
        current?.activities.where((a) => a.isCalibration).length ?? 0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'CONFIGURACIÓN DE LA SESIÓN',
            style: TextStyle(
              color: _accent,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 10),
          if (loading)
            const LinearProgressIndicator()
          else
            DropdownButtonFormField<String?>(
              initialValue: current?.protocolId,
              key: ValueKey('${current?.protocolId}|$modified|${protocols.length}'),
              isExpanded: true,
              dropdownColor: const Color(0xFF1E293B),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
              decoration: InputDecoration(
                labelText: 'PROTOCOLO DE ACTIVIDADES',
                labelStyle: const TextStyle(color: Colors.white60, fontSize: 12),
                prefixIcon: const Icon(
                  Icons.playlist_add_check_rounded,
                  color: _accent,
                  size: 20,
                ),
                filled: true,
                fillColor: const Color(0xFF0F172A),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              items: items,
              onChanged: onSelect,
            ),
          const SizedBox(height: 10),
          if (current != null) ...[
            Text(
              '${current.activities.length - calibrations} actividades'
              '${calibrations > 0 ? ' y $calibrations cajas de calibración' : ''}'
              ' · ${formatSeconds(current.plannedSeconds())} previstos sin esperas',
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 4),
            Text(
              current.sensors.isEmpty
                  ? 'Sin sensores configurados'
                  : '${current.sensors.length} sensores: '
                      '${current.sensors.map((s) => '${s.deviceName} (${s.placementLabel ?? '?'})').join(', ')}',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            if (missingSerials > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '$missingSerials sensor${missingSerials > 1 ? 'es' : ''} sin número de serie',
                  style: const TextStyle(color: Color(0xFFFBBF24), fontSize: 12),
                ),
              ),
          ] else
            const Text(
              'Todas las actividades duran lo que diga el Research Monitor y no '
              'se escriben sensores en el manifiesto.',
              style: TextStyle(color: Colors.white54),
            ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  const Icon(Icons.history_rounded, size: 16, color: _accent),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      note!,
                      style: const TextStyle(color: _accent, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (current != null)
                FilledButton.tonalIcon(
                  onPressed: onEdit,
                  icon: const Icon(Icons.tune_rounded),
                  label: const Text('Editar actividades y sensores'),
                ),
              OutlinedButton.icon(
                onPressed: onImport,
                icon: const Icon(Icons.file_open_outlined),
                label: const Text('Importar JSON'),
              ),
              if (onReset != null)
                TextButton(
                  onPressed: onReset,
                  child: const Text('Deshacer cambios'),
                ),
              if (onDeleteCustom != null)
                TextButton(
                  onPressed: onDeleteCustom,
                  style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
                  child: const Text('Borrar protocolo guardado'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
