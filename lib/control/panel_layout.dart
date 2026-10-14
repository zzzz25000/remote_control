import 'dart:math' as math;

class PanelPosition {
  const PanelPosition(this.x, this.y);
  final double x, y;
  Map<String, double> toJson() => {'x': x, 'y': y};
}

class PanelLayout {
  static const ids = [
    'leftStick',
    'rightStick',
    'leftPad',
    'rightPad',
    'leftSlider',
    'rightSlider',
    'enable',
  ];
  Map<String, PanelPosition> _saved = {}, _draft = {};
  Map<String, double> _savedScales = {}, _draftScales = {};
  bool editing = false;
  Map<String, PanelPosition> get positions =>
      Map.unmodifiable(editing ? _draft : _saved);
  Map<String, double> get scales =>
      Map.unmodifiable(editing ? _draftScales : _savedScales);
  void begin() {
    if (editing) return;
    _draft = Map.of(_saved);
    _draftScales = Map.of(_savedScales);
    editing = true;
  }

  void move(String id, PanelPosition p) {
    if (editing && ids.contains(id) && p.x.isFinite && p.y.isFinite) {
      _draft[id] = PanelPosition(p.x.clamp(0, 1), p.y.clamp(0, 1));
    }
  }

  void resize(String id, double scale) {
    if (editing && ids.contains(id) && scale.isFinite) {
      _draftScales[id] = scale.clamp(.3, 2.5);
    }
  }

  void save() {
    if (!editing) return;
    _saved = Map.of(_draft);
    _savedScales = Map.of(_draftScales);
    cancel();
  }

  void cancel() {
    editing = false;
    _draft = {};
    _draftScales = {};
  }

  void restoreDefaults() {
    if (editing) {
      _draft = {};
      _draftScales = {};
    }
  }

  Map<String, Object> toJson() => {
    'positions': _saved.map((id, p) => MapEntry(id, p.toJson())),
    'scales': _savedScales,
  };
  PanelLayout();
  factory PanelLayout.fromJson(Object? raw) {
    final result = PanelLayout();
    if (raw is! Map) return result;
    final positions = raw['positions'];
    final scales = raw['scales'];
    for (final id in ids) {
      final p = positions is Map ? positions[id] : null;
      if (p is Map && p['x'] is num && p['y'] is num) {
        final x = (p['x'] as num).toDouble(), y = (p['y'] as num).toDouble();
        if (x.isFinite && y.isFinite) {
          result._saved[id] = PanelPosition(x.clamp(0, 1), y.clamp(0, 1));
        }
      }
      final s = scales is Map ? scales[id] : null;
      if (s is num && s.isFinite) {
        result._savedScales[id] = s.toDouble().clamp(.3, 2.5);
      }
    }
    return result;
  }
  static double effectiveScale(
    double scale,
    double width,
    double height,
    double canvasWidth,
    double canvasHeight,
  ) {
    final maxScale = math.min(canvasWidth / width, canvasHeight / height);
    return scale.clamp(math.min(.3, maxScale), maxScale);
  }
}
