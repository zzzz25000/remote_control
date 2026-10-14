import 'dart:io';
import 'dart:ui' as ui;

import 'package:ble/main.dart';
import 'package:ble/control/remote_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_transport.dart';

void main() {
  testWidgets('render reference control previews for visual review', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final file = File('C:/Windows/Fonts/msyh.ttc');
      if (await file.exists()) {
        final bytes = ByteData.sublistView(await file.readAsBytes());
        await (FontLoader('Roboto')..addFont(Future.value(bytes))).load();
        await (FontLoader('Ahem')..addFont(Future.value(bytes))).load();
      }
      final icons = File(
        'D:/Study/Flutter/flutter_windows_3.47.7-stable/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      );
      if (await icons.exists()) {
        final bytes = ByteData.sublistView(await icons.readAsBytes());
        await (FontLoader(
          'MaterialIcons',
        )..addFont(Future.value(bytes))).load();
      }
    });
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final fake = FakeTransport();
    final c = RemoteController(transport: fake);
    await c.initialize();
    final key = GlobalKey();
    Future<void> capture(String name) async {
      await tester.pumpAndSettle();
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final dir = Directory('.dart_tool/ui-previews');
        await dir.create(recursive: true);
        await File('${dir.path}/$name.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }

    for (final entry in {
      'landscape': const Size(1000, 560),
      'compact-landscape': const Size(568, 320),
      'portrait': const Size(390, 844),
    }.entries) {
      tester.view.physicalSize = entry.value;
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MyApp(controller: c),
        ),
      );
      await capture(entry.key);
    }
    tester.view.physicalSize = const Size(1000, 560);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('options')));
    await capture('settings');
    await tester.tap(find.text('编辑布局'));
    await capture('layout-editor');
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await fake.bus.close();
  });
}
