import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../bluetooth/ble_transport.dart';
import 'control_config.dart';
import 'control_protocol.dart';
import 'panel_layout.dart';

class RemoteController extends ChangeNotifier {
  RemoteController({BleTransport? transport})
    : transport = transport ?? PlatformBleTransport();
  final BleTransport transport;
  ControlState state = const ControlState();
  LinkMode mode = LinkMode.uart;
  List<JoystickConfig> stickConfigs = List.filled(2, const JoystickConfig());
  List<SliderConfig> sliderConfigs = List.generate(2, (_) => SliderConfig());
  PanelLayout layout = PanelLayout();
  String selectedLayoutId = 'leftPad';
  String status = '未连接', scanDetails = '', lastFrame = '—', lastReceived = '—';
  List<BleDevice> devices = [];
  bool connected = false, connecting = false, scanning = false;
  int sent = 0;
  final gestureRevisions = [0, 0];
  bool get layoutEditing => layout.editing;
  bool get canEnable =>
      connected && _foreground && _handshaken && !layoutEditing;
  bool get controlsActive => _foreground && !layoutEditing && !state.stopped;
  bool _foreground = true,
      _handshaken = false,
      _disposed = false,
      _initialized = false;
  bool _scanFailed = false;
  bool _acceptScanEvents = false;
  int _scanRequest = 0;
  int _generation = 0, _sequence = 0;
  Timer? _sendTimer;
  Timer? _expiryTimer;
  int _expiryEpoch = 0;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  Future<void>? _writing;
  Future<void> _cleanup = Future.value(), _saveQueue = Future.value();
  DateTime? _lastCompleted;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _cancelGestures() {
    gestureRevisions[0]++;
    gestureRevisions[1]++;
  }

  void _clear() {
    state = const ControlState();
    _cancelGestures();
  }

  Future<void> initialize() async {
    if (_initialized || _disposed) return;
    _initialized = true;
    _subscription = transport.events.listen(
      _event,
      onError: (Object error) {
        status = _message(error);
        _notify();
      },
    );
    try {
      final json = await transport.loadSettings();
      if (_disposed) return;
      if (json != null) {
        final data = jsonDecode(json);
        if (data is Map && data['version'] == 1) {
          mode =
              LinkMode.values.where((v) => v.key == data['mode']).firstOrNull ??
              LinkMode.uart;
          final sticks = data['sticks'], sliders = data['sliders'];
          stickConfigs = List.generate(
            2,
            (i) => JoystickConfig.fromJson(
              sticks is List && i < sticks.length ? sticks[i] : null,
            ),
          );
          sliderConfigs = List.generate(
            2,
            (i) => SliderConfig.fromJson(
              sliders is List && i < sliders.length ? sliders[i] : null,
            ),
          );
          layout = PanelLayout.fromJson(data['layout']);
        }
      }
    } on FormatException {
      status = '设置已恢复默认';
    } catch (error) {
      status = _message(error);
    }
    if (_disposed) return;
    state = state.copyWith(
      slider1: sliderConfigs[0].map(0),
      slider2: sliderConfigs[1].map(0),
    );
    await _awake(_foreground);
    _notify();
  }

  Future<void> _awake(bool enabled) async {
    try {
      await transport.keepAwake(enabled);
    } catch (error) {
      if (!_disposed) {
        status = _message(error);
        _notify();
      }
    }
  }

  void _persist() {
    final json = jsonEncode({
      'version': 1,
      'mode': mode.key,
      'sticks': stickConfigs.map((v) => v.toJson()).toList(),
      'sliders': sliderConfigs.map((v) => v.toJson()).toList(),
      'layout': layout.toJson(),
    });
    _saveQueue = _saveQueue
        .then((_) => transport.saveSettings(json))
        .catchError((Object error) {
          if (!_disposed) {
            status = '设置保存失败：${_message(error)}';
            _notify();
          }
        });
  }

  Future<void> scan() async {
    if (!_foreground || _disposed) return;
    final cleanup = disconnect();
    final token = _generation;
    final request = ++_scanRequest;
    await cleanup;
    if (token != _generation ||
        request != _scanRequest ||
        !_foreground ||
        _disposed) {
      return;
    }
    devices = [];
    _scanFailed = false;
    scanDetails = '正在搜索 BLE 设备';
    scanning = true;
    _acceptScanEvents = true;
    status = '正在扫描…';
    _notify();
    try {
      await transport.scan(token);
    } catch (error) {
      if (token == _generation && request == _scanRequest) {
        scanning = false;
        _acceptScanEvents = false;
        status = _message(error);
        _notify();
      }
    }
  }

  Future<void> stopScan() async {
    _scanRequest++;
    _acceptScanEvents = false;
    scanning = false;
    _notify();
    try {
      await transport.stopScan();
    } catch (error) {
      if (!_disposed) {
        status = _message(error);
        _notify();
      }
    }
  }

  Future<void> changeMode(LinkMode next) async {
    if (mode == next) return;
    final cleanup = disconnect();
    // Commit the requested profile before teardown yields. A quick reversal
    // must supersede the earlier selection even if it equals the old mode.
    mode = next;
    devices = [];
    scanDetails = '';
    _persist();
    _notify();
    await cleanup;
  }

  Future<void> connect(BleDevice device) async {
    final cleanup = disconnect();
    final token = _generation;
    await cleanup;
    if (token != _generation || !_foreground || _disposed) return;
    connecting = true;
    status = '连接 ${device.name}…';
    lastReceived = '—';
    sent = 0;
    _notify();
    try {
      await transport
          .connect(device.id, mode.key, token)
          .timeout(const Duration(seconds: 12));
      if (token != _generation || !_foreground || _disposed) return;
      // MCU watchdog recovery requires a disabled frame before any motion.
      await _writeFrame(const ControlState(), token);
      if (token != _generation || !_foreground || _disposed) return;
      connected = true;
      connecting = false;
      status = '已连接 ${device.name} · 请手动使能';
      _notify();
      _schedule(token);
    } catch (error) {
      if (token == _generation) await _fail(_message(error));
    }
  }

  Future<void> _writeFrame(ControlState snapshot, int token) async {
    if (_writing != null) throw StateError('写入正在进行');
    final frame = ControlProtocol.encode(snapshot, _sequence++);
    final started = DateTime.now();
    // The MCU deadline starts at the previous completed write, including the
    // inter-frame delay. A timer per write would miss 50ms + 280ms gaps.
    if (_expiryTimer == null) _armExpiry(token);
    final epoch = _expiryEpoch;
    final operation = transport
        .write(frame, token)
        .timeout(const Duration(seconds: 1));
    _writing = operation;
    try {
      await operation;
      if (token != _generation || _disposed) return;
      _lastCompleted = DateTime.now();
      sent++;
      lastFrame = ControlProtocol.hex(frame);
      if (epoch == _expiryEpoch &&
          _lastCompleted!.difference(started).inMilliseconds < 300 &&
          !snapshot.enabled) {
        _handshaken = true;
      }
      _armExpiry(token);
      _notify();
    } finally {
      if (identical(_writing, operation)) _writing = null;
    }
  }

  void _armExpiry(int token) {
    _expiryTimer?.cancel();
    _expiryTimer = Timer(const Duration(milliseconds: 300), () {
      _expiryEpoch++;
      if (token == _generation && !_disposed) {
        _handshaken = false;
        _clear();
        status = '发送延迟，已关闭使能 · 请重新使能';
        _notify();
      }
    });
  }

  void _schedule(int token) {
    _sendTimer?.cancel();
    _sendTimer = Timer(
      Duration(milliseconds: mode.periodMs),
      () => _send(token),
    );
  }

  Future<void> _send(int token) async {
    if (token != _generation || !connected || !_foreground || _disposed) return;
    if (_lastCompleted != null &&
        DateTime.now().difference(_lastCompleted!).inMilliseconds >= 300) {
      _handshaken = false;
      _clear();
      status = '发送中断，已关闭使能 · 请重新使能';
      _notify();
    }
    try {
      await _writeFrame(_handshaken ? state : const ControlState(), token);
      if (token == _generation && connected && _foreground && !_disposed) {
        _schedule(token);
      }
    } catch (error) {
      if (token == _generation) await _fail(_message(error));
    }
  }

  Future<void> disconnect() {
    final oldToken = _generation++;
    _scanRequest++;
    _acceptScanEvents = false;
    final wasConnected = connected;
    _sendTimer?.cancel();
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _sendTimer = null;
    connected = false;
    connecting = false;
    scanning = false;
    _handshaken = false;
    _lastCompleted = null;
    _clear();
    status = '未连接';
    _notify();
    final pending = _writing;
    _cleanup = _cleanup.then((_) async {
      try {
        await transport.stopScan();
      } catch (_) {}
      if (wasConnected) {
        var idle = pending == null;
        if (pending != null) {
          try {
            await pending.timeout(const Duration(milliseconds: 120));
            idle = true;
          } catch (_) {}
        }
        if (idle) {
          try {
            await transport
                .write(
                  ControlProtocol.encode(const ControlState(), _sequence++),
                  oldToken,
                )
                .timeout(const Duration(milliseconds: 120));
          } catch (_) {}
        }
      }
      try {
        await transport.disconnect();
      } catch (_) {}
    });
    return _cleanup;
  }

  Future<void> _fail(String message) async {
    final cleanup = disconnect();
    final token = _generation;
    await cleanup;
    if (token == _generation && !_disposed) {
      status = message;
      _notify();
    }
  }

  Future<void> foreground(bool value) async {
    _foreground = value;
    if (!value) await disconnect();
    if (!_disposed && _foreground == value) await _awake(value);
    _notify();
  }

  /// Native layers distinguish their own first-use permission alert from a
  /// background transition. Preserve only a scan request during this brief
  /// inactive state; active control links always stop immediately.
  Future<void> interruption() async {
    _foreground = false;
    _clear();
    _notify();
    if (connected || connecting) await disconnect();
    if (!_disposed && !_foreground) await _awake(false);
  }

  void axes(int index, int x, int y) {
    if (!controlsActive || index < 0 || index > 1) return;
    final (mx, my) = stickConfigs[index].map(x, y);
    state = index == 0
        ? state.copyWith(lx: mx, ly: my)
        : state.copyWith(rx: mx, ry: my);
    _notify();
  }

  void releaseSticks() {
    state = state.copyWith(lx: 0, ly: 0, rx: 0, ry: 0);
    _cancelGestures();
    _notify();
  }

  void slider(int index, int position) {
    if (!controlsActive || index < 0 || index > 1) return;
    final value = sliderConfigs[index].map(position);
    state = index == 0
        ? state.copyWith(slider1: value)
        : state.copyWith(slider2: value);
    _notify();
  }

  void enable(bool value) {
    if (value && !canEnable) return;
    state = state.copyWith(
      enabled: value,
      stopped: value ? false : state.stopped,
      lx: 0,
      ly: 0,
      rx: 0,
      ry: 0,
    );
    if (value) {
      state = state.copyWith(
        slider1: sliderConfigs[0].map(
          sliderConfigs[0].position(state.slider1).round(),
        ),
        slider2: sliderConfigs[1].map(
          sliderConfigs[1].position(state.slider2).round(),
        ),
      );
    }
    _cancelGestures();
    _notify();
  }

  void setStickConfig(int index, JoystickConfig config) {
    if (layoutEditing || index < 0 || index > 1) return;
    state = index == 0
        ? state.copyWith(lx: 0, ly: 0)
        : state.copyWith(rx: 0, ry: 0);
    stickConfigs = List.of(stickConfigs)..[index] = config;
    gestureRevisions[index]++;
    _persist();
    _notify();
  }

  void cycleStickMode(int index) {
    final c = stickConfigs[index];
    setStickConfig(
      index,
      c.copyWith(
        mode: JoystickMode
            .values[(c.mode.index + 1) % JoystickMode.values.length],
      ),
    );
  }

  void setSliderConfig(int index, SliderConfig config) {
    if (layoutEditing || index < 0 || index > 1) return;
    sliderConfigs = List.of(sliderConfigs)..[index] = config;
    state = index == 0
        ? state.copyWith(slider1: config.map(0))
        : state.copyWith(slider2: config.map(0));
    _persist();
    _notify();
  }

  void beginLayoutEdit() {
    if (layoutEditing) return;
    enable(false);
    layout.begin();
    _cancelGestures();
    _notify();
  }

  void selectPanel(String id) {
    if (layoutEditing && PanelLayout.ids.contains(id)) {
      selectedLayoutId = id;
      _notify();
    }
  }

  void movePanel(String id, PanelPosition position) {
    if (!layoutEditing) return;
    selectedLayoutId = id;
    layout.move(id, position);
    _notify();
  }

  void resizePanel(double scale) {
    layout.resize(selectedLayoutId, scale);
    _notify();
  }

  void saveLayoutEdit() {
    layout.save();
    _persist();
    _cancelGestures();
    _notify();
  }

  void cancelLayoutEdit() {
    layout.cancel();
    _cancelGestures();
    _notify();
  }

  void defaultLayoutDraft() {
    layout.restoreDefaults();
    _notify();
  }

  Future<void> openSettings() async {
    try {
      await transport.openSettings();
    } catch (error) {
      status = _message(error);
      _notify();
    }
  }

  void _event(Map<String, dynamic> e) {
    if (_disposed || !_foreground || e['generation'] != _generation) return;
    switch (e['type']) {
      case 'device':
        if (!scanning || e['id'] is! String) return;
        final id = e['id'] as String, rawName = e['name'];
        final old = devices.where((d) => d.id == id).firstOrNull;
        final name =
            rawName is String &&
                rawName.trim().isNotEmpty &&
                rawName != '未命名 BLE 设备'
            ? rawName
            : old?.name ?? '未命名 BLE 设备';
        final source = e['source'] as String? ?? 'BLE';
        final merged = old != null && old.source != source
            ? 'BLE + 系统发现'
            : source;
        devices = [
          ...devices.where((d) => d.id != id),
          BleDevice(
            id: id,
            name: name,
            source: merged,
            rssi: e['rssi'] is int ? e['rssi'] as int : old?.rssi,
          ),
        ]..sort((a, b) => a.name.compareTo(b.name));
      case 'scan':
        if (!_acceptScanEvents) return;
        scanning = e['scanning'] == true;
        if (!scanning) _acceptScanEvents = false;
        scanDetails = e['details'] as String? ?? '';
        if (!scanning && !connected && !connecting && !_scanFailed) {
          status = devices.isEmpty ? '未发现 BLE 设备，请检查模块广播' : '请选择 BLE 设备';
        }
      case 'received':
        final bytes = e['bytes'];
        if (bytes is List) {
          lastReceived = ControlProtocol.hex(bytes.cast<int>());
        }
      case 'disconnected':
        unawaited(_fail(e['message'] as String? ?? '蓝牙连接已断开'));
      case 'error':
        final message = e['message'] as String? ?? '蓝牙操作失败';
        if (connected || connecting) {
          unawaited(_fail(message));
        } else {
          _scanFailed = true;
          scanning = false;
          status = message;
        }
    }
    _notify();
  }

  String _message(Object error) => switch (error) {
    PlatformException(:final message) => message ?? '蓝牙操作失败，请检查权限和设备状态',
    MissingPluginException() => '当前平台未提供蓝牙功能，请在 Android 或 iOS 上运行',
    TimeoutException() => '蓝牙操作超时，请检查模块供电与连接',
    _ => error.toString(),
  };
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _sendTimer?.cancel();
    _expiryTimer?.cancel();
    _generation++;
    _clear();
    unawaited(_subscription?.cancel());
    unawaited(
      _cleanup.then((_) => transport.disconnect()).catchError((Object _) {}),
    );
    unawaited(transport.keepAwake(false).catchError((Object _) {}));
    super.dispose();
  }
}
