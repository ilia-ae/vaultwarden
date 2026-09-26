package com.vaultapprover.app

import android.app.Activity
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.os.SystemClock
import android.view.WindowManager
import androidx.annotation.RequiresApi
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest

class MainActivity : FlutterFragmentActivity() {
    /** Native side of lib/services/privacy_service.dart for the current engine. */
    private var privacy: PrivacyChannel? = null

    /**
     * The registered `Activity.ScreenCaptureCallback` (API 34+) while started.
     * Typed `Any` so older Android versions never load that class.
     */
    private var screenCaptureCallback: Any? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // FLAG_SECURE prevents screenshots / screen recording / the app
        // appearing in the recents thumbnail with content visible. Keep it
        // ON for normal builds; opt-out ONLY when the harness passes
        // -Pallow-screenshots=true while building store screenshots.
        // Gradle wires that property into BuildConfig.ALLOW_SCREENSHOTS.
        applySecureFlag()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine) // registers the plugins
        privacy?.detach()
        privacy = PrivacyChannel(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        privacy?.detach()
        privacy = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onStart() {
        super.onStart()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            registerScreenshotCallback()
        }
    }

    override fun onStop() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            unregisterScreenshotCallback()
        }
        super.onStop()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // Android 10+ only lets the focused app read the clipboard, so this is
        // where an expiry that fired in the background gets finished.
        SensitiveClipboard.onFocusChanged(this, hasFocus)
    }

    /**
     * `setSecureScreen` from the secret-bearing (PIN) screens. FLAG_SECURE
     * depends on the build alone:
     * - production builds keep it on for the whole app, so forcing it
     *   changes nothing there;
     * - screenshot builds (`-Pallow-screenshots=true`, i.e.
     *   BuildConfig.ALLOW_SCREENSHOTS; store screenshots and Maestro only)
     *   keep it off even here, so every screen can be captured.
     * [enabled] is accepted for the channel contract (iOS parity).
     */
    @Suppress("UNUSED_PARAMETER")
    fun setSecureScreen(enabled: Boolean) {
        applySecureFlag()
    }

    private fun applySecureFlag() {
        if (BuildConfig.ALLOW_SCREENSHOTS) {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        } else {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private fun registerScreenshotCallback() {
        if (screenCaptureCallback != null) return
        val callback = Activity.ScreenCaptureCallback { privacy?.onScreenshot() }
        try {
            registerScreenCaptureCallback(mainExecutor, callback)
            screenCaptureCallback = callback
        } catch (e: SecurityException) {
            // DETECT_SCREEN_CAPTURE not granted: no screenshot events.
        }
    }

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private fun unregisterScreenshotCallback() {
        val callback = screenCaptureCallback as? Activity.ScreenCaptureCallback ?: return
        screenCaptureCallback = null
        try {
            unregisterScreenCaptureCallback(callback)
        } catch (e: RuntimeException) {
            // Already gone.
        }
    }
}

/**
 * In-app platform channel behind lib/services/privacy_service.dart (not a
 * plugin, so nothing to register in GeneratedPluginRegistrant).
 *
 * Method channel `com.vaultapprover.app/privacy`:
 * - `copySensitive {text, ttlSeconds}`: see [SensitiveClipboard.copy].
 * - `clearClipboardIfOurs` -> Boolean: clears now if the clip is still ours.
 * - `clearClipboard` -> true: clears unconditionally.
 * - `setSecureScreen {enabled}` -> true: see [MainActivity.setSecureScreen]
 *   (a no-op: FLAG_SECURE follows the build).
 * - `isScreenCaptured` -> false: Android has no capture state to report;
 *   FLAG_SECURE blanks recordings instead.
 * - `isScreenshotsAllowedBuild` -> Boolean: BuildConfig.ALLOW_SCREENSHOTS,
 *   true only in `-Pallow-screenshots=true` builds (no FLAG_SECURE at all).
 *
 * Event channel `com.vaultapprover.app/privacy/captured`: `"screenshot"` on
 * Android 14+ when a screenshot is taken (none while FLAG_SECURE blocks it).
 */
private class PrivacyChannel(
    private val activity: MainActivity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val methods = MethodChannel(messenger, "com.vaultapprover.app/privacy")
    private val events = EventChannel(messenger, "com.vaultapprover.app/privacy/captured")
    private var sink: EventChannel.EventSink? = null

    init {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    fun detach() {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink = null
    }

    fun onScreenshot() {
        sink?.success("screenshot")
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "copySensitive" -> {
                    val text = call.argument<String>("text")
                    if (text == null) {
                        result.error("bad_args", "text is required", null)
                        return
                    }
                    val ttlSeconds = call.argument<Number>("ttlSeconds")?.toDouble() ?: 60.0
                    val ttlMillis = (ttlSeconds.coerceAtLeast(1.0) * 1000).toLong()
                    SensitiveClipboard.copy(activity, text, ttlMillis)
                    result.success(true)
                }
                "clearClipboardIfOurs" -> result.success(SensitiveClipboard.clearIfOurs(activity))
                "clearClipboard" -> {
                    SensitiveClipboard.clear(activity)
                    result.success(true)
                }
                "setSecureScreen" -> {
                    activity.setSecureScreen(call.argument<Boolean>("enabled") == true)
                    result.success(true)
                }
                "isScreenCaptured" -> result.success(false)
                "isScreenshotsAllowedBuild" -> result.success(BuildConfig.ALLOW_SCREENSHOTS)
                else -> result.notImplemented()
            }
        } catch (e: RuntimeException) {
            // SecurityException from OEM clipboards, bad argument types, ...
            result.error("privacy_failed", e.message, null)
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }
}

/**
 * The one sensitive clip this app may have on the clipboard. Process-wide so
 * a pending expiry survives activity recreation; main thread only.
 *
 * "Ours" means the clip's label is [LABEL] (read from the description, which
 * does not trigger Android 12+'s "pasted from your clipboard" toast) and its
 * text hashes to [ownDigest], so the plaintext itself is not kept here.
 *
 * Android 10+ lets only the focused app read the clipboard. An expiry that
 * fires without focus (or not at all, while the process is frozen) cannot
 * verify ownership, so it waits for the next focus gain instead of clearing
 * something that might be the user's.
 *
 * All of this state dies with the process (swiped out of Recents, or killed
 * in the background). A clip left behind that way is recognised on the next
 * focus gain by [LABEL] plus the IS_SENSITIVE extra alone and cleared then;
 * until then only Android 13+'s own one-hour auto-clear applies. Nothing is
 * persisted: a digest of a short PIN on disk could be brute-forced.
 */
private object SensitiveClipboard {
    private const val LABEL = "Vault Approver"

    /**
     * Value of `ClipDescription.EXTRA_IS_SENSITIVE`, honoured by some keyboards
     * before API 33, and the key [clearLeftover] reads back on every version.
     */
    private const val EXTRA_IS_SENSITIVE_COMPAT = "android.content.extra.IS_SENSITIVE"

    private enum class Owner { OURS, NOT_OURS, UNKNOWN }

    private val handler = Handler(Looper.getMainLooper())
    private val expire = Runnable { sweep() }

    private var appContext: Context? = null
    private var ownDigest: ByteArray? = null
    private var expiresAt = 0L
    private var focused = false

    /**
     * Puts [text] on the clipboard flagged as sensitive (Android 13+ hides
     * the preview) and schedules a clear-if-ours after [ttlMillis].
     */
    fun copy(context: Context, text: String, ttlMillis: Long) {
        val clipboard = clipboard(context) ?: throw IllegalStateException("No clipboard service")
        val clip = ClipData.newPlainText(LABEL, text)
        val sensitiveKey =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                ClipDescription.EXTRA_IS_SENSITIVE
            } else {
                EXTRA_IS_SENSITIVE_COMPAT
            }
        clip.description.extras = PersistableBundle().apply { putBoolean(sensitiveKey, true) }
        clipboard.setPrimaryClip(clip)
        forget()
        ownDigest = sha256(text)
        expiresAt = SystemClock.elapsedRealtime() + ttlMillis
        handler.postDelayed(expire, ttlMillis)
    }

    /**
     * Clears now if the clip is still ours. Without focus on Android 10+ the
     * check cannot run; the clear then happens on the next focus gain.
     */
    fun clearIfOurs(context: Context): Boolean {
        val clipboard = clipboard(context) ?: return false
        return when (owner(clipboard)) {
            Owner.OURS -> {
                wipe(clipboard)
                forget()
                true
            }
            Owner.NOT_OURS -> {
                forget()
                false
            }
            Owner.UNKNOWN -> {
                expiresAt = 0L // due now; finished by the next sweep
                false
            }
        }
    }

    /** Clears unconditionally (e.g. after the user pasted a seed from it). */
    fun clear(context: Context) {
        clipboard(context)?.let(::wipe)
        forget()
    }

    fun onFocusChanged(context: Context, hasFocus: Boolean) {
        appContext = context.applicationContext
        focused = hasFocus
        if (!hasFocus) return
        if (ownDigest == null) clearLeftover(context) else sweep()
    }

    /**
     * Clears a sensitive clip that an earlier process of this app copied but
     * died before expiring. With nothing tracked in memory, any clip labelled
     * [LABEL] and flagged IS_SENSITIVE is such a leftover: only [copy] writes
     * that combination, and it tracks what it writes for as long as the
     * process lives. (Flutter's own Clipboard.setData uses the label
     * "text label?" and no extras.) Called with focus, so the clipboard is
     * readable; if an OEM clipboard drops the extras, this finds nothing.
     */
    private fun clearLeftover(context: Context) {
        val clipboard = clipboard(context) ?: return
        val description =
            try {
                clipboard.primaryClipDescription
            } catch (e: RuntimeException) {
                null
            } ?: return
        if (description.label?.toString() != LABEL) return
        if (description.extras?.getBoolean(EXTRA_IS_SENSITIVE_COMPAT, false) != true) return
        try {
            wipe(clipboard)
        } catch (e: RuntimeException) {
            // SecurityException from OEM clipboards: retried on the next focus gain.
        }
    }

    private fun sweep() {
        if (ownDigest == null) return
        val remaining = expiresAt - SystemClock.elapsedRealtime()
        if (remaining > 0) {
            handler.removeCallbacks(expire)
            handler.postDelayed(expire, remaining)
            return
        }
        val clipboard = appContext?.let(::clipboard) ?: return
        when (owner(clipboard)) {
            Owner.OURS -> {
                wipe(clipboard)
                forget()
            }
            Owner.NOT_OURS -> forget()
            Owner.UNKNOWN -> Unit // retried on the next focus gain
        }
    }

    private fun owner(clipboard: ClipboardManager): Owner {
        val digest = ownDigest ?: return Owner.NOT_OURS
        // Before Android 10 the clipboard is always readable, so "nothing
        // there" really means empty; later it may just mean "no focus".
        val canRead = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || focused
        val description =
            try {
                clipboard.primaryClipDescription
            } catch (e: RuntimeException) {
                null
            } ?: return if (canRead) Owner.NOT_OURS else Owner.UNKNOWN
        if (description.label?.toString() != LABEL) return Owner.NOT_OURS
        val clip =
            try {
                clipboard.primaryClip
            } catch (e: RuntimeException) {
                null
            } ?: return if (canRead) Owner.NOT_OURS else Owner.UNKNOWN
        val text = if (clip.itemCount > 0) clip.getItemAt(0).text?.toString() else null
        return if (text != null && MessageDigest.isEqual(sha256(text), digest)) {
            Owner.OURS
        } else {
            Owner.NOT_OURS
        }
    }

    private fun wipe(clipboard: ClipboardManager) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            clipboard.clearPrimaryClip()
        } else {
            clipboard.setPrimaryClip(ClipData.newPlainText("", ""))
        }
    }

    private fun forget() {
        handler.removeCallbacks(expire)
        ownDigest?.fill(0)
        ownDigest = null
        expiresAt = 0L
    }

    private fun clipboard(context: Context): ClipboardManager? {
        appContext = context.applicationContext
        return context.applicationContext.getSystemService(ClipboardManager::class.java)
    }

    private fun sha256(text: String): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8))
}
