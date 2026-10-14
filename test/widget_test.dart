import 'package:ble/main.dart';
import 'package:ble/control/control_config.dart';
import 'package:ble/control/remote_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_transport.dart';

Future<RemoteController> panel(
  WidgetTester tester, {
  Size size = const Size(1000, 560),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final transport = FakeTransport();
  final controller = RemoteController(transport: transport);
  await controller.initialize();
  await tester.pumpWidget(MyApp(controller: controller));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await transport.bus.close();
  });
  return controller;
}

void main() {
  testWidgets('reference panel exposes sliders, two sticks and fixed options', (
    tester,
  ) async {
    await panel(tester);
    expect(find.text('ROBOT CONTROL'), findsOneWidget);
    expect(find.text('功能选项'), findsOneWidget);
    expect(find.text('左摇杆'), findsOneWidget);
    expect(find.text('右摇杆'), findsOneWidget);
    expect(find.text('蓝牙使能'), findsOneWidget);
  });
  testWidgets(
    'two pointers move independently and cancel clears only its stick',
    (tester) async {
      final c = await panel(tester);
      final left = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('leftPadGesture'))),
        pointer: 1,
      );
      final right = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('rightPadGesture'))),
        pointer: 2,
      );
      await left.moveBy(const Offset(50, -30));
      await right.moveBy(const Offset(-40, 20));
      await tester.pump();
      expect(c.state.lx, greaterThan(0));
      expect(c.state.ly, greaterThan(0));
      expect(c.state.rx, lessThan(0));
      expect(c.state.ry, lessThan(0));
      await left.cancel();
      await tester.pump();
      expect(c.state.lx, 0);
      expect(c.state.ly, 0);
      expect(c.state.rx, lessThan(0));
      await right.up();
      await tester.pump();
      expect(c.state.rx, 0);
      expect(c.state.ry, 0);
    },
  );
  testWidgets('mode revision rejects held pointer until a fresh down', (
    tester,
  ) async {
    final c = await panel(tester);
    final finder = find.byKey(const ValueKey('leftPadGesture'));
    final gesture = await tester.startGesture(
      tester.getCenter(finder),
      pointer: 1,
    );
    await gesture.moveBy(const Offset(60, 10));
    await tester.pump();
    expect(c.state.lx, greaterThan(0));
    c.cycleStickMode(0);
    await tester.pump();
    await gesture.moveBy(const Offset(25, 15));
    await tester.pump();
    expect(c.state.lx, 0);
    expect(c.state.ly, 0);
    await gesture.up();
    final fresh = await tester.startGesture(
      tester.getCenter(finder),
      pointer: 2,
    );
    await fresh.moveBy(const Offset(45, 30));
    await tester.pump();
    expect(c.state.lx, greaterThan(0));
    expect(c.state.ly, 0);
    await fresh.up();
  });
  testWidgets(
    'layout draft moves pad beyond card and cancel restores saved geometry',
    (tester) async {
      final c = await panel(tester);
      final pad = find.byKey(const ValueKey('panel-leftPad'));
      final original = tester.getTopLeft(pad);
      await tester.tap(find.byKey(const ValueKey('options')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑布局'));
      await tester.pumpAndSettle();
      expect(c.layoutEditing, isTrue);
      await tester.drag(pad, const Offset(400, -100));
      await tester.pump();
      expect(tester.getTopLeft(pad).dx, greaterThan(original.dx + 250));
      expect(c.selectedLayoutId, 'leftPad');
      await tester.tap(find.text('取消'));
      await tester.pump();
      expect(c.layoutEditing, isFalse);
      expect(tester.getTopLeft(pad), original);
      c.beginLayoutEdit();
      await tester.pump();
      await tester.drag(pad, const Offset(350, -70));
      await tester.pump();
      await tester.tap(find.text('保存布局'));
      await tester.pump();
      expect(c.layout.positions['leftPad'], isNotNull);
      final saved = c.layout.positions['leftPad'];
      c.beginLayoutEdit();
      c.defaultLayoutDraft();
      c.cancelLayoutEdit();
      expect(c.layout.positions['leftPad'], same(saved));
    },
  );
  testWidgets('duplicate slider values disable apply and valid values save', (
    tester,
  ) async {
    final c = await panel(tester);
    await tester.tap(find.byKey(const ValueKey('options')));
    await tester.pumpAndSettle();
    expect(find.text('面板设置'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('step-value-0-1')), '0');
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('slider-apply-0')))
          .onPressed,
      isNull,
    );
    await tester.enterText(find.byKey(const ValueKey('step-value-0-1')), '800');
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('slider-apply-0')));
    await tester.tap(find.byKey(const ValueKey('slider-apply-0')));
    await tester.pumpAndSettle();
    expect(c.sliderConfigs[0].values, [0, 800, 2]);
    expect(c.state.slider1, 0);
  });
  testWidgets(
    'small portrait and landscape have no overflow and edit back cancels',
    (tester) async {
      final c = await panel(tester, size: const Size(320, 568));
      expect(tester.takeException(), isNull);
      c.beginLayoutEdit();
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(c.layoutEditing, isFalse);
      tester.view.physicalSize = const Size(568, 320);
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('each stick cycles its own four modes', (tester) async {
    final c = await panel(tester);
    for (final mode in [
      JoystickMode.horizontal,
      JoystickMode.vertical,
      JoystickMode.fourWay,
      JoystickMode.free,
    ]) {
      await tester.tap(find.byKey(const ValueKey('mode-0')));
      await tester.pump();
      expect(c.stickConfigs[0].mode, mode);
      expect(c.stickConfigs[1].mode, JoystickMode.free);
    }
  });
  testWidgets('second finger cannot steal the first finger stick', (
    tester,
  ) async {
    final c = await panel(tester);
    final center = tester.getCenter(
      find.byKey(const ValueKey('leftPadGesture')),
    );
    final first = await tester.startGesture(center, pointer: 1);
    await first.moveBy(const Offset(45, 0));
    await tester.pump();
    final original = c.state.lx;
    final second = await tester.startGesture(center, pointer: 2);
    await second.moveBy(const Offset(-60, 0));
    await tester.pump();
    expect(c.state.lx, original);
    await second.up();
    await tester.pump();
    expect(c.state.lx, original);
    await first.up();
    await tester.pump();
    expect(c.state.lx, 0);
  });
  testWidgets('editing size stays inside canvas and return cancels draft', (
    tester,
  ) async {
    final c = await panel(tester);
    c.beginLayoutEdit();
    c.selectPanel('leftPad');
    await tester.pump();
    final slider = find.byKey(const ValueKey('layout-size'));
    await tester.drag(slider, const Offset(1000, 0));
    await tester.pump();
    expect(c.layout.scales['leftPad'], 2.5);
    final rect = tester.getRect(find.byKey(const ValueKey('panel-leftPad')));
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(1000));
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(c.layoutEditing, isFalse);
    expect(c.layout.scales, isEmpty);
  });
  testWidgets('lifecycle interrupts a held gesture and requires a new touch', (
    tester,
  ) async {
    final c = await panel(tester);
    final pad = find.byKey(const ValueKey('leftPadGesture'));
    final held = await tester.startGesture(tester.getCenter(pad), pointer: 1);
    await held.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(c.state.lx, greaterThan(0));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(c.state.lx, 0);
    expect(c.state.enabled, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(c.controlsActive, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await held.moveBy(const Offset(30, 0));
    await tester.pump();
    expect(c.state.lx, 0);
    await held.up();
    final fresh = await tester.startGesture(tester.getCenter(pad), pointer: 2);
    await fresh.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(c.state.lx, greaterThan(0));
    await fresh.up();
  });
  testWidgets('joystick feedback describes mapped axes in horizontal mode', (
    tester,
  ) async {
    final c = await panel(tester);
    c.setStickConfig(
      0,
      const JoystickConfig(mode: JoystickMode.horizontal, maxValue: 600),
    );
    await tester.pump();
    final pad = find.byKey(const ValueKey('leftPadGesture'));
    final touch = await tester.startGesture(tester.getCenter(pad));
    await touch.moveBy(const Offset(40, -40));
    await tester.pump();
    final semantics = tester.widget<Semantics>(
      find.descendant(of: pad, matching: find.byType(Semantics)).first,
    );
    expect(semantics.properties.value, 'X: ${c.state.lx}, Y: 0');
    await touch.up();
  });
  testWidgets(
    'invalid left slider draft does not block applying right slider',
    (tester) async {
      final c = await panel(tester);
      await tester.tap(find.byKey(const ValueKey('options')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('step-value-0-1')), '0');
      await tester.pump();
      final right = find.byKey(const ValueKey('step-value-1-1'));
      await tester.ensureVisible(right);
      await tester.enterText(right, '400');
      await tester.pump();
      final apply = find.byKey(const ValueKey('slider-apply-1'));
      await tester.ensureVisible(apply);
      await tester.tap(apply);
      await tester.pump();
      expect(c.sliderConfigs[1].values, [0, 400, 2]);
      expect(c.sliderConfigs[0].values, [0, 1, 2]);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(c.sliderConfigs[0].values, [0, 1, 2]);
    },
  );
  testWidgets(
    'applying left stick settings preserves untouched right axes and revision',
    (tester) async {
      final c = await panel(tester);
      await tester.tap(find.byKey(const ValueKey('options')));
      await tester.pumpAndSettle();
      final maximum = find.byKey(const ValueKey('stick-max-0'));
      await tester.ensureVisible(maximum);
      await tester.enterText(maximum, '500');
      await tester.pump();
      c.axes(1, 400, -200);
      final rightX = c.state.rx,
          rightY = c.state.ry,
          revision = c.gestureRevisions[1];
      final apply = find.byKey(const ValueKey('stick-apply-0'));
      await tester.ensureVisible(apply);
      await tester.tap(apply);
      await tester.pump();
      expect(c.stickConfigs[0].maxValue, 500);
      expect(c.state.rx, rightX);
      expect(c.state.ry, rightY);
      expect(c.gestureRevisions[1], revision);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(c.state.rx, rightX);
    },
  );
  testWidgets('four-way drag outside pad keeps dominant horizontal direction', (
    tester,
  ) async {
    final c = await panel(tester);
    c.setStickConfig(0, const JoystickConfig(mode: JoystickMode.fourWay));
    await tester.pump();
    final pad = find.byKey(const ValueKey('leftPadGesture'));
    final held = await tester.startGesture(tester.getCenter(pad));
    await held.moveBy(const Offset(330, -100));
    await tester.pump();
    expect(c.state.lx, 1000);
    expect(c.state.ly, 0);
    await held.up();
  });
  testWidgets('rotation releases held sticks while preserving slider values', (
    tester,
  ) async {
    final c = await panel(tester);
    c.slider(0, 1000);
    await tester.pump();
    final pad = find.byKey(const ValueKey('leftPadGesture'));
    final held = await tester.startGesture(tester.getCenter(pad));
    await held.moveBy(const Offset(40, -20));
    await tester.pump();
    expect(c.state.lx, greaterThan(0));
    tester.view.physicalSize = const Size(390, 844);
    await tester.pump();
    expect(c.state.lx, 0);
    expect(c.state.ly, 0);
    expect(c.state.slider1, 2);
    await held.moveBy(const Offset(30, 0));
    await tester.pump();
    expect(c.state.lx, 0);
    await held.up();
    final fresh = await tester.startGesture(tester.getCenter(pad));
    await fresh.moveBy(const Offset(30, 0));
    await tester.pump();
    expect(c.state.lx, greaterThan(0));
    await fresh.up();
  });
  testWidgets('selecting a discovered device enables manual Bluetooth switch', (
    tester,
  ) async {
    final c = await panel(tester);
    final fake = c.transport as FakeTransport;
    expect(
      tester
          .widget<Switch>(find.byKey(const ValueKey('enable-switch')))
          .onChanged,
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('bluetooth-connect')));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    fake.bus.add({
      'type': 'device',
      'generation': fake.lastGeneration,
      'id': 'test-module',
      'name': 'Test module',
      'source': 'BLE',
    });
    await tester.pump();
    await tester.tap(find.text('Test module'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(c.connected, isTrue);
    expect(c.state.enabled, isFalse);
    expect(fake.connectedIds, ['test-module']);
    await tester.tap(find.byKey(const ValueKey('enable-switch')));
    await tester.pump();
    expect(c.state.enabled, isTrue);
    await tester.tap(find.byKey(const ValueKey('enable-switch')));
    await tester.pump();
    expect(c.state.enabled, isFalse);
    await c.disconnect();
    await tester.pump();
  });
  testWidgets(
    'joystick vertical drag controls Y without scrolling portrait canvas',
    (tester) async {
      final c = await panel(tester, size: const Size(320, 568));
      final pad = find.byKey(const ValueKey('leftPadGesture'));
      await tester.ensureVisible(pad);
      await tester.pump();
      final scroll = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      scroll.position.jumpTo(scroll.position.maxScrollExtent / 2);
      await tester.pump();
      final before = scroll.position.pixels;
      final held = await tester.startGesture(tester.getCenter(pad));
      await held.moveBy(const Offset(0, -20));
      await tester.pump();
      await held.moveBy(const Offset(0, -20));
      await tester.pump();
      expect(c.state.ly, greaterThan(0));
      expect(scroll.position.pixels, before);
      await held.up();
    },
  );
  testWidgets('revision invalidates held pointer before any rebuild', (
    tester,
  ) async {
    final c = await panel(tester);
    final held = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('leftPadGesture'))),
    );
    await held.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(c.state.lx, greaterThan(0));
    c.cycleStickMode(0);
    await held.moveBy(const Offset(25, 0));
    expect(c.state.lx, 0);
    expect(c.state.ly, 0);
    await held.up();
  });
}
