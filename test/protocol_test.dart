import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ble/control/control_protocol.dart';

void main() {
  test('CRC matches independent standard check vector', () {
    expect(ControlProtocol.crc(utf8.encode('123456789')), 0x29b1);
  });
  test('enabled frame matches reference signed little endian fixture', () {
    expect(
      ControlProtocol.encode(
        const ControlState(
          lx: -1000,
          ly: 1000,
          rx: -1,
          slider1: 0,
          slider2: 1000,
          enabled: true,
        ),
        255,
      ),
      [
        0xa5,
        0x5a,
        1,
        255,
        0x18,
        0xfc,
        0xe8,
        3,
        255,
        255,
        0,
        0,
        0,
        0,
        0xe8,
        3,
        1,
        0,
        0xdc,
        0x37,
      ],
    );
  });
  test('inactive and stopped states never encode motion', () {
    for (final state in [
      const ControlState(lx: 900, slider1: 1000),
      const ControlState(lx: 900, slider1: 1000, enabled: true, stopped: true),
    ]) {
      final frame = ControlProtocol.encode(state, 256);
      expect(frame.sublist(4, 16), List.filled(12, 0));
      expect(frame[16] & 1, 0);
      expect(frame[3], 0);
    }
  });
  test('out of range controls are clamped before encoding', () {
    final f = ControlProtocol.encode(
      const ControlState(
        lx: 5000,
        ly: -5000,
        slider1: -1,
        slider2: 5000,
        enabled: true,
      ),
      1,
    );
    expect(f.sublist(4, 8), [0xe8, 3, 0x18, 0xfc]);
    expect(f.sublist(12, 16), [0, 0, 0xe8, 3]);
  });
}
