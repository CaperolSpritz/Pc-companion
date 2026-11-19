package net.oxog.phonebox.deskpanel

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import android.util.Log
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.webkit.ConsoleMessage
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.WebViewAssetLoader
import org.json.JSONObject

class MainActivity : Activity(), SensorEventListener {

    private lateinit var web: WebView
    private lateinit var btHid: BluetoothHidController
    private lateinit var rfcommServer: BluetoothRfcommServer
    private val sensors by lazy { getSystemService(Context.SENSOR_SERVICE) as SensorManager? }
    private var lastLux = -1f
    private var lastLuxAt = 0L
    private var near: Boolean? = null

    private val assetLoader by lazy {
        WebViewAssetLoader.Builder()
            .addPathHandler("/assets/", WebViewAssetLoader.AssetsPathHandler(this))
            .build()
    }

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        btHid = BluetoothHidController(this) {
            val status = btHid.statusJson()
            web.evaluateJavascript("window.onBtState && window.onBtState(${JSONObject.quote(status)})", null)
        }

        rfcommServer = BluetoothRfcommServer(
            context = this,
            hasPermissions = { btHid.hasPermissions() },
            onBridgeMessage = { line ->
                web.evaluateJavascript("window.onPcBridgeData && window.onPcBridgeData(${JSONObject.quote(line)})", null)
            },
            onConnectionChanged = { connected, host ->
                web.evaluateJavascript(
                    "window.onPcBridgeStatus && window.onPcBridgeStatus($connected, ${JSONObject.quote(host)})",
                    null
                )
            }
        )

        web = WebView(this)
        web.setBackgroundColor(0xFF000000.toInt())
        setContentView(web)

        with(web.settings) {
            javaScriptEnabled = true
            domStorageEnabled = true
            mediaPlaybackRequiresUserGesture = false
            cacheMode = WebSettings.LOAD_NO_CACHE
            textZoom = 100
        }
        web.isVerticalScrollBarEnabled = false
        web.isHorizontalScrollBarEnabled = false
        web.webChromeClient = object : WebChromeClient() {
            override fun onConsoleMessage(message: ConsoleMessage): Boolean {
                if (message.messageLevel() == ConsoleMessage.MessageLevel.ERROR)
                    Log.e("PCCompanionWeb", "${message.sourceId()}:${message.lineNumber()} ${message.message()}")
                return true
            }
        }
        web.webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                val url = request.url
                val r = assetLoader.shouldInterceptRequest(url)
                if (r != null && url.path?.endsWith(".js") == true) r.mimeType = "text/javascript"
                return r
            }
        }
        web.addJavascriptInterface(Bridge(), "Android")
        WebView.setWebContentsDebuggingEnabled(BuildConfig.DEBUG)

        web.loadUrl("https://$ASSET_HOST/assets/www/index.html")
        hideSystemUi()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemUi()
    }

    @Suppress("DEPRECATION")
    private fun hideSystemUi() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.let {
                it.hide(WindowInsets.Type.systemBars())
                it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_FULLSCREEN
        }
    }

    override fun onResume() {
        super.onResume()
        web.onResume()
        hideSystemUi()
        btHid.start()
        rfcommServer.start()
        sensors?.getDefaultSensor(Sensor.TYPE_LIGHT)?.let {
            sensors?.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL)
        }
        sensors?.getDefaultSensor(Sensor.TYPE_PROXIMITY)?.let {
            sensors?.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL)
        }
    }

    override fun onPause() {
        sensors?.unregisterListener(this)
        web.onPause()
        super.onPause()
    }

    override fun onDestroy() {
        rfcommServer.stop()
        btHid.stop()
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == BluetoothHidController.PERMISSION_REQUEST_CODE) {
            btHid.start()
            rfcommServer.start()
        }
    }

    override fun onSensorChanged(e: SensorEvent) {
        when (e.sensor.type) {
            Sensor.TYPE_LIGHT -> {
                val lux = e.values[0]
                val now = SystemClock.elapsedRealtime()
                val jump = lastLux < 0 || kotlin.math.abs(lux - lastLux) > maxOf(3f, lastLux * 0.15f)
                if (!jump && now - lastLuxAt < 10_000) return
                if (now - lastLuxAt < 700) return
                lastLux = lux
                lastLuxAt = now
                web.evaluateJavascript("window.onAndroidSensor && window.onAndroidSensor('light', $lux)", null)
            }
            Sensor.TYPE_PROXIMITY -> {
                val isNear = e.values[0] < minOf(5f, e.sensor.maximumRange)
                if (isNear == near) return
                near = isNear
                web.evaluateJavascript("window.onAndroidSensor && window.onAndroidSensor('proximity', $isNear)", null)
            }
        }
    }

    override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) {}

    inner class Bridge {
        @JavascriptInterface
        fun haptic() {
            val v = getSystemService(Context.VIBRATOR_SERVICE) as Vibrator? ?: return
            if (!v.hasVibrator()) return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                v.vibrate(VibrationEffect.createOneShot(14, VibrationEffect.DEFAULT_AMPLITUDE))
            } else {
                @Suppress("DEPRECATION")
                v.vibrate(14)
            }
        }

        @JavascriptInterface
        fun setBrightness(value: Float) {
            runOnUiThread {
                val lp = window.attributes
                lp.screenBrightness = if (value < 0f) {
                    WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                } else {
                    value.coerceIn(0.01f, 1f)
                }
                window.attributes = lp
            }
        }

        @JavascriptInterface
        fun battery(): String {
            val i = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            val level = i?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
            val scale = i?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
            val pluggedType = i?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
            val temp = (i?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, 0) ?: 0) / 10.0
            return JSONObject()
                .put("level", if (level >= 0) level * 100 / scale else -1)
                .put("plugged", pluggedType != 0)
                .put("temp", temp)
                .toString()
        }

        @JavascriptInterface
        fun btStatus(): String = btHid.statusJson()

        @JavascriptInterface
        fun btRequestPermissions() {
            runOnUiThread { btHid.requestPermissions() }
        }

        @JavascriptInterface
        fun btMakeDiscoverable() {
            runOnUiThread { btHid.makeDiscoverable() }
        }

        @JavascriptInterface
        fun btConnect(address: String): Boolean = btHid.connect(address)

        @JavascriptInterface
        fun btDisconnect(): Boolean = btHid.disconnect()

        @JavascriptInterface
        fun btOpenSettings() {
            runOnUiThread { btHid.openBluetoothSettings() }
        }

        @JavascriptInterface
        fun sendMedia(usageCode: Int): Boolean = btHid.sendConsumerControl(usageCode)

        @JavascriptInterface
        fun sendKey(modifier: Int, keyCode: Int): Boolean = btHid.sendKeyboardKey(modifier, keyCode)

        @JavascriptInterface
        fun sendBridgeCmd(jsonLine: String): Boolean = rfcommServer.sendCommand(jsonLine)

        @JavascriptInterface
        fun bridgeConnected(): Boolean = rfcommServer.isConnected()
    }

    companion object {
        private const val ASSET_HOST = "appassets.androidplatform.net"
    }
}
