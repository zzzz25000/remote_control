import 'package:flutter/material.dart';

import '../control/control_config.dart';
import '../control/remote_controller.dart';

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.controller});
  final RemoteController controller;
  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late final List<bool> stepped;
  late final List<int> counts, deadzones;
  late final List<JoystickMode> modes;
  late final List<TextEditingController> maxima;
  late final List<List<TextEditingController>> values;
  @override
  void initState() {
    super.initState();
    stepped = widget.controller.sliderConfigs.map((c) => c.stepped).toList();
    counts = widget.controller.sliderConfigs
        .map((c) => c.values.length)
        .toList();
    deadzones = widget.controller.stickConfigs
        .map((c) => c.deadZonePercent)
        .toList();
    modes = widget.controller.stickConfigs.map((c) => c.mode).toList();
    maxima = widget.controller.stickConfigs
        .map((c) => TextEditingController(text: '${c.maxValue}'))
        .toList();
    values = List.generate(
      2,
      (i) => List.generate(
        8,
        (j) => TextEditingController(
          text:
              '${j < counts[i] ? widget.controller.sliderConfigs[i].values[j] : j}',
        ),
      ),
    );
  }

  @override
  void dispose() {
    for (final c in [...maxima, ...values.expand((v) => v)]) {
      c.dispose();
    }
    super.dispose();
  }

  int? _number(TextEditingController c, int min) {
    final n = int.tryParse(c.text);
    return n != null && n >= min && n <= 1000 ? n : null;
  }

  bool _sliderValid(int i) {
    if (!stepped[i]) return true;
    final numbers = values[i]
        .take(counts[i])
        .map((c) => _number(c, 0))
        .toList();
    return !numbers.contains(null) && numbers.toSet().length == numbers.length;
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 10),
    child: Text(
      text,
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
    ),
  );
  Widget _stick(int i) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _heading(i == 0 ? '左摇杆设置' : '右摇杆设置'),
      DropdownButtonFormField<JoystickMode>(
        initialValue: modes[i],
        decoration: const InputDecoration(labelText: '操控模式'),
        items: JoystickMode.values
            .map((m) => DropdownMenuItem(value: m, child: Text(m.title)))
            .toList(),
        onChanged: (m) {
          if (m != null) setState(() => modes[i] = m);
        },
      ),
      const SizedBox(height: 12),
      Text('死区 ${deadzones[i]}%'),
      Slider(
        key: ValueKey('deadzone-$i'),
        min: 0,
        max: 30,
        divisions: 30,
        value: deadzones[i].toDouble(),
        onChanged: (v) => setState(() => deadzones[i] = v.round()),
      ),
      TextField(
        key: ValueKey('stick-max-$i'),
        controller: maxima[i],
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: '最大绝对值（1～1000）',
          errorText: _number(maxima[i], 1) == null ? '请输入 1～1000 的整数' : null,
        ),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 10),
      FilledButton(
        key: ValueKey('stick-apply-$i'),
        onPressed:
            _number(maxima[i], 1) != null && !widget.controller.layoutEditing
            ? () => _applyStick(i)
            : null,
        child: const Text('应用'),
      ),
    ],
  );
  Widget _slider(int i) {
    final numbers = values[i]
        .take(counts[i])
        .map((c) => _number(c, 0))
        .toList();
    final duplicates = numbers.toSet().length != numbers.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(i == 0 ? '左滑块设置' : '右滑块设置'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('分档模式'),
          subtitle: Text(stepped[i] ? '每档独立数值，可非递增' : '连续输出 0～1000，显示百分比'),
          value: stepped[i],
          onChanged: (v) => setState(() => stepped[i] = v),
        ),
        if (stepped[i]) ...[
          DropdownButtonFormField<int>(
            key: ValueKey('step-count-$i'),
            initialValue: counts[i],
            decoration: const InputDecoration(labelText: '档位数量'),
            items: List.generate(
              7,
              (j) => DropdownMenuItem(value: j + 2, child: Text('${j + 2} 档')),
            ),
            onChanged: (v) {
              if (v != null) setState(() => counts[i] = v);
            },
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 12,
            children: List.generate(
              counts[i],
              (j) => SizedBox(
                width: 110,
                child: TextField(
                  key: ValueKey('step-value-$i-$j'),
                  controller: values[i][j],
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: '第 ${j + 1} 档',
                    helperText: '0～1000',
                    errorText: _number(values[i][j], 0) == null ? '数值无效' : null,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ),
          ),
          if (duplicates)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('各档数值不能重复', style: TextStyle(color: Colors.red)),
            ),
        ],
        const SizedBox(height: 10),
        FilledButton(
          key: ValueKey('slider-apply-$i'),
          onPressed: _sliderValid(i) && !widget.controller.layoutEditing
              ? () => _applySlider(i)
              : null,
          child: const Text('应用滑块设置'),
        ),
      ],
    );
  }

  void _applyStick(int i) {
    if (_number(maxima[i], 1) == null) return;
    widget.controller.setStickConfig(
      i,
      JoystickConfig(
        deadZonePercent: deadzones[i],
        maxValue: int.parse(maxima[i].text),
        mode: modes[i],
      ),
    );
  }

  void _applySlider(int i) {
    if (!_sliderValid(i)) return;
    widget.controller.setSliderConfig(
      i,
      SliderConfig(
        stepped: stepped[i],
        values: stepped[i]
            ? values[i].take(counts[i]).map((c) => int.parse(c.text)).toList()
            : widget.controller.sliderConfigs[i].values,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('面板设置'),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _slider(0),
            _slider(1),
            _stick(0),
            _stick(1),
            _heading('通信诊断'),
            AnimatedBuilder(
              animation: widget.controller,
              builder: (context, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${widget.controller.mode.title} · ${widget.controller.mode.periodMs}ms · 目标 ${widget.controller.mode.hz}Hz',
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '最近提交帧（${widget.controller.sent}）',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                  SelectableText(
                    widget.controller.lastFrame,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '最近收到的原始字节',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                  ),
                  SelectableText(
                    widget.controller.lastReceived,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '链路就绪和写入成功不代表 MCU 已确认收包。',
                    style: TextStyle(color: Color(0xFF64748B), fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton.icon(
        onPressed: () {
          Navigator.pop(context);
          widget.controller.beginLayoutEdit();
        },
        icon: const Icon(Icons.dashboard_customize_outlined, size: 16),
        label: const Text('编辑布局'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('完成'),
      ),
    ],
  );
}
