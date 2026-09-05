package com.example.ai_cast_hub

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.accessibilityservice.GestureDescription
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Path
import android.graphics.Point
import android.graphics.Rect
import android.os.Build
import android.provider.Settings
import android.util.Log
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityManager
import android.view.accessibility.AccessibilityNodeInfo

class RemoteControlService : AccessibilityService() {

    companion object {
        private const val TAG = "RemoteControlService"
        @Volatile
        var instance: RemoteControlService? = null

        /**
         * 判断无障碍服务是否已开启
         *
         * 三种检测方式按「可靠性由高到低」依次尝试，任一种命中即返回 true：
         *   1. 服务实例存活 —— 系统已绑定并拉起本服务，最直接可靠的证据
         *   2. Settings.Secure 精确匹配 —— 按 ComponentName 对比，避免子串误判
         *   3. AccessibilityManager 列表查询 —— 兜底
         *
         * 注意：三种方式必须都能被走到，不能在中间提前 return，
         * 否则一旦前序方式误判，后续更可靠的兜底就失效了。
         */
        fun isServiceEnabled(context: Context): Boolean {
            // 方法1：服务实例存在（最可靠）
            val instanceExists = instance != null
            Log.d(TAG, "isServiceEnabled [1/3] service instance exists: $instanceExists")
            if (instanceExists) return true

            // 方法2：Settings.Secure 精确匹配 "包名/完整类名"
            try {
                val enabledServicesString = Settings.Secure.getString(
                    context.contentResolver,
                    Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
                ) ?: ""
                Log.d(TAG, "isServiceEnabled [2/3] enabled services string: $enabledServicesString")

                if (enabledServicesString.isNotEmpty()) {
                    val target = ComponentName(context, RemoteControlService::class.java)
                    val found = enabledServicesString
                        .split(':')
                        .map { it.trim() }
                        .filter { it.isNotEmpty() }
                        .any { entry -> ComponentName.unflattenFromString(entry) == target }
                    Log.d(TAG, "isServiceEnabled [2/3] exact match: $found")
                    if (found) return true
                }
            } catch (e: Exception) {
                Log.e(TAG, "isServiceEnabled Settings.Secure check failed: ${e.message}")
            }

            // 方法3：AccessibilityManager 列表查询（用 FEEDBACK_ALL_MASK，避免按
            // feedbackType 过滤时把本服务漏掉）
            try {
                val am = context.getSystemService(Context.ACCESSIBILITY_SERVICE) as AccessibilityManager
                val enabledServices = am.getEnabledAccessibilityServiceList(
                    AccessibilityServiceInfo.FEEDBACK_ALL_MASK
                )
                val targetServiceName = RemoteControlService::class.java.name
                val targetPackage = context.packageName
                var found = false
                for (serviceInfo in enabledServices) {
                    val ri = serviceInfo.resolveInfo?.serviceInfo ?: continue
                    Log.d(TAG, "isServiceEnabled [3/3] checking: ${ri.packageName}/${ri.name}")
                    if (ri.name == targetServiceName && ri.packageName == targetPackage) {
                        found = true
                        break
                    }
                }
                Log.d(TAG, "isServiceEnabled [3/3] AccessibilityManager: $found (count: ${enabledServices.size})")
                if (found) return true
            } catch (e: Exception) {
                Log.e(TAG, "isServiceEnabled AccessibilityManager check failed: ${e.message}")
            }

            Log.d(TAG, "isServiceEnabled => false (所有检测方式均未命中)")
            return false
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
        clearRuntimeState()
        if (instance === this) {
            instance = null
        }
        Log.d(TAG, "RemoteControlService destroyed")
        super.onDestroy()
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        Log.d(TAG, "RemoteControlService connected")
        instance = this

        // 关键：必须基于系统解析出的 serviceInfo 做「增量修改」，不能用一个全新的
        // AccessibilityServiceInfo 对象整体覆盖。
        // 整体覆盖会丢掉 XML 中声明的 packageNames、以及系统填充的 mId /
        // resolveInfo 等字段，系统会认为该服务配置无效并将其解绑，
        // 导致 getEnabledAccessibilityServiceList() 查不到本服务，
        // 表现为「用户已开启无障碍服务，但 App 仍提示需要开启」。
        val info = serviceInfo
        if (info != null) {
            info.eventTypes = AccessibilityEvent.TYPES_ALL_MASK
            info.feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
            info.flags = (info.flags or
                    AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS or
                    AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS) and
                    AccessibilityServiceInfo.FLAG_REQUEST_TOUCH_EXPLORATION_MODE.inv()
            // canRetrieveWindowContent 已在 res/xml/accessibility_service_config.xml 中
            // 通过 android:canRetrieveWindowContent="true" 声明；该字段在 API 36 上是只读
            // val，无法在代码中赋值，故此处不再赋值（避免编译报错，且 XML 已保证该能力开启）。
            serviceInfo = info
            Log.d(
                TAG,
                "serviceInfo 已更新，未请求触摸探索模式 " +
                        "(flags=${info.flags}, canRetrieveWindowContent=true[from XML])"
            )
        } else {
            Log.w(TAG, "serviceInfo 为空，跳过配置更新")
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
    }

    override fun onInterrupt() {
        clearRuntimeState()
        Log.d(TAG, "RemoteControlService interrupted")
    }

    override fun onUnbind(intent: Intent?): Boolean {
        clearRuntimeState()
        if (instance === this) {
            instance = null
        }
        Log.d(TAG, "RemoteControlService unbound")
        return super.onUnbind(intent)
    }

    fun dispatchTap(xPercent: Double, yPercent: Double): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return false

        return try {
            val screenSize = getScreenSize()
            val x = (screenSize.x * xPercent.coerceIn(0.0, 1.0)).toFloat()
            val y = (screenSize.y * yPercent.coerceIn(0.0, 1.0)).toFloat()

            Log.d(TAG, "dispatchTap: ($x, $y)")

            val path = Path().apply {
                moveTo(x, y)
            }
            val gesture = GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(path, 0, 50))
                .build()
            val accepted = dispatchGesture(gesture, null, null)
            Log.d(TAG, "dispatchTap accepted=$accepted")
            accepted
        } catch (e: Exception) {
            Log.e(TAG, "dispatchTap failed", e)
            false
        }
    }

    /**
     * 长按：单点停留指定时长后抬起。
     *
     * AccessibilityService.dispatchGesture 的单点 stroke 停留超过系统长按阈值
     * （ViewConfiguration.getLongPressTimeout()，通常 500ms）即产生长按语义。
     * 因此这里用单点 + 可调时长实现，默认 600ms。
     */
    fun dispatchLongPress(xPercent: Double, yPercent: Double, durationMs: Long = 600L): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return false

        return try {
            val screenSize = getScreenSize()
            val x = (screenSize.x * xPercent.coerceIn(0.0, 1.0)).toFloat()
            val y = (screenSize.y * yPercent.coerceIn(0.0, 1.0)).toFloat()
            val duration = durationMs.coerceIn(500L, 3000L)

            Log.d(TAG, "dispatchLongPress: ($x, $y) duration=${duration}ms")

            val path = Path().apply {
                moveTo(x, y)
            }
            val gesture = GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(path, 0, duration))
                .build()
            val accepted = dispatchGesture(gesture, null, null)
            Log.d(TAG, "dispatchLongPress accepted=$accepted")
            accepted
        } catch (e: Exception) {
            Log.e(TAG, "dispatchLongPress failed", e)
            false
        }
    }

    fun dispatchTouchStart(xPercent: Double, yPercent: Double): Boolean {
        try {
            val screenSize = getScreenSize()
            val x = (screenSize.x * xPercent.coerceIn(0.0, 1.0)).toInt()
            val y = (screenSize.y * yPercent.coerceIn(0.0, 1.0)).toInt()
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
            val x = (screenSize.x * xPercent.coerceIn(0.0, 1.0)).toInt()
            val y = (screenSize.y * yPercent.coerceIn(0.0, 1.0)).toInt()

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
            val x = (screenSize.x * xPercent.coerceIn(0.0, 1.0)).toInt()
            val y = (screenSize.y * yPercent.coerceIn(0.0, 1.0)).toInt()

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
            val x = (screenSize.x * xPercent.coerceIn(0.0, 1.0)).toInt()
            val y = (screenSize.y * yPercent.coerceIn(0.0, 1.0)).toInt()

            val scrollAmountX = (-deltaX * 2).toInt()
            val scrollAmountY = (-deltaY * 2).toInt()

            Log.d(TAG, "dispatchScroll: ($x, $y) delta=($scrollAmountX, $scrollAmountY)")

            val rootNode = rootInActiveWindow ?: return false
            val node = findScrollableNode(rootNode, x, y)

            if (node != null) {
                // 以位移绝对值较大的轴为准判断方向。此前恒定 ACTION_SCROLL_FORWARD，
                // 导致向上/向左滚动无效。
                val action = if (isForwardScroll(deltaX, deltaY)) {
                    AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
                } else {
                    AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
                }
                val performed = node.performAction(action)
                if (!performed && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    Log.d(TAG, "dispatchScroll: 节点不支持该方向，退化为手势滑动")
                    performScrollGesture(x, y, scrollAmountX, scrollAmountY, screenSize)
                }
                node.recycle()
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                performScrollGesture(x, y, scrollAmountX, scrollAmountY, screenSize)
            }

            return true
        } catch (e: Exception) {
            Log.e(TAG, "dispatchScroll failed: ${e.message}")
            return false
        }
    }

    /**
     * 判断滚动方向：以位移绝对值较大的轴为准。
     * deltaY > 0（滚轮向下）→ 向前滚；deltaY < 0（滚轮向上）→ 向后滚。
     */
    private fun isForwardScroll(deltaX: Double, deltaY: Double): Boolean {
        return if (Math.abs(deltaX) > Math.abs(deltaY)) deltaX > 0 else deltaY > 0
    }

    /**
     * 退化为手势滑动：找不到可滚动节点，或节点不支持对应滚动方向时使用。
     * 向下滚（deltaY>0）等价于手指由下往上划；scrollAmountY 已取负，
     * 因此终点直接取 y + scrollAmountY。
     */
    private fun performScrollGesture(
        x: Int,
        y: Int,
        scrollAmountX: Int,
        scrollAmountY: Int,
        screenSize: Point,
    ) {
        val horizontal = Math.abs(scrollAmountX) > Math.abs(scrollAmountY)
        val path = Path().apply {
            if (horizontal) {
                val endX = (x + scrollAmountX).toFloat().coerceIn(0f, screenSize.x.toFloat())
                moveTo(x.toFloat(), y.toFloat())
                lineTo(endX, y.toFloat())
            } else {
                val endY = (y + scrollAmountY).toFloat().coerceIn(0f, screenSize.y.toFloat())
                moveTo(x.toFloat(), y.toFloat())
                lineTo(x.toFloat(), endY)
            }
        }
        val gestureBuilder = GestureDescription.Builder()
        gestureBuilder.addStroke(
            GestureDescription.StrokeDescription(path, 0, 200)
        )
        dispatchGesture(gestureBuilder.build(), null, null)
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
        val bounds = Rect()
        node.getBoundsInScreen(bounds)
        
        if (bounds.contains(x, y)) {
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
        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val display = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            this.display
        } else {
            @Suppress("DEPRECATION")
            wm.defaultDisplay
        }
        val size = Point()
        display?.getRealSize(size)
        return size
    }

    private fun clearRuntimeState() {
        lastTouchPoint = null
    }

    /**
     * 投屏结束时清理手势运行态（例如未抬起的触点），
     * 避免残留的 lastTouchPoint 影响下一次投屏的触控判定。
     */
    fun clearGestureState() {
        clearRuntimeState()
        Log.d(TAG, "clearGestureState: 手势运行态已清理")
    }

    fun dispatchSwipe(
        startXPercent: Double,
        startYPercent: Double,
        endXPercent: Double,
        endYPercent: Double,
        durationMs: Int
    ): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return false

        return try {
            val screenSize = getScreenSize()
            val startX = (screenSize.x * startXPercent.coerceIn(0.0, 1.0)).toFloat()
            val startY = (screenSize.y * startYPercent.coerceIn(0.0, 1.0)).toFloat()
            val endX = (screenSize.x * endXPercent.coerceIn(0.0, 1.0)).toFloat()
            val endY = (screenSize.y * endYPercent.coerceIn(0.0, 1.0)).toFloat()
            val duration = durationMs.coerceIn(50, 2000).toLong()
            val path = Path().apply {
                moveTo(startX, startY)
                lineTo(endX, endY)
            }
            val gesture = GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(path, 0, duration))
                .build()
            val accepted = dispatchGesture(gesture, null, null)
            Log.d(
                TAG,
                "dispatchSwipe: ($startX, $startY) -> ($endX, $endY), " +
                        "duration=${duration}ms accepted=$accepted"
            )
            accepted
        } catch (e: Exception) {
            Log.e(TAG, "dispatchSwipe failed", e)
            false
        }
    }
}
