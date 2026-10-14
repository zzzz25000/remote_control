import 'dart:async';
import 'dart:typed_data';

import 'package:ble/bluetooth/ble_transport.dart';

class FakeTransport implements BleTransport {
  final bus = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final frames = <Uint8List>[];
  final saved = <String>[];
  Completer<void>? gate;
  Completer<void>? connectGate;
  Completer<void>? scanGate;
  Completer<void>? disconnectGate;
  int scanCalls = 0;
  int disconnections = 0;
  final connectedIds = <String>[];
  String? settings;
  int activeWrites = 0, maximumWrites = 0, lastGeneration = 0;
  @override
  Stream<Map<String, dynamic>> get events => bus.stream;
  @override
  Future<void> scan(int generation) async {
    scanCalls++;
    lastGeneration = generation;
    await scanGate?.future;
  }

  @override
  Future<void> stopScan() async {}
  @override
  Future<void> connect(String id, String mode, int generation) async {
    lastGeneration = generation;
    connectedIds.add(id);
    await connectGate?.future;
  }

  @override
  Future<void> write(Uint8List bytes, int generation) async {
    activeWrites++;
    if (activeWrites > maximumWrites) maximumWrites = activeWrites;
    frames.add(Uint8List.fromList(bytes));
    try {
      await gate?.future;
    } finally {
      activeWrites--;
    }
  }

  @override
  Future<void> disconnect() async {
    disconnections++;
    await disconnectGate?.future;
  }

  @override
  Future<String?> loadSettings() async => settings;
  @override
  Future<void> saveSettings(String json) async {
    saved.add(json);
    settings = json;
  }

  @override
  Future<void> openSettings() async {}
  @override
  Future<void> keepAwake(bool enabled) async {}
}
