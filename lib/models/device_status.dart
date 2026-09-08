import 'package:flutter/material.dart';

/// Estado general de un dispositivo físico.
enum DeviceConnectionStatus {
  disconnected,
  connecting,
  connected,
  error,
}

/// Estado de una capacidad/sensor proporcionado por un dispositivo.
enum SensorAcquisitionStatus {
  unavailable,
  stopped,
  ready,
  acquiring,
  error,
}

/// Representa un sensor o capacidad disponible dentro de un dispositivo.
///
/// Ejemplos:
/// - Polar H10 → HR
/// - Polar H10 → ACC
/// - Polar H10 → ECG
/// - Verity Sense → HR
/// - Verity Sense → ACC
/// - Cámara → Video
class SensorStatus {
  final String id;
  final String name;
  final IconData icon;
  final SensorAcquisitionStatus status;

  /// Información adicional, por ejemplo "200 Hz", "130 Hz", "30 FPS".
  final String? detail;

  const SensorStatus({
    required this.id,
    required this.name,
    required this.icon,
    required this.status,
    this.detail,
  });
}

/// Representa un dispositivo físico.
///
/// Un dispositivo puede proporcionar uno o varios sensores/capacidades.
class DeviceStatus {
  final String id;
  final String name;
  final IconData icon;
  final DeviceConnectionStatus connectionStatus;

  final List<SensorStatus> sensors;

  const DeviceStatus({
    required this.id,
    required this.name,
    required this.icon,
    required this.connectionStatus,
    this.sensors = const [],
  });
}