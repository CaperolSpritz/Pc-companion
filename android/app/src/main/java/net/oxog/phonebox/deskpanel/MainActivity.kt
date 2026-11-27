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
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import android.provider.Settings
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.webkit.ConsoleMessage
import android.webkit.JavascriptInterface
import android.webkit.RenderProcessGoneDetail
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
    private val mainHandler = Handler(Looper.getMainLooper())
    private var lastLux = -1f
    private var lastLuxAt = 0L
    private var near: Boolean? = null
    @Volatile private var lastWebHeartbeat = SystemClock.elapsedRealtime()
    private var isActivityResumed = false

    private val assetLoader by lazy {
        WebViewAssetLoader.Builder()
            .addPathHandler("/assets/", WebViewAssetLoader.AssetsPathHandler(this))
            .build()
    }

    // Watchdog Nativo Kotlin: se per > 25s il JS della WebView non invia heartbeat (es. freeze o crash renderer),
    // abbassa subito la luminosità all'1% su sfondo nero e ricarica la WebView per impedire qualsiasi schermata bianca.
    private val watchdogRunnable = object : Runnable {
        override fun run() {
            if (isActivityResumed) {
                val elapsed = SystemClock.elapsedRealtime() - lastWebHeartbeat
                if (elapsed > 25_000L) {
                    Log.w("PCCompanionWatchdog", "WebView heartbeat assente da ${elapsed}ms: ripristino di sicurezza su sfondo nero!")
                    lastWebHeartbeat = SystemClock.elapsedRealtime()
                    try {
                        val lp = window.attributes
                        lp.screenBrightness = 0.01f
                        window.attributes = lp
                        web.setBackgroundColor(0xFF000000.toInt())
                        web.loadUrl("https://$ASSET_HOST/assets/www/index.html")
                    } catch (_: Exception) {}
                }
            }
            mainHandler.postDelayed(this, 10_000L)
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.decorView.setBackgroundColor(0xFF000000.toInt())

        btHid = BluetoothHidController(this) {
            val status = btHid.statusJson()
            if (::web.isInitialized) {
                web.evaluateJavascript("window.onBtState && window.onBtState(${JSONObject.quote(status)})", null)
            }
        }

        rfcommServer = BluetoothRfcommServer(
            context = this,
            hasPermissions = { btHid.hasPermissions() },
            onBridgeMessage = { line ->
                if (::web.isInitialized) {
                    web.evaluateJavascript("window.onPcBridgeData && window.onPcBridgeData(${JSONObject.quote(line)})", null)
                }
            },
            onConnectionChanged = { connected, host ->
                if (::web.isInitialized) {
                    web.evaluateJavascript(
                        "window.onPcBridgeStatus && window.onPcBridgeStatus($connected, ${JSONObject.quote(host)})",
                        null
                    )
                }
            }
        )

        setupWebView()
        hideSystemUi()
        mainHandler.postDelayed(watchdogRunnable, 12_000L)
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun setupWebView() {
        lastWebHeartbeat = SystemClock.elapsedRealtime()
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

            // Intercetta qualsiasi crash/kill del Renderer Process di Android WebView (evita la schermata bianca!)
            override fun onRenderProcessGone(view: WebView?, detail: RenderProcessGoneDetail?): Boolean {
                Log.e("PCCompanionWeb", "WebView RenderProcessGone rilevato! Ricreo subito WebView su sfondo nero.")
                runOnUiThread {
                    try {
                        val lp = window.attributes
                        lp.screenBrightness = 0.01f
                        window.attributes = lp
                        (view?.parent as? ViewGroup)?.removeView(view)
                        view?.destroy()
                    } catch (_: Exception) {}
                    setupWebView()
                }
                return true
            }
        }
        web.addJavascriptInterface(Bridge(), "Android")
        WebView.setWebContentsDebuggingEnabled(BuildConfig.DEBUG)
        web.loadUrl("https://$ASSET_HOST/assets/www/index.html")
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
        isActivityResumed = true
        lastWebHeartbeat = SystemClock.elapsedRealtime()
        if (::web.isInitialized) web.onResume()
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
        isActivityResumed = false
        sensors?.unregisterListener(this)
        if (::web.isInitialized) web.onPause()
        super.onPause()
    }

    override fun onDestroy() {
        mainHandler.removeCallbacks(watchdogRunnable)
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
        fun heartbeat() {
            lastWebHeartbeat = SystemClock.elapsedRealtime()
        }

        @JavascriptInterface
        fun setKeepScreenOn(enabled: Boolean) {
            runOnUiThread {
                if (enabled) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
            }
        }

        @JavascriptInterface
        fun battery(): String {
            val i = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            val level = i?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
            val scale = i?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
            val pluggedType = i?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
            val temp = (i?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, 0) ?: 0) / 10.0
            val sysBrightRaw = try {
                Settings.System.getInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS)
            } catch (_: Exception) {
                128
            }
            val sysBrightPct = ((sysBrightRaw * 100f) / 255f).toInt().coerceIn(0, 100)
            return JSONObject()
                .put("level", if (level >= 0) level * 100 / scale else -1)
                .put("plugged", pluggedType != 0)
                .put("temp", temp)
                .put("brightnessPct", sysBrightPct)
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
