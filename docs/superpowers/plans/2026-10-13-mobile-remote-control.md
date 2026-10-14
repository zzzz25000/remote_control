# Mobile Remote Control Implementation Plan

> For agentic workers: use the test-driven-development and verification-before-completion skills. The user explicitly requested starting implementation of the approved design; execute continuously. Independent native platform tasks may run in parallel under dispatching-parallel-agents.

**Goal:** Replace the Flutter template with the reference BLE remote controller on Android and iOS.

**Architecture:** Pure Dart protocol, configuration and state controller; shared Flutter UI; native Kotlin / Swift platform channels for BLE and persistence. No third-party runtime BLE dependency.

**Tech Stack:** Flutter / Dart, Android BluetoothGatt, iOS CoreBluetooth, MethodChannel / EventChannel.

**Spec:** ../specs/2026-10-13-mobile-remote-control-design.md

## Global constraints

- Do not read or modify linux or web. Keep MCU files unchanged.
- Both BLE profiles: uart FFE0/FFE1 at 50ms; bt630 FFF0/FFF2 with FFF1 receive at 20ms.
- Frames: 20 bytes, A5 5A 01, 8-bit sequence, signed LE axes, unsigned LE sliders, flags, reserved zero, CRC16-CCITT-FALSE over bytes 2..17.
- Disabled handshake precedes enable; background, editing and disconnect disarm; MCU expiry is 300ms.
- Preserve reference layout, seven editable elements, joystick mapping, actual stepped slider values and persistent settings.
- Cloud packaging / signing deferred by user. Verify Dart locally; report native checks not executable on this machine.
- No Git metadata in current workspace: work in place; no worktree or commit operations.

## Shared platform channel contract

MethodChannel `ble.remote/methods`; EventChannel `ble.remote/events`.

Methods: `scan` {generation:int}; `stopScan` {}; `connect` {id:string, mode:'uart'|'bt630', generation:int}; `write` {bytes:Uint8List, generation:int}; `disconnect` {}; `loadSettings` -> string?; `saveSettings` {json:string}; `openSettings` {}; `keepAwake` {enabled:bool}.

`connect` completes after writable characteristic discovery and optional notification setup. `write` completes once submitted without response or after write response, rejects concurrent writes and enforces 1s deadline. Failed futures use stable platform error code and Chinese message. `scan` requests permissions and resolves after starting; failed scanning reports future / error event.

Events are maps: `{type:'device',generation,id,name,source:'BLE'|'系统发现'|'BLE + 系统发现',rssi?:int}`; `{type:'scan',generation,scanning:bool,details:string}`; `{type:'disconnected',generation,message}`; `{type:'received',generation,bytes:Uint8List}`; `{type:'error',generation,code,message}`. Each native async callback checks its native token and original GATT/peripheral. Dart accepts events only for its current generation. Scan timeout 20s, connect timeout 10s (12s Dart), writes 1s.

## Review focus

- A late connect callback after disconnect must not re-enable or revive transport.
- A background transition during a pending write must disarm immediately and avoid future motion writes.
- Corrupt persistent JSON / NaN coordinates must restore valid defaults.
- Resizing controls / changing joystick settings during held touches must clear axes and require new pointer down.
- Small portrait / landscape screens and settings with eight slider slots must stay accessible.

## Task 1: Protocol and editable configuration

Files: `lib/control/control_protocol.dart`, `lib/control/control_config.dart`, `lib/control/panel_layout.dart`; tests `test/protocol_test.dart`, `test/config_test.dart`.

Interfaces: `ControlState`, `ControlProtocol.encode(state,sequence)` -> Uint8List; `JoystickConfig.map(x,y)` -> record(int,int); `SliderConfig.map(position)` / `position(value)`; `PanelLayout` draft, saved, move, resize, save / cancel / defaults and JSON.

- [x] Write fixed CRC/frame, clamping, inactive-zero and sequence-wrap tests, independent joystick and slider mapping tests, layout draft rollback / clamp / corrupt JSON tests.
- [x] Run `flutter test test/protocol_test.dart test/config_test.dart --no-pub`; expected RED for missing feature.
- [x] Implement exact reference algorithms and defensive decoding.
- [x] Rerun tests; expected all pass.

## Task 2: Native Android transport

Files: `android/app/src/main/kotlin/com/example/ble/{MainActivity,BleBridge}.kt`, Manifest.

Consumes / produces: shared channel contract above, settings JSON opaque.

- [x] Implement permissions, BLE + system discovery merge, scan tokens and teardown.
- [x] Implement GATT discovery, profile checking, notification descriptor queue, serial writes, callback identity and timeouts.
- [x] Wire bridge registration and native lifecycle teardown, keep awake, settings and system settings entry.
- [x] Review every async path against disconnect / replacement; run native compile checks if SDK exists, otherwise record unavailable checks.

## Task 3: Native iOS transport

Files: `ios/Runner/BleBridge.swift`, AppDelegate, Info.plist, project.pbxproj.

Consumes / produces: shared channel contract above, settings JSON opaque.

- [x] Implement CoreBluetooth state, scan UUID dedup, service discovery, subscriptions, serial write flow control and deadlines.
- [x] Register bridge with implicit engine messenger, keep awake, settings, foreground teardown.
- [x] Add usage description and Swift file to target; audit cancellation and stale peripheral paths. Xcode checks deferred.

## Task 4: Dart platform adapter and control session

Files: `lib/bluetooth/ble_transport.dart`, `lib/control/remote_controller.dart`; tests `test/controller_test.dart`, `test/transport_test.dart` with controllable transport double at hardware boundary.

Interfaces: `BleTransport` methods for shared contract plus event stream; `RemoteController extends ChangeNotifier`, fields state, mode, configs, layout, devices, status, scan details, last frames, readiness and revisions; actions initialize, scan, stopScan, connect, disconnect, foreground, enable, axes, slider, configuration updates and layout edit.

- [x] Write tests for disabled initial write before enable, no overlapping writes, delayed writes clearing enable, late event rejection, lifecycle clearing and persisted restore.
- [x] Run tests RED, then implement one cancellable send loop, explicit handshake, 300ms gap disarm, lifecycle and configuration persistence.
- [x] Run protocol/config/controller/transport tests GREEN.

## Task 5: Shared reference UI

Files: `lib/main.dart`, `lib/ui/{controller_screen,joystick,control_panel,settings_dialog,connection_dialog}.dart`; replace `test/widget_test.dart`.

Consumes RemoteController and configuration classes. Produces adaptive reference panel and dialogs with stable keys for controls.

- [x] Write widget tests for dual independent pointers / cancellation / config change, panel and dialogs, edit rollback, scaled layout and small screens.
- [x] Run RED against template, then implement panel palette / geometry, gesture ownership, seven independent editable controls, editor toolbar, settings validation and BLE device list.
- [x] Run all `flutter test --no-pub`; expected all pass and no overflow.

## Task 6: Integration verification and documentation

Files: README, THIRD_PARTY_NOTICES, implementation ledger.

- [x] Run formatter, `flutter analyze lib test --no-pub`, `flutter test --no-pub` and inspect outputs.
- [x] Perform fresh code review of native/Dart interfaces and lifecycle; reproduce meaningful findings in tests before fixes.
- [x] Record exact checks executed and limits. Defer build packaging per user; describe hardware acceptance and future build steps.
- [x] Final report implemented features and remaining native compilation / hardware validation.

## Final verification

2026-10-14: source development complete. Flutter scoped analysis clean; full default suite 43/43 passed; format check clean. Five preview images inspected under docs/previews. Native builds, signing, packaging and hardware tests deferred as requested; native XML/source-reference audit completed. Implementation ledger preserves review findings and regression evidence.
