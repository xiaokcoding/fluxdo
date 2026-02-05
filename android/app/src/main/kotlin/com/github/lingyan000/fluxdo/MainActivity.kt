package com.github.lingyan000.fluxdo

import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.net.Uri
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.github.lingyan000.fluxdo/browser"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "openInBrowser" -> {
                    val url = call.argument<String>("url")
                    if (url != null) {
                        val success = openInExternalBrowser(url)
                        result.success(success)
                    } else {
                        result.error("INVALID_URL", "URL is null", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun openInExternalBrowser(url: String): Boolean {
        return try {
            // 使用一个通用的 HTTPS URL 来查询默认浏览器
            val browserIntent = Intent(Intent.ACTION_VIEW, Uri.parse("https://example.com"))
            browserIntent.addCategory(Intent.CATEGORY_BROWSABLE)

            // 获取默认浏览器
            val defaultBrowser: ResolveInfo? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                packageManager.resolveActivity(
                    browserIntent,
                    PackageManager.ResolveInfoFlags.of(PackageManager.MATCH_DEFAULT_ONLY.toLong())
                )
            } else {
                @Suppress("DEPRECATION")
                packageManager.resolveActivity(browserIntent, PackageManager.MATCH_DEFAULT_ONLY)
            }

            val targetIntent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            targetIntent.addCategory(Intent.CATEGORY_BROWSABLE)
            targetIntent.flags = Intent.FLAG_ACTIVITY_NEW_TASK

            if (defaultBrowser != null && defaultBrowser.activityInfo.packageName != packageName) {
                // 使用默认浏览器打开
                targetIntent.setPackage(defaultBrowser.activityInfo.packageName)
                startActivity(targetIntent)
                true
            } else {
                // 默认浏览器是自己或未找到，查找其他浏览器
                val resolveInfoList: List<ResolveInfo> = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    packageManager.queryIntentActivities(
                        browserIntent,
                        PackageManager.ResolveInfoFlags.of(0)
                    )
                } else {
                    @Suppress("DEPRECATION")
                    packageManager.queryIntentActivities(browserIntent, 0)
                }

                val otherBrowsers = resolveInfoList.filter {
                    it.activityInfo.packageName != packageName
                }

                if (otherBrowsers.isNotEmpty()) {
                    // 使用第一个可用的浏览器
                    targetIntent.setPackage(otherBrowsers[0].activityInfo.packageName)
                    startActivity(targetIntent)
                    true
                } else {
                    // 没有其他浏览器，无法打开
                    false
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }
}
