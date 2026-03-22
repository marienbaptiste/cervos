package com.cervos.cervos

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity: FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        Lc3DecoderPlugin.register(flutterEngine)
        L2capAudioPlugin.register(flutterEngine)
    }
}
