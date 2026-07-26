package com.mdsscope.app

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.provider.Settings
import java.io.File
import java.io.FileInputStream
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory

class MainActivity: FlutterActivity() {
    private var openRequestsChannel: MethodChannel? = null
    private val pendingOpenRequests = mutableListOf<String>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "mdsscope/permissions"
        ).setMethodCallHandler { call, result ->
            if (call.method != "openAppSettings") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val intent = Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:$packageName")
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            try {
                startActivity(intent)
                result.success(true)
            } catch (error: Exception) {
                result.error("OPEN_SETTINGS_FAILED", error.message, null)
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "mdsscope/system_info"
        ).setMethodCallHandler { call, result ->
            if (call.method != "get") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            result.success(
                mapOf(
                    "name" to "Android",
                    "version" to Build.VERSION.RELEASE,
                    "architecture" to (Build.SUPPORTED_ABIS.firstOrNull() ?: Build.CPU_ABI)
                )
            )
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "mdsscope/system_fonts"
        ).setMethodCallHandler { call, result ->
            if (call.method != "listFamilies") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            result.success(systemFontFamilies())
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "mdsscope/user_data"
        ).setMethodCallHandler { call, result ->
            if (call.method != "supportDirectory") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            result.success(filesDir.absolutePath)
        }
        openRequestsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "mdsscope/open_requests"
        )
        openRequestsChannel?.setMethodCallHandler { call, result ->
            if (call.method != "takePending") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val pending = pendingOpenRequests.toList()
            pendingOpenRequests.clear()
            result.success(pending)
        }
        stageIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        stageIntent(intent)
    }

    private fun stageIntent(intent: Intent?) {
        if (intent == null) return
        val uri = when (intent.action) {
            Intent.ACTION_SEND -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
                }
            }
            Intent.ACTION_VIEW -> intent.data
            else -> null
        } ?: return

        val request = if (uri.scheme.equals("mdsscope", ignoreCase = true)) {
            uri.toString()
        } else {
            copyIncomingConfiguration(uri) ?: return
        }
        pendingOpenRequests.add(request)
        openRequestsChannel?.invokeMethod("openRequest", request)
    }

    private fun copyIncomingConfiguration(uri: Uri): String? {
        if (uri.scheme == "file") return uri.path
        val displayName = try {
            contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
        } catch (_: Exception) {
            null
        } ?: "shared-config.toml"
        val safeName = displayName.replace(Regex("[^A-Za-z0-9._-]"), "_")
        val destination = File(
            cacheDir,
            "${System.currentTimeMillis()}-${safeName.ifEmpty { "config.toml" }}"
        )
        return try {
            contentResolver.openInputStream(uri)?.use { input ->
                destination.outputStream().use { output ->
                    input.copyTo(output)
                }
            } ?: return null
            destination.absolutePath
        } catch (_: Exception) {
            null
        }
    }

    private fun systemFontFamilies(): List<String> {
        val families = linkedSetOf(
            "sans-serif",
            "serif",
            "monospace",
            "sans-serif-condensed"
        )
        val fontConfigs = listOf(
            "/system/etc/fonts.xml",
            "/system/etc/system_fonts.xml",
            "/product/etc/fonts_customization.xml",
            "/vendor/etc/fonts.xml"
        )
        for (path in fontConfigs) {
            val file = File(path)
            if (!file.isFile) continue
            try {
                FileInputStream(file).use { stream ->
                    val parser =
                        XmlPullParserFactory.newInstance().newPullParser()
                    parser.setInput(stream, "UTF-8")
                    var event = parser.eventType
                    while (event != XmlPullParser.END_DOCUMENT) {
                        if (event == XmlPullParser.START_TAG &&
                            (parser.name == "family" || parser.name == "alias")
                        ) {
                            parser.getAttributeValue(null, "name")
                                ?.trim()
                                ?.takeIf { it.isNotEmpty() }
                                ?.let(families::add)
                        }
                        event = parser.next()
                    }
                }
            } catch (_: Exception) {
                // OEM font configuration files are optional and may be
                // unreadable to applications.
            }
        }
        return families.sortedWith(String.CASE_INSENSITIVE_ORDER)
    }
}
