package com.example.ssh_tool_app

import android.content.Intent
import android.net.Uri
import java.net.NetworkInterface
import java.util.Collections
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ssh_tool_app/p2p")
            .setMethodCallHandler { call, result ->
                if (call.method != "networkInterfaces") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    val interfaces = Collections.list(NetworkInterface.getNetworkInterfaces())
                        .filter { it.isUp }
                        .map { network ->
                            mapOf(
                                "name" to network.name,
                                "index" to network.index,
                                "addresses" to Collections.list(network.inetAddresses)
                                    .filter { !it.isLinkLocalAddress && !it.isMulticastAddress }
                                    .mapNotNull { it.hostAddress }
                            )
                        }
                    result.success(interfaces)
                } catch (error: Exception) {
                    result.error("network_interfaces_failed", error.message, null)
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ssh_tool_app/browser")
            .setMethodCallHandler { call, result ->
                if (call.method != "openUrl") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val url = call.argument<String>("url")
                if (url == null || !url.startsWith("https://")) {
                    result.error("invalid_url", "Only HTTPS URLs can be opened", null)
                    return@setMethodCallHandler
                }
                try {
                    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                    result.success(null)
                } catch (error: Exception) {
                    result.error("open_failed", error.message, null)
                }
            }
    }
}
