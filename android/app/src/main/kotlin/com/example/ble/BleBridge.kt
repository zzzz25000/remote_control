package com.example.ble

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.WindowManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque
import java.util.UUID

/** Bluetooth callbacks and every state mutation are serialized on the main handler. */
@SuppressLint("MissingPermission")
@Suppress("DEPRECATION")
class BleBridge(private val activity: Activity, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val handler = Handler(Looper.getMainLooper())
    private val methods = MethodChannel(messenger, "ble.remote/methods")
    private val events = EventChannel(messenger, "ble.remote/events")
    private val adapter = (activity.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
    private val preferences = activity.getSharedPreferences("ble.remote.settings", Context.MODE_PRIVATE)
    private val nativeSession = NativeSession()
    private var sink: EventChannel.EventSink? = null
    private var scanCounter = 0L
    private var scan: Scan? = null
    private var connection: Connection? = null
    private var permission: PermissionRequest? = null
    private var nextPermissionCode = 4200
    private var foreground = true
    private var disposed = false
    private var adapterReceiverRegistered = false
    private var settingsAction = Settings.ACTION_BLUETOOTH_SETTINGS

    private class Reply(private val result: MethodChannel.Result) {
        private val completion = NativeCompletion()
        fun success(value: Any? = null) { if (completion.claim()) result.success(value) }
        fun error(code: String, message: String) { if (completion.claim()) result.error(code, message, null) }
    }

    private class PermissionRequest(
        val code: Int, val reply: Reply, val required: List<String>, val action: () -> Unit,
    ) {
        var cancelled = false
        var granted = false
    }

    private class DeviceRecord(val id: String) {
        var name: String = "未命名设备"
        var ble = false
        var system = false
        var rssi: Int? = null
        val source: String get() = if (ble && system) "BLE + 系统发现" else if (ble) "BLE" else "系统发现"
    }

    private class Scan(val token: Long, val generation: Int, val reply: Reply) {
        val devices = linkedMapOf<String, DeviceRecord>()
        var scanner: BluetoothLeScanner? = null
        var callback: ScanCallback? = null
        var receiver: BroadcastReceiver? = null
        var receiverRegistered = false
        var bleRunning = false
        var discoveryRunning = false
        var discoveryRequested = false
        var bleResults = 0
        var systemResults = 0
        var bleNote = "未启动"
        var systemNote = "未启动"
        var timeout: Runnable? = null
    }

    private class Connection(val token: Long, val generation: Int, val mode: String, val reply: Reply) {
        var gatt: BluetoothGatt? = null
        var tx: BluetoothGattCharacteristic? = null
        var rx: BluetoothGattCharacteristic? = null
        val descriptors = ArrayDeque<BluetoothGattDescriptor>()
        var descriptor: BluetoothGattDescriptor? = null
        var timeout: Runnable? = null
        var ready = false
        var write: Write? = null
        var lastFrame: ByteArray? = null
    }

    private class Write(val characteristic: BluetoothGattCharacteristic, val reply: Reply) {
        var timeout: Runnable? = null
    }

    private val adapterReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (disposed || intent.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
            if (state == BluetoothAdapter.STATE_TURNING_OFF || state == BluetoothAdapter.STATE_OFF) {
                scan?.let { failScan(it, "bluetooth_off", "蓝牙已关闭，请开启蓝牙后重试") }
                closeConnection("bluetooth_off", "蓝牙已关闭，连接已断开")
                cancelPermission("bluetooth_off", "蓝牙已关闭，请开启蓝牙后重试")
            }
        }
    }

    init {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
        registerReceiver(adapterReceiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED))
        adapterReceiverRegistered = true
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) { sink = events }
    override fun onCancel(arguments: Any?) { sink = null }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val reply = Reply(result)
        if (disposed) { reply.error("disposed", "蓝牙服务已释放"); return }
        try {
            when (call.method) {
                "scan" -> startScan(requireGeneration(call), reply)
                "stopScan" -> { stopScan("扫描已停止"); reply.success() }
                "connect" -> connect(requireString(call, "id"), requireString(call, "mode"), requireGeneration(call), reply)
                "write" -> write(call.argument<ByteArray>("bytes") ?: throw IllegalArgumentException("缺少待发送字节"), requireGeneration(call), reply)
                "disconnect" -> { stopScan("扫描已停止"); closeConnection("cancelled", "连接已断开"); cancelPermission("cancelled", "操作已取消"); reply.success() }
                "loadSettings" -> reply.success(preferences.getString("json", null))
                "saveSettings" -> {
                    if (preferences.edit().putString("json", requireString(call, "json")).commit()) reply.success()
                    else reply.error("settings_save_failed", "设置保存失败，请稍后重试")
                }
                "openSettings" -> { openSettings(); reply.success() }
                "keepAwake" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: throw IllegalArgumentException("缺少屏幕常亮开关")
                    setKeepAwake(enabled && foreground)
                    reply.success()
                }
                else -> result.notImplemented()
            }
        } catch (e: IllegalArgumentException) {
            reply.error("invalid_argument", e.message ?: "请求参数无效")
        } catch (e: SecurityException) {
            reply.error("permission_denied", "蓝牙或定位权限不足，请进入应用设置授权")
        } catch (e: Exception) {
            reply.error("native_error", "系统操作失败，请重试：${e.message ?: e.javaClass.simpleName}")
        }
    }

    private fun requireString(call: MethodCall, key: String): String =
        call.argument<String>(key)?.takeIf { it.isNotEmpty() } ?: throw IllegalArgumentException("缺少参数 $key")

    private fun requireGeneration(call: MethodCall): Int =
        call.argument<Number>("generation")?.toInt() ?: throw IllegalArgumentException("缺少连接代次")

    private fun emit(event: Map<String, Any?>) { if (!disposed) sink?.success(event) }
    private fun error(generation: Int, code: String, message: String) =
        emit(mapOf("type" to "error", "generation" to generation, "code" to code, "message" to message))

    private fun scanPermissions(): List<String> = buildList {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            add(Manifest.permission.BLUETOOTH_SCAN)
            add(Manifest.permission.BLUETOOTH_CONNECT)
        }
        // On Android 12+, coarse must accompany fine in the same location request.
        add(Manifest.permission.ACCESS_COARSE_LOCATION)
        add(Manifest.permission.ACCESS_FINE_LOCATION)
    }

    private fun connectionPermissions(): List<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) listOf(Manifest.permission.BLUETOOTH_CONNECT) else emptyList()

    private fun granted(permission: String): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M || activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun withPermissions(required: List<String>, reply: Reply, action: () -> Unit): Boolean {
        if (!foreground) { reply.error("background", "应用退到后台，操作已取消"); return false }
        val missing = required.filterNot(::granted).toMutableList()
        if (missing.isEmpty()) { action(); return true }
        if (permission != null) { reply.error("permission_busy", "请先完成当前权限申请，再重试"); return false }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && Manifest.permission.ACCESS_FINE_LOCATION in missing && Manifest.permission.ACCESS_COARSE_LOCATION !in missing) {
            missing.add(Manifest.permission.ACCESS_COARSE_LOCATION)
        }
        val request = PermissionRequest(nextPermissionCode++, reply, required, action)
        permission = request
        try { activity.requestPermissions(missing.toTypedArray(), request.code) }
        catch (e: Exception) {
            permission = null
            reply.error("permission_denied", "无法申请权限，请进入应用设置授权")
            return false
        }
        return true
    }

    fun onRequestPermissionsResult(requestCode: Int) {
        val request = permission ?: return
        if (requestCode != request.code) return
        if (request.cancelled || disposed) { permission = null; return }
        if (!request.required.all(::granted)) {
            permission = null
            settingsAction = Settings.ACTION_APPLICATION_DETAILS_SETTINGS
            request.reply.error("permission_denied", if (Manifest.permission.ACCESS_FINE_LOCATION in request.required)
                "需要附近设备与精确定位权限；仅允许大致位置无法完成系统发现，请在应用设置中授权"
                else "需要附近设备的蓝牙连接权限，请在应用设置中授权")
            scan?.takeIf { it.reply === request.reply }?.let { failScan(it, "permission_denied", "扫描权限未获授权，请允许附近设备与精确定位") }
            connection?.takeIf { it.reply === request.reply }?.let { failConnection(it, "permission_denied", "蓝牙连接权限未获授权") }
            return
        }
        request.granted = true
        if (foreground) { permission = null; request.action() }
        // Permission UI can deliver its result before the Activity resumes.
    }

    private fun cancelPermission(code: String, message: String) {
        permission?.let {
            it.cancelled = true
            it.reply.error(code, message)
            if (it.granted) permission = null
        }
        // Retain a cancelled physical dialog until its own requestCode callback arrives.
    }

    private fun requireAdapter(reply: Reply): BluetoothAdapter? {
        val current = adapter
        if (current == null || !activity.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) {
            reply.error("bluetooth_unsupported", "此设备不支持 BLE 蓝牙")
            return null
        }
        if (!current.isEnabled) {
            settingsAction = Settings.ACTION_BLUETOOTH_SETTINGS
            reply.error("bluetooth_off", "蓝牙未开启，请在系统设置中开启")
            return null
        }
        return current
    }

    private fun locationEnabled(): Boolean {
        val manager = activity.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) manager.isLocationEnabled
        else manager.isProviderEnabled(LocationManager.GPS_PROVIDER) || manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
    }

    private fun startScan(generation: Int, reply: Reply) {
        stopScan("开始新的扫描")
        val operation = Scan(++scanCounter, generation, reply)
        scan = operation
        val accepted = withPermissions(scanPermissions(), reply) {
            if (!current(operation)) return@withPermissions
            try {
                val bluetooth = requireAdapter(reply) ?: run { stopScan("蓝牙不可用"); return@withPermissions }
                if (!locationEnabled()) {
                    settingsAction = Settings.ACTION_LOCATION_SOURCE_SETTINGS
                    failScan(operation, "location_off", "系统发现需要开启定位服务；请开启定位并允许精确位置后重试")
                    return@withPermissions
                }
                settingsAction = Settings.ACTION_BLUETOOTH_SETTINGS
                val scanner = bluetooth.bluetoothLeScanner
                    ?: run { failScan(operation, "scan_unavailable", "BLE 扫描器不可用，请重新开启蓝牙"); return@withPermissions }
                operation.scanner = scanner
                val callback = object : ScanCallback() {
                    override fun onScanResult(callbackType: Int, result: ScanResult) {
                        handler.post { if (current(operation)) device(operation, result.device, result.scanRecord?.deviceName, true, result.rssi) }
                    }
                    override fun onBatchScanResults(results: MutableList<ScanResult>) {
                        val snapshot = results.toList()
                        handler.post { if (current(operation)) snapshot.forEach { device(operation, it.device, it.scanRecord?.deviceName, true, it.rssi) } }
                    }
                    override fun onScanFailed(errorCode: Int) {
                        handler.post {
                            if (!current(operation)) return@post
                            operation.bleRunning = false
                            operation.bleNote = "失败 $errorCode"
                            error(operation.generation, "scan_failed", "BLE 扫描失败（$errorCode），请稍后重试")
                            if (!operation.discoveryRunning) failScan(operation, "scan_failed", "BLE 与系统发现均不可用，请重新开启蓝牙")
                            else scanEvent(operation, true, "BLE 扫描失败，正在进行系统发现")
                        }
                    }
                }
                operation.callback = callback
                val receiver = object : BroadcastReceiver() {
                    override fun onReceive(context: Context, intent: Intent) {
                        if (!current(operation)) return
                        when (intent.action) {
                            BluetoothAdapter.ACTION_DISCOVERY_STARTED -> {
                                operation.discoveryRunning = true
                                operation.systemNote = "扫描中"
                                scanEvent(operation, true, "系统发现已启动")
                            }
                            BluetoothDevice.ACTION_FOUND -> {
                                val found = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
                                    intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                                else intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE)
                                found?.let {
                                    val rssi = if (intent.hasExtra(BluetoothDevice.EXTRA_RSSI)) intent.getShortExtra(BluetoothDevice.EXTRA_RSSI, 0).toInt() else null
                                    device(operation, it, intent.getStringExtra(BluetoothDevice.EXTRA_NAME), false, rssi)
                                }
                            }
                            BluetoothAdapter.ACTION_DISCOVERY_FINISHED -> {
                                // A finish broadcast from discovery cancelled before this scan
                                // must not mark a newly started system discovery as finished.
                                if (runCatching { bluetooth.isDiscovering }.getOrDefault(false)) return
                                operation.discoveryRunning = false
                                operation.systemNote = "结束"
                                if (!operation.bleRunning) stopScan("系统发现已完成")
                                else scanEvent(operation, true, "系统发现已完成，BLE 扫描继续")
                            }
                        }
                    }
                }
                operation.receiver = receiver
                registerReceiver(receiver, IntentFilter().apply {
                    addAction(BluetoothDevice.ACTION_FOUND)
                    addAction(BluetoothAdapter.ACTION_DISCOVERY_STARTED)
                    addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
                })
                operation.receiverRegistered = true
                if (bluetooth.isDiscovering) bluetooth.cancelDiscovery()
                operation.bleRunning = true
                operation.bleNote = "扫描中"
                scanner.startScan(null, ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), callback)
                operation.discoveryRunning = bluetooth.startDiscovery()
                operation.discoveryRequested = operation.discoveryRunning
                operation.systemNote = if (operation.discoveryRunning) "扫描中" else "启动失败"
                scanEvent(operation, true, if (operation.discoveryRunning) "BLE 扫描 + 系统发现" else "BLE 扫描中；系统发现未能启动")
                operation.timeout = Runnable { if (current(operation)) stopScan("扫描完成（20 秒）") }.also { handler.postDelayed(it, 20_000) }
                reply.success()
            } catch (e: SecurityException) {
                failScan(operation, "permission_denied", "扫描权限不足，请允许附近设备与精确定位")
            } catch (e: Exception) {
                failScan(operation, "scan_failed", "扫描启动失败，请重新开启蓝牙后重试")
            }
        }
        // Synchronous permission/background rejection must not leave an active scan slot.
        if (!accepted && current(operation)) stopScan("扫描请求未能开始")
    }

    private fun current(operation: Scan): Boolean = !disposed && scan === operation && operation.token == scanCounter

    private fun scanEvent(operation: Scan, scanning: Boolean, details: String) =
        emit(mapOf(
            "type" to "scan", "generation" to operation.generation, "scanning" to scanning,
            "details" to "BLE：${operation.bleResults} 条（${operation.bleNote}）；系统：${operation.systemResults} 条（${operation.systemNote}）；可选 ${operation.devices.size} 个；$details",
        ))

    private fun device(operation: Scan, device: BluetoothDevice, advertisedName: String?, ble: Boolean, rssi: Int?) {
        if (!current(operation)) return
        // Count every raw callback, including repeated advertisements and devices that
        // cannot be selected for either BLE profile, before applying the device filter.
        if (ble) operation.bleResults++ else operation.systemResults++
        try {
            if (ble || device.type == BluetoothDevice.DEVICE_TYPE_LE || device.type == BluetoothDevice.DEVICE_TYPE_DUAL) {
                val id = device.address
                val record = operation.devices.getOrPut(id) { DeviceRecord(id) }
                (advertisedName?.takeIf { it.isNotBlank() } ?: device.name?.takeIf { it.isNotBlank() })?.let { record.name = it }
                if (ble) record.ble = true else record.system = true
                if (rssi != null) record.rssi = rssi
                emit(buildMap {
                    put("type", "device"); put("generation", operation.generation); put("id", id)
                    put("name", record.name); put("source", record.source)
                    record.rssi?.let { put("rssi", it) }
                })
            }
            scanEvent(operation, true, "扫描中")
        } catch (e: SecurityException) { failScan(operation, "permission_denied", "读取设备信息的蓝牙权限已撤销") }
    }

    private fun failScan(operation: Scan, code: String, message: String) {
        if (!current(operation)) return
        operation.reply.error(code, message)
        error(operation.generation, code, message)
        stopScan(message)
    }

    private fun stopScan(details: String) {
        val operation = scan ?: return
        scan = null
        scanCounter++
        operation.timeout?.let(handler::removeCallbacks)
        if (permission?.reply === operation.reply) cancelPermission("cancelled", "扫描已取消")
        operation.reply.error("cancelled", "扫描已取消")
        if (operation.receiverRegistered) operation.receiver?.let { runCatching { activity.unregisterReceiver(it) } }
        if (operation.bleRunning) operation.callback?.let { runCatching { operation.scanner?.stopScan(it) } }
        if (operation.discoveryRequested) runCatching { adapter?.cancelDiscovery() }
        val finished = details == "扫描完成（20 秒）" || details == "系统发现已完成"
        if (operation.bleNote == "扫描中") operation.bleNote = if (finished) "结束" else "已停止"
        if (operation.systemNote == "扫描中") operation.systemNote = if (finished) "结束" else "已停止"
        scanEvent(operation, false, details)
    }

    private fun connect(id: String, mode: String, generation: Int, reply: Reply) {
        if (mode != "uart" && mode != "bt630") throw IllegalArgumentException("未知模块模式")
        if (!BluetoothAdapter.checkBluetoothAddress(id)) throw IllegalArgumentException("蓝牙设备地址无效")
        stopScan("正在连接，扫描已停止")
        closeConnection("cancelled", "连接已被新的请求替换")
        val operation = Connection(nativeSession.begin(generation), generation, mode, reply)
        connection = operation
        val accepted = withPermissions(connectionPermissions(), reply) {
            if (connection !== operation || disposed) return@withPermissions
            try {
                val bluetooth = requireAdapter(reply) ?: run { closeConnection("bluetooth_unavailable", "蓝牙不可用"); return@withPermissions }
                // Discovery competes with connections; cancel even if it was started by settings.
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || granted(Manifest.permission.BLUETOOTH_SCAN)) {
                    if (bluetooth.isDiscovering) bluetooth.cancelDiscovery()
                }
                operation.timeout = Runnable {
                    if (connection === operation) failConnection(operation, "connect_timeout", "连接超时，请确认模块已开机并靠近手机")
                }.also { handler.postDelayed(it, 10_000) }
                val gatt = bluetooth.getRemoteDevice(id).connectGatt(activity, false, callback(operation), BluetoothDevice.TRANSPORT_LE)
                if (gatt == null) { failConnection(operation, "connect_failed", "无法创建 BLE 连接，请重试"); return@withPermissions }
                operation.gatt = gatt
                if (!nativeSession.attach(operation.token, gatt)) { gatt.close(); return@withPermissions }
            } catch (e: SecurityException) {
                failConnection(operation, "permission_denied", "蓝牙连接权限不足，请进入应用设置授权")
            } catch (e: Exception) {
                failConnection(operation, "connect_failed", "连接失败，请确认设备支持所选 BLE 模式")
            }
        }
        if (!accepted && connection === operation) closeConnection("cancelled", "连接请求未能开始")
    }

    private fun current(operation: Connection, gatt: BluetoothGatt): Boolean =
        !disposed && connection === operation && operation.gatt === gatt && nativeSession.matches(operation.token, gatt)

    private fun callback(operation: Connection) = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            handler.post {
                if (!current(operation, gatt)) { runCatching { gatt.close() }; return@post }
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    failConnection(operation, "connect_failed", "BLE 连接失败（$status），请重新连接")
                } else if (newState == BluetoothProfile.STATE_CONNECTED) {
                    try {
                        if (!gatt.discoverServices()) failConnection(operation, "service_discovery_failed", "无法开始服务发现，请重新连接")
                    } catch (e: Exception) { failConnection(operation, "service_discovery_failed", "服务发现失败，请检查蓝牙权限") }
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    closeConnection("disconnected", "设备连接已断开，请重新连接")
                }
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            handler.post {
                if (!current(operation, gatt) || operation.ready) return@post
                if (status != BluetoothGatt.GATT_SUCCESS) { failConnection(operation, "service_discovery_failed", "服务发现失败（$status）"); return@post }
                discoverProfile(operation, gatt)
            }
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            handler.post {
                if (!current(operation, gatt) || operation.descriptor !== descriptor) return@post
                operation.descriptor = null
                if (status != BluetoothGatt.GATT_SUCCESS) failConnection(operation, "notification_failed", "通知订阅失败（$status），请重新连接")
                else nextDescriptor(operation, gatt)
            }
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            handler.post {
                if (!current(operation, gatt)) return@post
                val pending = operation.write ?: return@post
                if (pending.characteristic !== characteristic) return@post
                operation.write = null
                pending.timeout?.let(handler::removeCallbacks)
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    pending.reply.error("write_failed", "BLE 写入失败（$status），请重新连接")
                    failConnection(operation, "write_failed", "BLE 写入失败（$status），连接已关闭")
                } else pending.reply.success()
            }
        }

        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            val bytes = characteristic.value?.clone() ?: return
            received(operation, gatt, characteristic, bytes)
        }

        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            received(operation, gatt, characteristic, value.clone())
        }

        override fun onServiceChanged(gatt: BluetoothGatt) {
            handler.post { if (current(operation, gatt)) failConnection(operation, "services_changed", "设备服务已变更，请重新连接") }
        }
    }

    private fun received(operation: Connection, gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, bytes: ByteArray) {
        handler.post {
            if (current(operation, gatt) && operation.ready && operation.rx === characteristic)
                emit(mapOf("type" to "received", "generation" to operation.generation, "bytes" to bytes))
        }
    }

    private fun discoverProfile(operation: Connection, gatt: BluetoothGatt) {
        try {
            val uart = operation.mode == "uart"
            val service = gatt.getService(uuid(if (uart) 0xffe0 else 0xfff0))
            val tx = service?.getCharacteristic(uuid(if (uart) 0xffe1 else 0xfff2))
            val rx = service?.getCharacteristic(uuid(if (uart) 0xffe1 else 0xfff1))
            if (tx == null || tx.properties and (BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) == 0) {
                failConnection(operation, "profile_not_supported", "未找到可写特征，请核对 ${if (uart) "FFE0 / FFE1" else "FFF0 / FFF2"} 模式")
                return
            }
            operation.tx = tx
            operation.rx = rx
            runCatching { gatt.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH) }
            val notify = rx != null && rx.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0
            val indicate = rx != null && rx.properties and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0
            if (rx != null && (notify || indicate)) {
                val descriptor = rx.getDescriptor(uuid(0x2902))
                if (descriptor == null || !gatt.setCharacteristicNotification(rx, true)) {
                    failConnection(operation, "notification_failed", "模块声明通知能力但无法订阅，请重新连接")
                    return
                }
                descriptor.value = if (notify) BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE else BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
                operation.descriptors.add(descriptor)
            }
            nextDescriptor(operation, gatt)
        } catch (e: Exception) { failConnection(operation, "profile_not_supported", "无法设置 BLE 服务，请检查模块模式与蓝牙权限") }
    }

    /** Only one GATT descriptor is submitted; motion writes are blocked until this drains. */
    private fun nextDescriptor(operation: Connection, gatt: BluetoothGatt) {
        if (!current(operation, gatt) || operation.descriptor != null) return
        val descriptor = operation.descriptors.pollFirst()
        if (descriptor == null) {
            operation.timeout?.let(handler::removeCallbacks)
            operation.timeout = null
            operation.ready = true
            operation.reply.success()
            return
        }
        operation.descriptor = descriptor
        try {
            val submitted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
                gatt.writeDescriptor(descriptor, descriptor.value) == BluetoothStatusCodes.SUCCESS
            else gatt.writeDescriptor(descriptor)
            if (!submitted) failConnection(operation, "notification_failed", "通知订阅请求未能提交，请重新连接")
        } catch (e: Exception) { failConnection(operation, "notification_failed", "通知订阅失败，请检查蓝牙权限") }
    }

    private fun write(bytes: ByteArray, generation: Int, reply: Reply) {
        val operation = connection
        val gatt = operation?.gatt
        val tx = operation?.tx
        if (!foreground) { reply.error("background", "应用已退到后台，无法发送控制指令"); return }
        if (operation == null || gatt == null || tx == null || !current(operation, gatt) || !operation.ready || generation != operation.generation) {
            reply.error("not_ready", "蓝牙连接尚未就绪或连接代次已失效")
            return
        }
        if (bytes.size != 20) { reply.error("invalid_argument", "控制帧必须为 20 字节"); return }
        if (operation.write != null || operation.descriptor != null) { reply.error("write_busy", "上一条 BLE 写入尚未完成，请稍后重试"); return }
        val withoutResponse = tx.properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0
        val writeType = if (withoutResponse) BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE else BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        val pending = Write(tx, reply)
        operation.write = pending
        pending.timeout = Runnable {
            if (current(operation, gatt) && operation.write === pending) {
                pending.reply.error("write_timeout", "BLE 写入超时，连接已关闭，请重新连接")
                // Closing the GATT makes a late completion unable to match a later write.
                failConnection(operation, "write_timeout", "BLE 写入超时，连接已关闭，请重新连接")
            }
        }.also { handler.postDelayed(it, 1_000) }
        try {
            val submitted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
                gatt.writeCharacteristic(tx, bytes.clone(), writeType) == BluetoothStatusCodes.SUCCESS
            else {
                tx.writeType = writeType
                tx.value = bytes.clone()
                gatt.writeCharacteristic(tx)
            }
            if (!submitted) {
                pending.reply.error("write_failed", "BLE 写入请求未能提交，请重新连接")
                failConnection(operation, "write_failed", "BLE 写入请求未能提交，连接已关闭")
            } else operation.lastFrame = bytes.clone()
            // Both write types complete at Android's local callback. For no-response this
            // is still not a peripheral/MCU acknowledgement; it provides native flow control.
        } catch (e: SecurityException) {
            pending.reply.error("permission_denied", "蓝牙连接权限已撤销")
            failConnection(operation, "permission_denied", "蓝牙连接权限已撤销，连接已关闭")
        } catch (e: Exception) {
            pending.reply.error("write_failed", "BLE 写入失败，请重新连接")
            failConnection(operation, "write_failed", "BLE 写入失败，连接已关闭")
        }
    }

    private fun failConnection(operation: Connection, code: String, message: String) {
        if (connection !== operation) return
        error(operation.generation, code, message)
        closeConnection(code, message)
    }

    /** A last zero-output submission is best effort; teardown never waits for an ACK. */
    private fun tryDisarm(operation: Connection) {
        val gatt = operation.gatt ?: return
        val tx = operation.tx ?: return
        val previous = operation.lastFrame ?: return
        if (!operation.ready || operation.write != null || operation.descriptor != null || !current(operation, gatt)) return
        if (previous.size != 20 || previous[0] != 0xa5.toByte() || previous[1] != 0x5a.toByte() || previous[2] != 1.toByte()) return
        val bytes = ByteArray(20)
        bytes[0] = 0xa5.toByte(); bytes[1] = 0x5a; bytes[2] = 1
        bytes[3] = ((previous[3].toInt() and 0xff) + 1).toByte()
        var crc = 0xffff
        for (index in 2..17) {
            crc = crc xor ((bytes[index].toInt() and 0xff) shl 8)
            repeat(8) { crc = (if (crc and 0x8000 != 0) (crc shl 1) xor 0x1021 else crc shl 1) and 0xffff }
        }
        bytes[18] = crc.toByte(); bytes[19] = (crc shr 8).toByte()
        val type = if (tx.properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0)
            BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE else BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) gatt.writeCharacteristic(tx, bytes, type)
            else { tx.writeType = type; tx.value = bytes; gatt.writeCharacteristic(tx) }
        }
    }

    private fun closeConnection(code: String, message: String, disarm: Boolean = false) {
        val operation = connection ?: return
        if (disarm) tryDisarm(operation)
        connection = null
        nativeSession.invalidate()
        operation.ready = false
        operation.timeout?.let(handler::removeCallbacks)
        operation.reply.error(code, message)
        operation.write?.let { it.timeout?.let(handler::removeCallbacks); it.reply.error(code, message) }
        operation.write = null
        operation.descriptor = null
        operation.descriptors.clear()
        operation.tx = null
        operation.rx = null
        operation.lastFrame = null
        if (permission?.reply === operation.reply) cancelPermission(code, message)
        operation.gatt?.let {
            runCatching { it.disconnect() }
            runCatching { it.close() }
        }
        operation.gatt = null
        emit(mapOf("type" to "disconnected", "generation" to operation.generation, "message" to message))
    }

    private fun registerReceiver(receiver: BroadcastReceiver, filter: IntentFilter) {
        // Bluetooth broadcasts originate from a privileged process outside our UID.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) activity.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        else activity.registerReceiver(receiver, filter)
    }

    private fun setKeepAwake(enabled: Boolean) {
        if (enabled) activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    private fun openSettings() {
        val intent = Intent(settingsAction)
        if (settingsAction == Settings.ACTION_APPLICATION_DETAILS_SETTINGS) intent.data = Uri.parse("package:${activity.packageName}")
        try { activity.startActivity(intent) }
        catch (e: ActivityNotFoundException) { activity.startActivity(Intent(Settings.ACTION_SETTINGS)) }
    }

    fun onResume() {
        if (disposed) return
        foreground = true
        permission?.takeIf { it.granted && !it.cancelled }?.let {
            permission = null
            it.action()
        }
    }

    fun onPause() {
        if (disposed) return
        foreground = false
        setKeepAwake(false)
        val awaitingPermission = permission?.takeIf { !it.cancelled && !it.granted }
        // A permission dialog pauses the Activity. Preserve its pending request without
        // allowing an existing GATT or scan to keep running while backgrounded.
        if (awaitingPermission?.reply !== connection?.reply || connection?.gatt != null)
            closeConnection("background", "应用退到后台，连接已断开", disarm = true)
        if (awaitingPermission?.reply !== scan?.reply) stopScan("应用退到后台，扫描已停止")
    }

    fun onStop() {
        if (disposed) return
        stopScan("应用退到后台，扫描已停止")
        closeConnection("background", "应用退到后台，连接已断开", disarm = true)
        cancelPermission("background", "应用退到后台，操作已取消")
    }

    fun dispose() {
        if (disposed) return
        stopScan("蓝牙服务已释放")
        closeConnection("disposed", "蓝牙服务已释放，连接已断开")
        cancelPermission("disposed", "蓝牙服务已释放")
        setKeepAwake(false)
        if (adapterReceiverRegistered) runCatching { activity.unregisterReceiver(adapterReceiver) }
        adapterReceiverRegistered = false
        disposed = true
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink = null
        handler.removeCallbacksAndMessages(null)
    }

    private fun uuid(short: Int): UUID = UUID.fromString("0000${short.toString(16).padStart(4, '0')}-0000-1000-8000-00805f9b34fb")
}
