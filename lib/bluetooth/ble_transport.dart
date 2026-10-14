import 'package:flutter/services.dart';

class BleDevice {
  const BleDevice({
    required this.id,
    required this.name,
    required this.source,
    this.rssi,
  });
  final String id, name, source;
  final int? rssi;
}

abstract interface class BleTransport {
  Stream<Map<String, dynamic>> get events;
  Future<void> scan(int generation);
  Future<void> stopScan();
  Future<void> connect(String id, String mode, int generation);
  Future<void> write(Uint8List bytes, int generation);
  Future<void> disconnect();
  Future<String?> loadSettings();
  Future<void> saveSettings(String json);
  Future<void> openSettings();
  Future<void> keepAwake(bool enabled);
}

class PlatformBleTransport implements BleTransport {
  static const _methods = MethodChannel('ble.remote/methods');
  static const _events = EventChannel('ble.remote/events');
  late final Stream<Map<String, dynamic>> _stream = _events
      .receiveBroadcastStream()
      .map((event) => Map<String, dynamic>.from(event as Map));
  @override
  Stream<Map<String, dynamic>> get events => _stream;
  @override
  Future<void> scan(int generation) =>
      _methods.invokeMethod<void>('scan', {'generation': generation});
  @override
  Future<void> stopScan() => _methods.invokeMethod<void>('stopScan');
  @override
  Future<void> connect(String id, String mode, int generation) =>
      _methods.invokeMethod<void>('connect', {
        'id': id,
        'mode': mode,
        'generation': generation,
      });
  @override
  Future<void> write(Uint8List bytes, int generation) => _methods
      .invokeMethod<void>('write', {'bytes': bytes, 'generation': generation});
  @override
  Future<void> disconnect() => _methods.invokeMethod<void>('disconnect');
  @override
  Future<String?> loadSettings() =>
      _methods.invokeMethod<String>('loadSettings');
  @override
  Future<void> saveSettings(String json) =>
      _methods.invokeMethod<void>('saveSettings', {'json': json});
  @override
  Future<void> openSettings() => _methods.invokeMethod<void>('openSettings');
  @override
  Future<void> keepAwake(bool enabled) =>
      _methods.invokeMethod<void>('keepAwake', {'enabled': enabled});
}
