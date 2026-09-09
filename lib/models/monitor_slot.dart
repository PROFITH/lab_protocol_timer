import 'monitor_visualization.dart';

class MonitorSlot {
  /// Identificador de la ventana de monitorización.
  final int slotId;

  /// Visualización de la ventana de monitorización.
  final MonitorVisualization visualization;

  /// Dispositivo cuya señal se está mostrando.
  final String? deviceId;

  /// Sensor/capacidad cuya señal se está mostrando.
  final String? sensorId;

  const MonitorSlot({
    required this.slotId,
    this.deviceId,
    this.sensorId,
    this.visualization = MonitorVisualization.unknown,
  });

  /// Indica si esta ventana tiene una fuente asignada.
  bool get isAssigned {
    return deviceId != null && sensorId != null;
  }

  /// Identificador único de la fuente mostrada.
  ///
  /// Ejemplo:
  ///   polar_h10:heart_rate
  ///   polar_verity:heart_rate
  String? get sourceId {
    if (!isAssigned) {
      return null;
    }

    return '$deviceId:$sensorId';
  }

  MonitorSlot copyWith({
    String? deviceId,
    String? sensorId,
    MonitorVisualization? visualization,
    bool clearSource = false,
  }) {
    if (clearSource) {
      return MonitorSlot(
        slotId: slotId,
      );
    }

    return MonitorSlot(
      slotId: slotId,
      deviceId: deviceId ?? this.deviceId,
      sensorId: sensorId ?? this.sensorId,
      visualization: visualization ?? this.visualization,
    );
  }
}