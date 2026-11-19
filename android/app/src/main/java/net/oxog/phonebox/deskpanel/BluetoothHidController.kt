package net.oxog.phonebox.deskpanel

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothHidDevice
import android.bluetooth.BluetoothHidDeviceAppQosSettings
import android.bluetooth.BluetoothHidDeviceAppSdpSettings
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors

/**
 * Native Bluetooth HID Device controller (Consumer Control + Standard Keyboard).
 * Turns the Android smartphone into a standard driverless Bluetooth media remote & macropad for PC.
 */
@SuppressLint("MissingPermission")
class BluetoothHidController(
    private val activity: Activity,
    private val onStateChanged: () -> Unit
) {
    private val prefs = activity.getSharedPreferences("pc_companion_bt", Context.MODE_PRIVATE)
    private val executor = Executors.newSingleThreadScheduledExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    private val btManager = activity.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager?
    private val adapter: BluetoothAdapter? get() = btManager?.adapter

    @Volatile private var hidDevice: BluetoothHidDevice? = null
    @Volatile private var appRegistered: Boolean = false
    @Volatile private var connectedDevice: BluetoothDevice? = null
    @Volatile private var connectionState: Int = BluetoothProfile.STATE_DISCONNECTED

    private val sdpSettings = BluetoothHidDeviceAppSdpSettings(
        "PC-Companion",
        "PhoneBox Bluetooth HID Desk Panel",
        "PC-Companion",
        BluetoothHidDevice.SUBCLASS1_COMBO,
        HID_REPORT_DESCRIPTOR
    )

    private val qosOut = BluetoothHidDeviceAppQosSettings(
        BluetoothHidDeviceAppQosSettings.SERVICE_BEST_EFFORT,
        800, 9, 0, 11250, BluetoothHidDeviceAppQosSettings.MAX
    )

    private val hidCallback = object : BluetoothHidDevice.Callback() {
        override fun onAppStatusChanged(pluggedDevice: BluetoothDevice?, registered: Boolean) {
            appRegistered = registered
            Log.i(TAG, "onAppStatusChanged: registered=$registered plugged=${pluggedDevice?.address}")
            if (registered) {
                val lastAddr = prefs.getString(KEY_LAST_HOST, null)
                val target = adapter?.bondedDevices?.firstOrNull { it.address == lastAddr } ?: pluggedDevice
                if (target != null && connectedDevice == null) {
                    try { hidDevice?.connect(target) } catch (_: Exception) {}
                }
            } else {
                connectedDevice = null
                connectionState = BluetoothProfile.STATE_DISCONNECTED
            }
            notifyUi()
        }

        override fun onConnectionStateChanged(device: BluetoothDevice?, state: Int) {
            Log.i(TAG, "onConnectionStateChanged: device=${device?.address} state=$state")
            connectionState = state
            when (state) {
                BluetoothProfile.STATE_CONNECTED -> {
                    connectedDevice = device
                    if (device?.address != null) {
                        prefs.edit().putString(KEY_LAST_HOST, device.address).apply()
                    }
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    if (connectedDevice?.address == device?.address) {
                        connectedDevice = null
                    }
                }
            }
            notifyUi()
        }
    }

    private val profileListener = object : BluetoothProfile.ServiceListener {
        override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
            if (profile != BluetoothProfile.HID_DEVICE) return
            val hid = proxy as BluetoothHidDevice
            hidDevice = hid
            try {
                hid.registerApp(sdpSettings, null, qosOut, executor, hidCallback)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to register HID app", e)
            }
            notifyUi()
        }

        override fun onServiceDisconnected(profile: Int) {
            if (profile != BluetoothProfile.HID_DEVICE) return
            hidDevice = null
            appRegistered = false
            connectedDevice = null
            connectionState = BluetoothProfile.STATE_DISCONNECTED
            notifyUi()
        }
    }

    fun hasPermissions(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val connect = activity.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
            val advertise = activity.checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) == PackageManager.PERMISSION_GRANTED
            return connect && advertise
        }
        return true
    }

    fun requestPermissions() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            activity.requestPermissions(
                arrayOf(
                    Manifest.permission.BLUETOOTH_CONNECT,
                    Manifest.permission.BLUETOOTH_ADVERTISE
                ),
                PERMISSION_REQUEST_CODE
            )
        }
    }

    fun start() {
        if (!hasPermissions()) {
            notifyUi()
            return
        }
        val bt = adapter ?: return
        if (!bt.isEnabled) {
            notifyUi()
            return
        }
        if (hidDevice == null) {
            bt.getProfileProxy(activity, profileListener, BluetoothProfile.HID_DEVICE)
        } else if (!appRegistered) {
            try {
                hidDevice?.registerApp(sdpSettings, null, qosOut, executor, hidCallback)
            } catch (_: Exception) {}
        }
        notifyUi()
    }

    fun stop() {
        val hid = hidDevice ?: return
        try {
            if (appRegistered) hid.unregisterApp()
        } catch (_: Exception) {}
        try {
            adapter?.closeProfileProxy(BluetoothProfile.HID_DEVICE, hid)
        } catch (_: Exception) {}
        hidDevice = null
        appRegistered = false
        connectedDevice = null
        connectionState = BluetoothProfile.STATE_DISCONNECTED
    }

    fun connect(address: String): Boolean {
        if (!hasPermissions()) return false
        val hid = hidDevice ?: return false
        val dev = adapter?.bondedDevices?.firstOrNull { it.address.equals(address, ignoreCase = true) } ?: return false
        return try {
            prefs.edit().putString(KEY_LAST_HOST, dev.address).apply()
            connectionState = BluetoothProfile.STATE_CONNECTING
            notifyUi()
            hid.connect(dev)
        } catch (e: Exception) {
            Log.e(TAG, "Connect failed", e)
            false
        }
    }

    fun disconnect(): Boolean {
        if (!hasPermissions()) return false
        val hid = hidDevice ?: return false
        val dev = connectedDevice ?: return false
        return try {
            hid.disconnect(dev)
        } catch (_: Exception) {
            false
        }
    }

    fun openBluetoothSettings() {
        try {
            activity.startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS))
        } catch (_: Exception) {}
    }

    /**
     * Sends a 16-bit Consumer Control usage code (e.g. 0xCD Play/Pause, 0xE9 Vol+, 0xEA Vol-, 0xE2 Mute, 0xB5 Next, 0xB6 Prev).
     */
    fun sendConsumerControl(usageCode: Int): Boolean {
        if (!hasPermissions()) return false
        val hid = hidDevice ?: return false
        val dev = connectedDevice ?: return false
        return try {
            val press = byteArrayOf(
                (usageCode and 0xFF).toByte(),
                ((usageCode shr 8) and 0xFF).toByte()
            )
            val release = byteArrayOf(0, 0)
            val sent = hid.sendReport(dev, REPORT_ID_CONSUMER, press)
            executor.execute {
                try { Thread.sleep(25) } catch (_: InterruptedException) {}
                try { hid.sendReport(dev, REPORT_ID_CONSUMER, release) } catch (_: Exception) {}
            }
            sent
        } catch (e: Exception) {
            Log.e(TAG, "sendConsumerControl failed", e)
            false
        }
    }

    /**
     * Sends a standard HID keyboard shortcut (modifier mask + HID keycode).
     */
    fun sendKeyboardKey(modifier: Int, keyCode: Int): Boolean {
        if (!hasPermissions()) return false
        val hid = hidDevice ?: return false
        val dev = connectedDevice ?: return false
        return try {
            val press = byteArrayOf(modifier.toByte(), 0, keyCode.toByte(), 0, 0, 0, 0, 0)
            val release = ByteArray(8)
            val sent = hid.sendReport(dev, REPORT_ID_KEYBOARD, press)
            executor.execute {
                try { Thread.sleep(25) } catch (_: InterruptedException) {}
                try { hid.sendReport(dev, REPORT_ID_KEYBOARD, release) } catch (_: Exception) {}
            }
            sent
        } catch (e: Exception) {
            Log.e(TAG, "sendKeyboardKey failed", e)
            false
        }
    }

    fun statusJson(): String {
        val bt = adapter
        val perms = hasPermissions()
        val bondedArr = JSONArray()
        if (bt != null && perms && bt.isEnabled) {
            try {
                for (d in bt.bondedDevices.orEmpty()) {
                    bondedArr.put(
                        JSONObject()
                            .put("name", d.name ?: d.address)
                            .put("address", d.address)
                            .put("connected", d.address == connectedDevice?.address && connectionState == BluetoothProfile.STATE_CONNECTED)
                    )
                }
            } catch (_: Exception) {}
        }
        val stateStr = when (connectionState) {
            BluetoothProfile.STATE_CONNECTED -> "connected"
            BluetoothProfile.STATE_CONNECTING -> "connecting"
            else -> "disconnected"
        }
        return JSONObject()
            .put("supported", bt != null)
            .put("enabled", bt?.isEnabled == true)
            .put("permissionsGranted", perms)
            .put("registered", appRegistered)
            .put("state", stateStr)
            .put("hostName", if (perms) (connectedDevice?.name ?: "") else "")
            .put("hostAddress", connectedDevice?.address ?: "")
            .put("bondedDevices", bondedArr)
            .toString()
    }

    private fun notifyUi() {
        mainHandler.post { onStateChanged() }
    }

    companion object {
        private const val TAG = "PCCompanionHID"
        private const val KEY_LAST_HOST = "last_host_address"
        const val PERMISSION_REQUEST_CODE = 2001
        private const val REPORT_ID_CONSUMER = 1
        private const val REPORT_ID_KEYBOARD = 2

        /**
         * Combined USB/Bluetooth HID Report Descriptor:
         * - Report ID 1: Consumer Control (16-bit usage code for Media & Volume)
         * - Report ID 2: Standard Keyboard (8-byte boot-compatible report)
         */
        private val HID_REPORT_DESCRIPTOR = byteArrayOf(
            // --- Report ID 1: Consumer Control ---
            0x05.toByte(), 0x0C.toByte(),       // Usage Page (Consumer)
            0x09.toByte(), 0x01.toByte(),       // Usage (Consumer Control)
            0xA1.toByte(), 0x01.toByte(),       // Collection (Application)
            0x85.toByte(), 0x01.toByte(),       //   Report ID (1)
            0x15.toByte(), 0x00.toByte(),       //   Logical Minimum (0)
            0x26.toByte(), 0xFF.toByte(), 0x03.toByte(), // Logical Maximum (1023)
            0x19.toByte(), 0x00.toByte(),       //   Usage Minimum (0)
            0x2A.toByte(), 0xFF.toByte(), 0x03.toByte(), // Usage Maximum (1023)
            0x75.toByte(), 0x10.toByte(),       //   Report Size (16)
            0x95.toByte(), 0x01.toByte(),       //   Report Count (1)
            0x81.toByte(), 0x00.toByte(),       //   Input (Data, Array, Absolute)
            0xC0.toByte(),                      // End Collection

            // --- Report ID 2: Standard Keyboard ---
            0x05.toByte(), 0x01.toByte(),       // Usage Page (Generic Desktop)
            0x09.toByte(), 0x06.toByte(),       // Usage (Keyboard)
            0xA1.toByte(), 0x01.toByte(),       // Collection (Application)
            0x85.toByte(), 0x02.toByte(),       //   Report ID (2)
            0x05.toByte(), 0x07.toByte(),       //   Usage Page (Key Codes)
            0x19.toByte(), 0xE0.toByte(),       //   Usage Minimum (224)
            0x29.toByte(), 0xE7.toByte(),       //   Usage Maximum (231)
            0x15.toByte(), 0x00.toByte(),       //   Logical Minimum (0)
            0x25.toByte(), 0x01.toByte(),       //   Logical Maximum (1)
            0x75.toByte(), 0x01.toByte(),       //   Report Size (1)
            0x95.toByte(), 0x08.toByte(),       //   Report Count (8)
            0x81.toByte(), 0x02.toByte(),       //   Input (Data, Variable, Absolute) - Modifier byte
            0x95.toByte(), 0x01.toByte(),       //   Report Count (1)
            0x75.toByte(), 0x08.toByte(),       //   Report Size (8)
            0x81.toByte(), 0x01.toByte(),       //   Input (Constant) - Reserved byte
            0x95.toByte(), 0x06.toByte(),       //   Report Count (6)
            0x75.toByte(), 0x08.toByte(),       //   Report Size (8)
            0x15.toByte(), 0x00.toByte(),       //   Logical Minimum (0)
            0x25.toByte(), 0x65.toByte(),       //   Logical Maximum (101)
            0x05.toByte(), 0x07.toByte(),       //   Usage Page (Key Codes)
            0x19.toByte(), 0x00.toByte(),       //   Usage Minimum (0)
            0x29.toByte(), 0x65.toByte(),       //   Usage Maximum (101)
            0x81.toByte(), 0x00.toByte(),       //   Input (Data, Array) - Keycodes (6 bytes)
            0xC0.toByte()                       // End Collection
        )
    }
}
