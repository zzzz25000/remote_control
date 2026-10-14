import 'dart:math' as math;

enum LinkMode {
  uart('uart', 'BLE 串口', 50),
  bt630('bt630', 'FSC-BT630', 20);

  const LinkMode(this.key, this.title, this.periodMs);
  final String key, title;
  final int periodMs;
  int get hz => 1000 ~/ periodMs;
}

enum JoystickMode {
  free('自由'),
  horizontal('仅横向'),
  vertical('仅纵向'),
  fourWay('四向');

  const JoystickMode(this.title);
  final String title;
}

class JoystickConfig {
  const JoystickConfig({
    this.deadZonePercent = 5,
    this.maxValue = 1000,
    this.mode = JoystickMode.free,
  }) : assert(deadZonePercent >= 0 && deadZonePercent <= 30),
       assert(maxValue >= 1 && maxValue <= 1000);
  final int deadZonePercent, maxValue;
  final JoystickMode mode;
  JoystickConfig copyWith({
    int? deadZonePercent,
    int? maxValue,
    JoystickMode? mode,
  }) => JoystickConfig(
    deadZonePercent: deadZonePercent ?? this.deadZonePercent,
    maxValue: maxValue ?? this.maxValue,
    mode: mode ?? this.mode,
  );
  (int, int) map(int x, int y) {
    final dead = deadZonePercent * 10;
    if (mode == JoystickMode.fourWay) {
      final distance = math
          .sqrt(x.toDouble() * x + y.toDouble() * y)
          .clamp(0, 1000);
      if (distance <= dead) return (0, 0);
      final strength = ((distance - dead) * maxValue / (1000 - dead)).round();
      return x.abs() > y.abs()
          ? (x < 0 ? -strength : strength, 0)
          : (0, y < 0 ? -strength : strength);
    }
    int axis(int raw) {
      final value = raw.clamp(-1000, 1000);
      if (value.abs() <= dead) return 0;
      final strength = ((value.abs() - dead) * maxValue / (1000 - dead))
          .round();
      return value < 0 ? -strength : strength;
    }

    return (
      mode == JoystickMode.vertical ? 0 : axis(x),
      mode == JoystickMode.horizontal ? 0 : axis(y),
    );
  }

  Map<String, Object> toJson() => {
    'deadZonePercent': deadZonePercent,
    'maxValue': maxValue,
    'mode': mode.name,
  };
  factory JoystickConfig.fromJson(Object? raw) {
    final map = raw is Map ? raw : const {};
    final oldMode = map['mode'];
    return JoystickConfig(
      deadZonePercent: safeInt(map['deadZonePercent'], 5).clamp(0, 30),
      maxValue: safeInt(map['maxValue'], 1000).clamp(1, 1000),
      mode:
          JoystickMode.values.where((v) => v.name == oldMode).firstOrNull ??
          JoystickMode.free,
    );
  }
}

class SliderConfig {
  SliderConfig({this.stepped = true, List<int> values = const [0, 1, 2]})
    : values = List.unmodifiable(values) {
    if (values.length < 2 ||
        values.length > 8 ||
        values.toSet().length != values.length ||
        values.any((v) => v < 0 || v > 1000)) {
      throw ArgumentError('分档需 2～8 个不重复的数值，范围为 0～1000');
    }
  }
  final bool stepped;
  final List<int> values;
  int map(int position) => stepped
      ? values[(position.clamp(0, 1000) / 1000 * (values.length - 1)).round()]
      : position.clamp(0, 1000);
  double position(int value) => stepped
      ? math.max(0, values.indexOf(value)) * 1000 / (values.length - 1)
      : value.clamp(0, 1000).toDouble();
  Map<String, Object> toJson() => {'stepped': stepped, 'values': values};
  factory SliderConfig.fromJson(Object? raw) {
    if (raw is! Map) return SliderConfig();
    final list = raw['values'];
    try {
      return SliderConfig(
        stepped: raw['stepped'] is bool ? raw['stepped'] as bool : true,
        values: list is List && list.every((v) => v is int)
            ? list.cast<int>()
            : const [0, 1, 2],
      );
    } on ArgumentError {
      return SliderConfig();
    }
  }
}

int safeInt(Object? value, int fallback) =>
    value is num && value.isFinite ? value.toInt() : fallback;
