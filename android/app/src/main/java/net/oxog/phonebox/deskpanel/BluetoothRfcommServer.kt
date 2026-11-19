package net.oxog.phonebox.deskpanel

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.io.PrintWriter
import java.nio.charset.StandardCharsets
import java.util.UUID
import java.util.concurrent.Executors

/**
 * Bidirectional Bluetooth RFCOMM Server running on the Pixel 6a.
 * Allows the lightweight Windows PowerShell script (PC-Companion-Bridge.ps1) to connect over Bluetooth
 * (AF_BTH / BTPROTO_RFCOMM) without needing ADB, USB cables, Wi-Fi ports, or Windows Firewall rules.
 */
@SuppressLint("MissingPermission")
class BluetoothRfcommServer(
    private val context: Context,
    private val hasPermissions: () -> Boolean,
    private val onBridgeMessage: (String) -> Unit,
    private val onConnectionChanged: (Boolean, String) -> Unit
) {
    private val btManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager?
    private val adapter: BluetoothAdapter? get() = btManager?.adapter
    private val mainHandler = Handler(Looper.getMainLooper())
    private val writeExecutor = Executors.newSingleThreadExecutor()

    @Volatile private var running = false
    @Volatile private var serverSocket: BluetoothServerSocket? = null
    @Volatile private var activeSocket: BluetoothSocket? = null
    @Volatile private var writer: PrintWriter? = null
    private var acceptThread: Thread? = null

    fun start() {
        if (running) return
        if (!hasPermissions()) return
        val bt = adapter ?: return
        if (!bt.isEnabled) return

        running = true
        acceptThread = Thread({
            while (running) {
                try {
                    if (!hasPermissions() || bt.isEnabled != true) {
                        Thread.sleep(2000)
                        continue
                    }
                    val srv = bt.listenUsingInsecureRfcommWithServiceRecord(SERVICE_NAME, SERVICE_UUID)
                    serverSocket = srv
                    Log.i(TAG, "RFCOMM Bridge listening on UUID $SERVICE_UUID")
                    val sock = srv.accept()
                    try { srv.close() } catch (_: Exception) {}
                    serverSocket = null
                    if (sock != null) {
                        handleClient(sock)
                    }
                } catch (e: Exception) {
                    if (running) {
                        Log.w(TAG, "RFCOMM accept loop pause: ${e.message}")
                        try { Thread.sleep(1500) } catch (_: InterruptedException) {}
                    }
                }
            }
        }, "PCCompanion-RFCOMM-Accept").apply { isDaemon = true; start() }
    }

    private fun handleClient(sock: BluetoothSocket) {
        try { activeSocket?.close() } catch (_: Exception) {}
        activeSocket = sock
        val remoteName = try { sock.remoteDevice?.name ?: sock.remoteDevice?.address ?: "PC" } catch (_: Exception) { "PC" }
        Log.i(TAG, "RFCOMM Bridge connected from $remoteName")
        notifyStatus(true, remoteName)

        try {
            writer = PrintWriter(OutputStreamWriter(sock.outputStream, StandardCharsets.UTF_8), true)
            val reader = BufferedReader(InputStreamReader(sock.inputStream, StandardCharsets.UTF_8))
            while (running && sock.isConnected) {
                val line = reader.readLine() ?: break
                if (line.isNotBlank()) {
                    mainHandler.post { onBridgeMessage(line) }
                }
            }
        } catch (e: Exception) {
            Log.i(TAG, "RFCOMM client disconnected: ${e.message}")
        } finally {
            writer = null
            try { sock.close() } catch (_: Exception) {}
            if (activeSocket === sock) activeSocket = null
            notifyStatus(false, "")
        }
    }

    fun sendCommand(jsonLine: String): Boolean {
        val w = writer ?: return false
        writeExecutor.execute {
            try {
                w.println(jsonLine)
                w.flush()
            } catch (e: Exception) {
                Log.w(TAG, "RFCOMM write failed: ${e.message}")
            }
        }
        return true
    }

    fun isConnected(): Boolean = activeSocket?.isConnected == true

    fun stop() {
        running = false
        writer = null
        try { serverSocket?.close() } catch (_: Exception) {}
        try { activeSocket?.close() } catch (_: Exception) {}
        serverSocket = null
        activeSocket = null
    }

    private fun notifyStatus(connected: Boolean, host: String) {
        mainHandler.post { onConnectionChanged(connected, host) }
    }

    companion object {
        private const val TAG = "PCCompanionRFCOMM"
        private const val SERVICE_NAME = "PCCompanionBridge"
        val SERVICE_UUID: UUID = UUID.fromString("8ce255c0-200a-11e0-ac64-0800200c9a66")
    }
}
