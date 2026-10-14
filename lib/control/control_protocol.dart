import 'dart:typed_data';

class ControlState {
  const ControlState({
    this.lx = 0,
    this.ly = 0,
    this.rx = 0,
    this.ry = 0,
    this.slider1 = 0,
    this.slider2 = 0,
    this.enabled = false,
    this.stopped = false,
  });
  final int lx, ly, rx, ry, slider1, slider2;
  final bool enabled, stopped;
  ControlState copyWith({
    int? lx,
    int? ly,
    int? rx,
    int? ry,
    int? slider1,
    int? slider2,
    bool? enabled,
    bool? stopped,
  }) => ControlState(
    lx: lx ?? this.lx,
    ly: ly ?? this.ly,
    rx: rx ?? this.rx,
    ry: ry ?? this.ry,
    slider1: slider1 ?? this.slider1,
    slider2: slider2 ?? this.slider2,
    enabled: enabled ?? this.enabled,
    stopped: stopped ?? this.stopped,
  );
}

/// Matches the MCU receiver: CRC16-CCITT-FALSE, little endian, 20 bytes.
abstract final class ControlProtocol {
  static Uint8List encode(ControlState state, int sequence) {
    final frame = Uint8List(20);
    frame.setRange(0, 4, [0xa5, 0x5a, 1, sequence & 255]);
    final active = state.enabled && !state.stopped;
    if (active) {
      final data = ByteData.sublistView(frame);
      final axes = [state.lx, state.ly, state.rx, state.ry];
      for (var i = 0; i < 4; i++) {
        data.setInt16(4 + i * 2, axes[i].clamp(-1000, 1000), Endian.little);
      }
      data.setUint16(12, state.slider1.clamp(0, 1000), Endian.little);
      data.setUint16(14, state.slider2.clamp(0, 1000), Endian.little);
    }
    frame[16] = (active ? 1 : 0) | (state.stopped ? 2 : 0);
    ByteData.sublistView(frame).setUint16(18, crc(frame, 2, 18), Endian.little);
    return frame;
  }

  static int crc(List<int> bytes, [int from = 0, int? until]) {
    var value = 0xffff;
    for (var i = from; i < (until ?? bytes.length); i++) {
      value ^= (bytes[i] & 255) << 8;
      for (var bit = 0; bit < 8; bit++) {
        value =
            ((value & 0x8000) != 0 ? (value << 1) ^ 0x1021 : value << 1) &
            0xffff;
      }
    }
    return value;
  }

  static String hex(List<int> bytes) => bytes
      .map((v) => v.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');
}
