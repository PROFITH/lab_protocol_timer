import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import '../models/polar_hr_sample.dart';

class PolarBleService {
  // ===========================================================================
  // DEBUG
  // ===========================================================================

  // Keep this false during real recordings.
  //
  // At 200 Hz, printing every PMD frame can generate a very large amount of
  // console output and can itself affect the timing of the application.
  static const bool debugPmdFrames = false;

  // ===========================================================================
  // STANDARD HEART RATE SERVICE
  // ===========================================================================

  static const String hrServiceUuid =
      '0000180d-0000-1000-8000-00805f9b34fb';

  static const String hrMeasurementUuid =
      '00002a37-0000-1000-8000-00805f9b34fb';

  // ===========================================================================
  // POLAR MEASUREMENT DATA (PMD)
  // ===========================================================================

  static const String pmdServiceUuid =
      'fb005c80-02e7-f387-1cad-8acd2d8df0c8';

  static const String pmdControlPointUuid =
      'fb005c81-02e7-f387-1cad-8acd2d8df0c8';

  static const String pmdDataUuid =
      'fb005c82-02e7-f387-1cad-8acd2d8df0c8';

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
  // PMD CONTROL POINT
  // ===========================================================================

  static const int pmdResponse = 0xF0;

  static const int pmdOpGetMeasurementSettings = 0x01;
  static const int pmdOpStartMeasurement = 0x02;
  static const int pmdOpStopMeasurement = 0x03;

  // PMD setting types.
  static const int pmdSettingSampleRate = 0x00;
  static const int pmdSettingResolution = 0x01;
  static const int pmdSettingRange = 0x02;
  static const int pmdSettingRangeMilliUnit = 0x03;
  static const int pmdSettingChannels = 0x04;
  static const int pmdSettingFactor = 0x05;

  // ===========================================================================
  // TIME CALIBRATION
  // ===========================================================================
  
  // Diferencia calculada: (Host UTC Microseconds) - (Polar Timestamp Microseconds)
  int? _sensorToHostEpochOffsetMicros;

  void _resetClockSync() {
    _sensorToHostEpochOffsetMicros = null;
  }

  DateTime _convertPmdTimestampToHostUtc(int timestampNs) {
    final sampleMicrosFromPolar = timestampNs ~/ 1000;
    final nowHostMicros = DateTime.now().toUtc().microsecondsSinceEpoch;

    // Se calibra con el primer paquete recibido en la sesión
    _sensorToHostEpochOffsetMicros ??= (nowHostMicros - sampleMicrosFromPolar);

    final synchronizedMicros = sampleMicrosFromPolar + _sensorToHostEpochOffsetMicros!;
    return DateTime.fromMicrosecondsSinceEpoch(synchronizedMicros, isUtc: true);
  }

  // ===========================================================================
  // ACC SETTINGS
  // ===========================================================================

  static const int defaultAccSampleRateHz = 200;

  int _accSampleRateHz = defaultAccSampleRateHz;

  // PMD ACC factor.
  //
  // This is NOT assumed to be 1.0 permanently.
  //
  // Polar's SDK obtains the factor from PMD settings/start-response data.
  // For compressed ACC:
  //
  //     TYPE_0 -> value * factor * 1000 = mG
  //
  // We start with 1.0 as a safe fallback until the device provides the
  // actual factor.
  double _accFactor = 1.0;

  // ===========================================================================
  // ECG SETTINGS
  // ===========================================================================

  static const int ecgSampleRateHz = 130;

  // ===========================================================================
  // POLAR PSFTP / PFTP
  // ===========================================================================

  static const String psftpServiceUuid =
      '0000feee-0000-1000-8000-00805f9b34fb';

  static const String psftp51Uuid =
      'fb005c51-02e7-f387-1cad-8acd2d8df0c8';

  static const String psftp52Uuid =
      'fb005c52-02e7-f387-1cad-8acd2d8df0c8';

  static const String psftp53Uuid =
      'fb005c53-02e7-f387-1cad-8acd2d8df0c8';

  // ===========================================================================
  // CONNECTION
  // ===========================================================================

  BleDevice? _connectedDevice;

  BleCharacteristic? _hrCharacteristic;

  BleCharacteristic? _pmdControlPoint;
  BleCharacteristic? _pmdData;

  BleCharacteristic? _psftp51;
  BleCharacteristic? _psftp52;
  BleCharacteristic? _psftp53;

  // ===========================================================================
  // SUBSCRIPTIONS
  // ===========================================================================

  StreamSubscription<Uint8List>? _hrValueSubscription;
  StreamSubscription<Uint8List>? _pmdDataSubscription;
  StreamSubscription<Uint8List>? _pmdControlSubscription;

  StreamSubscription? _psftp51Subscription;
  StreamSubscription? _psftp52Subscription;
  StreamSubscription? _psftp53Subscription;

  // ===========================================================================
  // HR
  // ===========================================================================

  final List<PolarHrSample> recordedSamples = [];

  final List<PolarAccelerationSample> recordedAccelerationSamples = [];

  final List<PolarEcgSample> recordedEcgSamples = [];

  int currentHeartRate = 0;

  List<int> currentRrIntervals = [];

  final _hrStreamController =
      StreamController<int>.broadcast();

  Stream<int> get hrStream =>
      _hrStreamController.stream;

  // ===========================================================================
  // ECG
  // ===========================================================================

  final _ecgStreamController =
      StreamController<PolarEcgSample>.broadcast();

  Stream<PolarEcgSample> get ecgStream =>
      _ecgStreamController.stream;

  final _ecgUiStreamController =
      StreamController<PolarEcgSample>.broadcast();

  Stream<PolarEcgSample> get ecgUiStream =>
      _ecgUiStreamController.stream;

  int _lastEcgUiEmitMillis = 0;

  // ===========================================================================
  // ACC
  // ===========================================================================

  final _accStreamController =
      StreamController<PolarAccelerationSample>.broadcast();

  Stream<PolarAccelerationSample> get accelerationStream =>
      _accStreamController.stream;

  final _accUiStreamController =
      StreamController<PolarAccelerationSample>.broadcast();

  Stream<PolarAccelerationSample> get accelerationUiStream =>
      _accUiStreamController.stream;

  int _lastUiEmitMillis = 0;

  // ===========================================================================
  // PROTOCOL CONTEXT FOR ACC / ECG
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
  // PMD CONTROL POINT STATE
  // ===========================================================================

  Completer<_PmdControlResponse>? _pendingPmdResponse;

  // ===========================================================================
  // PMD TIMESTAMP STATE
  // ===========================================================================
  //
  // Polar maintains previous timestamps separately for measurement type and
  // frame type. We additionally distinguish compressed/raw because they are
  // different logical streams from the decoder's point of view.
  //
  // Key examples:
  //
  //     acc_raw_0
  //     acc_raw_1
  //     acc_raw_2
  //     acc_compressed_0
  //     acc_compressed_1
  //
  // ECG currently uses:
  //
  //     ecg_raw_0
  //
  final Map<String, int> _lastPmdFrameTimestampNs = {};

  int? _lastAccSampleTimestampNs;

  void _resetPmdTimingState() {
    _lastPmdFrameTimestampNs.clear();
    _lastAccSampleTimestampNs = null;
    _resetClockSync();
  }

  String _pmdTimestampKey({
    required int measurementType,
    required bool compressed,
    required int frameType,
  }) {
    return '${measurementType}_'
        '${compressed ? 'compressed' : 'raw'}_'
        '$frameType';
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
        _handleUnexpectedDisconnect();
      }
    };
  }

  // ===========================================================================
  // UNEXPECTED DISCONNECT
  // ===========================================================================

  void _handleUnexpectedDisconnect() {
    _connectedDevice = null;

    _hrCharacteristic = null;
    _pmdControlPoint = null;
    _pmdData = null;

    _psftp51 = null;
    _psftp52 = null;
    _psftp53 = null;

    _ecgStreaming = false;
    _accStreaming = false;

    _resetPmdTimingState();

    _completePendingPmdResponse(
      error: StateError(
        'PMD connection lost',
      ),
    );

    currentHeartRate = 0;
    currentRrIntervals = [];

    if (!_hrStreamController.isClosed) {
      _hrStreamController.add(0);
    }
  }

  // ===========================================================================
  // SCAN
  // ===========================================================================

  Future<void> startScan() async {
    _discoveredDevices.clear();

    UniversalBle.onScanResult = (device) {
      _discoveredDevices[device.deviceId] = device;

      if (!_scanStreamController.isClosed) {
        _scanStreamController.add(
          _discoveredDevices.values.toList(),
        );
      }
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

      final services =
          await device.discoverServices();

      for (final service in services) {
        for (final characteristic
            in service.characteristics) {
          final uuid =
              characteristic.uuid.toLowerCase();

          if (uuid == psftp51Uuid) {
            _psftp51 = characteristic;
          } else if (uuid == psftp52Uuid) {
            _psftp52 = characteristic;
          } else if (uuid == psftp53Uuid) {
            _psftp53 = characteristic;
          }
        }
      }

      debugPrint(
        '[PSFTP] FB005C51: '
        '${_psftp51 != null ? "ENCONTRADA" : "NO ENCONTRADA"}',
      );

      debugPrint(
        '[PSFTP] FB005C52: '
        '${_psftp52 != null ? "ENCONTRADA" : "NO ENCONTRADA"}',
      );

      debugPrint(
        '[PSFTP] FB005C53: '
        '${_psftp53 != null ? "ENCONTRADA" : "NO ENCONTRADA"}',
      );

      if (_psftp51 != null) {
        debugPrint(
          '[PSFTP] 51 properties: '
          '${_psftp51!.properties.map((p) => p.toString()).join(", ")}',
        );
      }

      if (_psftp52 != null) {
        debugPrint(
          '[PSFTP] 52 properties: '
          '${_psftp52!.properties.map((p) => p.toString()).join(", ")}',
        );
      }

      if (_psftp53 != null) {
        debugPrint(
          '[PSFTP] 53 properties: '
          '${_psftp53!.properties.map((p) => p.toString()).join(", ")}',
        );
      }

      await _setupPsftpNotifications();

      final state =
          await device.connectionState;

      if (state !=
          BleConnectionState.connected) {
        throw Exception(
          'Dispositivo no conectado: $state',
        );
      }

      // -----------------------------------------------------------------------
      // HR
      // -----------------------------------------------------------------------

      await _setupHeartRate(device);

      // -----------------------------------------------------------------------
      // PMD
      // -----------------------------------------------------------------------

      await _setupPmd(device);

      // -----------------------------------------------------------------------
      // ACCELEROMETER
      // -----------------------------------------------------------------------

      await startAcceleration();

      return true;
    } catch (e, stack) {
      debugPrint(
        '[POLAR DEBUG] Error conectando: $e',
      );

      debugPrint(
        '[POLAR DEBUG] $stack',
      );

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

    _hrCharacteristic =
        characteristic;

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
          '[POLAR DEBUG] ERROR PMD DATA: $error',
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

    await _pmdControlSubscription?.cancel();

    _pmdControlSubscription =
        _pmdControlPoint!
            .onValueReceived
            .listen(
      (value) {
        _handlePmdControlResponse(value);
      },
      onError: (error, stack) {
        debugPrint(
          '[POLAR DEBUG] ERROR PMD CONTROL: $error',
        );

        _completePendingPmdResponse(
          error: error,
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
  // SET UP PSFTP NOTIFICATIONS
  // ===========================================================================

  Future<void> _setupPsftpNotifications() async {
    // -------------------------------------------------------------------------
    // PSFTP 51
    // -------------------------------------------------------------------------

    if (_psftp51 != null) {
      try {
        await _psftp51Subscription?.cancel();

        _psftp51Subscription =
            _psftp51!.onValueReceived.listen(
          (value) {
            debugPrint(
              '[PSFTP RX 51] ${_hex(value)}',
            );
          },
        );

        if (_psftp51!
            .notifications.isSupported) {
          await _psftp51!
              .notifications
              .subscribe();

          debugPrint(
            '[PSFTP] FB005C51 SUSCRITA',
          );
        }
      } catch (e) {
        debugPrint(
          '[PSFTP] Error configurando 51: $e',
        );
      }
    }

    // -------------------------------------------------------------------------
    // PSFTP 52
    // -------------------------------------------------------------------------

    if (_psftp52 != null) {
      try {
        await _psftp52Subscription?.cancel();

        _psftp52Subscription =
            _psftp52!.onValueReceived.listen(
          (value) {
            debugPrint(
              '[PSFTP RX 52] ${_hex(value)}',
            );
          },
        );

        if (_psftp52!
            .notifications.isSupported) {
          await _psftp52!
              .notifications
              .subscribe();

          debugPrint(
            '[PSFTP] FB005C52 SUSCRITA',
          );
        }
      } catch (e) {
        debugPrint(
          '[PSFTP] Error configurando 52: $e',
        );
      }
    }

    // -------------------------------------------------------------------------
    // PSFTP 53
    // -------------------------------------------------------------------------

    if (_psftp53 != null) {
      try {
        await _psftp53Subscription?.cancel();

        _psftp53Subscription =
            _psftp53!.onValueReceived.listen(
          (value) {
            debugPrint(
              '[PSFTP RX 53] ${_hex(value)}',
            );
          },
        );

        if (_psftp53!
            .notifications.isSupported) {
          await _psftp53!
              .notifications
              .subscribe();

          debugPrint(
            '[PSFTP] FB005C53 SUSCRITA',
          );
        }
      } catch (e) {
        debugPrint(
          '[PSFTP] Error configurando 53: $e',
        );
      }
    }
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

    final command =
        Uint8List.fromList([
      0x02,
      pmdTypeEcg,
      0x00,
      0x01,
      0x82,
      0x00,
      0x01,
      0x01,
      0x0E,
      0x00,
    ]);

    final response =
        await _sendPmdCommandAndWaitForResponse(
      command,
      expectedOpcode: pmdOpStartMeasurement,
      expectedMeasurementType: pmdTypeEcg,
    );

    if (!response.isSuccess) {
      throw Exception(
        'ECG START rechazado por PMD: '
        '${response.errorCode}',
      );
    }

    _ecgStreaming = true;

    debugPrint(
      '[POLAR DEBUG] ECG START aceptado por PMD',
    );
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

    final command =
        Uint8List.fromList([
      0x02,
      pmdTypeAcc,
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

    debugPrint(
      '[POLAR DEBUG] ACC START TX: '
      '${_hex(command)}',
    );

    final response =
        await _sendPmdCommandAndWaitForResponse(
      command,
      expectedOpcode: pmdOpStartMeasurement,
      expectedMeasurementType: pmdTypeAcc,
    );

    debugPrint(
      '[POLAR DEBUG] ACC START RESPONSE PAYLOAD: '
      '${_hex(response.payload)}',
    );

    if (!response.isSuccess) {
      throw Exception(
        'ACC START rechazado por PMD: '
        '${response.errorCode}',
      );
    }

    // The requested configuration is 200 Hz. If the start response contains
    // a PMD sample-rate setting, _updatePmdSettingsFromResponse() may replace
    // this with the actual value reported by the sensor.
    _updatePmdSettingsFromResponse(
      response.payload,
      measurementType: pmdTypeAcc,
    );

    _resetPmdTimingState();

    _accStreaming = true;

    debugPrint(
      '[POLAR DEBUG] ACC START aceptado por PMD; '
      'sampleRate=$_accSampleRateHz Hz; '
      'factor=$_accFactor',
    );
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

    try {
      final response =
          await _sendPmdCommandAndWaitForResponse(
        command,
        expectedOpcode: pmdOpStopMeasurement,
        expectedMeasurementType: pmdTypeEcg,
      );

      if (!response.isSuccess) {
        debugPrint(
          '[POLAR DEBUG] ECG STOP rechazado: '
          '${response.errorCode}',
        );
      }
    } finally {
      _ecgStreaming = false;
      _removePmdTimingKeys(
        measurementType: pmdTypeEcg,
      );
    }
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

    try {
      final response =
          await _sendPmdCommandAndWaitForResponse(
        command,
        expectedOpcode: pmdOpStopMeasurement,
        expectedMeasurementType: pmdTypeAcc,
      );

      if (!response.isSuccess) {
        debugPrint(
          '[POLAR DEBUG] ACC STOP rechazado: '
          '${response.errorCode}',
        );
      }
    } finally {
      _accStreaming = false;
      _removePmdTimingKeys(
        measurementType: pmdTypeAcc,
      );
      _lastAccSampleTimestampNs = null;
    }
  }

  // ===========================================================================
  // PMD CONTROL COMMAND
  // ===========================================================================

  Future<_PmdControlResponse>
      _sendPmdCommandAndWaitForResponse(
    Uint8List command, {
    required int expectedOpcode,
    required int expectedMeasurementType,
  }) async {
    final controlPoint =
        _pmdControlPoint;

    if (controlPoint == null) {
      throw Exception(
        'PMD Control Point no disponible',
      );
    }

    if (_pendingPmdResponse != null) {
      throw StateError(
        'Ya existe una petición PMD pendiente',
      );
    }

    final completer =
        Completer<_PmdControlResponse>();

    _pendingPmdResponse = completer;

    try {
      await controlPoint.write(
        command,
        withResponse: true,
        timeout: const Duration(seconds: 30),
      );

      // Important:
      //
      // write() only confirms that the BLE write completed. It does NOT by
      // itself prove that PMD accepted the command.
      //
      // We therefore wait for the PMD Control Point indication.
      final response =
          await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw TimeoutException(
            'Timeout esperando respuesta PMD '
            'opcode=0x${expectedOpcode.toRadixString(16)} '
            'measurementType=0x'
            '${expectedMeasurementType.toRadixString(16)}',
          );
        },
      );

      if (response.opcode != expectedOpcode ||
          response.measurementType !=
              expectedMeasurementType) {
        throw StateError(
          'Respuesta PMD inesperada: '
          '${_hex(response.raw)}',
        );
      }

      return response;
    } finally {
      if (identical(
        _pendingPmdResponse,
        completer,
      )) {
        _pendingPmdResponse = null;
      }
    }
  }

  // ===========================================================================
  // PMD CONTROL RESPONSE
  // ===========================================================================

  void _handlePmdControlResponse(
    Uint8List data,
  ) {
    if (data.isEmpty) {
      return;
    }

    if (debugPmdFrames) {
      debugPrint(
        '[POLAR DEBUG] PMD CONTROL RESPONSE: '
        '${_hex(data)}',
      );
    }

    final response =
        _parsePmdControlResponse(data);

    if (response == null) {
      debugPrint(
        '[POLAR DEBUG] PMD Control response inválida: '
        '${_hex(data)}',
      );
      return;
    }

    if (response.errorCode != 0) {
      debugPrint(
        '[POLAR DEBUG] PMD command rechazado: '
        'opcode=0x'
        '${response.opcode.toRadixString(16)} '
        'measurement=0x'
        '${response.measurementType.toRadixString(16)} '
        'error=${response.errorCode}',
      );
    } else {
      debugPrint(
        '[POLAR DEBUG] PMD command OK: '
        'opcode=0x'
        '${response.opcode.toRadixString(16)} '
        'measurement=0x'
        '${response.measurementType.toRadixString(16)}',
      );
    }

    _completePendingPmdResponse(
      response: response,
    );
  }

  _PmdControlResponse?
      _parsePmdControlResponse(
    Uint8List data,
  ) {
    // Standard PMD response:
    //
    // byte 0 = 0xF0
    // byte 1 = response opcode
    // byte 2 = measurement type
    // byte 3 = error code
    // byte 4.. = optional response payload/settings

    if (data.length < 4) {
      return null;
    }

    if (data[0] != pmdResponse) {
      return null;
    }

    return _PmdControlResponse(
      raw: Uint8List.fromList(data),
      opcode: data[1],
      measurementType: data[2] & 0x3F,
      errorCode: data[3],
      payload: data.length > 4
          ? Uint8List.fromList(
              data.sublist(4),
            )
          : Uint8List(0),
    );
  }

  void _completePendingPmdResponse({
    _PmdControlResponse? response,
    Object? error,
  }) {
    final completer =
        _pendingPmdResponse;

    if (completer == null ||
        completer.isCompleted) {
      return;
    }

    if (error != null) {
      completer.completeError(error);
    } else if (response != null) {
      completer.complete(response);
    }
  }

  // ===========================================================================
  // UPDATE PMD SETTINGS FROM START RESPONSE
  // ===========================================================================

  void _updatePmdSettingsFromResponse(
    Uint8List payload, {
    required int measurementType,
  }) {
    if (payload.isEmpty) {
      return;
    }

    try {
      final settings =
          _parsePmdSettings(payload);

      final sampleRate =
          settings[pmdSettingSampleRate];

      if (sampleRate != null) {
        if (measurementType == pmdTypeAcc &&
            sampleRate > 0) {
          _accSampleRateHz =
              sampleRate;

          debugPrint(
            '[POLAR DEBUG] PMD ACC sample rate '
            'reported by sensor: '
            '$_accSampleRateHz Hz',
          );
        }
      }

      final factor =
          settings[pmdSettingFactor];

      if (factor != null) {
        _accFactor =
            _uint32ToDouble(factor);

        debugPrint(
          '[POLAR DEBUG] PMD ACC factor '
          'reported by sensor: '
          '$_accFactor',
        );
      }
    } catch (e) {
      debugPrint(
        '[POLAR DEBUG] Error parsing PMD settings '
        'from response: $e',
      );
    }
  }

  // ===========================================================================
  // PMD SETTINGS PARSER
  // ===========================================================================

  Map<int, int> _parsePmdSettings(
    Uint8List data,
  ) {
    final result = <int, int>{};

    int offset = 0;

    while (offset + 2 <= data.length) {
      final settingType =
          data[offset];

      final count =
          data[offset + 1];

      offset += 2;

      final fieldSize =
          _pmdSettingFieldSize(
        settingType,
      );

      if (fieldSize <= 0) {
        // Unknown setting type.
        //
        // We cannot safely advance without knowing its width.
        break;
      }

      if (count <= 0) {
        continue;
      }

      for (int i = 0; i < count; i++) {
        if (offset + fieldSize >
            data.length) {
          throw StateError(
            'Truncated PMD setting '
            'type=$settingType',
          );
        }

        final value =
            _readUnsignedLittleEndian(
          data,
          offset,
          fieldSize,
        );

        // Polar's PmdSetting.selected keeps one selected value for each
        // setting type. For our purposes the first value is sufficient.
        result.putIfAbsent(
          settingType,
          () => value,
        );

        offset += fieldSize;
      }
    }

    return result;
  }

  static int _pmdSettingFieldSize(
    int settingType,
  ) {
    switch (settingType) {
      case pmdSettingSampleRate:
        return 2;

      case pmdSettingResolution:
        return 2;

      case pmdSettingRange:
        return 2;

      case pmdSettingRangeMilliUnit:
        return 4;

      case pmdSettingChannels:
        return 1;

      case pmdSettingFactor:
        return 4;

      default:
        return 0;
    }
  }

  static double _uint32ToDouble(
    int value,
  ) {
    final bytes = ByteData(4)
      ..setUint32(
        0,
        value,
        Endian.little,
      );

    return bytes.getFloat32(
      0,
      Endian.little,
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

    if (debugPmdFrames) {
      debugPrint(
        '[POLAR DEBUG] PMD DATA RX: '
        '${_hex(data)}',
      );
    }

    // PMD measurement type occupies the lower 6 bits.
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
        break;
    }
  }

  // ===========================================================================
  // ECG FRAME
  // ===========================================================================

  void _parseEcgFrame(
    Uint8List data,
  ) {
    if (data.length < 13) {
      debugPrint(
        '[POLAR DEBUG] ECG frame demasiado corto: '
        '${data.length} bytes',
      );
      return;
    }

    // PMD header:
    //
    // byte 0      = measurement type
    // bytes 1..8  = frame timestamp (uint64 LE)
    // byte 9      = frame type
    // bytes 10..  = samples

    final timestampNs =
        _readUint64LittleEndian(
      data,
      1,
    );

    final frameTypeByte =
        data[9];

    final isCompressed =
        (frameTypeByte & 0x80) != 0;

    final frameType =
        frameTypeByte & 0x7F;

    if (isCompressed) {
      debugPrint(
        '[POLAR DEBUG] ECG compressed frame recibido; '
        'ECG delta no está soportado por PMD',
      );
      return;
    }

    if (frameType != 0) {
      debugPrint(
        '[POLAR DEBUG] ECG frame type no soportado: '
        '$frameType',
      );
      return;
    }

    const bytesPerSample = 3;

    final payloadLength =
        data.length - 10;

    if (payloadLength <= 0 ||
        payloadLength % bytesPerSample != 0) {
      debugPrint(
        '[POLAR DEBUG] ECG payload inválido: '
        '$payloadLength bytes',
      );
      return;
    }

    final sampleCount =
        payloadLength ~/ bytesPerSample;

    if (sampleCount <= 0) {
      return;
    }

    final timestampKey =
        _pmdTimestampKey(
      measurementType: pmdTypeEcg,
      compressed: false,
      frameType: frameType,
    );

    final previousTimestamp =
        _lastPmdFrameTimestampNs[
            timestampKey];

    final timestamps =
        _buildPmdTimestamps(
      timestampNs: timestampNs,
      previousTimestampNs:
          previousTimestamp,
      sampleCount: sampleCount,
      sampleRateHz:
          ecgSampleRateHz,
    );

    _lastPmdFrameTimestampNs[
        timestampKey] =
        timestampNs;

    int offset = 10;

    for (int i = 0;
        i < sampleCount;
        i++) {
      final rawUv =
          _readSigned24LittleEndian(
        data,
        offset,
      );

      final sample =
          PolarEcgSample(
        timestamp:
            _convertPmdTimestampToHostUtc(
          timestamps[i],
        ),
        participantId:
            currentParticipantId,
        activityIndex:
            currentActivityIndex,
        phaseName:
            currentPhaseName,
        microVolts:
            rawUv,
      );

      recordedEcgSamples.add(
        sample,
      );

      if (!_ecgStreamController.isClosed) {
        _ecgStreamController.add(
          sample,
        );
      }

      final nowMs =
          DateTime.now()
              .millisecondsSinceEpoch;

      if (nowMs -
              _lastEcgUiEmitMillis >=
          100) {
        _lastEcgUiEmitMillis =
            nowMs;

        if (!_ecgUiStreamController
            .isClosed) {
          _ecgUiStreamController
              .add(sample);
        }
      }

      offset +=
          bytesPerSample;
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
        '[POLAR DEBUG] ACC frame demasiado corto: '
        '${data.length} bytes',
      );
      return;
    }

    final timestampNs =
        _readUint64LittleEndian(
      data,
      1,
    );

    final frameTypeByte =
        data[9];

    final isCompressed =
        (frameTypeByte & 0x80) != 0;

    final frameType =
        frameTypeByte & 0x7F;

    if (debugPmdFrames) {
      debugPrint(
        '[POLAR DEBUG] ACC frame: '
        'timestamp=$timestampNs '
        'frameType=$frameType '
        'compressed=$isCompressed '
        'payload=${data.length - 10} bytes',
      );
    }

    if (isCompressed) {
      _parseAccelerationDeltaFrame(
        data,
        timestampNs,
        frameType,
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
        debugPrint(
          '[POLAR DEBUG] ACC raw frame type no soportado: '
          '$frameType',
        );
        return;
    }

    final bytesPerSample =
        bytesPerAxis * 3;

    final payloadLength =
        data.length - 10;

    if (payloadLength <= 0 ||
        payloadLength % bytesPerSample != 0) {
      debugPrint(
        '[POLAR DEBUG] ACC raw payload inválido: '
        '$payloadLength bytes; '
        'bytes/sample=$bytesPerSample',
      );
      return;
    }

    final sampleCount =
        payloadLength ~/ bytesPerSample;

    if (sampleCount <= 0) {
      return;
    }

    final timestampKey =
        _pmdTimestampKey(
      measurementType: pmdTypeAcc,
      compressed: false,
      frameType: frameType,
    );

    final previousTimestamp =
        _lastPmdFrameTimestampNs[
            timestampKey];

    final timestamps =
        _buildPmdTimestamps(
      timestampNs: timestampNs,
      previousTimestampNs:
          previousTimestamp,
      sampleCount: sampleCount,
      sampleRateHz:
          _accSampleRateHz,
    );

    _lastPmdFrameTimestampNs[
        timestampKey] =
        timestampNs;

    int offset = 10;

    for (int i = 0;
        i < sampleCount;
        i++) {
      final int x;
      final int y;
      final int z;

      switch (bytesPerAxis) {
        case 1:
          x = _readSigned8(
            data,
            offset,
          );

          y = _readSigned8(
            data,
            offset + 1,
          );

          z = _readSigned8(
            data,
            offset + 2,
          );
          break;

        case 2:
          x =
              _readSigned16LittleEndian(
            data,
            offset,
          );

          y =
              _readSigned16LittleEndian(
            data,
            offset + 2,
          );

          z =
              _readSigned16LittleEndian(
            data,
            offset + 4,
          );
          break;

        case 3:
          x =
              _readSigned24LittleEndian(
            data,
            offset,
          );

          y =
              _readSigned24LittleEndian(
            data,
            offset + 3,
          );

          z =
              _readSigned24LittleEndian(
            data,
            offset + 6,
          );
          break;

        default:
          return;
      }

      // Raw frames are kept as the values represented by the PMD raw frame.
      //
      // We intentionally do NOT apply the compressed-frame factor here.
      _emitAccelerationSampleDirect(
        sampleNs: timestamps[i],
        xMg:
            _convertRawAccelerationToMg(
          x,
          frameType,
        ),
        yMg:
            _convertRawAccelerationToMg(
          y,
          frameType,
        ),
        zMg:
            _convertRawAccelerationToMg(
          z,
          frameType,
        ),
      );

      offset +=
          bytesPerSample;
    }
  }

  double _convertRawAccelerationToMg(
    int value,
    int frameType,
  ) {
    // For uncompressed PMD ACC frames, Polar's decoder exposes the raw
    // representation according to the frame type rather than applying the
    // compressed factor transformation.
    //
    // Keep the current CSV/API semantics unchanged here.
    return value.toDouble();
  }

  // ===========================================================================
  // ACC DELTA FRAME
  // ===========================================================================

  void _parseAccelerationDeltaFrame(
    Uint8List data,
    int timestampNs,
    int frameType,
  ) {
    // Polar's official ACC decoder supports compressed TYPE_0 and TYPE_1.
    //
    // ACC compressed data uses:
    //
    //   channels   = 3
    //   resolution = 16 bits
    //
    // The dataContent starts immediately after the PMD 10-byte header:
    //
    //   reference sample:
    //       X = 16-bit signed LE
    //       Y = 16-bit signed LE
    //       Z = 16-bit signed LE
    //
    //   followed by one or more delta blocks:
    //
    //       deltaSize   : 1 byte
    //       sampleCount : 1 byte
    //       deltas      : bit-packed signed values
    //
    // This follows Polar's:
    //
    //   Pmd.parseDeltaFramesToSamples(
    //       data,
    //       channels: 3,
    //       resolution: 16
    //   )
    //
    // and AccData.dataFromCompressedType0 / Type1.

    if (frameType != 0 &&
        frameType != 1) {
      debugPrint(
        '[POLAR DEBUG] ACC compressed frame type '
        'no soportado: $frameType',
      );
      return;
    }

    const int channels = 3;
    const int resolutionBits = 16;

    if (data.length <= 10) {
      debugPrint(
        '[POLAR DEBUG] ACC compressed frame sin dataContent',
      );
      return;
    }

    final dataContent =
        Uint8List.fromList(
      data.sublist(10),
    );

    final samples =
        _parsePolarDeltaFramesToSamples(
      dataContent,
      channels: channels,
      resolution: resolutionBits,
    );

    if (samples.isEmpty) {
      return;
    }

    // -------------------------------------------------------------------------
    // Timestamp reconstruction
    // -------------------------------------------------------------------------
    //
    // Polar passes:
    //
    //   previousFrameTimeStamp
    //   frameTimeStamp
    //   samples.count
    //   sampleRate
    //
    // to PmdTimeStampUtils.getTimeStamps().
    //
    // We reproduce that logic here through the existing timestamp helper.
    final timestampKey =
        _pmdTimestampKey(
      measurementType: pmdTypeAcc,
      compressed: true,
      frameType: frameType,
    );

    final previousTimestamp =
        _lastPmdFrameTimestampNs[
            timestampKey];

    final timestamps =
        _buildPmdTimestamps(
      timestampNs: timestampNs,
      previousTimestampNs:
          previousTimestamp,
      sampleCount: samples.length,
      sampleRateHz:
          _accSampleRateHz,
    );

    _lastPmdFrameTimestampNs[
        timestampKey] = timestampNs;

    // -------------------------------------------------------------------------
    // Unit conversion
    // -------------------------------------------------------------------------
    //
    // Polar's official ACC TYPE_0 decoder:
    //
    //     accFactor = frame.factor * 1000
    //     x = Int32(Float(sample[0]) * accFactor)
    //
    // i.e. the compressed TYPE_0 values are in G and are converted to milli-G.
    //
    // TYPE_1 uses the factor only when factor != 1.0.
    //
    // Preserve the same semantics here.

    final double conversionFactor;

    if (frameType == 0) {
      conversionFactor =
          _accFactor * 1000.0;
    } else {
      conversionFactor =
          _accFactor != 1.0
              ? _accFactor
              : 1.0;
    }

    for (int i = 0;
        i < samples.length;
        i++) {
      final sample =
          samples[i];

      final double xMg =
          sample[0] *
              conversionFactor;

      final double yMg =
          sample[1] *
              conversionFactor;

      final double zMg =
          sample[2] *
              conversionFactor;

      if (debugPmdFrames &&
          i == 0) {
        debugPrint(
          '[ACC DEBUG] Polar delta decode: '
          'frameType=$frameType '
          'samples=${samples.length} '
          'rawFirst=('
          '${sample[0]}, '
          '${sample[1]}, '
          '${sample[2]}'
          ') '
          'factor=$_accFactor '
          'convertedFirst=('
          '$xMg, '
          '$yMg, '
          '$zMg'
          ')',
        );
      }

      _emitAccelerationSampleDirect(
        sampleNs:
            timestamps[i],
        xMg: xMg,
        yMg: yMg,
        zMg: zMg,
      );
    }
  }

  // ===========================================================================
  // POLAR DELTA FRAME DECODER
  // ===========================================================================
  //
  // Direct Dart equivalent of Polar's:
  //
  //   Pmd.parseDeltaFramesToSamples()
  //
  // The important point is that this function does NOT assume that there is
  // exactly one delta block per BLE frame. Polar iterates until all dataContent
  // has been consumed.
  //

  List<List<int>>
      _parsePolarDeltaFramesToSamples(
    Uint8List data, {
    required int channels,
    required int resolution,
  }) {
    if (channels <= 0 ||
        resolution <= 0) {
      debugPrint(
        '[POLAR DEBUG] Invalid delta decoder configuration: '
        'channels=$channels resolution=$resolution',
      );
      return const [];
    }

    // Polar:
    //
    // resolutionInBytes =
    //     ceil(resolution / 8)
    //
    // requiredBytes =
    //     resolutionInBytes * channels
    //
    final resolutionInBytes =
        (resolution + 7) ~/ 8;

    final referenceBytes =
        resolutionInBytes *
            channels;

    if (data.length <
        referenceBytes) {
      debugPrint(
        '[POLAR DEBUG] ACC delta frame too short for '
        'reference sample: '
        'required=$referenceBytes '
        'available=${data.length}',
      );
      return const [];
    }

    // -------------------------------------------------------------------------
    // Reference sample
    // -------------------------------------------------------------------------
    //
    // Polar's parseDeltaFrameRefSamples() reads one signed integer for each
    // channel using resolutionInBytes bytes.
    //
    // For ACC:
    //
    //   resolution = 16
    //   channels   = 3
    //
    // therefore:
    //
    //   X = bytes 0..1
    //   Y = bytes 2..3
    //   Z = bytes 4..5
    //
    final reference =
        <int>[];

    for (int channel = 0;
        channel < channels;
        channel++) {
      final offset =
          channel *
              resolutionInBytes;

      reference.add(
        _readSignedLittleEndian(
          data,
          offset,
          resolutionInBytes,
        ),
      );
    }

    final samples =
        <List<int>>[
      reference,
    ];

    int offset =
        referenceBytes;

    // -------------------------------------------------------------------------
    // Delta blocks
    // -------------------------------------------------------------------------
    //
    // Each block is:
    //
    //   byte 0 = deltaSize
    //   byte 1 = sampleCount
    //   remaining = sampleCount * deltaSize * channels bits
    //
    while (offset <
        data.length) {
      // Polar explicitly checks for a complete 2-byte block header.
      if (offset + 2 >
          data.length) {
        debugPrint(
          '[POLAR DEBUG] ACC delta header truncado: '
          'offset=$offset',
        );

        // Polar returns the samples decoded so far.
        return samples;
      }

      final deltaSize =
          data[offset];

      offset++;

      final sampleCount =
          data[offset];

      offset++;

      // Polar explicitly guards deltaSize == 0.
      if (deltaSize == 0) {
        debugPrint(
          '[POLAR DEBUG] ACC deltaSize=0; '
          'bloque ignorado',
        );

        continue;
      }

      if (sampleCount == 0) {
        continue;
      }

      // This is the exact bit length used by Polar:
      //
      //   sampleCount * deltaSize * channels
      //
      final totalBitLength =
          sampleCount *
              deltaSize *
              channels;

      final payloadLength =
          (totalBitLength + 7) ~/ 8;

      if (offset +
              payloadLength >
          data.length) {
        debugPrint(
          '[POLAR DEBUG] ACC delta payload truncado: '
          'offset=$offset '
          'needed=$payloadLength '
          'available=${data.length - offset}',
        );

        // Same effective behaviour as the official decoder:
        // return samples decoded before the malformed/truncated block.
        return samples;
      }

      final reader =
          _PolarBitReader(
        data,
        offset,
      );

      // -----------------------------------------------------------------------
      // Decode every delta sample in this block.
      // -----------------------------------------------------------------------

      for (int sampleIndex = 0;
          sampleIndex < sampleCount;
          sampleIndex++) {
        final delta =
            <int>[];

        for (int channel = 0;
            channel < channels;
            channel++) {
          delta.add(
            _readPolarSignedBits(
              reader,
              deltaSize,
            ),
          );
        }

        final previous =
            samples.last;

        final next =
            <int>[];

        bool overflow = false;

        for (int channel = 0;
            channel < channels;
            channel++) {
          final sum =
              _addInt32WithOverflow(
            previous[channel],
            delta[channel],
          );

          if (sum == null) {
            overflow = true;
            break;
          }

          next.add(sum);
        }

        // Polar uses addingReportingOverflow().
        //
        // If an overflow occurs, that reconstructed sample is not appended.
        if (!overflow &&
            next.length ==
                channels) {
          samples.add(next);
        }
      }

      offset +=
          payloadLength;
    }

    return samples;
  }

  // ===========================================================================
  // SIGNED LITTLE-ENDIAN READER
  // ===========================================================================
  //
  // Equivalent to Polar's arrayToInt() for the reference sample.
  //
  // Polar reads resolutionInBytes bytes and sign-extends according to the
  // number of bytes.
  //

  int _readSignedLittleEndian(
    Uint8List data,
    int offset,
    int byteCount,
  ) {
    int value = 0;

    for (int i = 0;
        i < byteCount;
        i++) {
      value |=
          data[offset + i]
              << (8 * i);
    }

    final signBit =
        1 <<
            (byteCount * 8 - 1);

    if ((value & signBit) !=
        0) {
      value -=
          1 <<
              (byteCount * 8);
    }

    return value;
  }

  // ===========================================================================
  // POLAR SIGNED DELTA
  // ===========================================================================
  //
  // Direct equivalent of Polar:
  //
  //   let mask = Int32.max << Int32(bitWidth - 1)
  //
  //   if (sample & mask) != 0 {
  //       sample |= mask
  //   }
  //
  //   return sample
  //
  // This is sign extension from the actual delta bit width.
  //

  int _readPolarSignedBits(
    _PolarBitReader reader,
    int bitWidth,
  ) {
    if (bitWidth <= 0 ||
        bitWidth > 32) {
      throw ArgumentError(
        'Invalid Polar delta bit width: '
        '$bitWidth',
      );
    }

    final unsignedValue =
        reader.readBits(
      bitWidth,
    );

    // Equivalent to:
    //
    //   Int32.max << (bitWidth - 1)
    //
    // but expressed in a way that is easier to reason about in Dart.

    final signBit =
        1 <<
            (bitWidth - 1);

    if ((unsignedValue &
            signBit) ==
        0) {
      return unsignedValue;
    }

    // Two's complement sign extension.
    return unsignedValue -
        (1 << bitWidth);
  }

  // ===========================================================================
  // INT32 ADDITION WITH OVERFLOW
  // ===========================================================================
  //
  // Equivalent to Swift's:
  //
  //   last[i].addingReportingOverflow(delta[i])
  //
  // Dart integers themselves do not overflow like Int32, so we explicitly
  // reproduce the Int32 range check.
  //

  int? _addInt32WithOverflow(
    int a,
    int b,
  ) {
    final sum =
        a + b;

    if (sum <
            -2147483648 ||
        sum >
            2147483647) {
      return null;
    }

    return sum;
  }

  // ===========================================================================
  // PMD TIMESTAMP RECONSTRUCTION
  // ===========================================================================

  List<int> _buildPmdTimestamps({
    required int timestampNs,
    required int? previousTimestampNs,
    required int sampleCount,
    required int sampleRateHz,
  }) {
    if (sampleCount <= 0 || sampleRateHz <= 0) {
      return const [];
    }

    final samplePeriodNs =
        (1000000000.0 / sampleRateHz);

    // -------------------------------------------------------------------------
    // First frame
    // -------------------------------------------------------------------------
    //
    // With no previous frame timestamp, the frame timestamp corresponds to the
    // end of the sample block. Reconstruct backwards from that timestamp.
    //
    // This is also the only safe fallback when starting a stream.
    //
    if (previousTimestampNs == null ||
        previousTimestampNs <= 0) {
      final firstTimestamp =
          timestampNs -
              (sampleCount - 1) *
                  samplePeriodNs;

      return List<int>.generate(
        sampleCount,
        (index) =>
            (firstTimestamp +
                    index * samplePeriodNs)
                .round(),
      );
    }

    // -------------------------------------------------------------------------
    // Consecutive frames
    // -------------------------------------------------------------------------
    //
    // Polar's PMD timestamp utility uses the frame timestamps as the temporal
    // anchors and the configured sample rate to reconstruct individual sample
    // timestamps.
    //
    // We deliberately do NOT derive the sample interval from:
    //
    //     (timestampNs - previousTimestampNs) / sampleCount
    //
    // because BLE notification timing and frame boundaries are not a substitute
    // for the sensor sample clock.
    //
    // The sample period therefore remains determined by the PMD sample rate.
    //
    final timestamps =
        List<int>.generate(
      sampleCount,
      (index) =>
          timestampNs -
          ((sampleCount - 1 - index) *
                  samplePeriodNs)
              .round(),
    );

    // -------------------------------------------------------------------------
    // Continuity check
    // -------------------------------------------------------------------------
    //
    // This is diagnostic only. We do not modify Polar timestamps merely because
    // a frame arrives with a gap.
    //
    final expectedFirstTimestamp =
        previousTimestampNs +
            samplePeriodNs.round();

    final actualFirstTimestamp =
        timestamps.first;

    final error =
        actualFirstTimestamp -
            expectedFirstTimestamp;

    // Small differences are normal because timestamps are integer nanoseconds.
    // A larger difference indicates a genuine discontinuity / dropped data /
    // sensor-side timing event and should be visible during development.
    if (error.abs() >
        (samplePeriodNs * 2).round()) {
      if (debugPmdFrames) {
        debugPrint(
          '[POLAR DEBUG] PMD timestamp discontinuity: '
          'previous=$previousTimestampNs '
          'expectedFirst=$expectedFirstTimestamp '
          'actualFirst=$actualFirstTimestamp '
          'error=${error}ns',
        );
      }
    }

    return timestamps;
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
    if (_lastAccSampleTimestampNs !=
        null) {
      final deltaNs =
          sampleNs -
              _lastAccSampleTimestampNs!;

      // Alert on unexpectedly large timestamp gaps.
      //
      // This does NOT necessarily mean that BLE packets were lost. A gap may
      // also reflect sensor-side timing, frame changes, notification delays,
      // or another timestamp discontinuity.
      if (deltaNs >
              50000000 ||
          deltaNs < 0) {
        debugPrint(
          '[POLAR ALERTA] ACC timestamp gap: '
          'salto de '
          '${deltaNs ~/ 1000000} ms',
        );
      }
    }

    _lastAccSampleTimestampNs =
        sampleNs;

    final sampleTime =
        _convertPmdTimestampToHostUtc(
      sampleNs,
    );

    final sample =
        PolarAccelerationSample(
      timestamp:
          sampleTime,
      participantId:
          currentParticipantId,
      activityIndex:
          currentActivityIndex,
      phaseName:
          currentPhaseName,
      xMg: xMg,
      yMg: yMg,
      zMg: zMg,
    );

    recordedAccelerationSamples.add(
      sample,
    );

    if (!_accStreamController.isClosed) {
      _accStreamController.add(
        sample,
      );
    }

    final nowMs =
        DateTime.now()
            .millisecondsSinceEpoch;

    if (nowMs -
            _lastUiEmitMillis >=
        100) {
      _lastUiEmitMillis =
          nowMs;

      if (!_accUiStreamController
          .isClosed) {
        _accUiStreamController.add(
          sample,
        );
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
          ByteData.sublistView(
        data,
      );

      final flags =
          byteData.getUint8(0);

      final is16Bit =
          (flags & 0x01) != 0;

      final hasEnergyExpended =
          (flags & 0x08) != 0;

      final hasRr =
          (flags & 0x10) != 0;

      int offset = 1;

      if (offset >=
          data.length) {
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
        if (offset + 1 >=
            data.length) {
          return;
        }

        offset += 2;
      }

      final rrList =
          <int>[];

      if (hasRr) {
        while (offset + 1 <
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

          rrList.add(
            rrMs,
          );

          offset += 2;
        }
      }

      currentHeartRate =
          bpm;

      currentRrIntervals =
          rrList;

      if (!_hrStreamController.isClosed) {
        _hrStreamController.add(
          bpm,
        );
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
    if (!isConnected ||
        currentHeartRate == 0) {
      return;
    }

    recordedSamples.add(
      PolarHrSample(
        timestamp:
            DateTime.now().toUtc(),
        participantId:
            participantId,
        activityIndex:
            activityIndex,
        phaseName:
            phaseName,
        heartRateBpm:
            currentHeartRate,
        rrIntervalsMs:
            List.from(
          currentRrIntervals,
        ),
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
    final buffer =
        StringBuffer();

    buffer.writeln(
      PolarAccelerationSample
          .csvHeader,
    );

    for (final sample
        in recordedAccelerationSamples) {
      buffer.writeln(
        sample.toCsvRow(),
      );
    }

    return buffer.toString();
  }

  // ===========================================================================
  // CSV ECG
  // ===========================================================================

  String exportEcgCsv() {
    final buffer =
        StringBuffer();

    buffer.writeln(
      PolarEcgSample.csvHeader,
    );

    for (final sample
        in recordedEcgSamples) {
      buffer.writeln(
        sample.toCsvRow(),
      );
    }

    return buffer.toString();
  }

  // ===========================================================================
  // REMOVE TIMESTAMP KEYS
  // ===========================================================================

  void _removePmdTimingKeys({
    required int measurementType,
  }) {
    _lastPmdFrameTimestampNs
        .removeWhere(
      (key, value) =>
          key.startsWith(
        '${measurementType}_',
      ),
    );
  }

  // ===========================================================================
  // DISCONNECT
  // ===========================================================================

  Future<void> disconnect() async {
    final device =
        _connectedDevice;

    if (device == null) {
      // Still clean up subscriptions in case the connection disappeared
      // before the normal disconnect path completed.
      await _cancelAllSubscriptions();
      _resetConnectionState();
      return;
    }

    debugPrint(
      '[POLAR DEBUG] Desconectando '
      '${device.deviceId}...',
    );

    // -------------------------------------------------------------------------
    // Stop active PMD measurements first.
    // -------------------------------------------------------------------------

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

    // -------------------------------------------------------------------------
    // Cancel subscriptions.
    // -------------------------------------------------------------------------

    await _cancelAllSubscriptions();

    // -------------------------------------------------------------------------
    // Unsubscribe characteristics.
    // -------------------------------------------------------------------------

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
      await _psftp51
          ?.unsubscribe();
    } catch (_) {}

    try {
      await _psftp52
          ?.unsubscribe();
    } catch (_) {}

    try {
      await _psftp53
          ?.unsubscribe();
    } catch (_) {}

    // -------------------------------------------------------------------------
    // Disconnect BLE device.
    // -------------------------------------------------------------------------

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

    _resetConnectionState();

    if (!_hrStreamController.isClosed) {
      _hrStreamController.add(0);
    }
  }

  // ===========================================================================
  // CANCEL ALL SUBSCRIPTIONS
  // ===========================================================================

  Future<void>
      _cancelAllSubscriptions() async {
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

    try {
      await _psftp51Subscription
          ?.cancel();
    } catch (_) {}

    try {
      await _psftp52Subscription
          ?.cancel();
    } catch (_) {}

    try {
      await _psftp53Subscription
          ?.cancel();
    } catch (_) {}

    _hrValueSubscription = null;
    _pmdDataSubscription = null;
    _pmdControlSubscription = null;

    _psftp51Subscription = null;
    _psftp52Subscription = null;
    _psftp53Subscription = null;
  }

  // ===========================================================================
  // RESET CONNECTION STATE
  // ===========================================================================

  void _resetConnectionState() {
    _completePendingPmdResponse(
      error: StateError(
        'PMD connection closed',
      ),
    );

    _connectedDevice = null;

    _hrCharacteristic = null;

    _pmdControlPoint = null;
    _pmdData = null;

    _psftp51 = null;
    _psftp52 = null;
    _psftp53 = null;

    _ecgStreaming = false;
    _accStreaming = false;

    _resetPmdTimingState();

    // Reset to configured fallback values for the next connection.
    _accSampleRateHz =
        defaultAccSampleRateHz;

    _accFactor = 1.0;

    currentHeartRate = 0;
    currentRrIntervals = [];
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

  static int _readUnsignedLittleEndian(
    Uint8List data,
    int offset,
    int length,
  ) {
    int value = 0;

    for (int i = 0; i < length; i++) {
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
        (data[offset + 1] <<
            8);

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
        (data[offset + 1] <<
            8) |
        (data[offset + 2] <<
            16);

    if ((value & 0x800000) != 0) {
      value -= 0x1000000;
    }

    return value;
  }

  // ===========================================================================
  // DISPOSE
  // ===========================================================================

  Future<void> dispose() async {
    await disconnect();

    await _hrStreamController.close();
    await _ecgStreamController.close();
    await _ecgUiStreamController.close();
    await _accStreamController.close();
    await _accUiStreamController.close();
    await _scanStreamController.close();
  }
}

// =============================================================================
// PMD CONTROL RESPONSE
// =============================================================================

class _PmdControlResponse {
  final Uint8List raw;
  final int opcode;
  final int measurementType;
  final int errorCode;
  final Uint8List payload;

  const _PmdControlResponse({
    required this.raw,
    required this.opcode,
    required this.measurementType,
    required this.errorCode,
    required this.payload,
  });

  bool get isSuccess =>
      errorCode == 0;
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
    return '${timestamp.toIso8601String()},'
        '$participantId,'
        '$activityIndex,'
        '$phaseName,'
        '$microVolts';
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
  final double xMg;
  final double yMg;
  final double zMg;

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
      'timestamp_iso,participant_id,activity_index,phase_name,'
      'acc_x_mg,acc_y_mg,acc_z_mg';

  String toCsvRow() {
    return '${timestamp.toIso8601String()},'
        '$participantId,'
        '$activityIndex,'
        '$phaseName,'
        '$xMg,'
        '$yMg,'
        '$zMg';
  }
}


// ===========================================================================
// POLAR BIT READER
// ===========================================================================
//
// Polar converts every byte to:
//
//   bit 0, bit 1, ..., bit 7
//
// and then reconstructs each delta using those bits in that order.
//
// Therefore the PMD delta stream is read LSB-first.
//

class _PolarBitReader {
  final Uint8List data;

  int byteOffset;
  int bitOffset = 0;

  _PolarBitReader(
    this.data,
    this.byteOffset,
  );

  int readBits(
    int count,
  ) {
    if (count <= 0 ||
        count > 32) {
      throw ArgumentError(
        'Invalid bit count: $count',
      );
    }

    int value = 0;

    for (int i = 0;
        i < count;
        i++) {
      if (byteOffset >=
          data.length) {
        throw StateError(
          'PolarBitReader: '
          'out of range',
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