import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:disk_space_2/disk_space_2.dart';

class VideoLogEntry {
  final String filePath;

  /// Camera of the session (`cam_room`...), empty in older logs.
  final String cameraId;
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
    this.cameraId = '',
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
      'camera_id': cameraId,
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
        cameraId: json['camera_id'] as String? ?? '',
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
      'recording_start_time_utc,recording_end_time_utc,duration_seconds,'
      'camera_id';

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
        '$durationSec,'
        '"$cameraId"';
  }
}

class VideoRecordingService {
  /// Camera of the session; it goes into the video file name.
  final String cameraId;

  VideoRecordingService({this.cameraId = ''});

  /// Folder and file stamp of the running session: every segment, also one
  /// closed when the camera recovers from an error, is kept there.
  String? sessionDirectory;
  String? sessionFileStamp;

  /// Called with each saved segment (to write its row of the video log).
  void Function(VideoLogEntry entry)? onSegmentSaved;

  /// 1080p by default (the old 480p lost detail in a whole-room view).
  ResolutionPreset resolutionPreset = ResolutionPreset.veryHigh;

  /// True when the microphone could not be opened and the camera records
  /// video only.
  bool audioUnavailable = false;

  String get resolutionLabel {
    final size = _controller?.value.previewSize;
    if (size != null) {
      return '${size.width.round()}×${size.height.round()}';
    }
    return switch (resolutionPreset) {
      ResolutionPreset.high => '720p',
      ResolutionPreset.veryHigh => '1080p',
      ResolutionPreset.ultraHigh => '4K',
      _ => resolutionPreset.name,
    };
  }

  CameraController? _controller;
  List<CameraDescription> _camerasList = [];
  CameraDescription? _selectedCamera;

  bool _isInitialized = false;
  bool _isRecording = false;
  static const double minimumFreeSpaceGB = 10.0;

  /// Motivo concreto del último fallo al iniciar la grabación, para
  /// mostrarlo en la UI en lugar de un mensaje genérico.
  String? lastStartError;

  /// Último error reportado por la cámara (desconexión USB, fallo de
  /// MediaFoundation...). null si la cámara funciona.
  final ValueNotifier<String?> cameraError = ValueNotifier(null);

  /// Última cámara usada, para poder reintentar la conexión.
  CameraDescription? _lastCamera;
  CameraDescription? get lastCamera => _lastCamera;

  /// Carpeta donde se comprobó el espacio libre la última vez.
  String? lastCheckedPath;

  /// Se activa si la cámara abre con audio pero no consigue grabar con él;
  /// a partir de ahí se abre directamente sin audio.
  bool _recordWithoutAudio = false;

  DateTime? _currentRecordingStartTime;
  final List<VideoLogEntry> recordedVideoLogs = [];

  CameraController? get controller => _controller;
  bool get isInitialized => _isInitialized;
  bool get isRecording => _isRecording;
  List<CameraDescription> get camerasList => _camerasList;
  CameraDescription? get selectedCamera => _selectedCamera;

  // ===========================================================================
  // DETECCIÓN DE ESPACIO EN DISCO DISPONIBLE
  // ===========================================================================

  /// Free space where the videos go: [path] (the data folder), else the
  /// session folder, else Documents.
  Future<double?> getFreeDiskSpaceGB([String? path]) async {
    try {
      final target = path ?? sessionDirectory;
      final directory = target != null && Directory(target).existsSync()
          ? Directory(target)
          : await getApplicationDocumentsDirectory();

      debugPrint(
        '[VIDEO] Comprobando espacio en: ${directory.path}',
      );

      lastCheckedPath = directory.path;

      final freeSpaceMB =
          await DiskSpace.getFreeDiskSpaceForPath(directory.path);

      debugPrint(
        '[VIDEO] Free space reported by disk_space_2: '
        '$freeSpaceMB MB',
      );

      if (freeSpaceMB == null) {
        debugPrint(
          '[VIDEO] No se pudo obtener el espacio libre.',
        );
        return null;
      }

      final freeSpaceGB = freeSpaceMB / 1024;

      debugPrint(
        '[VIDEO] Espacio libre en disco: '
        '${freeSpaceGB.toStringAsFixed(2)} GB',
      );

      return freeSpaceGB;
    } catch (e, stackTrace) {
      debugPrint(
        '[VIDEO] Error comprobando espacio libre: '
        '$e\n$stackTrace',
      );

      return null;
    }
  }

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

      _lastCamera = camera;
      cameraError.value = null;

      // Liberar el controlador anterior, si existe.
      if (_controller != null) {
        _controller!.removeListener(_onControllerValueChanged);
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

      // Crear controlador para la cámara seleccionada, con audio (las
      // palmadas de sincronización). On Windows the audio comes from the
      // first capture device; if it cannot be opened, the camera is opened
      // again without audio.
      audioUnavailable = _recordWithoutAudio;
      try {
        await _openController(camera, enableAudio: !_recordWithoutAudio);
      } on CameraException catch (e) {
        if (_recordWithoutAudio) rethrow;
        debugPrint(
          '[VIDEO] No se pudo abrir con audio (${e.code}); '
          'reintentando sin audio.',
        );
        try {
          await _controller?.dispose();
        } catch (_) {}
        _controller = null;
        await Future.delayed(const Duration(milliseconds: 300));
        await _openController(camera, enableAudio: false);
        audioUnavailable = true;
      }

      final freeSpaceGB = await getFreeDiskSpaceGB();

      debugPrint(
        '[VIDEO] Prueba espacio disponible: '
        '${freeSpaceGB?.toStringAsFixed(2) ?? 'desconocido'} GB',
      );

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

      _controller!.addListener(_onControllerValueChanged);

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

  Future<void> _openController(
    CameraDescription camera, {
    required bool enableAudio,
  }) async {
    _controller = CameraController(
      camera,
      resolutionPreset,
      enableAudio: enableAudio,
      // 1080p of a whole room needs more than the old 5 Mbps.
      videoBitrate: switch (resolutionPreset) {
        ResolutionPreset.ultraHigh => 35 * 1000 * 1000,
        ResolutionPreset.veryHigh => 12 * 1000 * 1000,
        _ => 6 * 1000 * 1000,
      },
      audioBitrate: enableAudio ? 128 * 1000 : null,
    );

    debugPrint(
      '[VIDEO] CameraController creado '
      '(${resolutionPreset.name}, audio: $enableAudio).',
    );

    // Inicializar cámara.
    await _controller!.initialize();
  }

  void _onControllerValueChanged() {
    final value = _controller?.value;
    if (value == null) return;

    if (value.hasError) {
      final description = value.errorDescription ?? 'Error de cámara';
      if (cameraError.value != description) {
        debugPrint('[VIDEO] Error reportado por la cámara: $description');
        cameraError.value = description;
      }
    }
  }

  /// Cierra y vuelve a abrir el controlador de la cámara actual con otros
  /// ajustes (sin audio o a menor resolución).
  Future<void> _reopenController({required bool enableAudio}) async {
    final camera = _selectedCamera;
    if (camera == null) {
      throw StateError('No hay cámara seleccionada');
    }

    _controller?.removeListener(_onControllerValueChanged);
    try {
      await _controller?.dispose();
    } catch (_) {}
    _controller = null;
    _isInitialized = false;

    await Future.delayed(const Duration(milliseconds: 300));

    await _openController(camera, enableAudio: enableAudio);
    audioUnavailable = !enableAudio;
    _isInitialized = true;
    _controller!.addListener(_onControllerValueChanged);
  }

  /// Inicia la grabación. Si Windows no consigue grabar con audio o a la
  /// resolución pedida (la vista previa puede funcionar y la grabación no),
  /// lo reintenta sin audio y después a 720p.
  Future<void> _startRecordingWithFallback() async {
    final attempts = <String>[];

    try {
      await _controller!.startVideoRecording();
      return;
    } on CameraException catch (e) {
      attempts.add(
        '$resolutionLabel${audioUnavailable ? '' : ' + audio'}: '
        '${e.code} ${e.description ?? ''}'.trim(),
      );
      debugPrint('[VIDEO] Falló la grabación (${attempts.last}).');
    }

    if (!audioUnavailable) {
      try {
        await _reopenController(enableAudio: false);
        await _controller!.startVideoRecording();
        _recordWithoutAudio = true;
        debugPrint('[VIDEO] Grabando sin audio.');
        return;
      } on CameraException catch (e) {
        attempts.add('$resolutionLabel sin audio: ${e.code} ${e.description ?? ''}'.trim());
        debugPrint('[VIDEO] Falló la grabación (${attempts.last}).');
      }
    }

    if (resolutionPreset == ResolutionPreset.veryHigh ||
        resolutionPreset == ResolutionPreset.ultraHigh) {
      final previous = resolutionPreset;
      resolutionPreset = ResolutionPreset.high;
      try {
        await _reopenController(enableAudio: false);
        await _controller!.startVideoRecording();
        _recordWithoutAudio = true;
        debugPrint('[VIDEO] Grabando a 720p sin audio.');
        return;
      } on CameraException catch (e) {
        resolutionPreset = previous;
        attempts.add('720p sin audio: ${e.code} ${e.description ?? ''}'.trim());
        debugPrint('[VIDEO] Falló la grabación (${attempts.last}).');
      }
    }

    throw _RecordingStartFailed(attempts);
  }

  /// Vuelve a inicializar la última cámara usada. Si estaba grabando,
  /// intenta guardar lo grabado y empieza un nuevo segmento, que queda
  /// registrado como otra entrada del log de vídeo.
  Future<bool> recoverCamera({
    String participantSummary = '',
    int activityIndex = 0,
    bool? restartRecording,
  }) async {
    final camera = _lastCamera;
    if (camera == null) {
      lastStartError = 'No hay ninguna cámara seleccionada.';
      return false;
    }

    final wasRecording = _isRecording;
    final shouldRecord = restartRecording ?? wasRecording;

    if (wasRecording) {
      try {
        await stopSessionRecording(
          participantSummary: participantSummary,
          totalActivities: activityIndex,
        );
      } catch (e) {
        debugPrint('[VIDEO] No se pudo cerrar el segmento anterior: $e');
      }
      _isRecording = false;
    }

    final ok = await initializeCamera(camera);
    if (!ok) {
      lastStartError ??= 'No se pudo abrir la cámara ${camera.name}.';
      return false;
    }

    if (shouldRecord) {
      return startSessionRecording(
        participantSummary: participantSummary,
      );
    }

    return true;
  }

  // ===========================================================================
  // CONTROL DE GRABACIÓN DE SESIÓN CONTINUA
  // ===========================================================================

  Future<bool> startSessionRecording({
    required String participantSummary,
  }) async {
    lastStartError = null;

    if (!_isInitialized || _controller == null) {
      lastStartError =
          'La cámara no está inicializada. Vuelve a seleccionarla.';
      return false;
    }

    if (_isRecording) {
      lastStartError = 'Ya hay una grabación en curso.';
      return false;
    }

    try {

      final freeSpaceGB = await getFreeDiskSpaceGB();

      if (freeSpaceGB != null &&
          freeSpaceGB < minimumFreeSpaceGB) {
        lastStartError =
            'Espacio insuficiente en ${lastCheckedPath ?? 'la carpeta de '
            'documentos'}: ${freeSpaceGB.toStringAsFixed(1)} GB libres '
            '(mínimo ${minimumFreeSpaceGB.toStringAsFixed(0)} GB).';

        debugPrint('[VIDEO] $lastStartError');

        return false;
      }


      debugPrint('[VIDEO] Iniciando pipeline de grabación...');

      // El await completa una vez que Windows MediaFoundation inicia la captura
      await _startRecordingWithFallback();

      // Timestamp del host registrado inmediatamente después de iniciar la grabación.
      // No garantiza correspondencia exacta con el primer fotograma del vídeo.
      _currentRecordingStartTime = DateTime.now().toUtc();
      _isRecording = true;

      debugPrint(
        '[VIDEO] Grabación iniciada en: '
        '${_currentRecordingStartTime!.toIso8601String()}',
      );

      return true;
    } on _RecordingStartFailed catch (e) {
      lastStartError =
          'La cámara no consiguió grabar. Intentos: ${e.attempts.join('; ')}.';
      debugPrint('[VIDEO] $lastStartError');
      _isRecording = false;
      return false;
    } on CameraException catch (e) {
      debugPrint('[VIDEO] CameraException: ${e.code} - ${e.description}');
      lastStartError =
          'La cámara rechazó iniciar la grabación '
          '(${e.code}: ${e.description ?? 'sin descripción'}).';
      _isRecording = false;
      return false;
    } catch (e, stackTrace) {
      debugPrint('[VIDEO] Error iniciando grabación: $e\n$stackTrace');
      lastStartError = 'Error iniciando la grabación: $e';
      _isRecording = false;
      return false;
    }
  }

  /// Stops the recording and keeps the video.
  ///
  /// With [destinationDirectory] (the session folder) the video goes there
  /// as `video_<camera>_<fileStamp>.mp4`; a second segment of the same
  /// session (resumed after a restart) gets `_2`, `_3`... Otherwise it goes
  /// to Documents/LabProtocolVideos as before.
  Future<VideoLogEntry?> stopSessionRecording({
    required String participantSummary,
    required int totalActivities,
    String? destinationDirectory,
    String? fileStamp,
  }) async {
    if (!_isInitialized || _controller == null || !_isRecording) {
      return null;
    }

    try {
      final xFile = await _controller!.stopVideoRecording();
      final endTime = DateTime.now().toUtc();
      _isRecording = false;

      final timeStr = endTime.toIso8601String().replaceAll(':', '-').split('.').first;
      final String destinationPath;
      final folder = destinationDirectory ?? sessionDirectory;
      if (folder != null) {
        final camera = cameraId.isEmpty ? 'camera' : cameraId;
        final stamp = fileStamp ?? sessionFileStamp ?? timeStr;
        final base = '$folder${Platform.pathSeparator}video_${camera}_$stamp';
        var candidate = '$base.mp4';
        for (var n = 2; await File(candidate).exists(); n++) {
          candidate = '${base}_$n.mp4';
        }
        destinationPath = candidate;
      } else {
        final appDir = await getApplicationDocumentsDirectory();
        final videosDir = Directory('${appDir.path}/LabProtocolVideos');
        if (!await videosDir.exists()) {
          await videosDir.create(recursive: true);
        }
        final cleanParticipant = participantSummary.replaceAll(';', '_').replaceAll(' ', '');
        final cameraPart = cameraId.isEmpty ? '' : '_$cameraId';
        destinationPath =
            '${videosDir.path}/video_session_$cleanParticipant${cameraPart}_$timeStr.mp4';
      }

      final savedFile = await _moveFile(File(xFile.path), destinationPath);

      final logEntry = VideoLogEntry(
        filePath: savedFile.path,
        cameraId: cameraId,
        participantId: participantSummary,
        activityIndex: totalActivities,
        recordingStartTime: _currentRecordingStartTime ?? endTime,
        recordingEndTime: endTime,
      );

      recordedVideoLogs.add(logEntry);
      _currentRecordingStartTime = null;
      onSegmentSaved?.call(logEntry);

      debugPrint('[VIDEO] Sesión continua guardada en: ${savedFile.path}');
      return logEntry;
    } catch (e) {
      debugPrint('[VIDEO] Error al detener grabación continua: $e');
      _isRecording = false;
      return null;
    }
  }

  /// Renames the file (instant on the same drive) or copies it to another
  /// drive; the temporary file is removed only once the copy is complete.
  static Future<File> _moveFile(File source, String destination) async {
    try {
      return await source.rename(destination);
    } on FileSystemException {
      final copy = await source.copy(destination);
      if (await copy.length() == await source.length()) {
        try {
          await source.delete();
        } catch (e) {
          debugPrint('[VIDEO] No se pudo borrar el temporal ${source.path}: $e');
        }
      }
      return copy;
    }
  }

  // ===========================================================================
  // EXPORTAR REGISTRO DE VÍDEOS (SINCRONIZACIÓN)
  // ===========================================================================

  String exportVideoSyncCsv() => exportVideoSyncCsvFor(recordedVideoLogs);

  /// One CSV for the videos of every camera of the session.
  static String exportVideoSyncCsvFor(Iterable<VideoLogEntry> entries) {
    final buffer = StringBuffer();
    buffer.writeln(VideoLogEntry.csvHeader);
    for (final entry in entries) {
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

class _RecordingStartFailed implements Exception {
  final List<String> attempts;

  const _RecordingStartFailed(this.attempts);

  @override
  String toString() => 'Recording start failed: ${attempts.join('; ')}';
}
