package com.example.ble

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var bleBridge: BleBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bleBridge?.dispose()
        bleBridge = BleBridge(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onResume() {
        super.onResume()
        bleBridge?.onResume()
    }

    override fun onPause() {
        bleBridge?.onPause()
        super.onPause()
    }

    override fun onStop() {
        bleBridge?.onStop()
        super.onStop()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        bleBridge?.onRequestPermissionsResult(requestCode)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        bleBridge?.dispose()
        bleBridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        bleBridge?.dispose()
        bleBridge = null
        super.onDestroy()
    }
}
