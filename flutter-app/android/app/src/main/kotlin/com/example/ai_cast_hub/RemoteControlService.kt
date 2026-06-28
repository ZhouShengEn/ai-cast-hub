package com.example.ai_cast_hub

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.content.Context
import android.content.Intent
import android.graphics.Path
import android.graphics.Point
import android.os.Build
import android.provider.Settings
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityManager
import android.view.accessibility.AccessibilityNodeInfo

class RemoteControlService : AccessibilityService() {

    companion object {
        private const val TAG = "RemoteControlService"
        var instance: RemoteControlService? = null

        fun isServiceEnabled(context: Context): Boolean {
            val am = context.getSystemService(Context.ACCESSIBILITY_SERVICE) as AccessibilityManager
            val enabledServices = am.getEnabledAccessibilityServiceList(
                AccessibilityServiceInfo.FEEDBACK_GENERIC
            )
            return enabledServices.any {
                it.resolveInfo.serviceInfo.name == RemoteControlService::class.java.name
            }
        }

        fun openAccessibilitySettings(context: Context) {
            val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
            intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
            context.startActivity(intent)
        }
    }

    private var lastTouchPoint: Point? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        Log.d(TAG, "RemoteControlService created")
    }

    override fun onDestroy() {
        super.onDestroy()
        instance = null
        Log.d(TAG, "RemoteControlService destroyed")
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        Log.d(TAG, "RemoteControlService connected")

        val info = AccessibilityServiceInfo().apply {
            eventTypes = AccessibilityEvent.TYPES_ALL_MASK
            feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
            flags = AccessibilityServiceInfo.FLAG_DEFAULT or
                    AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS or
                    AccessibilityServiceInfo.FLAG_REQUEST_TOUCH_EXPLORATION_MODE
        }
        serviceInfo = info
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
    }

    override fun onInterrupt() {
        Log.d(TAG, "RemoteControlService interrupted")
    }

    fun dispatchTap(xPercent: Double, yPercent: Double): Boolean {
        try {
            val screenSize = getScreenSize()
            val x = (screenSize.x * xPercent).toInt()
            val y = (screenSize.y * yPercent).toInt()

            Log.d(TAG, "dispatchTap: ($x, $y)")

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                val path = Path().apply {
                    moveTo(x.toFloat(), y.toFloat())
                }
                val gestureBuilder = GestureDescription.Builder()
                gestureBuilder.addStroke(
                    GestureDescription.StrokeDescription(path, 0, 50)
                )
                dispatchGesture(gestureBuilder.build(), null, null)
            }
            return true
        } catch (e: Exception) {
            Log.e(TAG, "dispatchTap failed: ${e.message}")
            return false
        }
    }

    fun dispatchTouchStart(xPercent: Double, yPercent: Double): Boolean {
        try {
            val screenSize = getScreenSize()
            val x = (screenSize.x * xPercent).toInt()
            val y = (screenSize.y * yPercent).toInt()
            lastTouchPoint = Point(x, y)

            Log.d(TAG, "dispatchTouchStart: ($x, $y)")
            return true
        } catch (e: Exception) {
            Log.e(TAG, "dispatchTouchStart failed: ${e.message}")
            return false
        }
    }

    fun dispatchTouchMove(xPercent: Double, yPercent: Double): Boolean {
        try {
            val screenSize = getScreenSize()
            val x = (screenSize.x * xPercent).toInt()
            val y = (screenSize.y * yPercent).toInt()

            val startPoint = lastTouchPoint ?: Point(x, y)

            Log.d(TAG, "dispatchTouchMove: (${startPoint.x}, ${startPoint.y}) -> ($x, $y)")

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                val path = Path().apply {
                    moveTo(startPoint.x.toFloat(), startPoint.y.toFloat())
                    lineTo(x.toFloat(), y.toFloat())
                }
                val gestureBuilder = GestureDescription.Builder()
                gestureBuilder.addStroke(
                    GestureDescription.StrokeDescription(path, 0, 100)
                )
                dispatchGesture(gestureBuilder.build(), null, null)
            }

            lastTouchPoint = Point(x, y)
            return true
        } catch (e: Exception) {
            Log.e(TAG, "dispatchTouchMove failed: ${e.message}")
            return false
        }
    }

    fun dispatchTouchEnd(xPercent: Double, yPercent: Double): Boolean {
        try {
            val screenSize = getScreenSize()
            val x = (screenSize.x * xPercent).toInt()
            val y = (screenSize.y * yPercent).toInt()

            Log.d(TAG, "dispatchTouchEnd: ($x, $y)")
            lastTouchPoint = null
            return true
        } catch (e: Exception) {
            Log.e(TAG, "dispatchTouchEnd failed: ${e.message}")
            return false
        }
    }

    fun dispatchScroll(xPercent: Double, yPercent: Double, deltaX: Double, deltaY: Double): Boolean {
        try {
            val screenSize = getScreenSize()
            val x = (screenSize.x * xPercent).toInt()
            val y = (screenSize.y * yPercent).toInt()

            val scrollAmountX = (-deltaX * 2).toInt()
            val scrollAmountY = (-deltaY * 2).toInt()

            Log.d(TAG, "dispatchScroll: ($x, $y) delta=($scrollAmountX, $scrollAmountY)")

            val rootNode = rootInActiveWindow ?: return false
            val node = findScrollableNode(rootNode, x, y)

            if (node != null) {
                node.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)
                node.recycle()
            } else {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    val startY = y.toFloat()
                    val endY = (y + scrollAmountY).toFloat().coerceIn(0f, screenSize.y.toFloat())

                    val path = Path().apply {
                        moveTo(x.toFloat(), startY)
                        lineTo(x.toFloat(), endY)
                    }
                    val gestureBuilder = GestureDescription.Builder()
                    gestureBuilder.addStroke(
                        GestureDescription.StrokeDescription(path, 0, 200)
                    )
                    dispatchGesture(gestureBuilder.build(), null, null)
                }
            }

            return true
        } catch (e: Exception) {
            Log.e(TAG, "dispatchScroll failed: ${e.message}")
            return false
        }
    }

    fun performGlobalAction(action: String): Boolean {
        try {
            val actionId = when (action) {
                "home" -> GLOBAL_ACTION_HOME
                "back" -> GLOBAL_ACTION_BACK
                "recent" -> GLOBAL_ACTION_RECENTS
                else -> return false
            }
            Log.d(TAG, "performGlobalAction: $action")
            return performGlobalAction(actionId)
        } catch (e: Exception) {
            Log.e(TAG, "performGlobalAction failed: ${e.message}")
            return false
        }
    }

    private fun findScrollableNode(node: AccessibilityNodeInfo, x: Int, y: Int): AccessibilityNodeInfo? {
        if (node.contains(x, y)) {
            if (node.isScrollable) {
                return node
            }
            for (i in 0 until node.childCount) {
                val child = node.getChild(i)
                if (child != null) {
                    val result = findScrollableNode(child, x, y)
                    if (result != null) {
                        return result
                    }
                    child.recycle()
                }
            }
        }
        return null
    }

    private fun getScreenSize(): Point {
        val display = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            display
        } else {
            @Suppress("DEPRECATION")
            windowManager.defaultDisplay
        }
        val size = Point()
        display?.getRealSize(size)
        return size
    }
}