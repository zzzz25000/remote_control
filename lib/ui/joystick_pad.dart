import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../control/remote_controller.dart';

class JoystickPad extends StatefulWidget {
  const JoystickPad({super.key, required this.controller, required this.index});
  final RemoteController controller;
  final int index;
  @override
  State<JoystickPad> createState() => _JoystickPadState();
}

class _JoystickPadState extends State<JoystickPad> {
  int? _pointer;
  int _revision = 0;
  @override
  void initState() {
    super.initState();
    _revision = widget.controller.gestureRevisions[widget.index];
  }

  @override
  void didUpdateWidget(JoystickPad oldWidget) {
    super.didUpdateWidget(oldWidget);
    final revision = widget.controller.gestureRevisions[widget.index];
    if (revision != _revision || !widget.controller.controlsActive) {
      _revision = revision;
      _pointer = null;
    }
  }

  void _move(PointerEvent event, Size size) {
    if (!_currentGesture()) return;
    if (_pointer != event.pointer || !widget.controller.controlsActive) return;
    final radius = math.min(size.width, size.height) * .34;
    final p =
        (event.localPosition - Offset(size.width / 2, size.height / 2)) /
        radius;
    widget.controller.axes(
      widget.index,
      (p.dx * 1000).round(),
      (-p.dy * 1000).round(),
    );
  }

  void _release(PointerEvent event) {
    if (!_currentGesture()) return;
    if (_pointer != event.pointer) return;
    _pointer = null;
    widget.controller.axes(widget.index, 0, 0);
  }

  bool _currentGesture() {
    final revision = widget.controller.gestureRevisions[widget.index];
    if (revision != _revision || !widget.controller.controlsActive) {
      _revision = revision;
      _pointer = null;
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      final state = widget.controller.state;
      final x = widget.index == 0 ? state.lx : state.rx;
      final y = widget.index == 0 ? state.ly : state.ry;
      final maximum = widget.controller.stickConfigs[widget.index].maxValue;
      return Semantics(
        label: widget.index == 0 ? '左摇杆操控区' : '右摇杆操控区',
        value: 'X: $x, Y: $y',
        child: RawGestureDetector(
          gestures: widget.controller.controlsActive
              ? {
                  EagerGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                        EagerGestureRecognizer
                      >(EagerGestureRecognizer.new, (_) {}),
                }
              : const {},
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) {
              _currentGesture();
              if (_pointer != null || !widget.controller.controlsActive) return;
              _pointer = event.pointer;
              _move(event, size);
            },
            onPointerMove: (event) => _move(event, size),
            onPointerUp: _release,
            onPointerCancel: _release,
            child: CustomPaint(
              painter: _PadPainter(Offset(x / maximum, -y / maximum)),
            ),
          ),
        ),
      );
    },
  );
}

class _PadPainter extends CustomPainter {
  _PadPainter(this.position);
  final Offset position;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(1), const Radius.circular(18)),
      Paint()..color = const Color(0xFFEAF1F8),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(1), const Radius.circular(18)),
      Paint()
        ..color = const Color(0xFFD8E3EE)
        ..style = PaintingStyle.stroke,
    );
    final line = Paint()
      ..color = const Color(0xFFB7C9DB)
      ..strokeWidth = 1;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          size.width * .13,
          size.height * .13,
          size.width * .74,
          size.height * .74,
        ),
        const Radius.circular(8),
      ),
      Paint()
        ..color = const Color(0xFFB7C9DB)
        ..style = PaintingStyle.stroke,
    );
    for (double p = 14; p < size.width - 14; p += 10) {
      canvas.drawLine(
        Offset(p, size.height / 2),
        Offset(math.min(p + 5, size.width - 14), size.height / 2),
        line,
      );
    }
    for (double p = 14; p < size.height - 14; p += 10) {
      canvas.drawLine(
        Offset(size.width / 2, p),
        Offset(size.width / 2, math.min(p + 5, size.height - 14)),
        line,
      );
    }
    final radius = math.min(28.0, math.min(size.width, size.height) * .15);
    final center =
        Offset(size.width / 2, size.height / 2) +
        Offset(position.dx * size.width * .34, position.dy * size.height * .34);
    canvas.drawCircle(
      center + const Offset(0, 4),
      radius + 1,
      Paint()
        ..color = const Color(0x220288D1)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xFF40B9F2), Color(0xFF0288D1)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
    canvas.drawCircle(
      center,
      radius - 1,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_PadPainter oldDelegate) =>
      position != oldDelegate.position;
}
