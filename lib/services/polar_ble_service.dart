import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import '../models/polar_hr_sample.dart';

class PolarBleService {
  // ===========================================================================
  // STANDARD HEART RATE SERVICE
  // ===========================================================================

  static const String hrServiceUuid =
      "0000180d-0000-1000-8000-00805f9b34fb";

  static const String hrMeasurementUuid =
      "00002a37-0000-1000-8000-00805f9b34fb";

  // ===========================================================================
  // POLAR MEASUREMENT DATA (PMD)
  // ===========================================================================

  static const String pmdServiceUuid =
      "fb005c80-02e7-f387-1cad-8acd2d8df0c8";

  static const String pmdControlPointUuid =
      "fb005c81-02e7-f387-1cad-8acd2d8df0c8";

  static const String pmdDataUuid =
      "fb005c82-02e7-f387-1cad-8acd2d8df0c8";

  // ===========================================================================
  // PMD MEASUREMENT TYPES
  // ===========================================================================

  static const int pmdTypeEcg = 0x00;
  static const int pmdTypePpg = 0x01;
  static const int pmdTypeAcc = 0x02;
  static const int pmdTypePpi = 0x03;
  static const int pmdTypeGyro = 0x05;
  static const int pmdTypeMagnetometer = 0x06;

  // ===========================================================================
  // ACC SETTINGS
  // ===========================================================================

  static const int accSampleRateHz = 200;

  // At 200 Hz:
  //
  // 1 sample = 5 ms
  //
  // DateTime has microsecond precision, therefore this is exact.
  static const int accSamplePeriodMicros = 5000;

  // ===========================================================================
  // CONNECTION
  // ===========================================================================

  BleDevice? _connectedDevice;

  BleCharacteristic? _hrCharacteristic;

  BleCharacteristic? _pmdControlPoint;
  BleCharacteristic? _pmdData;

  // ===========================================================================
  // SUBSCRIPTIONS
  // ===========================================================================

  StreamSubscription<Uint8List>? _hrValueSubscription;
  StreamSubscription<Uint8List>? _pmdDataSubscription;
  StreamSubscription<Uint8List>? _pmdControlSubscription;

  // ===========================================================================
  // HR
  // ===========================================================================

  final List<PolarHrSample> recordedSamples = [];
  final List<PolarAccelerationSample> recordedAccelerationSamples = [];
  final List<PolarEcgSample> recordedEcgSamples = [];

  int currentHeartRate = 0;

  List<int> currentRrIntervals = [];

  final _hrStreamController = StreamController<int>.broadcast();

  Stream<int> get hrStream => _hrStreamController.stream;

  // ===========================================================================
  // ECG
  // ===========================================================================

  final _ecgStreamController =
      StreamController<PolarEcgSample>.broadcast();
  Stream<PolarEcgSample> get ecgStream =>
      _ecgStreamController.stream;

  final _ecgUiStreamController =
      StreamController<PolarEcgSample>.broadcast();
  Stream<PolarEcgSample> get ecgUiStream => _ecgUiStreamController.stream;

  int _lastEcgUiEmitMillis = 0;

  // ===========================================================================
  // ACC
  // ===========================================================================

  final _accStreamController =
      StreamController<PolarAccelerationSample>.broadcast();

  Stream<PolarAccelerationSample> get accelerationStream =>
      _accStreamController.stream;
  
  // Limited stream for UI (updates ~10 Hz)
  final _accUiStreamController =
      StreamController<PolarAccelerationSample>.broadcast();
  Stream<PolarAccelerationSample> get accelerationUiStream =>
      _accUiStreamController.stream;
  
  int _lastUiEmitMillis = 0;

  // ===========================================================================
  // PROTOCOL CONTEXT FOR ACC
  // ===========================================================================

  String currentParticipantId = '';
  int currentActivityIndex = 1;
  String currentPhaseName = 'idle';

  void updateProtocolContext({
    required String participantId,
    required int activityIndex,
    required String phaseName,
  }) {
    currentParticipantId = participantId;
    currentActivityIndex = activityIndex;
    currentPhaseName = phaseName;
  }

  // ===========================================================================
  // SCAN
  // ===========================================================================

  final _scanStreamController =
      StreamController<List<BleDevice>>.broadcast();

  Stream<List<BleDevice>> get scanStream =>
      _scanStreamController.stream;

  final Map<String, BleDevice> _discoveredDevices = {};

  bool get isConnected =>
      _connectedDevice != null;

  // ===========================================================================
  // STATE
  // ===========================================================================

  bool _ecgStreaming = false;
  bool _accStreaming = false;

  bool get isEcgStreaming =>
      _ecgStreaming;

  bool get isAccelerationStreaming =>
      _accStreaming;

  // ===========================================================================
  // ACC TIMING STATE
  // ===========================================================================

  // Timestamp of the last ACC sample emitted by the decoder.
  //
  // This is NOT used to replace the timestamp provided by the H10.
  // It is used to:
  //
  //   1. detect discontinuities between PMD frames;
  //   2. detect unexpectedly large gaps;
  //   3. verify that the stream is behaving as expected at 200 Hz.
  //
  // The H10 frame timestamp remains authoritative.
  int? _lastAccFrameTimestampNs;
  int? _lastAccSampleTimestampNs;

  void _resetAccTimingState() {
    _lastAccFrameTimestampNs = null;
    _lastAccSampleTimestampNs = null;
  }
  

  // ===========================================================================
  // CONSTRUCTOR
  // ===========================================================================

  PolarBleService() {
    UniversalBle.onConnectionChange = (
      deviceId,
      isConnected,
      error,
    ) {
      if (!isConnected &&
          deviceId == _connectedDevice?.deviceId) {
        
        _connectedDevice = null;

        _hrCharacteristic = null;
        _pmdControlPoint = null;
        _pmdData = null;

        _ecgStreaming = false;
        _accStreaming = false;

        _resetAccTimingState();

        currentHeartRate = 0;
        currentRrIntervals = [];

        _hrStreamController.add(0);
      }
    };
  }

  // ===========================================================================
  // SCAN
  // ===========================================================================

  Future<void> startScan() async {
    
    _discoveredDevices.clear();

    UniversalBle.onScanResult = (device) {
      _discoveredDevices[device.deviceId] = device;

      _scanStreamController.add(
        _discoveredDevices.values.toList(),
      );
    };

    await UniversalBle.startScan();
  }

  Future<void> stopScan() async {
    try {
      UniversalBle.onScanResult = null;
      await UniversalBle.stopScan();
    } catch (e) {
      debugPrint(
        '[POLAR DEBUG] Error deteniendo scan: $e',
      );
    }
  }

  // ===========================================================================
  // CONNECT
  // ===========================================================================

  Future<bool> connectToDevice(
    BleDevice device,
  ) async {
    try {
      if (_connectedDevice != null) {
        await disconnect();
      }

      await stopScan();

      await device.connect(
        timeout: const Duration(seconds: 30),
      );

      _connectedDevice = device;

      final state =
          await device.connectionState;

      if (state !=
          BleConnectionState.connected) {
        throw Exception(
          'Dispositivo no conectado: $state',
        );
      }

      // =====================================================================
      // HR
      // =====================================================================

      await _setupHeartRate(device);

      // =====================================================================
      // PMD
      // =====================================================================

      await _setupPmd(device);

      return true;
    } catch (e) {

      await disconnect();

      return false;
    }
  }

  // ===========================================================================
  // SETUP HR
  // ===========================================================================

  Future<void> _setupHeartRate(
    BleDevice device,
  ) async {
    final characteristic =
        await device.getCharacteristic(
      hrMeasurementUuid,
      service: hrServiceUuid,
      preferCached: false,
    );

    _hrCharacteristic = characteristic;

    if (!characteristic
        .notifications.isSupported) {
      throw Exception(
        'HR does not support notifications',
      );
    }

    await _hrValueSubscription?.cancel();

    _hrValueSubscription =
        characteristic.onValueReceived.listen(
      (value) {
        _parseHeartRateData(value);
      },
    );

    await characteristic
        .notifications
        .subscribe();

    debugPrint(
      '[POLAR DEBUG] HR notifications SUSCRITAS',
    );
  }

  // ===========================================================================
  // SETUP PMD
  // ===========================================================================

  Future<void> _setupPmd(
    BleDevice device,
  ) async {
    debugPrint(
      '[POLAR DEBUG] Configurando PMD...',
    );

    _pmdControlPoint =
        await device.getCharacteristic(
      pmdControlPointUuid,
      service: pmdServiceUuid,
      preferCached: false,
    );

    _pmdData =
        await device.getCharacteristic(
      pmdDataUuid,
      service: pmdServiceUuid,
      preferCached: false,
    );

    // -------------------------------------------------------------------------
    // PMD DATA NOTIFICATIONS
    // -------------------------------------------------------------------------

    if (!_pmdData!
        .notifications.isSupported) {
      throw Exception(
        'PMD Data no soporta notifications',
      );
    }

    await _pmdDataSubscription?.cancel();

    _pmdDataSubscription =
        _pmdData!.onValueReceived.listen(
      (value) {
        _handlePmdData(value);
      },
      onError: (error, stack) {
        debugPrint(
          '[POLAR DEBUG] ERROR PMD DATA: '
          '$error',
        );
      },
    );

    debugPrint(
      '[POLAR DEBUG] Suscribiendo PMD Data...',
    );

    await _pmdData!
        .notifications
        .subscribe();

    debugPrint(
      '[POLAR DEBUG] PMD Data SUSCRITO',
    );

    // -------------------------------------------------------------------------
    // PMD CONTROL POINT INDICATIONS
    // -------------------------------------------------------------------------

    if (!_pmdControlPoint!
        .indications.isSupported) {
      throw Exception(
        'PMD Control Point no soporta indications',
      );
    }

    await _pmdControlSubscription
        ?.cancel();

    _pmdControlSubscription =
        _pmdControlPoint!
            .onValueReceived
            .listen(
      (value) {
        _handlePmdControlResponse(value);
      },
      onError: (error, stack) {
        debugPrint(
          '[POLAR DEBUG] ERROR PMD CONTROL: '
          '$error',
        );
      },
    );

    debugPrint(
      '[POLAR DEBUG] Suscribiendo PMD Control indications...',
    );

    await _pmdControlPoint!
        .indications
        .subscribe();

    debugPrint(
      '[POLAR DEBUG] PMD Control indications SUSCRITAS',
    );
  }

  // ===========================================================================
  // START ECG
  // ===========================================================================

  Future<void> startEcg() async {
    if (_pmdControlPoint == null) {
      throw Exception(
        'PMD no está conectado',
      );
    }

    if (_ecgStreaming) {
      debugPrint(
        '[POLAR DEBUG] ECG ya está activo',
      );

      return;
    }

    // H10 ECG:
    //
    // measurement type = 0x00
    // sample rate      = 130 Hz
    // resolution       = 14 bit
    //
    // 02 = start measurement
    // 00 = ECG
    // 00 01 82 00 = 130 Hz
    // 01 01 0E 00 = 14-bit resolution

    final command = Uint8List.fromList([
      0x02,
      0x00,
      0x00,
      0x01,
      0x82,
      0x00,
      0x01,
      0x01,
      0x0E,
      0x00,
    ]);

    await _pmdControlPoint!.write(
      command,
      withResponse: true,
      timeout: const Duration(seconds: 30),
    );

    _ecgStreaming = true;

  }

  // ===========================================================================
  // START ACC
  // ===========================================================================

  Future<void> startAcceleration() async {
    if (_pmdControlPoint == null) {
      throw Exception(
        'PMD no está conectado',
      );
    }

    if (_accStreaming) {
      return;
    }

    // H10 ACC:
    //
    // measurement type = 0x02
    // sample rate      = 200 Hz
    // resolution       = 16 bit
    // range            = 8 G
    //
    // Setting 0x00 = sample rate
    // Setting 0x01 = resolution
    // Setting 0x02 = range
    //
    // 200 Hz = C8 00
    // 16 bit = 10 00
    // 8 G    = 08 00

    final command = Uint8List.fromList([
      0x02,
      0x02,
      0x00,
      0x01,
      0xC8,
      0x00,
      0x01,
      0x01,
      0x10,
      0x00,
      0x02,
      0x01,
      0x08,
      0x00,
    ]);

    await _pmdControlPoint!.write(
      command,
      withResponse: true,
      timeout: const Duration(seconds: 30),
    );

    _resetAccTimingState();

    _accStreaming = true;
  }

  // ===========================================================================
  // STOP ECG
  // ===========================================================================

  Future<void> stopEcg() async {
    if (_pmdControlPoint == null ||
        !_ecgStreaming) {
      return;
    }


    final command =
        Uint8List.fromList([
      0x03,
      pmdTypeEcg,
    ]);

    await _pmdControlPoint!.write(
      command,
      withResponse: true,
      timeout: const Duration(seconds: 30),
    );

    _ecgStreaming = false;

  }

  // ===========================================================================
  // STOP ACC
  // ===========================================================================

  Future<void> stopAcceleration() async {
    if (_pmdControlPoint == null ||
        !_accStreaming) {
      return;
    }

    final command =
        Uint8List.fromList([
      0x03,
      pmdTypeAcc,
    ]);

    await _pmdControlPoint!.write(
      command,
      withResponse: true,
      timeout: const Duration(seconds: 30),
    );

    _accStreaming = false;

  }

  // ===========================================================================
  // PMD CONTROL RESPONSE
  // ===========================================================================

  void _handlePmdControlResponse(
    Uint8List data,
  ) {
    debugPrint(
      '[POLAR DEBUG] PMD CONTROL RESPONSE: '
      '${_hex(data)}',
    );
  }

  // ===========================================================================
  // PMD DATA
  // ===========================================================================

  void _handlePmdData(
    Uint8List data,
  ) {
    if (data.isEmpty) {
      return;
    }
    final measurementType =
        data[0] & 0x3F;

    switch (measurementType) {
      case pmdTypeEcg:
        _parseEcgFrame(data);
        break;

      case pmdTypeAcc:
        _parseAccelerationFrame(data);
        break;

      default:
    }
  }

  // ===========================================================================
  // ECG FRAME
  // ===========================================================================

  void _parseEcgFrame(Uint8List data) {
    if (data.length < 10) return;

    final timestampNs = _readUint64LittleEndian(data, 1);
    final isDelta = (data[9] & 0x80) != 0;

    if (isDelta) {
      debugPrint('[POLAR DEBUG] ECG delta no implementado en firmware H10');
      return;
    }

    int offset = 10;
    int sampleIndex = 0;
    final totalEcgSamples = (data.length - 10) ~/ 3;
    const double ecgIntervalNs = 1000000000.0 / 130.0;

    while (offset + 2 < data.length) {
      final rawUv = _readSigned24LittleEndian(data, offset);
      final currentSampleNs = timestampNs -
          ((totalEcgSamples - 1 - sampleIndex) * ecgIntervalNs).round();
      final sampleTime = _pmdTimestampToDateTime(currentSampleNs);

      final sample = PolarEcgSample(
        timestamp: sampleTime,
        participantId: currentParticipantId,
        activityIndex: currentActivityIndex,
        phaseName: currentPhaseName,
        microVolts: rawUv,
      );

      if (!_ecgStreamController.isClosed) {
        _ecgStreamController.add(sample);
      }

      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (nowMs - _lastEcgUiEmitMillis >= 100) {
        _lastEcgUiEmitMillis = nowMs;
        if (!_ecgUiStreamController.isClosed) {
          _ecgUiStreamController.add(sample);
        }
      }

      offset += 3;
      sampleIndex++;
    }
  }

  // ===========================================================================
  // ACC FRAME
  // ===========================================================================

  void _parseAccelerationFrame(
    Uint8List data,
  ) {
    if (data.length < 10) {
      debugPrint(
        '[POLAR DEBUG] ACC frame demasiado corto',
      );

      return;
    }


    // -------------------------------------------------------------------------
    // PMD HEADER
    // -------------------------------------------------------------------------

    final timestampNs =
        _readUint64LittleEndian(
      data,
      1,
    );

    // Bit 7 indicates delta compression.
    //
    // Bits 0-6 indicate the frame type:
    //
    //   0 = 8-bit XYZ
    //   1 = 16-bit XYZ
    //   2 = 24-bit XYZ
    //   128 = delta frame (0x80)
    //
    final frameType =
        data[9] & 0x7F;

    final isDelta =
        (data[9] & 0x80) != 0;

    if (isDelta) {

      _parseAccelerationDeltaFrame(
        data,
        timestampNs,
      );
    } else {
      _parseAccelerationNormalFrame(
        data,
        timestampNs,
        frameType,
      );
    }
  }

  // ===========================================================================
  // ACC NORMAL FRAME
  // ===========================================================================

  void _parseAccelerationNormalFrame(
    Uint8List data,
    int timestampNs,
    int frameType,
  ) {
    // -------------------------------------------------------------------------
    // Determine sample size from frame type.
    //
    // Each sample consists of:
    //
    //   X + Y + Z
    //
    // Therefore:
    //
    //   type 0 -> 3 bytes/sample
    //   type 1 -> 6 bytes/sample
    //   type 2 -> 9 bytes/sample
    // -------------------------------------------------------------------------

    final int bytesPerAxis;
    switch (frameType) {
      case 0:
        bytesPerAxis = 1;
        break;
      case 1:
        bytesPerAxis = 2;
        break;
      case 2:
        bytesPerAxis = 3;
        break;
      default:
        return;
    }

    final bytesPerSample = bytesPerAxis * 3;
    final payloadLength = data.length - 10;
    if (payloadLength < bytesPerSample) return;

    final sampleCount = payloadLength ~/ bytesPerSample;

    // Intervalo exacto de reloj entre la trama previa y la actual
    final double actualIntervalNs;
    if (_lastAccFrameTimestampNs != null && timestampNs > _lastAccFrameTimestampNs!) {
      actualIntervalNs = (timestampNs - _lastAccFrameTimestampNs!) / sampleCount;
    } else {
      actualIntervalNs = 1000000000.0 / accSampleRateHz;
    }
    _lastAccFrameTimestampNs = timestampNs;

    int offset = 10;

    for (int i = 0; i < sampleCount; i++) {
      final int x;
      final int y;
      final int z;

      switch (bytesPerAxis) {
        case 1:
          x = _readSigned8(data, offset);
          y = _readSigned8(data, offset + 1);
          z = _readSigned8(data, offset + 2);
          break;
        case 2:
          x = _readSigned16LittleEndian(data, offset);
          y = _readSigned16LittleEndian(data, offset + 2);
          z = _readSigned16LittleEndian(data, offset + 4);
          break;
        case 3:
          x = _readSigned24LittleEndian(data, offset);
          y = _readSigned24LittleEndian(data, offset + 3);
          z = _readSigned24LittleEndian(data, offset + 6);
          break;
        default:
          return;
      }

      final currentSampleNs = timestampNs + (i * actualIntervalNs).round();

      _emitAccelerationSampleDirect(
        sampleNs: currentSampleNs,
        xMg: x.toDouble(),
        yMg: y.toDouble(),
        zMg: z.toDouble(),
      );

      offset += bytesPerSample;
    }
  }

  // ===========================================================================
  // ACC DELTA FRAME
  // ===========================================================================

  void _parseAccelerationDeltaFrame(
    Uint8List data,
    int timestampNs,
  ) {
    int offset = 10;
    const int referenceBytes = 6;

    if (data.length < offset + referenceBytes + 2) return;

    final referenceX = _readSigned16LittleEndian(data, offset);
    final referenceY = _readSigned16LittleEndian(data, offset + 2);
    final referenceZ = _readSigned16LittleEndian(data, offset + 4);

    offset += referenceBytes;

    final deltaBits = data[offset];
    final sampleCount = data[offset + 1];

    offset += 2;

    if (deltaBits <= 0 || deltaBits > 32) return;

    final totalSamples = sampleCount + 1;

    final double actualIntervalNs;
    if (_lastAccFrameTimestampNs != null && timestampNs > _lastAccFrameTimestampNs!) {
      actualIntervalNs = (timestampNs - _lastAccFrameTimestampNs!) / totalSamples;
    } else {
      actualIntervalNs = 1000000000.0 / accSampleRateHz;
    }
    _lastAccFrameTimestampNs = timestampNs;

    int currentX = referenceX;
    int currentY = referenceY;
    int currentZ = referenceZ;
    int sampleIndex = 0;

    // Muestra de referencia
    _emitAccelerationSampleDirect(
      sampleNs: timestampNs,
      xMg: currentX.toDouble(),
      yMg: currentY.toDouble(),
      zMg: currentZ.toDouble(),
    );

    sampleIndex++;

    final totalBits = sampleCount * 3 * deltaBits;
    final totalBytes = (totalBits + 7) ~/ 8;
    final availableBytes = data.length - offset;

    if (availableBytes < totalBytes) return;

    final deltaReader = _BitReader(data, offset);

    try {
      for (int i = 0; i < sampleCount; i++) {
        final dx = _readSignedBits(deltaReader, deltaBits);
        final dy = _readSignedBits(deltaReader, deltaBits);
        final dz = _readSignedBits(deltaReader, deltaBits);

        currentX += dx;
        currentY += dy;
        currentZ += dz;

        final currentSampleNs = timestampNs + (sampleIndex * actualIntervalNs).round();

        _emitAccelerationSampleDirect(
          sampleNs: currentSampleNs,
          xMg: currentX.toDouble(),
          yMg: currentY.toDouble(),
          zMg: currentZ.toDouble(),
        );

        sampleIndex++;
      }
    } catch (e) {
      debugPrint('[POLAR DEBUG] ERROR DECODING ACC DELTA: $e');
    }
  }

  // ===========================================================================
  // EMIT ACCELERATION SAMPLE
  // ===========================================================================

  void _emitAccelerationSampleDirect({
    required int sampleNs,
    required double xMg,
    required double yMg,
    required double zMg,
  }) {
    if (_lastAccSampleTimestampNs != null) {
      final deltaNs = sampleNs - _lastAccSampleTimestampNs!;
      // Alerta únicamente si el salto supera 50 ms (pérdida de paquetes BLE)
      if (deltaNs > 50000000 || deltaNs < 0) {
        debugPrint(
          '[POLAR ALERTA] Paquete perdido / Discontinuidad BLE: salto de ${deltaNs ~/ 1000000} ms',
        );
      }
    }

    _lastAccSampleTimestampNs = sampleNs;

    final sampleTime = _pmdTimestampToDateTime(sampleNs);

    final sample = PolarAccelerationSample(
      timestamp: sampleTime,
      participantId: currentParticipantId,
      activityIndex: currentActivityIndex,
      phaseName: currentPhaseName,
      xMg: xMg.round(),
      yMg: yMg.round(),
      zMg: zMg.round(),
    );

    recordedAccelerationSamples.add(sample);
    if (!_accStreamController.isClosed) {
      _accStreamController.add(sample);
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastUiEmitMillis >= 100) {
      _lastUiEmitMillis = nowMs;
      if (!_accUiStreamController.isClosed) {
        _accUiStreamController.add(sample);
      }
    }
  }

  // ===========================================================================
  // HR PARSER
  // ===========================================================================

  void _parseHeartRateData(
    Uint8List data,
  ) {
    if (data.isEmpty) {
      return;
    }

    try {
      final byteData =
          ByteData.sublistView(data);

      final flags =
          byteData.getUint8(0);

      final is16Bit =
          (flags & 0x01) != 0;

      final hasEnergyExpended =
          (flags & 0x08) != 0;

      final hasRr =
          (flags & 0x10) != 0;

      int offset = 1;

      if (offset >= data.length) {
        return;
      }

      final bpm = is16Bit
          ? byteData.getUint16(
              offset,
              Endian.little,
            )
          : byteData.getUint8(
              offset,
            );

      offset +=
          is16Bit ? 2 : 1;

      if (hasEnergyExpended) {
        if (offset + 1 >= data.length) {
          return;
        }

        offset += 2;
      }

      final rrList = <int>[];

      if (hasRr) {
        while (
            offset + 1 <
                data.length) {
          final rawRr =
              byteData.getUint16(
            offset,
            Endian.little,
          );

          final rrMs =
              ((rawRr / 1024.0) *
                      1000.0)
                  .round();

          rrList.add(rrMs);

          offset += 2;
        }
      }

      currentHeartRate = bpm;
      currentRrIntervals =
          rrList;

      if (!_hrStreamController.isClosed) {
        _hrStreamController.add(bpm);
      }
    } catch (e, stack) {
      debugPrint(
        '[POLAR DEBUG] ERROR PARSING HR: '
        '$e',
      );

      debugPrint(
        '[POLAR DEBUG] $stack',
      );
    }
  }

  // ===========================================================================
  // CAPTURE HR SAMPLE
  // ===========================================================================

  void captureSample({
    required String participantId,
    required int activityIndex,
    required String phaseName,
  }) {
    if (!isConnected || currentHeartRate == 0) {
      return;
    }

    recordedSamples.add(
      PolarHrSample(
        timestamp: DateTime.now().toUtc(),
        participantId: participantId,
        activityIndex: activityIndex,
        phaseName: phaseName,
        heartRateBpm: currentHeartRate,
        rrIntervalsMs: List.from(currentRrIntervals),
      ),
    );
  }

  // ===========================================================================
  // CSV HR
  // ===========================================================================

  String exportCsv() {
    final buffer =
        StringBuffer();

    buffer.writeln(
      PolarHrSample.csvHeader,
    );

    for (final sample
        in recordedSamples) {
      buffer.writeln(
        sample.toCsvRow(),
      );
    }

    return buffer.toString();
  }

  // ===========================================================================
  // CSV ACCELEROMETER
  // ===========================================================================

  String exportAccelerationCsv() {
    final buffer = StringBuffer();
    buffer.writeln(PolarAccelerationSample.csvHeader);

    for (final sample in recordedAccelerationSamples) {
      buffer.writeln(sample.toCsvRow());
    }

    return buffer.toString();
  }

  // ===========================================================================
  // CSV ECG
  // ===========================================================================

  String exportEcgCsv() {
    final buffer = StringBuffer();
    buffer.writeln(PolarEcgSample.csvHeader);

    for (final sample in recordedEcgSamples) {
      buffer.writeln(sample.toCsvRow());
    }

    return buffer.toString();
  }

  // ===========================================================================
  // DISCONNECT
  // ===========================================================================

  Future<void> disconnect() async {
    final device =
        _connectedDevice;

    if (device == null) {
      return;
    }

    debugPrint(
      '[POLAR DEBUG] Desconectando '
      '${device.deviceId}...',
    );

    try {
      if (_ecgStreaming) {
        await stopEcg();
      }
    } catch (e) {
      debugPrint(
        '[POLAR DEBUG] Error deteniendo ECG: '
        '$e',
      );
    }

    try {
      if (_accStreaming) {
        await stopAcceleration();
      }
    } catch (e) {
      debugPrint(
        '[POLAR DEBUG] Error deteniendo ACC: '
        '$e',
      );
    }

    try {
      await _hrValueSubscription
          ?.cancel();
    } catch (_) {}

    try {
      await _pmdDataSubscription
          ?.cancel();
    } catch (_) {}

    try {
      await _pmdControlSubscription
          ?.cancel();
    } catch (_) {}

    _hrValueSubscription = null;
    _pmdDataSubscription = null;
    _pmdControlSubscription = null;

    try {
      await _hrCharacteristic
          ?.unsubscribe();
    } catch (_) {}

    try {
      await _pmdData
          ?.unsubscribe();
    } catch (_) {}

    try {
      await _pmdControlPoint
          ?.unsubscribe();
    } catch (_) {}

    try {
      await device.disconnect(
        timeout:
            const Duration(
          seconds: 30,
        ),
      );
    } catch (e) {
      debugPrint(
        '[POLAR DEBUG] Error desconectando: '
        '$e',
      );
    }

    _connectedDevice = null;

    _hrCharacteristic = null;
    _pmdControlPoint = null;
    _pmdData = null;

    _ecgStreaming = false;
    _accStreaming = false;

    _resetAccTimingState();

    currentHeartRate = 0;
    currentRrIntervals = [];

    if (!_hrStreamController.isClosed) {
        _hrStreamController.add(0);
      }
  }

  // ===========================================================================
  // HELPERS
  // ===========================================================================

  static String _hex(
    Uint8List data,
  ) {
    return data
        .map(
          (e) => e
              .toRadixString(16)
              .padLeft(2, '0'),
        )
        .join(' ');
  }

  static int _readUint64LittleEndian(
    Uint8List data,
    int offset,
  ) {
    int value = 0;

    for (int i = 0; i < 8; i++) {
      value |=
          data[offset + i] <<
              (8 * i);
    }

    return value;
  }

  static int _readSigned8(
    Uint8List data,
    int offset,
  ) {
    final value =
        data[offset];

    if ((value & 0x80) != 0) {
      return value - 0x100;
    }

    return value;
  }

  static int _readSigned16LittleEndian(
    Uint8List data,
    int offset,
  ) {
    int value =
        data[offset] |
        (data[offset + 1] << 8);

    if ((value & 0x8000) != 0) {
      value -= 0x10000;
    }

    return value;
  }

  static int _readSigned24LittleEndian(
    Uint8List data,
    int offset,
  ) {
    int value =
        data[offset] |
        (data[offset + 1] << 8) |
        (data[offset + 2] << 16);

    if ((value & 0x800000) != 0) {
      value -= 0x1000000;
    }

    return value;
  }

  // ===========================================================================
  // PMD TIMESTAMP
  // ===========================================================================

  static DateTime _pmdTimestampToDateTime(
    int timestampNs,
  ) {
    final epoch =
        DateTime.utc(
      2000,
      1,
      1,
    );

    final micros =
        timestampNs ~/ 1000;

    return epoch.add(
      Duration(
        microseconds: micros,
      ),
    );
  }

  // ===========================================================================
  // DISPOSE
  // ===========================================================================

  void dispose() {
    _hrValueSubscription?.cancel();
    _pmdDataSubscription?.cancel();
    _pmdControlSubscription?.cancel();

    disconnect();

    _hrStreamController.close();
    _ecgStreamController.close();
    _ecgUiStreamController.close();
    _accStreamController.close();
    _accUiStreamController.close();
    _scanStreamController.close();
  }
}

// =============================================================================
// ECG SAMPLE
// =============================================================================

class PolarEcgSample {
  final DateTime timestamp;
  final String participantId;
  final int activityIndex;
  final String phaseName;
  final int microVolts;

  const PolarEcgSample({
    required this.timestamp,
    required this.participantId,
    required this.activityIndex,
    required this.phaseName,
    required this.microVolts,
  });

  static const String csvHeader =
      'timestamp_iso,participant_id,activity_index,phase_name,ecg_uv';

  String toCsvRow() {
    return '${timestamp.toIso8601String()},$participantId,$activityIndex,$phaseName,$microVolts';
  }
}

// =============================================================================
// ACCELERATION SAMPLE
// =============================================================================

class PolarAccelerationSample {
  final DateTime timestamp;
  final String participantId;
  final int activityIndex;
  final String phaseName;
  final int xMg;
  final int yMg;
  final int zMg;

  const PolarAccelerationSample({
    required this.timestamp,
    required this.participantId,
    required this.activityIndex,
    required this.phaseName,
    required this.xMg,
    required this.yMg,
    required this.zMg,
  });

  static const String csvHeader =
      'timestamp_iso,participant_id,activity_index,phase_name,acc_x_mg,acc_y_mg,acc_z_mg';

  String toCsvRow() {
    return '${timestamp.toIso8601String()},$participantId,$activityIndex,$phaseName,$xMg,$yMg,$zMg';
  }
}

// =============================================================================
// BIT READER
// =============================================================================

class _BitReader {
  final Uint8List data;

  int byteOffset;

  int bitOffset = 0;

  _BitReader(
    this.data,
    this.byteOffset,
  );

  int readBits(
    int count,
  ) {
    if (count <= 0) {
      return 0;
    }

    int value = 0;

    for (int i = 0;
        i < count;
        i++) {
      if (byteOffset >=
          data.length) {
        throw StateError(
          'BitReader: fuera de rango',
        );
      }

      final bit =
          (data[byteOffset] >>
                  bitOffset) &
              0x01;

      value |=
          bit << i;

      bitOffset++;

      if (bitOffset == 8) {
        bitOffset = 0;
        byteOffset++;
      }
    }

    return value;
  }
}

// =============================================================================
// SIGNED BIT READER
// =============================================================================

int _readSignedBits(
  _BitReader reader,
  int bits,
) {
  final int unsignedValue = reader.readBits(bits);
  final int signBit = 1 << (bits - 1);

  if ((unsignedValue & signBit) != 0) {
    return unsignedValue - (1 << bits);
  }

  return unsignedValue;
}