import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class VideoLogEntry {
  final String filePath;
  final String participantId;
  final int activityIndex;

  /// Host UTC timestamp recorded when the camera recording
  /// command has completed successfully.
  ///
  /// This is a recording-start reference timestamp, not a
  /// guaranteed timestamp for encoded video frame 0.
  final DateTime recordingStartTime;

  /// Host UTC timestamp recorded after stopVideoRecording()
  /// has completed.
  final DateTime? recordingEndTime;

  VideoLogEntry({
    required this.filePath,
    required this.participantId,
    required this.activityIndex,
    required this.recordingStartTime,
    this.recordingEndTime,
  });

  Duration? get duration {
    if (recordingEndTime == null) {
      return null;
    }

    return recordingEndTime!.difference(recordingStartTime);
  }

  Map<String, dynamic> toJson() => {
      'file_path': filePath,
      'participant_id': participantId,
      'activity_index': activityIndex,
      'recording_start_time_utc':
          recordingStartTime.toUtc().toIso8601String(),
      'recording_end_time_utc':
          recordingEndTime?.toUtc().toIso8601String(),
      'duration_seconds': duration == null
          ? null
          : duration!.inMicroseconds / 1000000.0,
    };

  factory VideoLogEntry.fromJson(Map<String, dynamic> json) =>
      VideoLogEntry(
        filePath: json['file_path'] as String,
        participantId: json['participant_id'] as String,
        activityIndex: json['activity_index'] as int,
        recordingStartTime:
            DateTime.parse(
              json['recording_start_time_utc'] ??
                  json['start_time_iso'],
            ).toUtc(),
        recordingEndTime:
            (json['recording_end_time_utc'] ??
                    json['end_time_iso']) ==
                null
            ? null
            : DateTime.parse(
                json['recording_end_time_utc'] ??
                    json['end_time_iso'],
              ).toUtc(),
      );

  static const String csvHeader =
      'file_path,participant_id,activity_index,'
      'recording_start_time_utc,recording_end_time_utc,duration_seconds';

  String toCsvRow() {
    final startIso =
        recordingStartTime.toUtc().toIso8601String();

    final endIso =
        recordingEndTime?.toUtc().toIso8601String() ?? '';

    final durationSec = duration == null
        ? ''
        : (duration!.inMicroseconds / 1000000.0)
            .toStringAsFixed(6);

    return '"$filePath",'
        '"$participantId",'
        '$activityIndex,'
        '$startIso,'
        '$endIso,'
        '$durationSec';
  }
}

class VideoRecordingService {
  CameraController? _controller;
  List<CameraDescription> _camerasList = [];
  CameraDescription? _selectedCamera;

  bool _isInitialized = false;
  bool _isRecording = false;

  DateTime? _currentRecordingStartTime;
  final List<VideoLogEntry> recordedVideoLogs = [];

  CameraController? get controller => _controller;
  bool get isInitialized => _isInitialized;
  bool get isRecording => _isRecording;
  List<CameraDescription> get camerasList => _camerasList;
  CameraDescription? get selectedCamera => _selectedCamera;

  // ===========================================================================
  // DETECCIÓN DE CÁMARAS
  // ===========================================================================

  Future<List<CameraDescription>> discoverCameras() async {
    try {
      debugPrint('[VIDEO] Buscando cámaras...');

      _camerasList = await availableCameras();

      debugPrint(
        '[VIDEO] Cámaras encontradas: ${_camerasList.length}',
      );

      for (final camera in _camerasList) {
        debugPrint(
          '[VIDEO] Camera: '
          'name=${camera.name}, '
          'lensDirection=${camera.lensDirection}, '
          'sensorOrientation=${camera.sensorOrientation}',
        );
      }

      return _camerasList;
    } on CameraException catch (e) {
      debugPrint(
        '[VIDEO] CAMERA EXCEPTION buscando cámaras\n'
        'code: ${e.code}\n'
        'description: ${e.description}',
      );

      _camerasList = [];
      return [];
    } catch (e, stackTrace) {
      debugPrint(
        '[VIDEO] ERROR buscando cámaras: $e\n$stackTrace',
      );

      _camerasList = [];
      return [];
    }
  }

  // ===========================================================================
  // INICIALIZAR CÁMARA SELECCIONADA
  // ===========================================================================

  Future<bool> initializeCamera(CameraDescription camera) async {
    try {
      debugPrint(
        '[VIDEO] Inicializando cámara seleccionada: '
        '${camera.name}',
      );

      // Liberar el controlador anterior, si existe.
      if (_controller != null) {
        debugPrint('[VIDEO] Liberando controlador anterior...');

        try {
          await _controller!.dispose();
        } catch (e) {
          debugPrint('[VIDEO] Error liberando controlador anterior: $e');
        }

        _controller = null;
        _isInitialized = false;
        _selectedCamera = null;

        // Dar tiempo al sistema operativo para liberar el dispositivo.
        await Future.delayed(
          const Duration(milliseconds: 300),
        );
      }

      // Crear controlador para la cámara seleccionada.
      _controller = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio: false,
      );

      debugPrint('[VIDEO] CameraController creado.');

      // Inicializar cámara.
      await _controller!.initialize();

      if (!_controller!.value.isInitialized) {
        debugPrint('[VIDEO] La cámara no quedó inicializada.');

        await _controller!.dispose();
        _controller = null;
        _selectedCamera = null;
        _isInitialized = false;

        return false;
      }

      // Solo guardar la selección después de inicializar correctamente.
      _selectedCamera = camera;
      _isInitialized = true;

      debugPrint(
        '[VIDEO] Cámara inicializada correctamente: '
        '${camera.name}',
      );

      return true;
    } on CameraException catch (e) {
      debugPrint(
        '[VIDEO] CAMERA EXCEPTION inicializando cámara\n'
        'code: ${e.code}\n'
        'description: ${e.description}',
      );

      _isInitialized = false;
      _selectedCamera = null;

      try {
        await _controller?.dispose();
      } catch (_) {}

      _controller = null;

      return false;
    } catch (e, stackTrace) {
      debugPrint(
        '[VIDEO] ERROR inicializando cámara: $e\n'
        '$stackTrace',
      );

      _isInitialized = false;
      _selectedCamera = null;

      try {
        await _controller?.dispose();
      } catch (_) {}

      _controller = null;

      return false;
    }
  }

  // ===========================================================================
  // CONTROL DE GRABACIÓN DE SESIÓN CONTINUA
  // ===========================================================================

  Future<bool> startSessionRecording({
    required String participantSummary,
  }) async {
    if (!_isInitialized || _controller == null || _isRecording) {
      return false;
    }

    try {
      debugPrint('[VIDEO] Iniciando pipeline de grabación...');

      // El await completa una vez que Windows MediaFoundation inicia la captura
      await _controller!.startVideoRecording();

      // Timestamp del host registrado inmediatamente después de iniciar la grabación.
      // No garantiza correspondencia exacta con el primer fotograma del vídeo.
      _currentRecordingStartTime = DateTime.now().toUtc();
      _isRecording = true;

      debugPrint(
        '[VIDEO] Grabación iniciada en: '
        '${_currentRecordingStartTime!.toIso8601String()}',
      );

      return true;
    } on CameraException catch (e) {
      debugPrint('[VIDEO] CameraException: ${e.code} - ${e.description}');
      _isRecording = false;
      return false;
    } catch (e, stackTrace) {
      debugPrint('[VIDEO] Error iniciando grabación: $e\n$stackTrace');
      _isRecording = false;
      return false;
    }
  }

  Future<VideoLogEntry?> stopSessionRecording({
    required String participantSummary,
    required int totalActivities,
  }) async {
    if (!_isInitialized || _controller == null || !_isRecording) {
      return null;
    }

    try {
      final xFile = await _controller!.stopVideoRecording();
      final endTime = DateTime.now().toUtc();
      _isRecording = false;

      final appDir = await getApplicationDocumentsDirectory();
      final videosDir = Directory('${appDir.path}/LabProtocolVideos');
      if (!await videosDir.exists()) {
        await videosDir.create(recursive: true);
      }

      final timeStr = endTime.toIso8601String().replaceAll(':', '-').split('.').first;
      final cleanParticipant = participantSummary.replaceAll(';', '_').replaceAll(' ', '');
      final destinationPath =
          '${videosDir.path}/video_session_${cleanParticipant}_$timeStr.mp4';

      final savedFile = await File(xFile.path).copy(destinationPath);
      await File(xFile.path).delete();

      final logEntry = VideoLogEntry(
        filePath: savedFile.path,
        participantId: participantSummary,
        activityIndex: totalActivities,
        recordingStartTime: _currentRecordingStartTime ?? endTime,
        recordingEndTime: endTime,
      );

      recordedVideoLogs.add(logEntry);
      _currentRecordingStartTime = null;

      debugPrint('[VIDEO] Sesión continua guardada en: ${savedFile.path}');
      return logEntry;
    } catch (e) {
      debugPrint('[VIDEO] Error al detener grabación continua: $e');
      _isRecording = false;
      return null;
    }
  }

  // ===========================================================================
  // EXPORTAR REGISTRO DE VÍDEOS (SINCRONIZACIÓN)
  // ===========================================================================

  String exportVideoSyncCsv() {
    final buffer = StringBuffer();
    buffer.writeln(VideoLogEntry.csvHeader);
    for (final entry in recordedVideoLogs) {
      buffer.writeln(entry.toCsvRow());
    }
    return buffer.toString();
  }

  // ===========================================================================
  // DISPOSE
  // ===========================================================================

  Future<void> dispose() async {
    if (_isRecording) {
      try {
        await _controller?.stopVideoRecording();
      } catch (_) {}
    }
    await _controller?.dispose();
    _controller = null;
    _isInitialized = false;
  }
}