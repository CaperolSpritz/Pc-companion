package net.oxog.phonebox.deskpanel

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothHidDevice
import android.bluetooth.BluetoothHidDeviceAppSdpSettings
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
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
 * Native Bluetooth HID Device controller (Keyboard + Consumer Control).
 * Configured for maximum compatibility with Windows 10/11 Intel Wireless Bluetooth stack:
 * - Uses SUBCLASS1_KEYBOARD (0x40) so Windows enumerates BTHENUM\{00001124-...} hidbth driver.
 * - Passes null for inQos/outQos so Windows L2CAP does not reject custom QoS negotiation.
 * - Supports making the phone discoverable directly from the app while SDP record 0x1124 is live.
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
    @Volatile private var lastNote: String = "In attesa di avvio servizio HID..."
    private var receiverRegistered = false

    private val sdpSettings = BluetoothHidDeviceAppSdpSettings(
        "PC-Companion Keyboard",
        "Bluetooth HID Media & Macro Pad",
        "PC-Companion",
        BluetoothHidDevice.SUBCLASS1_KEYBOARD,
        HID_REPORT_DESCRIPTOR
    )

    private val bondReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                BluetoothDevice.ACTION_BOND_STATE_CHANGED -> {
                    val dev = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                    }
                    val bondState = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR)
                    when (bondState) {
                        BluetoothDevice.BOND_BONDING -> lastNote = "Accoppiamento in corso con ${dev?.name ?: dev?.address}..."
                        BluetoothDevice.BOND_BONDED -> {
                            lastNote = "Accoppiato con ${dev?.name ?: dev?.address}. Connessione HID..."
                            if (dev != null && appRegistered) {
                                mainHandler.postDelayed({ connect(dev.address) }, 600)
                            }
                        }
                        BluetoothDevice.BOND_NONE -> lastNote = "Dispositivo disaccoppiato o pairing annullato"
                    }
                    notifyUi()
                }
                BluetoothAdapter.ACTION_SCAN_MODE_CHANGED -> {
                    val mode = intent.getIntExtra(BluetoothAdapter.EXTRA_SCAN_MODE, BluetoothAdapter.SCAN_MODE_NONE)
                    if (mode == BluetoothAdapter.SCAN_MODE_CONNECTABLE_DISCOVERABLE) {
                        lastNote = "Telefono VISIBILE al PC come 'PC-Companion'! Ora cercalo dal Bluetooth di Windows."
                    }
                    notifyUi()
                }
            }
        }
    }

    private val hidCallback = object : BluetoothHidDevice.Callback() {
        override fun onAppStatusChanged(pluggedDevice: BluetoothDevice?, registered: Boolean) {
            appRegistered = registered
            Log.i(TAG, "onAppStatusChanged: registered=$registered plugged=${pluggedDevice?.address}")
            if (registered) {
                lastNote = "Servizio Tastiera HID (0x1124) attivo e pronto"
                val lastAddr = prefs.getString(KEY_LAST_HOST, null)
                val target = adapter?.bondedDevices?.firstOrNull { it.address == lastAddr } ?: pluggedDevice
                if (target != null && connectedDevice == null) {
                    try { hidDevice?.connect(target) } catch (_: Exception) {}
                }
            } else {
                lastNote = "Servizio HID non registrato (chiudi altre app HID o riavvia il Bluetooth)"
                connectedDevice = null
                connectionState = BluetoothProfile.STATE_DISCONNECTED
            }
            notifyUi()
        }

        override fun onConnectionStateChanged(device: BluetoothDevice?, state: Int) {
            Log.i(TAG, "onConnectionStateChanged: device=${device?.address} state=$state")
            connectionState = state
            val devName = device?.name ?: device?.address ?: "PC"
            when (state) {
                BluetoothProfile.STATE_CONNECTED -> {
                    connectedDevice = device
                    lastNote = "Connesso via HID a $devName"
                    if (device?.address != null) {
                        prefs.edit().putString(KEY_LAST_HOST, device.address).apply()
                    }
                }
                BluetoothProfile.STATE_CONNECTING -> {
                    lastNote = "Connessione HID a $devName in corso..."
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    if (connectedDevice?.address == device?.address) {
                        connectedDevice = null
                    }
                    lastNote = "Disconnesso da $devName (se Windows era già associato prima dell'app, rimuovi e riassocia il Pixel)"
                }
            }
            notifyUi()
        }

        override fun onGetReport(device: BluetoothDevice?, type: Byte, id: Byte, bufferSize: Int) {
            val hid = hidDevice ?: return
            if (device == null) return
            val empty = if (id.toInt() == REPORT_ID_KEYBOARD) ByteArray(8) else ByteArray(2)
            hid.replyReport(device, type, id, empty)
        }

        override fun onSetProtocol(device: BluetoothDevice?, protocol: Byte) {
            Log.i(TAG, "onSetProtocol: protocol=$protocol")
        }
    }

    private val profileListener = object : BluetoothProfile.ServiceListener {
        override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
            if (profile != BluetoothProfile.HID_DEVICE) return
            val hid = proxy as BluetoothHidDevice
            hidDevice = hid
            registerHidApp(hid)
        }

        override fun onServiceDisconnected(profile: Int) {
            if (profile != BluetoothProfile.HID_DEVICE) return
            hidDevice = null
            appRegistered = false
            connectedDevice = null
            connectionState = BluetoothProfile.STATE_DISCONNECTED
            lastNote = "Profilo HID disconnesso dal sistema"
            notifyUi()
        }
    }

    private fun registerHidApp(hid: BluetoothHidDevice) {
        try {
            // Pass null for inQos and outQos for maximum compatibility with Windows 10/11 Bluetooth stack
            val ok = hid.registerApp(sdpSettings, null, null, executor, hidCallback)
            if (!ok) {
                lastNote = "registerApp ha restituito false (riprovo tra 1s...)"
                mainHandler.postDelayed({
                    try { hid.registerApp(sdpSettings, null, null, executor, hidCallback) } catch (_: Exception) {}
                }, 1000)
            }
        } catch (e: Exception) {
            lastNote = "Errore registrazione HID: ${e.message}"
            Log.e(TAG, "Failed to register HID app", e)
        }
        notifyUi()
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
            val perms = mutableListOf(
                Manifest.permission.BLUETOOTH_CONNECT,
                Manifest.permission.BLUETOOTH_ADVERTISE
            )
            if (activity.checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) != PackageManager.PERMISSION_GRANTED) {
                perms.add(Manifest.permission.BLUETOOTH_SCAN)
            }
            activity.requestPermissions(perms.toTypedArray(), PERMISSION_REQUEST_CODE)
        }
    }

    fun start() {
        if (!receiverRegistered) {
            val filter = IntentFilter().apply {
                addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
                addAction(BluetoothAdapter.ACTION_SCAN_MODE_CHANGED)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                activity.registerReceiver(bondReceiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                activity.registerReceiver(bondReceiver, filter)
            }
            receiverRegistered = true
        }

        if (!hasPermissions()) {
            lastNote = "Permessi Bluetooth richiesti (Android 12+)"
            notifyUi()
            return
        }
        val bt = adapter ?: return
        if (!bt.isEnabled) {
            lastNote = "Bluetooth spento sul telefono"
            notifyUi()
            return
        }
        try {
            if (bt.name != "PC-Companion") {
                bt.name = "PC-Companion"
            }
        } catch (e: Exception) {
            Log.w(TAG, "Unable to set adapter name: ${e.message}")
        }
        if (hidDevice == null) {
            lastNote = "Apertura profilo BluetoothHidDevice..."
            bt.getProfileProxy(activity, profileListener, BluetoothProfile.HID_DEVICE)
        } else if (!appRegistered) {
            hidDevice?.let { registerHidApp(it) }
        }
        notifyUi()
    }

    fun stop() {
        if (receiverRegistered) {
            try { activity.unregisterReceiver(bondReceiver) } catch (_: Exception) {}
            receiverRegistered = false
        }
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

    /**
     * Makes the phone discoverable for 300 seconds while keeping the app and its SDP 0x1124 HID record in the foreground.
     */
    fun makeDiscoverable() {
        if (!hasPermissions()) {
            requestPermissions()
            return
        }
        try {
            adapter?.let { bt ->
                if (bt.name != "PC-Companion") bt.name = "PC-Companion"
            }
        } catch (_: Exception) {}
        if (!appRegistered) {
            start()
        }
        try {
            val intent = Intent(BluetoothAdapter.ACTION_REQUEST_DISCOVERABLE).apply {
                putExtra(BluetoothAdapter.EXTRA_DISCOVERABLE_DURATION, 300)
            }
            activity.startActivityForResult(intent, DISCOVERABLE_REQUEST_CODE)
            lastNote = "Conferma il popup per rendere il Pixel visibile a Windows per 5 minuti"
            notifyUi()
        } catch (e: Exception) {
            lastNote = "Impossibile attivare visibilità: ${e.message}"
            notifyUi()
        }
    }

    fun connect(address: String): Boolean {
        if (!hasPermissions()) return false
        val hid = hidDevice ?: return false
        if (!appRegistered) {
            lastNote = "Attendi: servizio HID non ancora registrato"
            notifyUi()
            return false
        }
        val dev = adapter?.bondedDevices?.firstOrNull { it.address.equals(address, ignoreCase = true) } ?: return false
        return try {
            prefs.edit().putString(KEY_LAST_HOST, dev.address).apply()
            connectionState = BluetoothProfile.STATE_CONNECTING
            lastNote = "Richiesta connessione HID a ${dev.name ?: dev.address}..."
            notifyUi()
            val ok = hid.connect(dev)
            if (!ok) {
                connectionState = BluetoothProfile.STATE_DISCONNECTED
                lastNote = "Connessione rifiutata: rimuovi il Pixel dal Bluetooth di Windows e riassocialo usando 'Rendi Visibile al PC'"
                notifyUi()
            }
            ok
        } catch (e: Exception) {
            Log.e(TAG, "Connect failed", e)
            lastNote = "Errore connessione: ${e.message}"
            notifyUi()
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
     * Sends a 16-bit Consumer Control usage code on Report ID 2.
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
                try { Thread.sleep(30) } catch (_: InterruptedException) {}
                try { hid.sendReport(dev, REPORT_ID_CONSUMER, release) } catch (_: Exception) {}
            }
            sent
        } catch (e: Exception) {
            Log.e(TAG, "sendConsumerControl failed", e)
            false
        }
    }

    /**
     * Sends a standard HID keyboard shortcut on Report ID 1.
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
                try { Thread.sleep(30) } catch (_: InterruptedException) {}
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
        val discoverable = try {
            perms && bt?.scanMode == BluetoothAdapter.SCAN_MODE_CONNECTABLE_DISCOVERABLE
        } catch (_: Exception) { false }

        val localName = try {
            if (perms) (bt?.name ?: "PC-Companion") else "PC-Companion"
        } catch (_: Exception) { "PC-Companion" }

        return JSONObject()
            .put("supported", bt != null)
            .put("enabled", bt?.isEnabled == true)
            .put("permissionsGranted", perms)
            .put("registered", appRegistered)
            .put("discoverable", discoverable)
            .put("localName", localName)
            .put("state", stateStr)
            .put("note", lastNote)
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
        const val DISCOVERABLE_REQUEST_CODE = 2002
        private const val REPORT_ID_KEYBOARD = 1
        private const val REPORT_ID_CONSUMER = 2

        /**
         * Windows-friendly Composite HID Report Descriptor:
         * - Report ID 1: Standard 8-byte Keyboard
         * - Report ID 2: 16-bit Consumer Control (Media & Volume keys)
         */
        private val HID_REPORT_DESCRIPTOR = byteArrayOf(
            // --- Report ID 1: Standard Keyboard ---
            0x05.toByte(), 0x01.toByte(),       // Usage Page (Generic Desktop)
            0x09.toByte(), 0x06.toByte(),       // Usage (Keyboard)
            0xA1.toByte(), 0x01.toByte(),       // Collection (Application)
            0x85.toByte(), 0x01.toByte(),       //   Report ID (1)
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
            0xC0.toByte(),                      // End Collection

            // --- Report ID 2: Consumer Control (Media & Volume) ---
            0x05.toByte(), 0x0C.toByte(),       // Usage Page (Consumer)
            0x09.toByte(), 0x01.toByte(),       // Usage (Consumer Control)
            0xA1.toByte(), 0x01.toByte(),       // Collection (Application)
            0x85.toByte(), 0x02.toByte(),       //   Report ID (2)
            0x15.toByte(), 0x00.toByte(),       //   Logical Minimum (0)
            0x26.toByte(), 0xFF.toByte(), 0x03.toByte(), // Logical Maximum (1023)
            0x19.toByte(), 0x00.toByte(),       //   Usage Minimum (0)
            0x2A.toByte(), 0xFF.toByte(), 0x03.toByte(), // Usage Maximum (1023)
            0x75.toByte(), 0x10.toByte(),       //   Report Size (16)
            0x95.toByte(), 0x01.toByte(),       //   Report Count (1)
            0x81.toByte(), 0x00.toByte(),       //   Input (Data, Array, Absolute)
            0xC0.toByte()                       // End Collection
        )
    }
}
