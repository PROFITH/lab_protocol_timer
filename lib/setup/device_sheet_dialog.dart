import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/session_sensor.dart';
import '../services/device_inventory.dart';
import '../services/lab_redcap_service.dart';
import '../ui/app_theme.dart';

/// The devices of each participant (laboratory and free-living) with their
/// place, code and serial, for the evaluator placing them. The same list
/// goes to `dispositivos.csv` in the participant's folder and to REDCap.
Future<void> showDeviceSheetDialog(
  BuildContext context, {
  required List<ParticipantEntry> participants,
  required List<SessionSensor> layout,
}) {
  final sheets = [
    for (final p in participants) (id: p.participantId, devices: deviceEntriesOf(p.sensorsOr(layout))),
  ];
  String tsv() => [
        DeviceSheet.header.join('\t'),
        for (final sheet in sheets)
          for (final d in sheet.devices)
            [
              sheet.id,
              d.periodLabel,
              d.sensor.deviceName,
              d.place,
              d.sensor.sensorId,
              d.serial ?? '',
              d.settings,
              d.sensor.connection == 'live' ? 'en directo' : (d.initialized ? 'sí' : 'no'),
            ].join('\t'),
      ].join('\n');

  return showDialog<void>(
    context: context,
    builder: (context) {
      final pal = context.pal;
      Widget cell(String text, {bool bold = false, Color? color}) => Text(
            text,
            style: TextStyle(fontSize: 13, fontWeight: bold ? FontWeight.w700 : FontWeight.normal, color: color ?? pal.on),
          );
      return AlertDialog(
        key: const Key('device_sheet_dialog'),
        backgroundColor: pal.surface,
        title: const Text('Ficha de dispositivos'),
        content: SizedBox(
          width: 900,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final sheet in sheets) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 4),
                    child: Text(sheet.id, style: TextStyle(fontWeight: FontWeight.w900, color: pal.accent)),
                  ),
                  if (sheet.devices.isEmpty)
                    cell('Sin dispositivos en el protocolo.', color: pal.on54)
                  else
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        headingRowHeight: 32,
                        dataRowMinHeight: 30,
                        dataRowMaxHeight: 40,
                        columnSpacing: 18,
                        columns: const [
                          DataColumn(label: Text('Periodo')),
                          DataColumn(label: Text('Dispositivo')),
                          DataColumn(label: Text('Lugar')),
                          DataColumn(label: Text('Código')),
                          DataColumn(label: Text('Nº de serie')),
                          DataColumn(label: Text('Ajustes')),
                          DataColumn(label: Text('Inicializado')),
                        ],
                        rows: [
                          for (final d in sheet.devices)
                            DataRow(cells: [
                              DataCell(cell(d.periodLabel, color: d.isFreeLiving ? pal.accent : null)),
                              DataCell(cell(d.sensor.deviceName)),
                              DataCell(cell(d.place, bold: true)),
                              DataCell(cell(d.sensor.sensorId)),
                              DataCell(cell(d.serial ?? 'falta', bold: d.serial != null, color: d.serial == null ? pal.warn : null)),
                              DataCell(cell(d.settings)),
                              DataCell(cell(
                                d.sensor.connection == 'live' ? 'en directo' : (d.initialized ? 'sí' : 'no'),
                                color: d.sensor.connection != 'live' && !d.initialized ? pal.warn : null,
                              )),
                            ]),
                        ],
                      ),
                    ),
                ],
                const SizedBox(height: 10),
                Text(
                  'Al pasar a la sesión se guarda en ${DeviceSheet.fileName} en la carpeta de cada participante y, '
                  'con REDCap conectado, los de vida libre van a onboarding_config (healthy_tracker los descarga).',
                  style: TextStyle(fontSize: 11, color: pal.on54),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            key: const Key('device_sheet_copy'),
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: const Text('Copiar (para Excel)'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: tsv()));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ficha copiada')));
            },
          ),
          FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cerrar')),
        ],
      );
    },
  );
}
