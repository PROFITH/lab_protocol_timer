import 'dart:async';
import 'dart:io';

/// Appends rows to a CSV file while a session runs and writes them to disk
/// about once a second, so a crash loses at most the last second.
///
/// The file is created with [header] at the first row; an existing file
/// (a session resumed after a crash) gets the new rows at its end. A write
/// that fails (a locked file on a synced drive) is tried again with the
/// next rows; [lastError] keeps the reason for the operator.
class CsvStreamWriter {
  CsvStreamWriter(this.path, this.header, {this.flushEvery = const Duration(seconds: 1)});

  final String path;
  final String header;
  final Duration flushEvery;

  IOSink? _sink;
  final StringBuffer _buffer = StringBuffer();
  String _retry = '';
  Timer? _timer;
  Future<void> _pending = Future.value();
  bool _closed = false;

  int rows = 0;
  Object? lastError;
  DateTime? lastErrorAt;

  bool get isClosed => _closed;

  void add(String row) {
    if (_closed) return;
    _buffer.writeln(row);
    rows++;
    _timer ??= Timer(flushEvery, flush);
  }

  /// Writes what is buffered now.
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    if (_buffer.isEmpty && _retry.isEmpty) return _pending;
    final chunk = _retry + _buffer.toString();
    _retry = '';
    _buffer.clear();
    _pending = _pending.then((_) => _write(chunk));
    return _pending;
  }

  Future<void> _write(String chunk) async {
    try {
      var sink = _sink;
      if (sink == null) {
        final file = File(path);
        final hasHeader = await file.exists() && await file.length() > 0;
        sink = file.openWrite(mode: FileMode.append);
        if (!hasHeader) sink.writeln(header);
        _sink = sink;
      }
      sink.write(chunk);
      await sink.flush();
      lastError = null;
    } catch (e) {
      lastError = e;
      lastErrorAt = DateTime.now();
      _retry = chunk + _retry;
      final broken = _sink;
      _sink = null;
      try {
        await broken?.close();
      } catch (_) {}
      if (!_closed) _timer ??= Timer(flushEvery, flush);
    }
  }

  Future<void> close() async {
    if (_closed) return _pending;
    await flush();
    _closed = true;
    _timer?.cancel();
    _timer = null;
    if (_retry.isNotEmpty) {
      // One last try.
      final chunk = _retry;
      _retry = '';
      await _write(chunk);
    }
    try {
      await _sink?.close();
    } catch (e) {
      lastError = e;
    }
    _sink = null;
  }
}

/// Quotes a CSV field when it needs it.
String csvField(Object? value) {
  if (value == null) return '';
  final text = value.toString();
  if (!text.contains(RegExp(r'[",\n\r]'))) return text;
  return '"${text.replaceAll('"', '""')}"';
}
