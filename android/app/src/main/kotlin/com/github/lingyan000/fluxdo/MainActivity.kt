package com.github.lingyan000.fluxdo

import android.content.Intent
import android.net.Uri
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
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            intent.addCategory(Intent.CATEGORY_BROWSABLE)
            intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK

            // 获取所有能处理这个 Intent 的应用
            val resolveInfoList = packageManager.queryIntentActivities(intent, 0)

            // 过滤掉自己的应用
            val filteredList = resolveInfoList.filter {
                it.activityInfo.packageName != packageName
            }

            if (filteredList.isNotEmpty()) {
                // 如果只有一个浏览器，直接打开
                if (filteredList.size == 1) {
                    intent.setPackage(filteredList[0].activityInfo.packageName)
                    startActivity(intent)
                } else {
                    // 多个浏览器时，创建选择器但排除自己
                    val chooserIntent = Intent.createChooser(intent, null)

                    // 使用 EXTRA_EXCLUDE_COMPONENTS 排除自己（API 24+）
                    val excludeComponents = resolveInfoList
                        .filter { it.activityInfo.packageName == packageName }
                        .map { android.content.ComponentName(it.activityInfo.packageName, it.activityInfo.name) }
                        .toTypedArray()

                    if (excludeComponents.isNotEmpty()) {
                        chooserIntent.putExtra(Intent.EXTRA_EXCLUDE_COMPONENTS, excludeComponents)
                    }

                    startActivity(chooserIntent)
                }
                true
            } else {
                // 没有可用的浏览器，回退到默认行为
                startActivity(intent)
                true
            }
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }
}
