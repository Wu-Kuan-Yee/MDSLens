package com.mdslens.app

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.provider.Settings
import androidx.core.content.FileProvider
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
            "mdslens/permissions"
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
            "mdslens/system_info"
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
            "mdslens/system_fonts"
        ).setMethodCallHandler { call, result ->
            if (call.method != "listFamilies") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            result.success(systemFontFamilies())
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "mdslens/user_data"
        ).setMethodCallHandler { call, result ->
            if (call.method != "supportDirectory") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            result.success(filesDir.absolutePath)
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "mdslens/drop_file_access"
        ).setMethodCallHandler { call, result ->
            if (call.method != "readContentUri") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val value = call.arguments as? String
            if (value.isNullOrBlank()) {
                result.error("INVALID_URI", "The dropped content URI is empty.", null)
                return@setMethodCallHandler
            }
            try {
                val uri = Uri.parse(value)
                val bytes = contentResolver.openInputStream(uri)?.use { stream ->
                    stream.readBytes()
                }
                if (bytes == null) {
                    result.error(
                        "READ_FAILED",
                        "The Android document provider returned no file data.",
                        null
                    )
                } else {
                    result.success(bytes)
                }
            } catch (error: Exception) {
                result.error("READ_FAILED", error.message, null)
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "mdslens/updater"
        ).setMethodCallHandler { call, result ->
            if (call.method != "installApk") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val value = call.arguments as? String
            if (value.isNullOrBlank()) {
                result.error("INVALID_UPDATE", "The update path is empty.", null)
                return@setMethodCallHandler
            }
            try {
                val update = File(value).canonicalFile
                val cache = cacheDir.canonicalFile
                if (!update.isFile ||
                    !update.name.endsWith(".apk", ignoreCase = true) ||
                    !update.path.startsWith(cache.path + File.separator)
                ) {
                    result.error(
                        "INVALID_UPDATE",
                        "The update must be a verified APK in the application cache.",
                        null
                    )
                    return@setMethodCallHandler
                }
                when (validateUpdatePackage(update)) {
                    "invalid_package" -> {
                        result.success("invalid_package")
                        return@setMethodCallHandler
                    }
                    "signature_mismatch" -> {
                        result.success("signature_mismatch")
                        return@setMethodCallHandler
                    }
                    "not_newer" -> {
                        result.success("not_newer")
                        return@setMethodCallHandler
                    }
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                    !packageManager.canRequestPackageInstalls()
                ) {
                    openUnknownSourcesSettings()
                    result.success("permission_required")
                    return@setMethodCallHandler
                }
                val contentUri = FileProvider.getUriForFile(
                    this,
                    "$packageName.update_files",
                    update
                )
                result.success(
                    if (launchPackageInstaller(contentUri)) {
                        "launched"
                    } else {
                        "installer_unavailable"
                    }
                )
            } catch (error: Exception) {
                result.error("INSTALL_UPDATE_FAILED", error.message, null)
            }
        }
        openRequestsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "mdslens/open_requests"
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

    private fun validateUpdatePackage(update: File): String {
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            @Suppress("DEPRECATION")
            PackageManager.GET_SIGNATURES
        }
        val archive = packageManager.getPackageArchiveInfo(update.path, flags)
            ?: return "invalid_package"
        if (archive.packageName != packageName) return "invalid_package"
        val installed = try {
            packageManager.getPackageInfo(packageName, flags)
        } catch (_: PackageManager.NameNotFoundException) {
            return "invalid_package"
        }
        val installedSigners = signingCertificates(installed)
        val archiveSigners = signingCertificates(archive)
        if (installedSigners.isEmpty() ||
            archiveSigners.isEmpty() ||
            installedSigners.intersect(archiveSigners).isEmpty()
        ) {
            return "signature_mismatch"
        }
        val installedVersion = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            installed.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            installed.versionCode.toLong()
        }
        val archiveVersion = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            archive.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            archive.versionCode.toLong()
        }
        return if (archiveVersion > installedVersion) "valid" else "not_newer"
    }

    private fun signingCertificates(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signingInfo = info.signingInfo ?: return emptySet()
            if (signingInfo.hasMultipleSigners()) {
                signingInfo.apkContentsSigners
            } else {
                signingInfo.signingCertificateHistory
            }
        } else {
            @Suppress("DEPRECATION")
            info.signatures
        }
        return signatures.orEmpty().map { it.toCharsString() }.toSet()
    }

    private fun openUnknownSourcesSettings() {
        val intents = listOf(
            Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName")
            ),
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:$packageName")
            ),
            Intent(Settings.ACTION_SECURITY_SETTINGS)
        )
        for (candidate in intents) {
            try {
                startActivity(candidate)
                return
            } catch (_: ActivityNotFoundException) {
                // Try the next settings surface supplied by this Android build.
            } catch (_: SecurityException) {
                // Some vendor builds restrict a settings intent; fall back.
            }
        }
    }

    private fun launchPackageInstaller(contentUri: Uri): Boolean {
        val mimeType = "application/vnd.android.package-archive"
        for (action in listOf(Intent.ACTION_INSTALL_PACKAGE, Intent.ACTION_VIEW)) {
            val candidate = Intent(action)
                .setDataAndType(contentUri, mimeType)
                .addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_ACTIVITY_NEW_TASK
                )
            candidate.clipData = ClipData.newRawUri("MDSLens update", contentUri)
            packageManager.queryIntentActivities(
                candidate,
                PackageManager.MATCH_DEFAULT_ONLY
            ).forEach { target ->
                grantUriPermission(
                    target.activityInfo.packageName,
                    contentUri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
            }
            try {
                startActivity(candidate)
                return true
            } catch (_: ActivityNotFoundException) {
                // Try the legacy ACTION_VIEW path next.
            } catch (_: SecurityException) {
                // Try the legacy ACTION_VIEW path next.
            }
        }
        return false
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

        val request = if (uri.scheme.equals("mdslens", ignoreCase = true)) {
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
