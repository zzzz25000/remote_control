import CoreBluetooth
import Flutter
import UIKit

/// All platform calls, delegates and deadlines run on the main queue. Each BLE
/// operation owns a fresh central/delegate, so old same-UUID callbacks are inert.
final class BleBridge: NSObject, FlutterStreamHandler {
  private let methods: FlutterMethodChannel
  private let events: FlutterEventChannel
  private var sink: FlutterEventSink?
  private var session: BleSession?
  private var observers: [NSObjectProtocol] = []
  private var foreground = UIApplication.shared.applicationState != .background
  private var disposed = false
  private let settingsKey = "ble.remote.settings.v1"

  init(messenger: FlutterBinaryMessenger) {
    methods = FlutterMethodChannel(name: "ble.remote/methods", binaryMessenger: messenger)
    events = FlutterEventChannel(name: "ble.remote/events", binaryMessenger: messenger)
    super.init()
    methods.setMethodCallHandler { [weak self] call, result in
      guard let self = self, !self.disposed else {
        result(FlutterError(code: "disposed", message: "蓝牙控制器已关闭", details: nil))
        return
      }
      self.handle(call, result: result)
    }
    events.setStreamHandler(self)
    let center = NotificationCenter.default
    // UIScene notifications cover the current Flutter scene lifecycle as well
    // as UIApplication notifications used by older application lifecycle hosts.
    for name in [UIApplication.willResignActiveNotification,
                 UIApplication.didEnterBackgroundNotification,
                 UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
        let background = notification.name == UIApplication.didEnterBackgroundNotification ||
          notification.name == UIScene.didEnterBackgroundNotification
        self?.leaveForeground(background: background)
      })
    }
    for name in [UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.foreground = true
        self?.session?.resumeForeground()
      })
    }
    observers.append(center.addObserver(forName: UIApplication.willTerminateNotification,
                                       object: nil, queue: .main) { [weak self] _ in self?.dispose() })
  }

  func dispose() {
    guard !disposed else { return }
    disposed = true
    stopSession(code: "cancelled", message: "蓝牙控制器已关闭", safetyFrame: true)
    UIApplication.shared.isIdleTimerDisabled = false
    methods.setMethodCallHandler(nil)
    events.setStreamHandler(nil)
    sink = nil
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers.removeAll()
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    stopSession(code: "cancelled", message: "蓝牙事件订阅已关闭", safetyFrame: true)
    sink = nil
    UIApplication.shared.isIdleTimerDisabled = false
    return nil
  }

  fileprivate func isCurrent(_ candidate: BleSession) -> Bool {
    foreground && ownsSession(candidate)
  }

  fileprivate func ownsSession(_ candidate: BleSession) -> Bool {
    !disposed && session === candidate
  }

  fileprivate func emit(_ event: [String: Any]) { sink?(event) }

  fileprivate func finished(_ candidate: BleSession) {
    if session === candidate { session = nil }
  }

  private func leaveForeground(background: Bool) {
    foreground = false
    // A first-use system permission alert can temporarily deactivate the scene.
    // Preserve only the unstarted permission request; a real background entry
    // always cancels it. Active transport is torn down on any loss of focus.
    if background || session?.awaitingAuthorization != true {
      stopSession(code: "background", message: "应用已离开前台，控制已停止", safetyFrame: true)
    }
    UIApplication.shared.isIdleTimerDisabled = false
  }

  private func stopSession(code: String, message: String, safetyFrame: Bool = false) {
    let old = session
    // Invalidate the identity before completing pending futures or cancelling
    // CoreBluetooth, since those completions may schedule another operation.
    session = nil
    old?.close(code: code, message: message, safetyFrame: safetyFrame)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "scan":
      guard let generation = args["generation"] as? Int else { badArguments(result); return }
      guard foreground else { fail(result, "background", "请回到前台后扫描蓝牙设备"); return }
      stopSession(code: "cancelled", message: "已开始新的蓝牙扫描", safetyFrame: true)
      let next = BleSession(owner: self, generation: generation, kind: .scan, result: result)
      session = next
      next.start()
    case "stopScan":
      if session?.kind == .scan { stopSession(code: "cancelled", message: "扫描已停止") }
      result(nil)
    case "connect":
      guard let generation = args["generation"] as? Int,
            let id = args["id"] as? String, let uuid = UUID(uuidString: id),
            let mode = args["mode"] as? String, let profile = BleProfile(mode: mode) else {
        badArguments(result); return
      }
      guard foreground else { fail(result, "background", "请回到前台后连接蓝牙设备"); return }
      stopSession(code: "cancelled", message: "已切换蓝牙连接", safetyFrame: true)
      let next = BleSession(owner: self, generation: generation,
                            kind: .connection, result: result, id: uuid, profile: profile)
      session = next
      next.start()
    case "write":
      guard let generation = args["generation"] as? Int,
            let bytes = args["bytes"] as? FlutterStandardTypedData,
            bytes.elementSize == 1, !bytes.data.isEmpty else { badArguments(result); return }
      guard foreground else { fail(result, "background", "应用不在前台，不能发送控制数据"); return }
      guard let current = session, current.kind == .connection,
            current.generation == generation else {
        fail(result, "not_connected", "连接已失效，请重新连接"); return
      }
      current.write(bytes.data, result: result)
    case "disconnect":
      stopSession(code: "cancelled", message: "蓝牙连接已断开", safetyFrame: true)
      result(nil)
    case "loadSettings":
      result(UserDefaults.standard.string(forKey: settingsKey))
    case "saveSettings":
      guard let json = args["json"] as? String else { badArguments(result); return }
      UserDefaults.standard.set(json, forKey: settingsKey)
      if UserDefaults.standard.string(forKey: settingsKey) == json { result(nil) }
      else { fail(result, "settings_failed", "设置保存失败，请重试") }
    case "keepAwake":
      guard let enabled = args["enabled"] as? Bool else { badArguments(result); return }
      UIApplication.shared.isIdleTimerDisabled = enabled && foreground
      result(nil)
    case "openSettings":
      guard let url = URL(string: UIApplication.openSettingsURLString) else {
        fail(result, "settings_unavailable", "无法打开应用设置，请手动进入系统设置"); return
      }
      UIApplication.shared.open(url, options: [:]) { opened in
        DispatchQueue.main.async {
          if opened { result(nil) }
          else { result(FlutterError(code: "settings_unavailable", message: "无法打开应用设置，请手动进入系统设置", details: nil)) }
        }
      }
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func badArguments(_ result: FlutterResult) { fail(result, "invalid_arguments", "蓝牙请求参数无效") }
  private func fail(_ result: FlutterResult, _ code: String, _ message: String) {
    result(FlutterError(code: code, message: message, details: nil))
  }

  /// Best-effort disabled frame on teardown. It is never queued behind a write;
  /// if the transport cannot send immediately, the MCU watchdog remains active.
  static func disabledFrame(after data: Data) -> Data? {
    var bytes = [UInt8](data)
    guard bytes.count == 20, bytes[0] == 0xA5, bytes[1] == 0x5A, bytes[2] == 1 else { return nil }
    bytes[3] = bytes[3] &+ 1
    for index in 4...17 { bytes[index] = 0 }
    var crc: UInt16 = 0xFFFF
    for byte in bytes[2...17] {
      crc ^= UInt16(byte) << 8
      for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc &<< 1) ^ 0x1021 : crc &<< 1 }
    }
    bytes[18] = UInt8(crc & 0xFF)
    bytes[19] = UInt8(crc >> 8)
    return Data(bytes)
  }
}

fileprivate struct BleProfile {
  let service: CBUUID
  let transmit: CBUUID
  let receive: CBUUID

  init?(mode: String) {
    switch mode {
    case "uart": service = CBUUID(string: "FFE0"); transmit = CBUUID(string: "FFE1"); receive = transmit
    case "bt630": service = CBUUID(string: "FFF0"); transmit = CBUUID(string: "FFF2"); receive = CBUUID(string: "FFF1")
    default: return nil
    }
  }
}

/// This object is the native callback token. It is never reused or assigned to
/// another request. Its original central and peripheral must also match.
fileprivate final class BleSession: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
  enum Kind { case scan, connection }
  let kind: Kind
  let generation: Int
  private weak var owner: BleBridge?
  private var central: CBCentralManager?
  private var peripheral: CBPeripheral?
  private let id: UUID?
  private let profile: BleProfile?
  private var initialResult: FlutterResult?
  private var writeResult: FlutterResult?
  private var writeToken: UUID?
  private var queuedWrite: Data?
  private var lastSubmitted: Data?
  private var operationDeadline: DispatchWorkItem?
  private var writeDeadline: DispatchWorkItem?
  private var tx: CBCharacteristic?
  private var rx: CBCharacteristic?
  private var writeType: CBCharacteristicWriteType = .withResponse
  private var started = false
  private var scanning = false
  private var ready = false
  private var closed = false
  private var devices: [UUID: CBPeripheral] = [:]

  init(owner: BleBridge, generation: Int, kind: Kind, result: @escaping FlutterResult,
       id: UUID? = nil, profile: BleProfile? = nil) {
    self.owner = owner
    self.generation = generation
    self.kind = kind
    initialResult = result
    self.id = id
    self.profile = profile
    super.init()
  }

  func start() {
    let deadline = DispatchWorkItem { [weak self] in
      guard let self = self, !self.closed, self.owner?.ownsSession(self) == true else { return }
      if self.kind == .scan, self.scanning {
        self.close(code: "cancelled", message: "扫描已结束")
      } else {
        self.fail(self.kind == .scan ? "scan_timeout" : "connect_timeout",
                  self.kind == .scan ? "蓝牙未就绪，扫描超时，请检查权限和蓝牙开关" : "连接超时，请确认模块已开启并重试")
      }
    }
    operationDeadline = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + (kind == .scan ? 20 : 10), execute: deadline)
    central = CBCentralManager(delegate: self, queue: .main,
                               options: [CBCentralManagerOptionShowPowerAlertKey: false])
  }

  private var current: Bool { !closed && owner?.isCurrent(self) == true }

  var awaitingAuthorization: Bool {
    !closed && !started && CBCentralManager.authorization == .notDetermined
  }

  func resumeForeground() {
    if let manager = central { centralManagerDidUpdateState(manager) }
  }
  private func matches(_ manager: CBCentralManager) -> Bool { current && central === manager }
  private func matches(_ candidate: CBPeripheral) -> Bool { current && peripheral === candidate }

  private func event(_ type: String, _ fields: [String: Any] = [:]) {
    var values = fields
    values["type"] = type
    values["generation"] = generation
    owner?.emit(values)
  }

  private func completeInitial(_ error: FlutterError? = nil) {
    let result = initialResult
    initialResult = nil
    result?(error)
  }

  private func completeWrite(_ error: FlutterError? = nil) {
    writeDeadline?.cancel()
    writeDeadline = nil
    queuedWrite = nil
    writeToken = nil
    let result = writeResult
    writeResult = nil
    result?(error)
  }

  private func fail(_ code: String, _ message: String) {
    guard !closed else { return }
    event("error", ["code": code, "message": message])
    close(code: code, message: message)
  }

  func close(code: String, message: String, safetyFrame: Bool = false) {
    guard !closed else { return }
    closed = true
    operationDeadline?.cancel()
    operationDeadline = nil
    writeDeadline?.cancel()
    if safetyFrame, ready, writeResult == nil, central?.state == .poweredOn,
       let candidate = peripheral, candidate.state == .connected, let characteristic = tx,
       let last = lastSubmitted, let disabled = BleBridge.disabledFrame(after: last),
       disabled.count <= candidate.maximumWriteValueLength(for: writeType),
       writeType == .withResponse || candidate.canSendWriteWithoutResponse {
      candidate.writeValue(disabled, for: characteristic, type: writeType)
    }
    ready = false
    if let manager = central {
      if manager.state == .poweredOn {
        if scanning { manager.stopScan() }
        if let candidate = peripheral { manager.cancelPeripheralConnection(candidate) }
      }
      manager.delegate = nil
    }
    peripheral?.delegate = nil
    peripheral = nil
    central = nil
    tx = nil
    rx = nil
    devices.removeAll()
    owner?.finished(self)
    let error = FlutterError(code: code, message: message, details: nil)
    completeInitial(error)
    completeWrite(error)
    if kind == .scan { scanning = false; event("scan", ["scanning": false, "details": message]) }
    else { event("disconnected", ["message": message]) }
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    guard matches(central) else { return }
    switch CBCentralManager.authorization {
    case .denied, .restricted: fail("permission_denied", "蓝牙权限未授权，请在应用设置中允许蓝牙访问"); return
    case .allowedAlways, .notDetermined: break
    @unknown default: fail("permission_denied", "无法确认蓝牙权限，请检查应用设置"); return
    }
    switch central.state {
    case .unknown, .resetting:
      if started { fail("bluetooth_reset", "蓝牙正在重置，控制已停止，请重新连接") }
      // Before startup, await a later state callback within the deadline.
      return
    case .unauthorized: fail("permission_denied", "蓝牙权限未授权，请在应用设置中允许蓝牙访问")
    case .poweredOff: fail("bluetooth_off", "蓝牙已关闭，请在系统设置或控制中心开启蓝牙")
    case .unsupported: fail("bluetooth_unavailable", "此设备不支持 BLE 蓝牙")
    case .poweredOn:
      guard !started else { return }
      started = true
      if kind == .scan {
        scanning = true
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        event("scan", ["scanning": true, "details": "正在扫描 BLE 设备（iOS 使用设备 UUID）"])
        completeInitial()
      } else if let id = id {
        guard let candidate = central.retrievePeripherals(withIdentifiers: [id]).first else {
          fail("device_unavailable", "设备已不可用，请重新扫描后连接"); return
        }
        peripheral = candidate
        candidate.delegate = self
        central.connect(candidate, options: nil)
      }
    @unknown default: fail("bluetooth_unavailable", "蓝牙状态异常，请重试")
    }
  }

  func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                      advertisementData: [String: Any], rssi RSSI: NSNumber) {
    guard matches(central), kind == .scan, scanning else { return }
    guard devices[peripheral.identifier] == nil else { return }
    devices[peripheral.identifier] = peripheral
    let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
    let name = (advertised?.isEmpty == false ? advertised : peripheral.name) ?? "未命名 BLE 设备"
    event("device", ["id": peripheral.identifier.uuidString, "name": name,
                     "source": "BLE", "rssi": RSSI.intValue])
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard matches(central), matches(peripheral), let profile = profile, !ready else { return }
    peripheral.discoverServices([profile.service])
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    guard matches(central), matches(peripheral) else { return }
    fail("connect_failed", "蓝牙连接失败，请确认模块可连接后重试")
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    guard matches(central), matches(peripheral) else { return }
    close(code: "disconnected", message: error == nil ? "蓝牙连接已断开" : "蓝牙连接中断，请重新连接")
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard matches(peripheral), !ready, let profile = profile else { return }
    guard error == nil else { fail("service_discovery_failed", "发现蓝牙服务失败，请重新连接"); return }
    guard let service = peripheral.services?.first(where: { $0.uuid == profile.service }) else {
      fail("service_missing", "设备没有当前模式所需的蓝牙服务，请检查模块模式"); return
    }
    peripheral.discoverCharacteristics(Array(Set([profile.transmit, profile.receive])), for: service)
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    guard matches(peripheral), !ready, let profile = profile, service.uuid == profile.service,
          peripheral.services?.contains(where: { $0 === service }) == true else { return }
    guard error == nil else { fail("characteristic_discovery_failed", "发现蓝牙特征失败，请重新连接"); return }
    guard let characteristic = service.characteristics?.first(where: { $0.uuid == profile.transmit }) else {
      fail("characteristic_missing", "设备缺少写入特征，请检查模块模式"); return
    }
    if characteristic.properties.contains(.writeWithoutResponse) { writeType = .withoutResponse }
    else if characteristic.properties.contains(.write) { writeType = .withResponse }
    else { fail("not_writable", "当前模块的特征不支持写入"); return }
    tx = characteristic
    if let receive = service.characteristics?.first(where: { $0.uuid == profile.receive }),
       receive.properties.contains(.notify) || receive.properties.contains(.indicate) {
      rx = receive
      peripheral.setNotifyValue(true, for: receive)
    } else { becomeReady() }
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
    guard matches(peripheral), characteristic === rx, !ready else { return }
    guard error == nil, characteristic.isNotifying else {
      fail("notification_failed", "启用模块通知失败，请重新连接"); return
    }
    becomeReady()
  }

  private func becomeReady() {
    guard current, !ready, tx != nil else { return }
    ready = true
    operationDeadline?.cancel()
    operationDeadline = nil
    completeInitial()
  }

  func write(_ data: Data, result: @escaping FlutterResult) {
    guard current, ready, let candidate = peripheral, candidate.state == .connected, let characteristic = tx else {
      result(FlutterError(code: "not_connected", message: "蓝牙连接尚未就绪，请重新连接", details: nil)); return
    }
    guard writeResult == nil else {
      result(FlutterError(code: "write_busy", message: "上一条蓝牙写入尚未完成", details: nil)); return
    }
    guard data.count <= candidate.maximumWriteValueLength(for: writeType) else {
      result(FlutterError(code: "write_too_large", message: "数据长度超过当前蓝牙写入上限", details: nil)); return
    }
    writeResult = result
    let token = UUID()
    writeToken = token
    queuedWrite = data
    let deadline = DispatchWorkItem { [weak self, weak candidate] in
      guard let self = self, let candidate = candidate, self.matches(candidate),
            self.writeToken == token, self.writeResult != nil else { return }
      self.fail("write_timeout", "蓝牙写入超时，控制已停止，请重新连接")
    }
    writeDeadline = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: deadline)
    if writeType == .withoutResponse { submitWithoutResponse(candidate) }
    else {
      queuedWrite = nil
      lastSubmitted = data
      candidate.writeValue(data, for: characteristic, type: .withResponse)
    }
  }

  private func submitWithoutResponse(_ candidate: CBPeripheral) {
    guard matches(candidate), ready, writeType == .withoutResponse,
          candidate.canSendWriteWithoutResponse, let data = queuedWrite,
          let characteristic = tx, writeResult != nil else { return }
    queuedWrite = nil
    lastSubmitted = data
    candidate.writeValue(data, for: characteristic, type: .withoutResponse)
    completeWrite()
  }

  func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
    guard matches(peripheral) else { return }
    submitWithoutResponse(peripheral)
  }

  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
    guard matches(peripheral), ready, characteristic === tx, writeType == .withResponse,
          writeResult != nil else { return }
    if error != nil { fail("write_failed", "蓝牙写入失败，控制已停止，请重新连接") }
    else { completeWrite() }
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    guard matches(peripheral), ready, characteristic === rx else { return }
    guard error == nil else {
      event("error", ["code": "receive_failed", "message": "读取模块通知失败"]); return
    }
    if let data = characteristic.value { event("received", ["bytes": FlutterStandardTypedData(bytes: data)]) }
  }

  func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
    guard matches(peripheral), let profile = profile,
          invalidatedServices.contains(where: { $0.uuid == profile.service }) else { return }
    fail("service_invalidated", "模块服务已变化，请重新连接")
  }
}
