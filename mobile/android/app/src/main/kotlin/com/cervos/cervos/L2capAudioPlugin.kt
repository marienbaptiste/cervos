package com.cervos.cervos

import android.bluetooth.*
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

private const val TAG = "CervosL2CAP"

/**
 * Flutter platform channel for BLE L2CAP CoC audio streaming.
 *
 * flutter_reactive_ble doesn't support L2CAP CoC, so we bridge it natively.
 *
 * Methods:
 *   connectL2cap(String deviceAddress, int psm) → bool
 *   disconnectL2cap() → void
 *
 * Event stream:
 *   com.cervos.cervos/l2cap_audio → Uint8List packets
 */
class L2capAudioPlugin {
    companion object {
        private const val METHOD_CHANNEL = "com.cervos.cervos/l2cap"
        private const val EVENT_CHANNEL = "com.cervos.cervos/l2cap_audio"

        fun register(flutterEngine: FlutterEngine) {
            val plugin = L2capAudioHandler()

            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "connectL2cap" -> {
                            val address = call.argument<String>("address")
                            val psm = call.argument<Int>("psm")
                            if (address == null || psm == null) {
                                result.error("INVALID_ARG", "Missing address or psm", null)
                                return@setMethodCallHandler
                            }
                            plugin.connect(address, psm, result)
                        }
                        "disconnectL2cap" -> {
                            plugin.disconnect()
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                }

            EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
                .setStreamHandler(plugin)
        }
    }
}

private class L2capAudioHandler : EventChannel.StreamHandler {
    private var socket: BluetoothSocket? = null
    private var readThread: Thread? = null
    private var eventSink: EventChannel.EventSink? = null
    private val handler = Handler(Looper.getMainLooper())

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun connect(address: String, psm: Int, result: MethodChannel.Result) {
        disconnect()

        Thread {
            try {
                val adapter = BluetoothAdapter.getDefaultAdapter()
                val device = adapter.getRemoteDevice(address)

                // L2CAP CoC requires Android 10+ (API 29)
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                    handler.post { result.error("UNSUPPORTED", "L2CAP CoC requires Android 10+", null) }
                    return@Thread
                }

                socket = device.createInsecureL2capChannel(psm)
                socket?.connect()
                Log.i(TAG, "L2CAP connected to $address PSM $psm")

                handler.post { result.success(true) }

                // Start reading audio packets
                val input = socket?.inputStream ?: run {
                    Log.e(TAG, "inputStream is null after connect")
                    return@Thread
                }
                val buffer = ByteArray(1024)  // Max L2CAP packet
                var totalPackets = 0

                readThread = Thread.currentThread()
                Log.i(TAG, "Starting L2CAP read loop, eventSink=${eventSink != null}")
                while (!Thread.interrupted() && socket?.isConnected == true) {
                    val bytesRead = input.read(buffer)
                    if (bytesRead > 0) {
                        totalPackets++
                        if (totalPackets <= 5 || totalPackets % 500 == 0) {
                            Log.d(TAG, "L2CAP rx: $bytesRead bytes (total=$totalPackets, sink=${eventSink != null})")
                        }
                        val packet = buffer.copyOf(bytesRead)
                        handler.post {
                            eventSink?.success(packet)
                        }
                    } else if (bytesRead == 0) {
                        Log.w(TAG, "L2CAP read returned 0 bytes")
                    }
                }
                Log.i(TAG, "L2CAP read loop ended, total packets=$totalPackets")
            } catch (e: Exception) {
                handler.post {
                    if (socket == null) {
                        // Connection failed
                        result.error("CONNECT_FAIL", e.message, null)
                    } else {
                        // Read error — stream ended
                        eventSink?.endOfStream()
                    }
                }
            }
        }.start()
    }

    fun disconnect() {
        readThread?.interrupt()
        readThread = null
        try {
            socket?.close()
        } catch (_: Exception) {}
        socket = null
    }
}
