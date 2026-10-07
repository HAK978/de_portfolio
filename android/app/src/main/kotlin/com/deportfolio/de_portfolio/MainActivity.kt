package com.deportfolio.de_portfolio

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.webkit.CookieManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Shares downloaded update APKs with the system installer (see update_paths.xml). */
class UpdateFileProvider : FileProvider()

class MainActivity : FlutterActivity() {
    private val cookieChannel = "com.deportfolio/cookies"
    private val updateChannel = "com.deportfolio/updates"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, cookieChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getCookies" -> {
                        val url = call.argument<String>("url")
                        if (url == null) {
                            result.error("INVALID_ARG", "URL is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val cookieManager = CookieManager.getInstance()
                            val cookies = cookieManager.getCookie(url)
                            result.success(cookies)
                        } catch (e: Exception) {
                            result.error("COOKIE_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, updateChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> installApk(call.argument<String>("path"), result)
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Opens the system installer for an APK the app downloaded and verified.
     * Only files inside cache/updates are accepted. Android shows its own
     * confirmation and refuses updates signed with a different key.
     */
    private fun installApk(path: String?, result: MethodChannel.Result) {
        val updatesDir = File(cacheDir, "updates").canonicalFile
        val apk = path?.let { File(it).canonicalFile }
        if (apk == null || apk.parentFile != updatesDir || !apk.isFile || apk.extension != "apk") {
            result.error("INVALID_APK", "Not a downloaded update", null)
            return
        }

        // Android 8+: the user must allow this app to install apps once.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
            startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))
            )
            result.success("needs_permission")
            return
        }

        try {
            val uri = FileProvider.getUriForFile(this, "$packageName.updates", apk)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            result.success("started")
        } catch (e: Exception) {
            result.error("INSTALL_ERROR", e.message, null)
        }
    }
}
