import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import '../models/polar_hr_sample.dart';
import '../models/device_configuration.dart';
import 'pmd_clock.dart';

/// Estado del enlace BLE con el sensor Polar, pensado para mostrarse en la UI.
enum PolarLinkState {
  disconnected,
  connecting,
  pairing,
  configuring,
  connected,
  reconnecting,
  error,
}

class PolarLinkStatus {
  final PolarLinkState state;
  final String message;

  /// Número de intento durante una reconexión (0 si no aplica).
  final int attempt;

  const PolarLinkStatus(
    this.state,
    this.message, {
    this.attempt = 0,
  });

  bool get isBusy =>
      state == PolarLinkState.connecting ||
      state == PolarLinkState.pairing ||
      state == PolarLinkState.configuring ||
      state == PolarLinkState.reconnecting;
}

/// Evento de conexión registrado para poder localizar huecos en los datos.
class PolarConnectionEvent {
  final DateTime timestamp;
  final String event;
  final String detail;

  PolarConnectionEvent(
    this.event, [
    this.detail = '',
  ]) : timestamp = DateTime.now().toUtc();

  static const String csvHeader = 'timestamp_utc,event,detail';

  String toCsvRow() {
    final escapedDetail = detail.replaceAll('"', "'");
    return '${timestamp.toIso8601String()},$event,"$escapedDetail"';
  }
}

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
  
  /// Sensor clock to host clock, from every PMD frame (see [PmdClockMapper]).
  final PmdClockMapper _clock = PmdClockMapper();

  /// One row per PMD frame: arrival, sensor time of its last sample and the
  /// offset in use, so SAVES can check or redo the mapping.
  final List<PmdClockObservation> clockObservations = [];

  void _resetClockSync() {
    _clock.reset();
  }

  DateTime _convertPmdTimestampToHostUtc(int timestampNs) => _clock.toHostUtc(timestampNs);

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
  // VERITY SENSE STREAMS (PPG, PPI, GYRO, MAGNETOMETER)
  // ===========================================================================

  /// Rates asked to the Verity Sense when it offers them: its defaults
  /// outside SDK mode are PPG 55 Hz and gyro 52 Hz at ±2000 dps; of the
  /// 10-100 Hz the magnetometer offers (±50 gauss), 50 Hz.
  static const int defaultPpgSampleRateHz = 55;
  static const int defaultGyroSampleRateHz = 52;
  static const int defaultMagSampleRateHz = 50;
  static const int preferredGyroRangeDps = 2000;

  /// Name of each PMD stream in the device configuration, the session files
  /// (`polar_<name>_<device>_<stamp>.csv`) and the clock log.
  static const Map<int, String> pmdStreamNames = {
    pmdTypeEcg: 'ecg',
    pmdTypeAcc: 'acc',
    pmdTypePpg: 'ppg',
    pmdTypePpi: 'ppi',
    pmdTypeGyro: 'gyro',
    pmdTypeMagnetometer: 'mag',
  };

  /// Sample rate and factor the sensor reported when each of those streams
  /// started (ACC keeps [_accSampleRateHz] and [_accFactor]).
  final Map<int, int> _pmdSampleRateHz = {};
  final Map<int, double> _pmdFactor = {};

  int get ppgSampleRateHz => _pmdSampleRateHz[pmdTypePpg] ?? defaultPpgSampleRateHz;
  int get gyroSampleRateHz => _pmdSampleRateHz[pmdTypeGyro] ?? defaultGyroSampleRateHz;
  int get magSampleRateHz => _pmdSampleRateHz[pmdTypeMagnetometer] ?? defaultMagSampleRateHz;

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

  final List<PolarPpgSample> recordedPpgSamples = [];

  final List<PolarPpiSample> recordedPpiSamples = [];

  final List<PolarGyroSample> recordedGyroSamples = [];

  final List<PolarMagSample> recordedMagSamples = [];

  int currentHeartRate = 0;

  List<int> currentRrIntervals = [];

  final _hrStreamController =
      StreamController<int>.broadcast();

  Stream<int> get hrStream =>
      _hrStreamController.stream;

  final _rrStreamController =
    StreamController<int>.broadcast();

  Stream<int> get rrStream =>
      _rrStreamController.stream;

  // ===========================================================================
  // ECG
  // ===========================================================================

  final _ecgStreamController =
      StreamController<PolarEcgSample>.broadcast();

  Stream<PolarEcgSample> get ecgStream =>
      _ecgStreamController.stream;



  // ===========================================================================
  // ACC
  // ===========================================================================

  final _accStreamController =
      StreamController<PolarAccelerationSample>.broadcast();

  Stream<PolarAccelerationSample> get accelerationStream =>
      _accStreamController.stream;

  // ===========================================================================
  // PPG, PPI, GYRO, MAGNETOMETER (VERITY SENSE)
  // ===========================================================================

  final _ppgStreamController = StreamController<PolarPpgSample>.broadcast();

  Stream<PolarPpgSample> get ppgStream => _ppgStreamController.stream;

  final _ppiStreamController = StreamController<PolarPpiSample>.broadcast();

  Stream<PolarPpiSample> get ppiStream => _ppiStreamController.stream;

  final _gyroStreamController = StreamController<PolarGyroSample>.broadcast();

  Stream<PolarGyroSample> get gyroStream => _gyroStreamController.stream;

  final _magStreamController = StreamController<PolarMagSample>.broadcast();

  Stream<PolarMagSample> get magStream => _magStreamController.stream;



  // ===========================================================================
  // PROTOCOL CONTEXT FOR ACC / ECG
  // ===========================================================================

  String currentParticipantId = '';
  int currentActivityIndex = 1;
  String currentPhaseName = 'idle';

  /// Type of the device in the session (`polar_h10`, `verity_sense`), set by
  /// the Research Monitor; it names the source of the heart rate in the files.
  String deviceType = '';

  /// Where the heart rate of [recordedSamples] comes from, see
  /// [PolarHrSample.sourceFor].
  String get hrSource => PolarHrSample.sourceFor(deviceType: deviceType, deviceName: _lastDeviceName);

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
  // LINK STATUS, RECONNECTION AND WATCHDOG
  // ===========================================================================

  final ValueNotifier<PolarLinkStatus> linkStatus = ValueNotifier(
    const PolarLinkStatus(PolarLinkState.disconnected, 'Desconectado'),
  );

  final List<PolarConnectionEvent> connectionEvents = [];

  /// Reintenta automáticamente cuando se pierde la conexión o dejan de
  /// llegar datos.
  bool autoReconnectEnabled = true;

  /// Sin datos durante este tiempo con un flujo activo se considera pérdida
  /// de recepción y se fuerza la reconexión.
  static const Duration dataLossTimeout = Duration(seconds: 6);

  static const List<Duration> _reconnectBackoff = [
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];

  BleDevice? _lastDevice;
  String _lastDeviceName = 'Polar';

  /// Sensores que estaban activos y deben reanudarse tras reconectar.
  final Set<String> _sensorsToRestore = {};

  /// Signals asked for since the user connected, even if they could not
  /// start (ACC and ECG while Windows refuses PMD). A reconnection brings
  /// them back too, so pairing the sensor afterwards starts the ACC.
  final Set<String> _requestedSensors = {};

  bool _userRequestedDisconnect = false;
  bool _reconnectLoopRunning = false;
  int _connectGeneration = 0;

  Timer? _watchdogTimer;
  DateTime? _lastHrDataAt;
  DateTime? _lastPmdDataAt;

  /// Tipos de medida PMD que anuncia el sensor (ECG, ACC, PPG...).
  /// Vacío si no se pudo leer; en ese caso se intenta todo lo configurado.
  Set<int> _supportedPmdTypes = {};

  bool get hasLastDevice => _lastDevice != null;
  String get lastDeviceName => _lastDeviceName;

  bool get supportsEcg =>
      _supportedPmdTypes.isEmpty ||
      _supportedPmdTypes.contains(pmdTypeEcg);

  bool get supportsAcc =>
      _supportedPmdTypes.isEmpty ||
      _supportedPmdTypes.contains(pmdTypeAcc);

  bool _supportsPmd(int type) => _supportedPmdTypes.isEmpty || _supportedPmdTypes.contains(type);

  bool get supportsPpg => _supportsPmd(pmdTypePpg);
  bool get supportsPpi => _supportsPmd(pmdTypePpi);
  bool get supportsGyro => _supportsPmd(pmdTypeGyro);
  bool get supportsMagnetometer => _supportsPmd(pmdTypeMagnetometer);

  void _setStatus(
    PolarLinkState state,
    String message, {
    int attempt = 0,
  }) {
    debugPrint('[POLAR LINK] ${state.name}: $message');
    linkStatus.value = PolarLinkStatus(state, message, attempt: attempt);
  }

  void _logEvent(String event, [String detail = '']) {
    connectionEvents.add(PolarConnectionEvent(event, detail));
  }

  String exportConnectionEventsCsv() {
    final buffer = StringBuffer()..writeln(PolarConnectionEvent.csvHeader);
    for (final event in connectionEvents) {
      buffer.writeln(event.toCsvRow());
    }
    return buffer.toString();
  }

  static String _displayName(BleDevice device) {
    final name = device.name;
    return name != null && name.isNotEmpty ? name : device.deviceId;
  }

  static bool get _isWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;


  // ===========================================================================
  // STATE
  // ===========================================================================

  bool _hrStreaming = false;
  bool _rrStreaming = false;
  bool _ecgStreaming = false;
  bool _accStreaming = false;
  Completer<void>? _firstHrNotificationCompleter;


  bool get isHeartRateStreaming => _hrStreaming;
  bool get isRrStreaming => _rrStreaming;
  bool get isEcgStreaming => _ecgStreaming;
  bool get isAccelerationStreaming => _accStreaming;

  bool _ppgStreaming = false;
  bool _ppiStreaming = false;
  bool _gyroStreaming = false;
  bool _magStreaming = false;

  bool get isPpgStreaming => _ppgStreaming;
  bool get isPpiStreaming => _ppiStreaming;
  bool get isGyroStreaming => _gyroStreaming;
  bool get isMagnetometerStreaming => _magStreaming;

  /// Whether the stream [name] (`heart_rate`, `rr` or a [pmdStreamNames]
  /// value) is running.
  bool isStreaming(String name) => switch (name) {
        'heart_rate' => _hrStreaming,
        'rr' => _rrStreaming,
        'acc' => _accStreaming,
        'ecg' => _ecgStreaming,
        'ppg' => _ppgStreaming,
        'ppi' => _ppiStreaming,
        'gyro' => _gyroStreaming,
        'mag' => _magStreaming,
        _ => false,
      };

  void _setStreaming(int type, bool value) {
    switch (type) {
      case pmdTypePpg:
        _ppgStreaming = value;
      case pmdTypePpi:
        _ppiStreaming = value;
      case pmdTypeGyro:
        _gyroStreaming = value;
      case pmdTypeMagnetometer:
        _magStreaming = value;
    }
  }

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

  // Several services can run at once (Polar H10 and Verity Sense), so each
  // one listens to the connection state of its own device instead of the
  // global UniversalBle callbacks, which keep only the last one set.
  StreamSubscription<bool>? _connectionSubscription;

  void _watchConnection(BleDevice device) {
    _connectionSubscription?.cancel();
    _connectionSubscription =
        UniversalBle.connectionStream(device.deviceId).listen((isConnected) {
      debugPrint(
        '[BLE CONNECTION] device=${device.deviceId} '
        'isConnected=$isConnected',
      );
      if (!isConnected &&
          !_establishing &&
          !_tearingDown &&
          device.deviceId == _connectedDevice?.deviceId) {
        _handleUnexpectedDisconnect();
      }
    });
  }

  /// Name advertised by the connected device (e.g. `Polar H10 ABCD1234`).
  String? get connectedDeviceName => _connectedDevice?.name;

  String? get connectedDeviceId => _connectedDevice?.deviceId;

  /// ACC sampling rate in use (negotiated with the device when it started).
  int get accSampleRateHz => _accSampleRateHz;

  // ===========================================================================
  // UNEXPECTED DISCONNECT
  // ===========================================================================

  void _handleUnexpectedDisconnect() {
    final wasStreaming = _rememberActiveSensors();

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

    _logEvent('disconnected_unexpectedly', _lastDeviceName);
    _scheduleReconnect(
      reason: 'Conexión perdida',
      restoreSensors: wasStreaming,
    );
  }

  /// Guarda qué sensores estaban activos. Devuelve true si había alguno.
  bool _rememberActiveSensors() {
    if (_hrStreaming) _sensorsToRestore.add('heart_rate');
    if (_accStreaming) _sensorsToRestore.add('acc');
    if (_ecgStreaming) _sensorsToRestore.add('ecg');
    for (final name in const ['ppg', 'ppi', 'gyro', 'mag']) {
      if (isStreaming(name)) _sensorsToRestore.add(name);
    }
    _sensorsToRestore.addAll(_requestedSensors);
    return _sensorsToRestore.isNotEmpty;
  }

  // ===========================================================================
  // DATA-LOSS WATCHDOG
  // ===========================================================================

  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _checkDataFlow(),
    );
  }

  void _stopWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
  }

  void _checkDataFlow() {
    if (_connectedDevice == null || linkStatus.value.isBusy) {
      return;
    }

    final now = DateTime.now();
    DateTime? lastData;
    String stream;

    Duration timeout;

    if (_accStreaming || _ecgStreaming) {
      lastData = _lastPmdDataAt;
      stream = 'PMD (ACC/ECG)';
      timeout = dataLossTimeout;
    } else if (_hrStreaming) {
      // HR puede pausarse si la banda pierde contacto con la piel, así que
      // se da más margen antes de considerarlo una pérdida de conexión.
      lastData = _lastHrDataAt;
      stream = 'HR';
      timeout = dataLossTimeout * 2.5;
    } else {
      return;
    }

    if (lastData == null || now.difference(lastData) < timeout) {
      return;
    }

    debugPrint(
      '[POLAR LINK] Sin datos de $stream desde '
      '${now.difference(lastData).inSeconds} s; forzando reconexión.',
    );

    _logEvent(
      'data_loss',
      'Sin datos de $stream durante ${now.difference(lastData).inSeconds} s',
    );

    _rememberActiveSensors();
    _stopWatchdog();

    unawaited(() async {
      await _teardownConnection();
      _scheduleReconnect(
        reason: 'Sin datos del sensor',
        restoreSensors: true,
      );
    }());
  }

  // ===========================================================================
  // RECONNECTION
  // ===========================================================================

  void _scheduleReconnect({
    required String reason,
    required bool restoreSensors,
  }) {
    if (_userRequestedDisconnect ||
        !autoReconnectEnabled ||
        _lastDevice == null) {
      _setStatus(PolarLinkState.disconnected, reason);
      return;
    }

    if (!restoreSensors) {
      _sensorsToRestore.clear();
    }

    unawaited(_runReconnectLoop(reason));
  }

  /// Reintento manual desde la UI. Reanuda los sensores que estuvieran
  /// activos o, si no había ninguno, los indicados en [configuration].
  Future<bool> retryConnection({
    DeviceConfiguration? configuration,
  }) async {
    final device = _lastDevice;
    if (device == null) {
      return false;
    }

    if (_sensorsToRestore.isEmpty && configuration != null) {
      _sensorsToRestore.addAll(configuration.sensors);
    }

    _userRequestedDisconnect = false;
    _logEvent('manual_retry', _lastDeviceName);

    _rememberActiveSensors();
    await _teardownConnection();

    final ok = await _connectAndRestore(device, attempt: 1);

    // Si ya hay un bucle automático en marcha, sigue él; si no, se arranca.
    if (!ok && autoReconnectEnabled) {
      unawaited(_runReconnectLoop('Reintento fallido'));
    }

    return ok;
  }

  Future<void> _runReconnectLoop(String reason) async {
    if (_reconnectLoopRunning) {
      return;
    }

    _reconnectLoopRunning = true;
    final generation = ++_connectGeneration;

    try {
      var attempt = 0;

      while (!_userRequestedDisconnect &&
          autoReconnectEnabled &&
          generation == _connectGeneration &&
          _connectedDevice == null) {
        final device = _lastDevice;
        if (device == null) break;

        final wait = _reconnectBackoff[
            math.min(attempt, _reconnectBackoff.length - 1)];
        attempt++;

        _setStatus(
          PolarLinkState.reconnecting,
          '$reason. Reintentando en ${wait.inSeconds} s '
          '(intento $attempt)...',
          attempt: attempt,
        );

        await Future.delayed(wait);

        if (_userRequestedDisconnect ||
            generation != _connectGeneration ||
            _connectedDevice != null) {
          break;
        }

        _logEvent('reconnect_attempt', 'intento $attempt');

        final ok = await _connectAndRestore(device, attempt: attempt);
        if (ok) break;
      }
    } finally {
      _reconnectLoopRunning = false;
    }
  }

  bool _attemptInProgress = false;

  Future<bool> _connectAndRestore(
    BleDevice device, {
    required int attempt,
  }) async {
    if (_attemptInProgress) {
      return false;
    }

    _attemptInProgress = true;
    try {
      return await _connectAndRestoreInner(device, attempt: attempt);
    } finally {
      _attemptInProgress = false;
    }
  }

  Future<bool> _connectAndRestoreInner(
    BleDevice device, {
    required int attempt,
  }) async {
    final ok = await _establishConnection(device, attempt: attempt);
    if (!ok) {
      return false;
    }

    final sensors = Set<String>.from(_sensorsToRestore);
    if (sensors.isNotEmpty) {
      _setStatus(
        PolarLinkState.configuring,
        'Reanudando sensores (${sensors.join(', ')})...',
        attempt: attempt,
      );

      await startConfiguredSensors(
        DeviceConfiguration(
          deviceId: 'polar',
          deviceName: _lastDeviceName,
          sensors: sensors,
        ),
      );
    }

    // La conexión puede haberse vuelto a caer mientras se reanudaban.
    if (_connectedDevice == null) {
      return false;
    }

    _sensorsToRestore.clear();
    _logEvent('reconnected', _lastDeviceName);
    _setStatus(PolarLinkState.connected, 'Conectado a $_lastDeviceName');
    _startWatchdog();
    return true;
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

  /// Conexión iniciada por el usuario desde el diálogo de búsqueda.
  Future<bool> connectToDevice(
    BleDevice device,
  ) async {
    _userRequestedDisconnect = false;
    _connectGeneration++;
    _sensorsToRestore.clear();
    _requestedSensors.clear();
    _stopPairingWatch();
    _stopWatchdog();

    if (_connectedDevice != null) {
      await _teardownConnection();
    }

    _lastDevice = device;
    _lastDeviceName = _displayName(device);
    _logEvent('connect_requested', _lastDeviceName);

    final ok = await _establishConnection(device);

    if (ok) {
      _logEvent('connected', _lastDeviceName);
      _setStatus(PolarLinkState.connected, 'Conectado a $_lastDeviceName');
      _startWatchdog();
    }

    return ok;
  }

  /// Cancela una conexión en curso (por ejemplo, si se queda esperando al
  /// emparejamiento de Windows).
  Future<void> cancelConnection() async {
    _connectGeneration++;
    _userRequestedDisconnect = true;
    _logEvent('connect_cancelled', _lastDeviceName);
    await _teardownConnection();
    final device = _lastDevice;
    if (device != null) {
      try {
        await device.disconnect(timeout: const Duration(seconds: 5));
      } catch (_) {}
    }
    _setStatus(PolarLinkState.disconnected, 'Conexión cancelada');
  }

  bool _establishing = false;

  Future<bool> _establishConnection(
    BleDevice device, {
    int attempt = 0,
  }) async {
    final generation = _connectGeneration;
    final name = _displayName(device);
    var linkWasUp = false;
    var clearedBond = false;

    _establishing = true;

    try {
      await stopScan();

      for (var pass = 0; pass < 2; pass++) {
        try {
          _setStatus(
            attempt > 0
                ? PolarLinkState.reconnecting
                : PolarLinkState.connecting,
            'Conectando con $name...',
            attempt: attempt,
          );

          if (!await device.isConnected) {
            await device.connect(
              timeout: const Duration(seconds: 20),
            );
          }

          linkWasUp = true;

          // Windows sigue descubriendo servicios justo después de conectar.
          // No se empareja: la Verity Sense funciona sin emparejar, y el
          // diálogo de emparejamiento de Windows 11 se queda bloqueado.
          await Future.delayed(const Duration(milliseconds: 600));
          _checkNotCancelled(generation);

          _setStatus(
            PolarLinkState.configuring,
            'Configurando $name...',
            attempt: attempt,
          );

          await _configureConnectedDevice(device);
          _checkNotCancelled(generation);

          return true;
        } catch (e, stack) {
          debugPrint('[POLAR DEBUG] Error conectando (pasada $pass): $e');
          debugPrint('[POLAR DEBUG] $stack');

          await _teardownConnection();
          try {
            await device.disconnect(timeout: const Duration(seconds: 5));
          } catch (_) {}

          if (e is _ConnectCancelled) {
            return false;
          }

          // Segunda pasada solo en Windows, si llegó a conectar (el fallo fue
          // al configurar, típico de falta de emparejamiento) y si aún no
          // se ha intentado emparejar.
          // "Requiere autenticación" en Windows suele venir de un
          // emparejamiento a medias que quedó guardado. Se borra y se
          // vuelve a intentar sin emparejar.
          final authError = _isAuthenticationError(e);
          if (pass == 0 && _isWindows && linkWasUp && authError) {
            clearedBond = await _clearStaleBond(device, name);
            continue;
          }

          _logEvent('connect_failed', '$e');
          _setStatus(
            PolarLinkState.error,
            authError
                ? 'Windows pide autenticación a $name'
                    '${clearedBond ? ' tras borrar el emparejamiento' : ''}. '
                    'Quítalo en Configuración > Bluetooth y dispositivos '
                    '(Quitar dispositivo), cierra otras apps que lo usen y '
                    'vuelve a pulsar Conectar.'
                : 'No se pudo conectar con $name: ${_shortError(e)}',
            attempt: attempt,
          );
          return false;
        }
      }

      return false;
    } finally {
      _establishing = false;
    }
  }

  void _checkNotCancelled(int generation) {
    if (generation != _connectGeneration) {
      throw const _ConnectCancelled();
    }
  }

  static bool _isAuthenticationError(Object e) {
    final text = e.toString().toLowerCase();
    return text.contains('autentic') ||
        text.contains('authenticat') ||
        text.contains('insufficient') ||
        text.contains('cifrado') ||
        text.contains('encrypt');
  }

  static String _shortError(Object e) {
    final text = e.toString();
    return text.length > 160 ? '${text.substring(0, 160)}...' : text;
  }

  /// Borra un emparejamiento guardado en Windows. Devuelve true si había
  /// uno y se quitó.
  Future<bool> _clearStaleBond(BleDevice device, String name) async {
    _setStatus(
      PolarLinkState.connecting,
      'Borrando un emparejamiento antiguo de $name y reintentando...',
    );
    try {
      final paired = await device.isPaired(
        timeout: const Duration(seconds: 5),
      );
      if (paired != true) {
        _logEvent('stale_bond_none', name);
        return false;
      }
      await device.unpair(timeout: const Duration(seconds: 10));
      _logEvent('stale_bond_removed', name);
      await Future.delayed(const Duration(seconds: 1));
      return true;
    } catch (e) {
      debugPrint('[POLAR DEBUG] No se pudo borrar el emparejamiento: $e');
      _logEvent('stale_bond_failed', '$e');
      return false;
    }
  }

  /// Repite una operación GATT que en Windows falla a menudo de forma
  /// pasajera ("Connection already in progress"). Los errores de
  /// autenticación no se repiten.
  Future<T> _gattRetry<T>(
    String label,
    Future<T> Function() action, {
    int tries = 4,
  }) async {
    Object? last;
    for (var i = 1; i <= tries; i++) {
      try {
        return await action();
      } catch (e) {
        last = e;
        if (_isAuthenticationError(e) || i == tries) rethrow;
        debugPrint('[POLAR DEBUG] $label: intento $i/$tries fallido ($e)');
        await Future.delayed(Duration(milliseconds: 500 * i));
      }
    }
    throw last!;
  }

  Future<void> _configureConnectedDevice(BleDevice device) async {
    _connectedDevice = device;
    _watchConnection(device);

    final services = await device.discoverServices(
      timeout: const Duration(seconds: 15),
    );

    for (final service in services) {
      for (final characteristic in service.characteristics) {
        final uuid = characteristic.uuid.toLowerCase();

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
      '${_psftp51 != null ? "ENCONTRADA" : "NO ENCONTRADA"}, '
      'FB005C52: '
      '${_psftp52 != null ? "ENCONTRADA" : "NO ENCONTRADA"}, '
      'FB005C53: '
      '${_psftp53 != null ? "ENCONTRADA" : "NO ENCONTRADA"}',
    );

    final state = await device.connectionState;

    if (state != BleConnectionState.connected) {
      throw Exception(
        'Dispositivo no conectado: $state',
      );
    }

    // -------------------------------------------------------------------------
    // HR
    // -------------------------------------------------------------------------

    await _prepareHeartRate(device);

    // -------------------------------------------------------------------------
    // PMD
    // -------------------------------------------------------------------------

    // If Windows refuses PMD (ACC, ECG) for lack of pairing, stay connected
    // with heart rate only, as the web app does («Conectado (solo FC)»),
    // instead of dropping the whole device.
    pmdProblem = null;
    try {
      await _setupPmd(device);
      await _readPmdFeatures();
    } catch (e) {
      if (!_isAuthenticationError(e)) rethrow;
      debugPrint('[POLAR DEBUG] PMD pide autenticación; solo FC: $e');
      _logEvent('pmd_needs_pairing', '$e');
      try {
        await _pmdDataSubscription?.cancel();
        await _pmdControlSubscription?.cancel();
      } catch (_) {}
      _pmdDataSubscription = null;
      _pmdControlSubscription = null;
      _pmdControlPoint = null;
      _pmdData = null;
      pmdProblem = 'Windows no deja usar el acelerómetro ni el ECG sin '
          'emparejar el sensor (solo FC). Si Windows pide «Permitir», '
          'acéptalo: el acelerómetro se activará solo';
      _startPairingWatch(device);
    }
  }

  // While only heart rate works, watch whether Windows finishes pairing the
  // sensor (the «Permitir» prompt) and then reconnect, which starts the ACC.
  Timer? _pairingWatchTimer;

  void _startPairingWatch(BleDevice device) {
    _stopPairingWatch();
    var ticks = 0;
    _pairingWatchTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      ticks++;
      if (ticks > 100 || _userRequestedDisconnect) {
        _stopPairingWatch();
        return;
      }
      if (_establishing || _attemptInProgress || _tearingDown) return;
      if (_connectedDevice != null && hasPmd) {
        _stopPairingWatch();
        return;
      }
      bool? paired;
      try {
        paired = await device.isPaired(timeout: const Duration(seconds: 3));
      } catch (_) {
        return;
      }
      if (paired != true || _pairingWatchTimer == null) return;
      _stopPairingWatch();
      debugPrint('[POLAR DEBUG] Sensor emparejado: reconectando para el ACC');
      _logEvent('paired_reconnect', _lastDeviceName);
      try {
        await retryConnection();
      } catch (e) {
        debugPrint('[POLAR DEBUG] Reconexión tras emparejar fallida: $e');
      }
    });
  }

  void _stopPairingWatch() {
    _pairingWatchTimer?.cancel();
    _pairingWatchTimer = null;
  }

  /// PMD (ACC, ECG) is available on the connected device.
  bool get hasPmd => _pmdControlPoint != null && _pmdData != null;

  /// Why PMD (ACC, ECG) is not available on the connected device, or null.
  String? pmdProblem;

  // ===========================================================================
  // PMD FEATURES
  // ===========================================================================

  /// Lee el Control Point PMD: el primer byte es 0x0F y los siguientes son
  /// una máscara de bits con los tipos de medida soportados.
  Future<void> _readPmdFeatures() async {
    _supportedPmdTypes = {};

    final controlPoint = _pmdControlPoint;
    if (controlPoint == null) return;

    try {
      final data = await controlPoint.read(
        timeout: const Duration(seconds: 10),
      );

      if (data.length >= 2 && data[0] == 0x0F) {
        final features = <int>{};
        for (var byteIndex = 1; byteIndex < data.length; byteIndex++) {
          for (var bit = 0; bit < 8; bit++) {
            if ((data[byteIndex] >> bit) & 0x01 == 1) {
              features.add((byteIndex - 1) * 8 + bit);
            }
          }
        }
        _supportedPmdTypes = features;
      }

      debugPrint(
        '[POLAR DEBUG] PMD features: ${_hex(data)} -> '
        'tipos $_supportedPmdTypes',
      );
    } catch (e) {
      debugPrint('[POLAR DEBUG] No se pudieron leer las PMD features: $e');
    }
  }

  // ===========================================================================
  // SETUP HR
  // ===========================================================================

  Future<void> _prepareHeartRate(
    BleDevice device,
  ) async {
    final characteristic =
        await device.getCharacteristic(
      hrMeasurementUuid,
      service: hrServiceUuid,
      timeout: const Duration(seconds: 15),
    );

    _hrCharacteristic =
        characteristic;

    if (!characteristic
        .notifications.isSupported) {
      throw Exception(
        'HR does not support notifications',
      );
    }
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
      timeout: const Duration(seconds: 15),
    );

    _pmdData =
        await device.getCharacteristic(
      pmdDataUuid,
      service: pmdServiceUuid,
      timeout: const Duration(seconds: 15),
    );

    // -------------------------------------------------------------------------
    // PMD CONTROL POINT INDICATIONS
    // -------------------------------------------------------------------------

    // Indications (H10) or notifications, whichever the device offers, as
    // Web Bluetooth's startNotifications() does.
    final controlUsesIndications =
        _pmdControlPoint!.indications.isSupported;
    if (!controlUsesIndications &&
        !_pmdControlPoint!.notifications.isSupported) {
      throw Exception(
        'PMD Control Point no admite indications ni notifications',
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

    await _gattRetry(
      'PMD Control',
      () => controlUsesIndications
          ? _pmdControlPoint!.indications
              .subscribe(timeout: const Duration(seconds: 15))
          : _pmdControlPoint!.notifications
              .subscribe(timeout: const Duration(seconds: 15)),
    );

    debugPrint(
      '[POLAR DEBUG] PMD Control indications SUSCRITAS',
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
        if (debugPmdFrames) {
          debugPrint(
            '[POLAR DEBUG] PMD CALLBACK RECIBIDO: ${value.length} bytes',
          );
        }

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

    await _gattRetry(
      'PMD Data',
      () => _pmdData!
          .notifications
          .subscribe(timeout: const Duration(seconds: 15)),
    );

    debugPrint(
      '[POLAR DEBUG] PMD Data SUSCRITO',
    );
  }

  // ===========================================================================
  // START ECG
  // ===========================================================================

  Future<void> startEcg() async {
    _requestedSensors.add('ecg');
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
        await _startMeasurement(command, pmdTypeEcg);

    if (!response.isSuccess) {
      throw Exception(
        'ECG START rechazado por PMD: '
        '${response.errorCode}',
      );
    }

    _lastPmdDataAt = DateTime.now();
    _ecgStreaming = true;

    debugPrint(
      '[POLAR DEBUG] ECG START aceptado por PMD',
    );
  }

  // ===========================================================================
  // START ACC
  // ===========================================================================

  Future<void> startAcceleration() async {
    _requestedSensors.add('acc');
    if (_pmdControlPoint == null) {
      throw Exception(
        'PMD no está conectado',
      );
    }

    if (_accStreaming) {
      return;
    }

    // The settings are asked to the device first (opcode 0x01), as the
    // Polar SDK does: the H10 offers 25-200 Hz and ±2/4/8 G; the Verity Sense
    // 52 Hz, ±8 G and 3 channels. Without an answer, the H10 settings are
    // requested (200 Hz, 16 bit, ±8 G).
    final command = await _accStartCommand();
    debugPrint(
      '[POLAR DEBUG] ACC START TX: '
      '${_hex(command)}',
    );

    final response =
        await _startMeasurement(command, pmdTypeAcc);

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

    _lastPmdDataAt = DateTime.now();
    _accStreaming = true;

    debugPrint(
      '[POLAR DEBUG] ACC START aceptado por PMD; '
      'sampleRate=$_accSampleRateHz Hz; '
      'factor=$_accFactor',
    );
  }

  // ===========================================================================
  // VERITY SENSE STREAMS: PPG, PPI, GYRO, MAGNETOMETER
  // ===========================================================================

  /// Raw PPG of the Verity Sense: three green channels and the ambient light
  /// (22 bit, 55 Hz).
  Future<void> startPpg() => _startPmdStream(pmdTypePpg, preferredRateHz: defaultPpgSampleRateHz);

  /// Pulse-to-pulse intervals from Polar's PPI algorithm. The first batch
  /// comes about 25 s after the start and, while it runs, the sensor updates
  /// the heart rate of the HR service only every 5 s.
  Future<void> startPpi() => _startPmdStream(pmdTypePpi);

  Future<void> startGyro() => _startPmdStream(
        pmdTypeGyro,
        preferredRateHz: defaultGyroSampleRateHz,
        preferredRange: preferredGyroRangeDps,
      );

  Future<void> startMagnetometer() =>
      _startPmdStream(pmdTypeMagnetometer, preferredRateHz: defaultMagSampleRateHz);

  Future<void> stopPpg() => _stopPmdStream(pmdTypePpg);
  Future<void> stopPpi() => _stopPmdStream(pmdTypePpi);
  Future<void> stopGyro() => _stopPmdStream(pmdTypeGyro);
  Future<void> stopMagnetometer() => _stopPmdStream(pmdTypeMagnetometer);

  /// Starts a PMD stream the way the Polar SDK does: the settings are asked
  /// to the sensor and the start command is built from them
  /// ([startCommandFor]); PPI has no settings. The rate and factor the
  /// sensor answers with are kept for its frames.
  Future<void> _startPmdStream(int type, {int? preferredRateHz, int? preferredRange}) async {
    final name = pmdStreamNames[type]!;
    _requestedSensors.add(name);
    if (_pmdControlPoint == null) {
      throw Exception('PMD no está conectado');
    }
    if (isStreaming(name)) return;

    final Uint8List command;
    var offeredRates = const <int>[];
    if (type == pmdTypePpi) {
      command = Uint8List.fromList([pmdOpStartMeasurement, pmdTypePpi]);
    } else {
      final options = await _settingsOffered(type);
      offeredRates = options[pmdSettingSampleRate] ?? const [];
      if (offeredRates.isEmpty) {
        throw Exception('El sensor no ofrece ajustes de ${name.toUpperCase()}');
      }
      command = startCommandFor(type, options, preferredRateHz: preferredRateHz, preferredRange: preferredRange);
    }
    debugPrint('[POLAR DEBUG] ${name.toUpperCase()} START TX: ${_hex(command)}');

    final response = await _startMeasurement(command, type);
    if (!response.isSuccess) {
      throw Exception('${name.toUpperCase()} START rechazado por PMD: ${response.errorCode}');
    }
    _updatePmdSettingsFromResponse(response.payload, measurementType: type);
    if (offeredRates.isNotEmpty && type != pmdTypeAcc) {
      // The start response echoes the settings; without them, the rate asked
      // for is the one in force. Older Verity Sense firmware reports a PPG
      // rate it does not sample at, and the timestamps need the real one.
      final reported = _pmdSampleRateHz[type] ?? pickSetting(offeredRates, preferredRateHz);
      final corrected = type == pmdTypePpg
          ? correctedPpgRate(
              offeredRates: offeredRates,
              reportedRateHz: reported,
              deviceName: _lastDeviceName,
              deviceType: deviceType,
            )
          : null;
      _pmdSampleRateHz[type] = corrected ?? reported;
      if (corrected != null) {
        _logEvent(
          'ppg_rate_corrected',
          'el sensor dice $reported Hz pero muestrea a $corrected Hz (problema conocido del firmware)',
        );
      }
    }
    _removePmdTimingKeys(measurementType: type);
    _lastPmdDataAt = DateTime.now();
    _setStreaming(type, true);
    debugPrint(
      '[POLAR DEBUG] ${name.toUpperCase()} START aceptado por PMD; '
      'sampleRate=${_pmdSampleRateHz[type]} Hz; factor=${_pmdFactor[type]}',
    );
  }

  Future<void> _stopPmdStream(int type) async {
    final name = pmdStreamNames[type]!;
    if (_pmdControlPoint == null || !isStreaming(name)) return;
    try {
      final response = await _sendPmdCommandAndWaitForResponse(
        Uint8List.fromList([pmdOpStopMeasurement, type]),
        expectedOpcode: pmdOpStopMeasurement,
        expectedMeasurementType: type,
      );
      if (!response.isSuccess) {
        debugPrint('[POLAR DEBUG] ${name.toUpperCase()} STOP rechazado: ${response.errorCode}');
      }
    } finally {
      _setStreaming(type, false);
      _removePmdTimingKeys(measurementType: type);
    }
  }

  /// Settings the sensor offers for [type] (empty when it answers nothing).
  Future<Map<int, List<int>>> _settingsOffered(int type) async {
    try {
      final response = await _sendPmdCommandAndWaitForResponse(
        Uint8List.fromList([pmdOpGetMeasurementSettings, type]),
        expectedOpcode: pmdOpGetMeasurementSettings,
        expectedMeasurementType: type,
      );
      if (response.isSuccess) {
        final options = parsePmdSettingOptions(_pmdParameters(response.payload));
        debugPrint('[POLAR DEBUG] ${pmdStreamNames[type]} settings offered: $options');
        return options;
      }
    } catch (e) {
      debugPrint('[POLAR DEBUG] ${pmdStreamNames[type]} settings not available: $e');
    }
    return const {};
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

    _pendingPmdParameters.clear();
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

    // A long answer (e.g. the settings of a Verity Sense) can come in several
    // parts: while the "more" byte is set, keep the parameters and wait for
    // the next one (as the Polar SDK and the web app do).
    if (response.errorCode == 0 && response.payload.isNotEmpty) {
      _pendingPmdParameters.addAll(_pmdParameters(response.payload));
      if (response.payload[0] != 0) return;
      final parameters = Uint8List.fromList(_pendingPmdParameters);
      _pendingPmdParameters.clear();
      _completePendingPmdResponse(
        response: _PmdControlResponse(
          raw: response.raw,
          opcode: response.opcode,
          measurementType: response.measurementType,
          errorCode: 0,
          payload: Uint8List.fromList([0, ...parameters]),
        ),
      );
      return;
    }
    _pendingPmdParameters.clear();

    _completePendingPmdResponse(
      response: response,
    );
  }

  final List<int> _pendingPmdParameters = [];

  /// Error code of a PMD start rejected because the measurement was already
  /// running (e.g. left on by another app).
  static const int pmdErrorAlreadyInState = 6;

  /// Sends a start command; if the sensor says the measurement is already
  /// running, stops it and starts it again with these settings.
  Future<_PmdControlResponse> _startMeasurement(
    Uint8List command,
    int measurementType,
  ) async {
    var response = await _sendPmdCommandAndWaitForResponse(
      command,
      expectedOpcode: pmdOpStartMeasurement,
      expectedMeasurementType: measurementType,
    );
    if (response.errorCode == pmdErrorAlreadyInState) {
      debugPrint(
        '[POLAR DEBUG] Medida 0x${measurementType.toRadixString(16)} ya '
        'activa: se para y se vuelve a iniciar.',
      );
      await _sendPmdCommandAndWaitForResponse(
        Uint8List.fromList([pmdOpStopMeasurement, measurementType]),
        expectedOpcode: pmdOpStopMeasurement,
        expectedMeasurementType: measurementType,
      );
      response = await _sendPmdCommandAndWaitForResponse(
        command,
        expectedOpcode: pmdOpStartMeasurement,
        expectedMeasurementType: measurementType,
      );
    }
    return response;
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
          _parsePmdSettings(_pmdParameters(payload));

      final sampleRate = settings[pmdSettingSampleRate];
      if (sampleRate != null && sampleRate > 0) {
        if (measurementType == pmdTypeAcc) {
          _accSampleRateHz = sampleRate;
        } else {
          _pmdSampleRateHz[measurementType] = sampleRate;
        }
        debugPrint(
          '[POLAR DEBUG] PMD ${pmdStreamNames[measurementType]} sample rate '
          'reported by sensor: $sampleRate Hz',
        );
      }

      final factor = settings[pmdSettingFactor];
      if (factor != null) {
        final value = _uint32ToDouble(factor);
        if (measurementType == pmdTypeAcc) {
          _accFactor = value;
        } else {
          _pmdFactor[measurementType] = value;
        }
        debugPrint(
          '[POLAR DEBUG] PMD ${pmdStreamNames[measurementType]} factor '
          'reported by sensor: $value',
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
  // ACC SETTINGS NEGOTIATION
  // ===========================================================================

  /// Parameters of a PMD control-point response. The first payload byte
  /// (after the error code) is the "more" flag, not a setting
  /// (PmdControlPointResponse in the Polar BLE SDK).
  static Uint8List _pmdParameters(Uint8List payload) =>
      payload.length > 1 ? Uint8List.sublistView(payload, 1) : Uint8List(0);

  /// Every value offered for each setting type.
  static Map<int, List<int>> parsePmdSettingOptions(Uint8List data) {
    final result = <int, List<int>>{};
    var offset = 0;
    while (offset + 2 <= data.length) {
      final settingType = data[offset];
      final count = data[offset + 1];
      offset += 2;
      final fieldSize = _pmdSettingFieldSize(settingType);
      if (fieldSize <= 0) break;
      for (var i = 0; i < count; i++) {
        if (offset + fieldSize > data.length) {
          throw StateError('Truncated PMD setting type=$settingType');
        }
        var value = 0;
        for (var b = 0; b < fieldSize; b++) {
          value |= data[offset + b] << (8 * b);
        }
        result.putIfAbsent(settingType, () => []).add(value);
        offset += fieldSize;
      }
    }
    return result;
  }

  /// Start command for ACC from the offered settings: [preferredRateHz] if
  /// offered (else the highest rate), the highest resolution, ±8 G if
  /// offered (else the highest range) and the most channels.
  static Uint8List accStartCommandFor(
    Map<int, List<int>> options, {
    int preferredRateHz = defaultAccSampleRateHz,
    int preferredRangeG = 8,
  }) =>
      startCommandFor(pmdTypeAcc, options, preferredRateHz: preferredRateHz, preferredRange: preferredRangeG);

  /// Start command for a PMD stream from the settings the sensor offers: the
  /// preferred rate and range when offered (else the highest), the highest
  /// resolution and the most channels, as the Polar SDK's `maxSettings`.
  /// The value asked to the sensor among the [values] it offers: [preferred]
  /// when offered, otherwise the highest.
  static int pickSetting(List<int> values, int? preferred) =>
      preferred != null && values.contains(preferred)
          ? preferred
          : values.reduce((a, b) => a > b ? a : b);

  /// Polar's known PPG issue (polar-ble-sdk, KnownIssues.md): in normal mode
  /// the Verity Sense with firmware 1.1.5 to 2.1.0 offers a single PPG rate,
  /// 135 Hz, but samples at 55 Hz; the OH1 offers 130 Hz but samples at
  /// 135 Hz. The sample timestamps need the real rate, so this returns it, or
  /// null when the sensor is right. Several offered rates mean SDK mode,
  /// where the sensor reports them correctly.
  static int? correctedPpgRate({
    required List<int> offeredRates,
    required int reportedRateHz,
    String deviceName = '',
    String deviceType = '',
  }) {
    if (offeredRates.length != 1) return null;
    final name = deviceName.toLowerCase();
    if (name.contains('oh1')) return reportedRateHz == 130 ? 135 : null;
    final verity = deviceType == 'verity_sense' || name.contains('sense');
    if (verity && reportedRateHz == 135) return 55;
    return null;
  }

  static Uint8List startCommandFor(
    int type,
    Map<int, List<int>> options, {
    int? preferredRateHz,
    int? preferredRange,
  }) {
    final bytes = <int>[pmdOpStartMeasurement, type];
    void add(int settingType, int value) {
      final size = _pmdSettingFieldSize(settingType);
      bytes..add(settingType)..add(1);
      for (var b = 0; b < size; b++) {
        bytes.add((value >> (8 * b)) & 0xFF);
      }
    }

    for (final (settingType, preferred) in [
      (pmdSettingSampleRate, preferredRateHz),
      (pmdSettingResolution, null),
      (pmdSettingRange, preferredRange),
      (pmdSettingRangeMilliUnit, null),
      (pmdSettingChannels, null),
    ]) {
      final values = options[settingType];
      if (values != null && values.isNotEmpty) {
        add(settingType, pickSetting(values, preferred));
      }
    }
    return Uint8List.fromList(bytes);
  }

  static final Uint8List _h10AccStartCommand = Uint8List.fromList([
    0x02, pmdTypeAcc, //
    0x00, 0x01, 0xC8, 0x00, // 200 Hz
    0x01, 0x01, 0x10, 0x00, // 16 bit
    0x02, 0x01, 0x08, 0x00, // 8 G
  ]);

  Future<Uint8List> _accStartCommand() async {
    final options = await _settingsOffered(pmdTypeAcc);
    if (options[pmdSettingSampleRate]?.isNotEmpty == true) {
      return accStartCommandFor(options);
    }
    return _h10AccStartCommand;
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

    _lastPmdDataAt = DateTime.now();

    // PMD measurement type occupies the lower 6 bits.
    final measurementType =
        data[0] & 0x3F;

    // Bytes 1..8: sensor time of the last sample of the frame. PPI frames
    // are held back by the sensor for tens of seconds, so they say nothing
    // about the clocks; a frame without a time (0) neither.
    if (data.length >= 10 &&
        measurementType != pmdTypePpi &&
        pmdStreamNames.containsKey(measurementType) &&
        _readUint64LittleEndian(data, 1) != 0) {
      final arrival = DateTime.now().toUtc().microsecondsSinceEpoch;
      final frameNs = _readUint64LittleEndian(data, 1);
      _clock.observe(arrivalHostMicros: arrival, lastSampleSensorMicros: frameNs ~/ 1000);
      clockObservations.add(PmdClockObservation(
        measurementType: measurementType,
        arrivalHostMicros: arrival,
        frameSensorNs: frameNs,
        offsetMicros: _clock.offsetMicros ?? 0,
      ));
    }

    switch (measurementType) {
      case pmdTypeEcg:
        _parseEcgFrame(data);
        break;

      case pmdTypeAcc:
        _parseAccelerationFrame(data);
        break;

      case pmdTypePpg:
        _parsePpgFrame(data);
        break;

      case pmdTypePpi:
        _parsePpiFrame(data);
        break;

      case pmdTypeGyro:
      case pmdTypeMagnetometer:
        _parseThreeAxisFrame(measurementType, data);
        break;

      default:
        break;
    }
  }

  // ===========================================================================
  // PPG, PPI, GYRO AND MAGNETOMETER FRAMES (VERITY SENSE)
  // ===========================================================================

  /// Sensor time of every sample of a frame whose last sample is at
  /// [timestampNs], as [_buildPmdTimestamps] does for ACC and ECG.
  List<int> _frameTimestamps({
    required int measurementType,
    required bool compressed,
    required int frameType,
    required int timestampNs,
    required int sampleCount,
    required int sampleRateHz,
  }) {
    final key = _pmdTimestampKey(
      measurementType: measurementType,
      compressed: compressed,
      frameType: frameType,
    );
    final timestamps = _buildPmdTimestamps(
      timestampNs: timestampNs,
      previousTimestampNs: _lastPmdFrameTimestampNs[key],
      sampleCount: sampleCount,
      sampleRateHz: sampleRateHz,
    );
    _lastPmdFrameTimestampNs[key] = timestampNs;
    return timestamps;
  }

  /// PPG frame type 0 of the Verity Sense: four channels (three green PPG
  /// and the ambient light) of 22 bits, raw (3 bytes each) or delta coded,
  /// as PpgData in the Polar BLE SDK.
  void _parsePpgFrame(Uint8List data) {
    if (data.length < 11) return;
    final timestampNs = _readUint64LittleEndian(data, 1);
    final compressed = (data[9] & 0x80) != 0;
    final frameType = data[9] & 0x7F;
    if (frameType != 0) {
      debugPrint('[POLAR DEBUG] PPG frame type no soportado: $frameType');
      return;
    }
    final content = Uint8List.sublistView(data, 10);
    const channels = 4;
    final List<List<int>> samples;
    if (compressed) {
      samples = _parsePolarDeltaFramesToSamples(content, channels: channels, resolution: 22);
    } else {
      const bytesPerSample = 3 * channels;
      if (content.isEmpty || content.length % bytesPerSample != 0) {
        debugPrint('[POLAR DEBUG] PPG raw payload inválido: ${content.length} bytes');
        return;
      }
      samples = [
        for (var offset = 0; offset < content.length; offset += bytesPerSample)
          [for (var c = 0; c < channels; c++) _readSigned24LittleEndian(content, offset + 3 * c)],
      ];
    }
    if (samples.isEmpty) return;
    final timestamps = _frameTimestamps(
      measurementType: pmdTypePpg,
      compressed: compressed,
      frameType: frameType,
      timestampNs: timestampNs,
      sampleCount: samples.length,
      sampleRateHz: ppgSampleRateHz,
    );
    final factor = _pmdFactor[pmdTypePpg] ?? 1.0;
    int scaled(int raw) => factor == 1.0 ? raw : (raw * factor).round();
    for (var i = 0; i < samples.length; i++) {
      final s = samples[i];
      final sample = PolarPpgSample(
        timestamp: _convertPmdTimestampToHostUtc(timestamps[i]),
        participantId: currentParticipantId,
        activityIndex: currentActivityIndex,
        phaseName: currentPhaseName,
        ppg0: scaled(s[0]),
        ppg1: scaled(s[1]),
        ppg2: scaled(s[2]),
        ambient: scaled(s[3]),
        sensorTimeNs: timestamps[i],
      );
      recordedPpgSamples.add(sample);
      if (!_ppgStreamController.isClosed) _ppgStreamController.add(sample);
    }
  }

  /// Gyroscope and magnetometer frames, always delta coded. Type 0 carries
  /// three 16-bit axes times the factor the sensor reported (degrees per
  /// second, gauss); type 1 three float32 axes (gyro) or four 16-bit values
  /// in milligauss plus the calibration status (magnetometer), as GyrData
  /// and MagData in the Polar BLE SDK.
  void _parseThreeAxisFrame(int measurementType, Uint8List data) {
    final name = pmdStreamNames[measurementType]!.toUpperCase();
    if (data.length < 11) return;
    final timestampNs = _readUint64LittleEndian(data, 1);
    final compressed = (data[9] & 0x80) != 0;
    final frameType = data[9] & 0x7F;
    if (!compressed || frameType > 1) {
      debugPrint('[POLAR DEBUG] $name frame ${compressed ? 'delta' : 'raw'} type $frameType no soportado');
      return;
    }
    final content = Uint8List.sublistView(data, 10);
    final isMag = measurementType == pmdTypeMagnetometer;
    final channels = frameType == 1 && isMag ? 4 : 3;
    final resolution = frameType == 1 && !isMag ? 32 : 16;
    final samples = _parsePolarDeltaFramesToSamples(content, channels: channels, resolution: resolution);
    if (samples.isEmpty) return;
    final timestamps = _frameTimestamps(
      measurementType: measurementType,
      compressed: true,
      frameType: frameType,
      timestampNs: timestampNs,
      sampleCount: samples.length,
      sampleRateHz: isMag ? magSampleRateHz : gyroSampleRateHz,
    );
    final factor = _pmdFactor[measurementType] ?? 1.0;
    double value(int raw) {
      final base = resolution == 32 ? _int32BitsToFloat(raw) : raw.toDouble();
      final scaled = factor != 1.0 ? base * factor : base;
      return frameType == 1 && isMag ? scaled / 1000.0 : scaled;
    }

    for (var i = 0; i < samples.length; i++) {
      final s = samples[i];
      final t = _convertPmdTimestampToHostUtc(timestamps[i]);
      if (isMag) {
        final sample = PolarMagSample(
          timestamp: t,
          participantId: currentParticipantId,
          activityIndex: currentActivityIndex,
          phaseName: currentPhaseName,
          xGauss: value(s[0]),
          yGauss: value(s[1]),
          zGauss: value(s[2]),
          sensorTimeNs: timestamps[i],
        );
        recordedMagSamples.add(sample);
        if (!_magStreamController.isClosed) _magStreamController.add(sample);
      } else {
        final sample = PolarGyroSample(
          timestamp: t,
          participantId: currentParticipantId,
          activityIndex: currentActivityIndex,
          phaseName: currentPhaseName,
          xDps: value(s[0]),
          yDps: value(s[1]),
          zDps: value(s[2]),
          sensorTimeNs: timestamps[i],
        );
        recordedGyroSamples.add(sample);
        if (!_gyroStreamController.isClosed) _gyroStreamController.add(sample);
      }
    }
  }

  static double _int32BitsToFloat(int bits) =>
      (ByteData(4)..setInt32(0, bits, Endian.little)).getFloat32(0, Endian.little);

  /// PPI frame type 0 (Verity Sense): 6 bytes per pulse (heart rate, interval
  /// in ms, error estimate in ms, flags). The sensor sends them in batches;
  /// when the frame carries a sensor time it is that of the last pulse and
  /// the earlier ones are placed back by their intervals (PpiData in the
  /// Polar BLE SDK); otherwise the pulses share the arrival time of the
  /// batch and [PolarPpiSample.indexInFrame] orders them. The activity and
  /// phase of the rows are those at the arrival.
  void _parsePpiFrame(Uint8List data) {
    if (data.length < 11) return;
    final timestampNs = _readUint64LittleEndian(data, 1);
    final compressed = (data[9] & 0x80) != 0;
    final frameType = data[9] & 0x7F;
    if (compressed || frameType != 0) {
      debugPrint('[POLAR DEBUG] PPI frame type no soportado: $frameType');
      return;
    }
    final content = Uint8List.sublistView(data, 10);
    const bytesPerSample = 6;
    if (content.isEmpty || content.length % bytesPerSample != 0) {
      debugPrint('[POLAR DEBUG] PPI payload inválido: ${content.length} bytes');
      return;
    }
    final count = content.length ~/ bytesPerSample;
    final arrival = DateTime.now().toUtc();
    final intervals = [
      for (var i = 0; i < count; i++)
        content[i * bytesPerSample + 1] | (content[i * bytesPerSample + 2] << 8),
    ];
    final sensorTimes = List<int?>.filled(count, null);
    if (timestampNs != 0) {
      var t = timestampNs;
      for (var i = count - 1; i >= 0; i--) {
        sensorTimes[i] = t;
        t -= intervals[i] * 1000000;
      }
    }
    for (var i = 0; i < count; i++) {
      final o = i * bytesPerSample;
      final flags = content[o + 5];
      final sensorTime = sensorTimes[i];
      final sample = PolarPpiSample(
        timestamp: sensorTime == null ? arrival : _convertPmdTimestampToHostUtc(sensorTime),
        participantId: currentParticipantId,
        activityIndex: currentActivityIndex,
        phaseName: currentPhaseName,
        ppiMs: intervals[i],
        heartRateBpm: content[o],
        errorEstimateMs: content[o + 3] | (content[o + 4] << 8),
        blocker: flags & 0x01 != 0,
        skinContact: flags & 0x02 != 0,
        skinContactSupported: flags & 0x04 != 0,
        indexInFrame: i,
        sensorTimeNs: sensorTime,
      );
      recordedPpiSamples.add(sample);
      if (!_ppiStreamController.isClosed) _ppiStreamController.add(sample);
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
        sensorTimeNs:
            timestamps[i],
      );

      recordedEcgSamples.add(
        sample,
      );

      if (!_ecgStreamController.isClosed) {
        _ecgStreamController.add(
          sample,
        );
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
      sensorTimeNs: sampleNs,
    );

    recordedAccelerationSamples.add(
      sample,
    );

    if (!_accStreamController.isClosed) {
      _accStreamController.add(
        sample,
      );
    }

  }

  // ===========================================================================
  // HR START
  // ===========================================================================

  Future<void> startHeartRate() async {
    _requestedSensors.add('heart_rate');
    final characteristic = _hrCharacteristic;

    if (characteristic == null) {
      throw Exception(
        'HR characteristic no preparada',
      );
    }

    if (_hrStreaming) {
      return;
    }

    await _hrValueSubscription?.cancel();

    // Creamos el completer ANTES de suscribirnos para no perder
    // una posible primera notificación rápida.
    _firstHrNotificationCompleter = Completer<void>();

    _hrValueSubscription = characteristic.onValueReceived.listen(
      (value) {
        debugPrint(
          '[POLAR DEBUG] HR CALLBACK RECIBIDO: ${value.length} bytes',
        );

        _lastHrDataAt = DateTime.now();
        _parseHeartRateData(value);

        // Confirmamos que HR ya está recibiendo datos reales.
        if (!(_firstHrNotificationCompleter?.isCompleted ?? true)) {
          _firstHrNotificationCompleter!.complete();
        }
      },
    );

    if (!characteristic.notifications.isSupported) {
      throw Exception(
        'HR does not support notifications',
      );
    }

    await _gattRetry(
      'HR',
      () => characteristic.notifications.subscribe(
        timeout: const Duration(seconds: 15),
      ),
    );

    _lastHrDataAt = DateTime.now();
    _hrStreaming = true;
    _rrStreaming = true;

    debugPrint(
      '[POLAR DEBUG] HR notifications SUSCRITAS',
    );

    // No devolvemos el control todavía.
    // Esperamos a recibir el primer paquete HR real.
    try {
      await _firstHrNotificationCompleter!.future.timeout(
        const Duration(seconds: 2),
      );

      debugPrint(
        '[POLAR DEBUG] PRIMERA NOTIFICACIÓN HR RECIBIDA',
      );
    } on TimeoutException {
      debugPrint(
        '[POLAR DEBUG] TIMEOUT esperando primera notificación HR',
      );
    } finally {
      _firstHrNotificationCompleter = null;
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

      // One row per notification keeps every RR interval (a row per second
      // taken from the last value lost the RR of skipped notifications).
      if (bpm > 0 || rrList.isNotEmpty) {
        recordedSamples.add(
          PolarHrSample(
            timestamp: DateTime.now().toUtc(),
            participantId: currentParticipantId,
            activityIndex: currentActivityIndex,
            phaseName: currentPhaseName,
            heartRateBpm: bpm,
            rrIntervalsMs: rrList,
            hrSource: hrSource,
          ),
        );
      }

      if (!_hrStreamController.isClosed) {
        _hrStreamController.add(
          bpm,
        );
      }

      for (final rrMs in rrList) {
        if (!_rrStreamController.isClosed) {
          _rrStreamController.add(
            rrMs,
          );
        }
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

  /// Desconexión pedida por el usuario: no se reintenta automáticamente.
  Future<void> disconnect() async {
    _userRequestedDisconnect = true;
    _connectGeneration++;
    _sensorsToRestore.clear();
    _requestedSensors.clear();
    _stopPairingWatch();
    _stopWatchdog();

    if (_connectedDevice != null) {
      _logEvent('disconnected_by_user', _lastDeviceName);
    }

    await _teardownConnection();
    _setStatus(PolarLinkState.disconnected, 'Desconectado');
  }

  bool _tearingDown = false;

  Future<void> _teardownConnection() async {
    _tearingDown = true;
    try {
      await _teardownConnectionInner();
    } finally {
      _tearingDown = false;
    }
  }

  Future<void> _teardownConnectionInner() async {
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

    for (final (type, stop) in [
      (pmdTypePpg, stopPpg),
      (pmdTypePpi, stopPpi),
      (pmdTypeGyro, stopGyro),
      (pmdTypeMagnetometer, stopMagnetometer),
    ]) {
      try {
        if (isStreaming(pmdStreamNames[type]!)) await stop();
      } catch (e) {
        debugPrint('[POLAR DEBUG] Error deteniendo ${pmdStreamNames[type]}: $e');
      }
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
          seconds: 10,
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
    _lastHrDataAt = null;
    _lastPmdDataAt = null;

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

    _hrStreaming = false;
    _rrStreaming = false;
    _ecgStreaming = false;
    _accStreaming = false;
    _ppgStreaming = false;
    _ppiStreaming = false;
    _gyroStreaming = false;
    _magStreaming = false;
    _pmdSampleRateHz.clear();
    _pmdFactor.clear();

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
    _stopPairingWatch();
    await disconnect();
    linkStatus.dispose();
    await _connectionSubscription?.cancel();

    await _hrStreamController.close();
    await _ecgStreamController.close();
    await _accStreamController.close();
    await _ppgStreamController.close();
    await _ppiStreamController.close();
    await _gyroStreamController.close();
    await _magStreamController.close();
    await _scanStreamController.close();
  }

  // ===========================================================================
  // START CONFIGURED SENSORS
  // ===========================================================================

  /// Inicia los sensores configurados que el dispositivo soporta. Un fallo
  /// en uno no impide arrancar los demás. Devuelve los errores por sensor.
  Future<Map<String, String>> startConfiguredSensors(
    DeviceConfiguration configuration,
  ) async {
    final errors = <String, String>{};

    Future<void> run(String sensor, Future<void> Function() start) async {
      try {
        await start();
      } catch (e) {
        debugPrint('[POLAR DEBUG] Error iniciando $sensor: $e');
        errors[sensor] = _shortError(e);
        _logEvent('sensor_start_failed', '$sensor: $e');
      }
    }

    if (configuration.hasSensor('heart_rate')) {
      await run('heart_rate', startHeartRate);
    }

    if (configuration.hasSensor('acc')) {
      if (supportsAcc) {
        await run('acc', startAcceleration);
      } else {
        errors['acc'] = 'No soportado por $_lastDeviceName';
      }
    }

    if (configuration.hasSensor('ecg')) {
      if (supportsEcg) {
        await run('ecg', startEcg);
      } else {
        errors['ecg'] = 'No soportado por $_lastDeviceName';
      }
    }

    for (final (name, supported, start) in [
      ('ppg', supportsPpg, startPpg),
      ('ppi', supportsPpi, startPpi),
      ('gyro', supportsGyro, startGyro),
      ('mag', supportsMagnetometer, startMagnetometer),
    ]) {
      if (!configuration.hasSensor(name)) continue;
      if (supported) {
        await run(name, start);
      } else {
        errors[name] = 'No soportado por $_lastDeviceName';
      }
    }

    return errors;
  }

  /// Feeds a PMD data notification as if the sensor had sent it (tests).
  @visibleForTesting
  void handlePmdDataForTest(Uint8List data) => _handlePmdData(data);

  /// Applies the parameters of a PMD start response: sample rate and factor
  /// of a stream (tests).
  @visibleForTesting
  void applyStartResponseForTest(int measurementType, Uint8List payload) =>
      _updatePmdSettingsFromResponse(payload, measurementType: measurementType);
}

class _ConnectCancelled implements Exception {
  const _ConnectCancelled();

  @override
  String toString() => 'Conexión cancelada';
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

  /// Sensor clock of the sample (ns), before mapping it to the host clock.
  final int? sensorTimeNs;

  const PolarEcgSample({
    required this.timestamp,
    required this.participantId,
    required this.activityIndex,
    required this.phaseName,
    required this.microVolts,
    this.sensorTimeNs,
  });

  static const String csvHeader =
      'timestamp_iso,participant_id,activity_index,phase_name,ecg_uv,sensor_time_ns';

  String toCsvRow() {
    return '${timestamp.toIso8601String()},'
        '$participantId,'
        '$activityIndex,'
        '$phaseName,'
        '$microVolts,'
        '${sensorTimeNs ?? ''}';
  }
}

/// One PMD frame as received: see [PolarBleService.clockObservations].
class PmdClockObservation {
  final int measurementType;
  final int arrivalHostMicros;
  final int frameSensorNs;
  final int offsetMicros;

  const PmdClockObservation({
    required this.measurementType,
    required this.arrivalHostMicros,
    required this.frameSensorNs,
    required this.offsetMicros,
  });

  static const String csvHeader =
      'arrival_utc,stream,frame_sensor_time_ns,offset_us';

  String toCsvRow() {
    final stream = PolarBleService.pmdStreamNames[measurementType] ?? '$measurementType';
    final arrival = DateTime.fromMicrosecondsSinceEpoch(arrivalHostMicros, isUtc: true);
    return '${arrival.toIso8601String()},$stream,$frameSensorNs,$offsetMicros';
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

  /// Sensor clock of the sample (ns), before mapping it to the host clock.
  final int? sensorTimeNs;

  const PolarAccelerationSample({
    required this.timestamp,
    required this.participantId,
    required this.activityIndex,
    required this.phaseName,
    required this.xMg,
    required this.yMg,
    required this.zMg,
    this.sensorTimeNs,
  });

  static const String csvHeader =
      'timestamp_iso,participant_id,activity_index,phase_name,'
      'acc_x_mg,acc_y_mg,acc_z_mg,sensor_time_ns';

  String toCsvRow() {
    return '${timestamp.toIso8601String()},'
        '$participantId,'
        '$activityIndex,'
        '$phaseName,'
        '$xMg,'
        '$yMg,'
        '$zMg,'
        '${sensorTimeNs ?? ''}';
  }
}


// =============================================================================
// VERITY SENSE SAMPLES: PPG, PPI, GYRO, MAGNETOMETER
// =============================================================================

/// One PPG sample of the Verity Sense: raw 22-bit counts of its three green
/// channels and of the ambient-light channel (PMD PPG frame type 0).
class PolarPpgSample {
  final DateTime timestamp;
  final String participantId;
  final int activityIndex;
  final String phaseName;
  final int ppg0;
  final int ppg1;
  final int ppg2;
  final int ambient;

  /// Sensor clock of the sample (ns), before mapping it to the host clock.
  final int? sensorTimeNs;

  const PolarPpgSample({
    required this.timestamp,
    required this.participantId,
    required this.activityIndex,
    required this.phaseName,
    required this.ppg0,
    required this.ppg1,
    required this.ppg2,
    required this.ambient,
    this.sensorTimeNs,
  });

  static const String csvHeader =
      'timestamp_iso,participant_id,activity_index,phase_name,ppg0,ppg1,ppg2,ambient,sensor_time_ns';

  String toCsvRow() => '${timestamp.toIso8601String()},$participantId,$activityIndex,$phaseName,'
      '$ppg0,$ppg1,$ppg2,$ambient,${sensorTimeNs ?? ''}';
}

/// One pulse of Polar's PPI algorithm (Verity Sense): the interval to the
/// previous pulse, the heart rate the algorithm derives from it, its error
/// estimate and the flags of the sensor.
class PolarPpiSample {
  final DateTime timestamp;
  final String participantId;
  final int activityIndex;
  final String phaseName;
  final int ppiMs;
  final int heartRateBpm;
  final int errorEstimateMs;

  /// Movement detected: the interval is not reliable.
  final bool blocker;
  final bool skinContact;
  final bool skinContactSupported;

  /// Position of the pulse in its batch, which orders the pulses of a batch
  /// that shares one arrival time.
  final int indexInFrame;

  /// Sensor clock of the pulse (ns) when the frame carried one.
  final int? sensorTimeNs;

  const PolarPpiSample({
    required this.timestamp,
    required this.participantId,
    required this.activityIndex,
    required this.phaseName,
    required this.ppiMs,
    required this.heartRateBpm,
    required this.errorEstimateMs,
    required this.blocker,
    required this.skinContact,
    required this.skinContactSupported,
    required this.indexInFrame,
    this.sensorTimeNs,
  });

  /// Source of [heartRateBpm], see [PolarHrSample.hrSource].
  static const String hrSource = 'verity_ppi_firmware';

  static const String csvHeader =
      'timestamp_iso,participant_id,activity_index,phase_name,ppi_ms,hr_bpm,error_estimate_ms,'
      'blocker,skin_contact,skin_contact_supported,index_in_frame,sensor_time_ns,hr_source';

  String toCsvRow() => '${timestamp.toIso8601String()},$participantId,$activityIndex,$phaseName,'
      '$ppiMs,$heartRateBpm,$errorEstimateMs,${blocker ? 1 : 0},${skinContact ? 1 : 0},'
      '${skinContactSupported ? 1 : 0},$indexInFrame,${sensorTimeNs ?? ''},$hrSource';
}

/// One gyroscope sample of the Verity Sense, in degrees per second.
class PolarGyroSample {
  final DateTime timestamp;
  final String participantId;
  final int activityIndex;
  final String phaseName;
  final double xDps;
  final double yDps;
  final double zDps;

  /// Sensor clock of the sample (ns), before mapping it to the host clock.
  final int? sensorTimeNs;

  const PolarGyroSample({
    required this.timestamp,
    required this.participantId,
    required this.activityIndex,
    required this.phaseName,
    required this.xDps,
    required this.yDps,
    required this.zDps,
    this.sensorTimeNs,
  });

  static const String csvHeader =
      'timestamp_iso,participant_id,activity_index,phase_name,gyro_x_dps,gyro_y_dps,gyro_z_dps,sensor_time_ns';

  String toCsvRow() => '${timestamp.toIso8601String()},$participantId,$activityIndex,$phaseName,'
      '$xDps,$yDps,$zDps,${sensorTimeNs ?? ''}';
}

/// One magnetometer sample of the Verity Sense, in gauss.
class PolarMagSample {
  final DateTime timestamp;
  final String participantId;
  final int activityIndex;
  final String phaseName;
  final double xGauss;
  final double yGauss;
  final double zGauss;

  /// Sensor clock of the sample (ns), before mapping it to the host clock.
  final int? sensorTimeNs;

  const PolarMagSample({
    required this.timestamp,
    required this.participantId,
    required this.activityIndex,
    required this.phaseName,
    required this.xGauss,
    required this.yGauss,
    required this.zGauss,
    this.sensorTimeNs,
  });

  static const String csvHeader =
      'timestamp_iso,participant_id,activity_index,phase_name,mag_x_gauss,mag_y_gauss,mag_z_gauss,sensor_time_ns';

  String toCsvRow() => '${timestamp.toIso8601String()},$participantId,$activityIndex,$phaseName,'
      '$xGauss,$yGauss,$zGauss,${sensorTimeNs ?? ''}';
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