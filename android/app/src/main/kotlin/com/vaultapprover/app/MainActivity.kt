package com.vaultapprover.app

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // FLAG_SECURE prevents screenshots / screen recording / the app
        // appearing in the recents thumbnail with content visible. Keep it
        // ON for normal builds; opt-out ONLY when the harness passes
        // -PallowScreenshots=true while building store screenshots.
        // Gradle wires that property into BuildConfig.ALLOW_SCREENSHOTS.
        if (!BuildConfig.ALLOW_SCREENSHOTS) {
            window.setFlags(
                WindowManager.LayoutParams.FLAG_SECURE,
                WindowManager.LayoutParams.FLAG_SECURE
            )
        }
    }
}
