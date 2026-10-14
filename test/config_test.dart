import 'package:flutter_test/flutter_test.dart';
import 'package:ble/control/control_config.dart';
import 'package:ble/control/panel_layout.dart';

void main() {
  test(
    'dead zone rescales strength and each single axis mode masks other axis',
    () {
      const c = JoystickConfig(deadZonePercent: 10, maxValue: 500);
      expect(c.map(100, -100), (0, 0));
      expect(c.map(550, -1000), (250, -500));
      expect(c.copyWith(mode: JoystickMode.horizontal).map(1000, 1000), (
        500,
        0,
      ));
      expect(c.copyWith(mode: JoystickMode.vertical).map(1000, -1000), (
        0,
        -500,
      ));
    },
  );
  test(
    'four way tie prefers vertical and radial intensity remains continuous',
    () {
      const c = JoystickConfig(deadZonePercent: 0, mode: JoystickMode.fourWay);
      expect(c.map(1000, -1000), (0, -1000));
      expect(c.map(300, 400), (0, 500));
      expect(c.map(-400, 300), (-500, 0));
    },
  );
  test(
    'stepped slider sends configured actual values including unsorted slots',
    () {
      final c = SliderConfig(values: [0, 900, 25, 1000]);
      expect(c.map(333), 900);
      expect(c.map(667), 25);
      expect(c.position(25), closeTo(666.667, .01));
      expect(SliderConfig(stepped: false).map(1500), 1000);
      expect(() => SliderConfig(values: [1, 1]), throwsArgumentError);
    },
  );
  test('draft movement clamps, cancel rolls back and only save persists', () {
    final l = PanelLayout();
    l.begin();
    l.move('leftPad', const PanelPosition(.3, .7));
    l.resize('leftPad', 4);
    expect(l.scales['leftPad'], 2.5);
    l.cancel();
    expect(l.positions, isEmpty);
    l.begin();
    l.move('leftSlider', const PanelPosition(-1, 2));
    l.save();
    expect(l.positions['leftSlider']?.x, 0);
    expect(l.positions['leftSlider']?.y, 1);
    final restored = PanelLayout.fromJson(l.toJson());
    expect(restored.positions['leftSlider']?.y, 1);
    l.begin();
    l.restoreDefaults();
    l.cancel();
    expect(l.positions, isNotEmpty);
  });
  test(
    'corrupt coordinates and unrecognized ids do not poison restored layout',
    () {
      final l = PanelLayout.fromJson({
        'positions': {
          'leftPad': {'x': 'bad', 'y': .2},
          'intruder': {'x': .2, 'y': .3},
        },
        'scales': {'rightPad': -2},
      });
      expect(l.positions, isEmpty);
      expect(l.scales['rightPad'], .3);
      expect(
        JoystickConfig.fromJson({'maxValue': 0, 'deadZonePercent': 100})
            .maxValue,
        1,
      );
      expect(
        SliderConfig.fromJson({
          'values': [1, 1],
        }).values,
        [0, 1, 2],
      );
    },
  );
}
