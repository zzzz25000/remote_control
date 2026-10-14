# 蓝牙遥控器（Android / iOS）

Flutter 共用遥控页面与协议，Android 使用系统 BluetoothGatt，iOS 使用 CoreBluetooth；蓝牙与本地设置通过平台通道接入，无额外第三方 BLE 插件。

页面和行为依据 [remote-control 固定 Android 版本](https://github.com/Norlive666/remote-control/tree/76dc101fc07e57cbd3b6195a8d34f80ccce2b71d/android)。方案见 [设计文档](docs/superpowers/specs/2026-10-13-mobile-remote-control-design.md)，任务和检查见 [实施计划](docs/superpowers/plans/2026-10-13-mobile-remote-control.md) 与 [记录](docs/superpowers/plans/2026-10-13-mobile-remote-control-ledger.md)。

## 使用

1. 点中央蓝牙卡片，选择 BLE 串口或 FSC-BT630，允许蓝牙权限并扫描。Android 系统发现需要定位权限和定位开关；不读取 GPS 坐标。
2. 选择设备；发现正确服务与可写特征后先发送禁用帧。链路就绪后手动开启“使能”。
3. 双摇杆同时操作，松手归零。每侧模式分别为自由、仅横向、仅纵向和四向；四向保持连续力度。
4. “功能选项”进入面板设置：摇杆死区和量程、滑块连续或 2～8 档、每档实际数值、发送与接收原始数据。
5. 布局编辑可拖动和缩放左右卡片、两个独立蓝色摇杆、两个滑块和蓝牙卡片。保存生效，取消回滚，恢复默认先修改草稿。编辑期间关闭使能。

配置保存在手机本地，重启恢复。退出前台、断连或模式切换会清除控制状态；回来或重连后需要手动使能。

## 模块与协议

| 模式 | 服务 | 写入 | 接收 | 目标周期 | MCU 串口配置 |
| --- | --- | --- | --- | --- | --- |
| BLE 串口 | FFE0 | FFE1 | FFE1（若支持通知） | 50ms / 20Hz | 原固件默认 9600 |
| FSC-BT630 | FFF0 | FFF2 | FFF1（若支持通知） | 20ms / 50Hz | 原固件 RC_InitBT630，115200 |

16 位 UUID 使用标准 Bluetooth Base UUID 扩展。两种模式都是 BLE GATT，不使用经典蓝牙 SPP。iOS 展示设备 UUID，Android 展示 MAC / 发现来源。

帧格式：`A5 5A 01 SEQ` + 4 个有符号小端轴（±1000）+ 2 个无符号小端滑块（0～1000）+ flags + 保留 0 + 小端 CRC16。总长 20 字节；CRC16-CCITT-FALSE 覆盖字节 2～17。禁用或 stopped 时所有输出为零。

串行发送，每次完成后采样最新状态，不排队旧摇杆帧。20/50Hz 是目标上限，受系统写入完成和链路速度影响。蓝牙就绪、写入回调和收到通知都不表示 STM32 已处理控制帧，当前固件没有 ACK。

原 MCU 协议 300ms 超时后归零并关闭使能，恢复需先收到禁用帧。应用在长时间写入延迟时也关闭使能并先发送禁用帧。退后台/断开尝试零输出，但立即关闭链路不保证该帧抵达，MCU 超时仍是必要保障。

## 源码结构

- `lib/control`：帧编码、映射、布局草稿、连接状态和发送控制器。
- `lib/bluetooth`：设备模型与平台通道适配器。
- `lib/ui`：主面板、摇杆、连接与设置弹窗。
- `android/app/src/main/kotlin/com/example/ble`：权限、BLE + 系统发现、GATT 操作与生命周期。
- `ios/Runner/BleBridge.swift`：CoreBluetooth、流量控制与生命周期。
- `test`：固定协议向量、映射、连接/扫描竞态、持久化、双指与页面交互。

平台接口在实施计划中定义。native session identity 与 Dart generation 双层检查防止旧连接回调污染新状态。

## 本地检查

上传 GitHub 和准备 APK / iOS 云构建请见 [上传指南](docs/GITHUB_UPLOAD.md)，其中列出应保留的文件、首次上传命令、已有仓库处理方式及 Flutter / 签名要求。

2026-10-14 实际验证：`flutter analyze lib test --no-pub` 无问题；`flutter test --no-pub` 共 43 项通过；Dart 格式检查通过。Android Manifest、iOS Info.plist XML 和 iOS 新增源码目标引用已检查。原生编译和硬件通信尚未执行。

页面预览：[横屏](docs/previews/landscape.png)、[小屏横屏](docs/previews/compact-landscape.png)、[竖屏](docs/previews/portrait.png)、[设置](docs/previews/settings.png)、[布局编辑](docs/previews/layout-editor.png)。预览使用测试替代传输，不表示连接了真实蓝牙模块。

本环境 Flutter 3.47.7 / Dart 3.13.5，iOS 部署目标沿用 15.0。

```sh
flutter pub get
dart format lib test
flutter analyze lib test --no-pub
flutter test --no-pub
```

Android/iOS 构建、签名、IPA/APK 导出与 GitHub Actions 按用户要求留到后续。Windows 不能执行 Xcode 检查；iOS 原生代码与 XCTest 需要在 macOS 编译运行。Android 需要 Android SDK 和符合现有配置的 JDK。

## 真机验收

分别用 FFE0/FFE1 模块与 BT630 在 Android/iPhone 上验证：首次授权、扫描刷新、正确/错误模式、双指遥控、滑块实际档值、配置重启恢复、布局保存/取消、使能关闭、断连/后台、蓝牙开关、超过 300ms 中断及恢复。模拟器和 Dart 替代传输测试不能代替模块蓝牙验收。

本次不读取或修改 `linux`、`web`，不修改用户 MCU 固件。
