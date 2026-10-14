import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ble/bluetooth/ble_transport.dart';
import 'package:ble/control/remote_controller.dart';
import 'package:ble/control/control_config.dart';

import 'support/fake_transport.dart';

void main() {
  testWidgets(
    'send delay plus pending write reaches MCU expiry before 300ms write timeout',
    (tester) async {
      final link = FakeTransport();
      final c = RemoteController(transport: link);
      await c.initialize();
      await c.connect(
        const BleDevice(id: 'device', name: 'module', source: 'BLE'),
      );
      c.enable(true);
      link.gate = Completer<void>();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 280));
      expect(c.state.enabled, false);
      expect(c.canEnable, false);
      link.gate!.complete();
      link.gate = null;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(link.frames.last[16], 0);
      await c.disconnect();
      c.dispose();
      await link.bus.close();
    },
  );
  testWidgets('closing scan during teardown cannot start it afterwards', (
    tester,
  ) async {
    final link = FakeTransport()..disconnectGate = Completer<void>();
    final c = RemoteController(transport: link);
    await c.initialize();
    final pending = c.scan();
    await tester.pump();
    await c.stopScan();
    link.disconnectGate!.complete();
    link.disconnectGate = null;
    await pending;
    expect(link.scanCalls, 0);
    expect(c.scanning, false);
    c.dispose();
    await link.bus.close();
  });
  testWidgets('late scan start cannot revive scanning after explicit stop', (
    tester,
  ) async {
    final link = FakeTransport();
    final c = RemoteController(transport: link);
    await c.initialize();
    await c.scan();
    final token = link.lastGeneration;
    await c.stopScan();
    link.bus.add({
      'type': 'scan',
      'generation': token,
      'scanning': true,
      'details': 'late',
    });
    expect(c.scanning, false);
    c.dispose();
    await link.bus.close();
  });
  testWidgets('rapid mode reversal keeps latest mode and persisted profile', (
    tester,
  ) async {
    final link = FakeTransport();
    final c = RemoteController(transport: link);
    await c.initialize();
    final first = c.changeMode(LinkMode.bt630);
    final second = c.changeMode(LinkMode.uart);
    await Future.wait([first, second]);
    await tester.pump();
    expect(c.mode, LinkMode.uart);
    expect(link.settings, contains('"mode":"uart"'));
    c.dispose();
    await link.bus.close();
  });
  testWidgets('terminal scan event retains the actionable scan error', (
    tester,
  ) async {
    final link = FakeTransport();
    final c = RemoteController(transport: link);
    await c.initialize();
    await c.scan();
    final token = link.lastGeneration;
    link.bus.add({
      'type': 'error',
      'generation': token,
      'code': 'bluetooth_off',
      'message': '蓝牙已关闭，请开启蓝牙',
    });
    link.bus.add({
      'type': 'scan',
      'generation': token,
      'scanning': false,
      'details': '已停止',
    });
    expect(c.status, '蓝牙已关闭，请开启蓝牙');
    expect(c.scanning, false);
    c.dispose();
    await link.bus.close();
  });
  testWidgets(
    'permission modal preserves pending scan while real background cancels it',
    (tester) async {
      final link = FakeTransport()..scanGate = Completer<void>();
      final c = RemoteController(transport: link);
      await c.initialize();
      final scanning = c.scan();
      await tester.pump();
      final before = link.disconnections;
      await c.interruption();
      expect(link.disconnections, before);
      expect(c.state.enabled, false);
      await c.foreground(true);
      link.scanGate!.complete();
      await scanning;
      link.bus.add({
        'type': 'device',
        'generation': link.lastGeneration,
        'id': 'ok',
        'name': 'module',
        'source': 'BLE',
      });
      expect(c.devices.single.id, 'ok');
      await c.foreground(false);
      expect(link.disconnections, before + 1);
      expect(c.scanning, false);
      c.dispose();
      await link.bus.close();
    },
  );
  testWidgets(
    'two connect requests in one turn only attempt the newest device',
    (tester) async {
      final link = FakeTransport();
      final c = RemoteController(transport: link);
      await c.initialize();
      final first = c.connect(
        const BleDevice(id: 'first', name: 'first', source: 'BLE'),
      );
      final second = c.connect(
        const BleDevice(id: 'second', name: 'second', source: 'BLE'),
      );
      await tester.pump();
      await Future.wait([first, second]);
      expect(link.connectedIds, ['second']);
      expect(c.connected, true);
      await c.disconnect();
      c.dispose();
      await link.bus.close();
    },
  );
  testWidgets(
    'disconnect during connection ignores late ready and sends no handshake',
    (tester) async {
      final link = FakeTransport()..connectGate = Completer<void>();
      final c = RemoteController(transport: link);
      await c.initialize();
      final ready = c.connect(
        const BleDevice(id: 'first', name: 'first', source: 'BLE'),
      );
      await tester.pump();
      await c.disconnect();
      link.connectGate!.complete();
      await ready;
      expect(c.connected, false);
      expect(link.frames, isEmpty);
      expect(c.state.enabled, false);
      c.dispose();
      await link.bus.close();
    },
  );
  testWidgets(
    'disabled handshake precedes enabling and pending writes do not queue',
    (tester) async {
      final link = FakeTransport()..gate = Completer<void>();
      final c = RemoteController(transport: link);
      await c.initialize();
      final ready = c.connect(
        const BleDevice(id: 'device', name: 'module', source: 'BLE'),
      );
      await tester.pump();
      c.enable(true);
      expect(c.state.enabled, false);
      expect(link.frames.single[16], 0);
      link.gate!.complete();
      link.gate = null;
      await tester.pump();
      await ready;
      c.enable(true);
      c.axes(0, 1000, 0);
      link.gate = Completer<void>();
      await tester.pump(const Duration(milliseconds: 50));
      c.axes(0, -1000, 0);
      await tester.pump(const Duration(milliseconds: 100));
      expect(link.maximumWrites, 1);
      expect(link.frames.length, 2);
      link.gate!.complete();
      link.gate = null;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(link.frames.last.sublist(4, 6), [0x18, 0xfc]);
      await c.disconnect();
      c.dispose();
      await link.bus.close();
    },
  );
  testWidgets('300ms stalled write disarms and requires a new disabled frame', (
    tester,
  ) async {
    final link = FakeTransport();
    final c = RemoteController(transport: link);
    await c.initialize();
    await c.connect(
      const BleDevice(id: 'device', name: 'module', source: 'BLE'),
    );
    c.enable(true);
    c.axes(0, 1000, 500);
    link.gate = Completer<void>();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 300));
    expect(c.state.enabled, false);
    expect(c.state.lx, 0);
    c.enable(true);
    expect(c.state.enabled, false);
    link.gate!.complete();
    link.gate = null;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(link.frames.last[16], 0);
    c.enable(true);
    expect(c.state.enabled, true);
    await c.disconnect();
    c.dispose();
    await link.bus.close();
  });
  testWidgets(
    'background clears state and stale scan/connection events are rejected',
    (tester) async {
      final link = FakeTransport();
      final c = RemoteController(transport: link);
      await c.initialize();
      await c.connect(
        const BleDevice(id: 'device', name: 'module', source: 'BLE'),
      );
      final old = link.lastGeneration;
      c.enable(true);
      c.axes(1, 800, -900);
      final off = c.foreground(false);
      expect(c.state.enabled, false);
      expect(c.state.rx, 0);
      link.bus.add({
        'type': 'device',
        'generation': old,
        'id': 'late',
        'name': 'late',
        'source': 'BLE',
      });
      link.bus.add({
        'type': 'disconnected',
        'generation': old,
        'message': 'stale',
      });
      await off;
      expect(c.devices, isEmpty);
      expect(c.connected, false);
      c.dispose();
      await link.bus.close();
    },
  );
  testWidgets('config and layout persist while cancelled draft does not', (
    tester,
  ) async {
    final link = FakeTransport();
    final c = RemoteController(transport: link);
    await c.initialize();
    c.setSliderConfig(0, SliderConfig(values: [0, 9, 100]));
    c.setStickConfig(1, const JoystickConfig(maxValue: 255));
    c.beginLayoutEdit();
    c.resizePanel(.6);
    c.cancelLayoutEdit();
    await tester.pump();
    final other = RemoteController(transport: link);
    await other.initialize();
    expect(other.sliderConfigs[0].values, [0, 9, 100]);
    expect(other.stickConfigs[1].maxValue, 255);
    expect(other.layout.scales, isEmpty);
    c.dispose();
    other.dispose();
    await link.bus.close();
  });
  testWidgets(
    'malformed saved data and unsupported versions fall back safely',
    (tester) async {
      final link = FakeTransport()..settings = '{"version":99,"mode":"bt630"}';
      final c = RemoteController(transport: link);
      await c.initialize();
      expect(c.mode, LinkMode.uart);
      c.dispose();
      link.settings = 'broken json';
      final d = RemoteController(transport: link);
      await d.initialize();
      expect(d.stickConfigs[0].maxValue, 1000);
      expect(d.state.enabled, false);
      d.dispose();
      await link.bus.close();
    },
  );
}
