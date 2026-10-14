import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../control/panel_layout.dart';
import '../control/remote_controller.dart';
import 'bluetooth_dialog.dart';
import 'settings_dialog.dart';
import 'joystick_pad.dart';

const panelBlue = Color(0xFF0288D1);
const mutedText = Color(0xFF64748B);
const panelNames = {
  'leftStick': '左摇杆卡片',
  'rightStick': '右摇杆卡片',
  'leftPad': '左蓝色摇杆',
  'rightPad': '右蓝色摇杆',
  'leftSlider': '左滑块',
  'rightSlider': '右滑块',
  'enable': '蓝牙卡片',
};

class ControllerScreen extends StatefulWidget {
  const ControllerScreen({super.key, this.controller});
  final RemoteController? controller;
  @override
  State<ControllerScreen> createState() => _ControllerScreenState();
}

class _ControllerScreenState extends State<ControllerScreen>
    with WidgetsBindingObserver {
  late final RemoteController controller;
  @override
  void initState() {
    super.initState();
    controller = widget.controller ?? RemoteController();
    WidgetsBinding.instance.addObserver(this);
    unawaited(controller.initialize());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      unawaited(controller.interruption());
    } else {
      unawaited(controller.foreground(state == AppLifecycleState.resumed));
    }
  }

  @override
  void didChangeMetrics() {
    controller.releaseSticks();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.controller == null) controller.dispose();
    super.dispose();
  }

  void _options() => showDialog<void>(
    context: context,
    builder: (_) => SettingsDialog(controller: controller),
  );
  void _bluetooth() => showDialog<void>(
    context: context,
    builder: (_) => BluetoothDialog(controller: controller),
  );
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => PopScope(
      canPop: !controller.layoutEditing,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && controller.layoutEditing) controller.cancelLayoutEdit();
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final screenSize = MediaQuery.sizeOf(context);
                    final portrait = screenSize.width < screenSize.height;
                    final height = math.max(
                      constraints.maxHeight,
                      portrait ? 720.0 : 280.0,
                    );
                    return SingleChildScrollView(
                      child: SizedBox(
                        width: constraints.maxWidth,
                        height: height,
                        child: _canvas(
                          Size(constraints.maxWidth, height),
                          portrait,
                        ),
                      ),
                    );
                  },
                ),
              ),
              if (controller.layoutEditing) _editor(),
            ],
          ),
        ),
      ),
    ),
  );
  Widget _canvas(Size size, bool portrait) {
    final design = portrait ? const Size(400, 760) : size;
    final sx = size.width / design.width, sy = size.height / design.height;
    final unit = math.min(sx, sy);
    final compact = size.height < 370;
    final gap = compact ? 12.0 : 20.0;
    final cardWidth = (size.width - gap * 2) / 3;
    final sliderWidth = (size.width - 100 - gap * 2) / 2;
    final sliderHeight = compact ? 54.0 : 60.0;
    final mainY = sliderHeight + 10;
    final mainHeight = size.height - mainY;
    final card = portrait
        ? const Size(180, 272)
        : Size(cardWidth, mainHeight * .8);
    final padSide =
        .75 * math.min(cardWidth - 20, math.min(mainHeight - 76, 260));
    final pad = portrait ? const Size(146, 146) : Size.square(padSide);
    final slider = portrait
        ? const Size(114, 60)
        : Size(sliderWidth, sliderHeight);
    final hub = portrait
        ? const Size(364, 128)
        : Size(cardWidth, compact ? 112 : 128);
    final bases = <String, (Offset, Size)>{
      'leftSlider': (Offset(portrait ? 16 : 0, portrait ? 18 : 0), slider),
      'rightSlider': (
        Offset(portrait ? 270 : size.width - sliderWidth, portrait ? 18 : 0),
        slider,
      ),
      'leftStick': (Offset(portrait ? 16 : 0, portrait ? 235 : mainY), card),
      'rightStick': (
        Offset(portrait ? 204 : size.width - cardWidth, portrait ? 235 : mainY),
        card,
      ),
      'leftPad': (
        Offset(
          portrait ? 33 : (cardWidth - padSide) / 2,
          portrait
              ? 235 + (card.height - pad.height) * unit / (2 * sy)
              : mainY + (card.height - padSide) / 2,
        ),
        pad,
      ),
      'rightPad': (
        Offset(
          portrait ? 221 : size.width - cardWidth + (cardWidth - padSide) / 2,
          portrait
              ? 235 + (card.height - pad.height) * unit / (2 * sy)
              : mainY + (card.height - padSide) / 2,
        ),
        pad,
      ),
      'enable': (
        Offset(portrait ? 18 : cardWidth + gap, portrait ? 552 : mainY + 58),
        hub,
      ),
    };
    Widget item(String id) {
      final (defaultOffset, baseSize) = bases[id]!;
      final base = Size(baseSize.width * unit, baseSize.height * unit);
      final scale = PanelLayout.effectiveScale(
        controller.layout.scales[id] ?? 1,
        base.width,
        base.height,
        size.width,
        size.height,
      );
      final rendered = base * scale;
      final p = controller.layout.positions[id];
      final travel = Size(
        math.max(0, size.width - rendered.width),
        math.max(0, size.height - rendered.height),
      );
      final x = (p == null ? defaultOffset.dx * sx : p.x * travel.width).clamp(
        0.0,
        travel.width,
      );
      final y = (p == null ? defaultOffset.dy * sy : p.y * travel.height).clamp(
        0.0,
        travel.height,
      );
      final content = switch (id) {
        'leftStick' => _stickCard(0),
        'rightStick' => _stickCard(1),
        'leftPad' => JoystickPad(
          key: const ValueKey('leftPadGesture'),
          controller: controller,
          index: 0,
        ),
        'rightPad' => JoystickPad(
          key: const ValueKey('rightPadGesture'),
          controller: controller,
          index: 1,
        ),
        'leftSlider' => _sliderCard(0),
        'rightSlider' => _sliderCard(1),
        _ => _hub(),
      };
      return Positioned(
        left: x,
        top: y,
        width: rendered.width,
        height: rendered.height,
        child: GestureDetector(
          key: ValueKey('panel-$id'),
          behavior: HitTestBehavior.opaque,
          onTap: controller.layoutEditing
              ? () => controller.selectPanel(id)
              : null,
          onPanStart: controller.layoutEditing
              ? (_) => controller.selectPanel(id)
              : null,
          onPanUpdate: controller.layoutEditing
              ? (event) {
                  // Re-read the current draft position; drag deltas are in canvas pixels.
                  final current = controller.layout.positions[id];
                  final px = current == null ? x : current.x * travel.width;
                  final py = current == null ? y : current.y * travel.height;
                  controller.movePanel(
                    id,
                    PanelPosition(
                      travel.width == 0
                          ? 0
                          : (px + event.delta.dx) / travel.width,
                      travel.height == 0
                          ? 0
                          : (py + event.delta.dy) / travel.height,
                    ),
                  );
                }
              : null,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: controller.layoutEditing
                  ? Border.all(
                      color: controller.selectedLayoutId == id
                          ? panelBlue
                          : const Color(0xFFB7C9DB),
                      width: 2,
                    )
                  : null,
            ),
            child: IgnorePointer(
              ignoring: controller.layoutEditing,
              child: FittedBox(
                fit: BoxFit.fill,
                child: SizedBox(
                  width: baseSize.width,
                  height: baseSize.height,
                  child: content,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Stack(
      children: [
        Positioned(
          left: portrait ? 40 * sx : cardWidth + gap,
          top: portrait ? 153 * sy : mainY + 4,
          width: portrait ? 320 * sx : cardWidth,
          child: const Column(
            children: [
              Text(
                'ROBOT CONTROL',
                style: TextStyle(
                  color: panelBlue,
                  fontSize: 9,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: 5),
              Text(
                '操控面板',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
        for (final id in PanelLayout.ids) item(id),
        // Always last: overlapping editable panels can never bury the recovery menu.
        Positioned(
          top: portrait ? 22 * sy : (sliderHeight - 44) / 2,
          left: size.width / 2 - 50,
          width: 100,
          height: 44,
          child: OutlinedButton.icon(
            key: const ValueKey('options'),
            onPressed: _options,
            style: OutlinedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: panelBlue,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              side: const BorderSide(color: Color(0xFFE6EDF5)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: const Icon(Icons.tune, size: 16),
            label: const Text('功能选项', style: TextStyle(fontSize: 11)),
          ),
        ),
      ],
    );
  }

  Widget _card(Widget child) => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: const Color(0xFFE6EDF5)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x061E293B),
          blurRadius: 12,
          offset: Offset(0, 3),
        ),
      ],
    ),
    child: child,
  );
  Widget _stickCard(int index) {
    final left = index == 0, config = controller.stickConfigs[index];
    final x = left ? controller.state.lx : controller.state.rx,
        y = left ? controller.state.ly : controller.state.ry;
    return _card(
      Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  left ? '左摇杆' : '右摇杆',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text(
                      'X: $x   Y: $y',
                      style: const TextStyle(fontSize: 10, color: mutedText),
                    ),
                  ),
                ),
              ],
            ),
            const Spacer(),
            Row(
              children: [
                Text(
                  '死区 ${config.deadZonePercent}%',
                  style: const TextStyle(fontSize: 9, color: mutedText),
                ),
                const Spacer(),
                InkWell(
                  key: ValueKey('mode-$index'),
                  onTap: () => controller.cycleStickMode(index),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEAF6FC),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          config.mode.title,
                          style: const TextStyle(
                            color: panelBlue,
                            fontSize: 10,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.sync, size: 12, color: panelBlue),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _sliderCard(int index) {
    final config = controller.sliderConfigs[index];
    final value = index == 0
        ? controller.state.slider1
        : controller.state.slider2;
    return _card(
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          index == 0 ? '左滑块' : '右滑块',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          config.stepped
                              ? '$value'
                              : '${(value / 10).round()}%',
                          style: const TextStyle(
                            color: panelBlue,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                InkWell(
                  onTap: controller.controlsActive
                      ? () => controller.slider(index, 500)
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      config.stepped ? '中档' : '50%',
                      style: const TextStyle(fontSize: 9, color: panelBlue),
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(
              height: 30,
              child: Slider(
                key: ValueKey('slider-$index'),
                min: 0,
                max: 1000,
                divisions: config.stepped ? config.values.length - 1 : null,
                value: config.position(value),
                onChanged: controller.controlsActive
                    ? (v) => controller.slider(index, v.round())
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _hub() => _card(
    Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Material(
            color: const Color(0xFFEAF6FC),
            borderRadius: BorderRadius.circular(9),
            child: InkWell(
              key: const ValueKey('bluetooth-connect'),
              onTap: _bluetooth,
              borderRadius: BorderRadius.circular(9),
              child: SizedBox(
                height: 40,
                width: double.infinity,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    children: [
                      const Icon(Icons.bluetooth, color: panelBlue, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              controller.mode.title,
                              style: const TextStyle(
                                color: panelBlue,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              controller.connected ? '点击查看连接' : '点击配对连接',
                              style: const TextStyle(
                                color: mutedText,
                                fontSize: 9,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.chevron_right,
                        color: panelBlue,
                        size: 16,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                controller.status,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: mutedText, fontSize: 10),
              ),
            ),
          ),
          const Divider(height: 6, color: Color(0xFFE6EDF5)),
          SizedBox(
            height: 28,
            child: Row(
              children: [
                const Text(
                  '蓝牙使能',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Transform.scale(
                  scale: .72,
                  child: Switch(
                    key: const ValueKey('enable-switch'),
                    value: controller.state.enabled,
                    onChanged: controller.canEnable ? controller.enable : null,
                  ),
                ),
                Text(
                  '${controller.mode.hz}Hz',
                  style: const TextStyle(fontSize: 10, color: mutedText),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
  Widget _editor() => Material(
    color: Colors.white,
    elevation: 5,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButton<String>(
                  key: const ValueKey('element-selector'),
                  isExpanded: true,
                  value: controller.selectedLayoutId,
                  items: PanelLayout.ids
                      .map(
                        (id) => DropdownMenuItem(
                          value: id,
                          child: Text(panelNames[id]!),
                        ),
                      )
                      .toList(),
                  onChanged: (id) {
                    if (id != null) controller.selectPanel(id);
                  },
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${((controller.layout.scales[controller.selectedLayoutId] ?? 1) * 100).round()}%',
                style: const TextStyle(color: panelBlue),
              ),
            ],
          ),
          SizedBox(
            height: 34,
            child: Slider(
              key: const ValueKey('layout-size'),
              min: .3,
              max: 2.5,
              value:
                  (controller.layout.scales[controller.selectedLayoutId] ?? 1)
                      .clamp(.3, 2.5),
              onChanged: controller.resizePanel,
            ),
          ),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 10,
            children: [
              TextButton(
                onPressed: controller.defaultLayoutDraft,
                child: const Text('恢复默认'),
              ),
              TextButton(
                onPressed: controller.cancelLayoutEdit,
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: controller.saveLayoutEdit,
                child: const Text('保存布局'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
