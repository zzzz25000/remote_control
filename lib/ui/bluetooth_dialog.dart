import 'dart:async';

import 'package:flutter/material.dart';

import '../control/control_config.dart';
import '../control/remote_controller.dart';

class BluetoothDialog extends StatefulWidget {
  const BluetoothDialog({super.key, required this.controller});
  final RemoteController controller;
  @override
  State<BluetoothDialog> createState() => _BluetoothDialogState();
}

class _BluetoothDialogState extends State<BluetoothDialog> {
  RemoteController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !controller.connected && !controller.connecting) {
        unawaited(controller.scan());
      }
    });
  }

  @override
  void dispose() {
    unawaited(Future<void>.microtask(controller.stopScan));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.bluetooth, color: Color(0xFF0288D1)),
          const SizedBox(width: 10),
          const Expanded(child: Text('蓝牙连接')),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          key: const ValueKey('bluetooth-dialog-scroll'),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<LinkMode>(
                initialValue: controller.mode,
                decoration: const InputDecoration(labelText: '模块模式'),
                items: LinkMode.values
                    .map(
                      (mode) => DropdownMenuItem(
                        value: mode,
                        child: Text('${mode.title} · ${mode.hz}Hz'),
                      ),
                    )
                    .toList(),
                onChanged: (mode) async {
                  if (mode == null) return;
                  await controller.changeMode(mode);
                  if (mounted && controller.mode == mode) {
                    await controller.scan();
                  }
                },
              ),
              const SizedBox(height: 10),
              Text(controller.status, style: const TextStyle(fontSize: 13)),
              if (controller.scanning)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: LinearProgressIndicator(),
                ),
              const SizedBox(height: 8),
              Text(
                controller.scanDetails,
                style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
              ),
              const SizedBox(height: 8),
              controller.devices.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 22),
                      child: Text(
                        '暂无设备，请确认模块供电并开启广播。',
                        style: TextStyle(color: Color(0xFF64748B)),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: controller.devices.length,
                      itemBuilder: (context, index) {
                        final device = controller.devices[index];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.bluetooth),
                          title: Text(device.name),
                          subtitle: Text(
                            '${device.id}\n${device.source}${device.rssi == null ? '' : ' · ${device.rssi} dBm'}',
                            style: const TextStyle(fontSize: 11),
                          ),
                          isThreeLine: true,
                          onTap: controller.connecting
                              ? null
                              : () async {
                                  await controller.connect(device);
                                  if (context.mounted && controller.connected) {
                                    Navigator.pop(context);
                                  }
                                },
                        );
                      },
                    ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: controller.openSettings,
                icon: const Icon(Icons.settings_outlined, size: 18),
                label: const Text('系统设置'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (controller.connected || controller.connecting)
          TextButton(onPressed: controller.disconnect, child: const Text('断开')),
        TextButton(
          onPressed: controller.scanning
              ? controller.stopScan
              : controller.scan,
          child: Text(controller.scanning ? '停止扫描' : '刷新'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
