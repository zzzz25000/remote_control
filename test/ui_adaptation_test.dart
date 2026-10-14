import 'package:ble/main.dart';
import 'package:ble/control/remote_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_transport.dart';

void main() {
  testWidgets('Bluetooth dialog fits small landscape while listing devices', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(568, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fake = FakeTransport();
    final c = RemoteController(transport: fake);
    await c.initialize();
    await tester.pumpWidget(MyApp(controller: c));
    await tester.tap(find.byKey(const ValueKey('bluetooth-connect')));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(c.scanning, isTrue);
    fake.bus.add({
      'type': 'device',
      'generation': fake.lastGeneration,
      'id': 'PERIPHERAL-ID',
      'name': 'Test module',
      'source': 'BLE',
    });
    await tester.pump();
    expect(c.devices, hasLength(1));
    expect(tester.takeException(), isNull);
    expect(find.text('Test module'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(c.scanning, isFalse);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await fake.bus.close();
  });
  testWidgets('tiny landscape uses three columns and keeps options reachable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(568, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fake = FakeTransport();
    final c = RemoteController(transport: fake);
    await c.initialize();
    await tester.pumpWidget(MyApp(controller: c));
    final hub = tester.getTopLeft(find.byKey(const ValueKey('panel-enable')));
    final card = tester.getRect(find.byKey(const ValueKey('panel-leftStick')));
    expect(hub.dx, greaterThan(card.right));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await fake.bus.close();
  });
}
