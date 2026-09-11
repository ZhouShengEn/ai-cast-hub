package com.example.ai_cast_hub

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.accessibilityservice.GestureDescription
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Point
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.media.AudioManager
import android.graphics.Path
import android.os.Build
import android.provider.Settings
import android.util.Log
import android.view.Display
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
        /**
         * 无障碍服务实例是否已绑定到本进程。
         *
         * 只有它为 true 时 dispatchGesture 才可能成功，因此它才是「远程控制是否真的
         * 可用」的判据。必须与 [isEnabledInSettings] 严格区分：
         * 用户在系统设置里打开了开关（settings == true）**不代表** 服务实例还活着——
         * App 进程重启、服务被系统回收、或改过 accessibility_service_config.xml 之后
         * 都会出现「设置里开着但实例为 null」。历史上正是这个差异导致
         * 「Web 端显示已开启、但点击仍然失败且提示让人去开启」的误导。
         */
        fun isServiceConnected(): Boolean = instance != null

        /**
         * 仅在系统设置层面判定是否已启用（不含「实例存活」这一条）。
         *
         * 两种检测方式按可靠性依次尝试，任一命中即返回 true。
         */
        fun isEnabledInSettings(context: Context): Boolean {
            // 方式1：Settings.Secure 精确匹配 "包名/完整类名"
            try {
                val enabledServicesString = Settings.Secure.getString(
                    context.contentResolver,
                    Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
                ) ?: ""
                Log.d(TAG, "isEnabledInSettings [1/2] enabled services: $enabledServicesString")

                if (enabledServicesString.isNotEmpty()) {
                    val target = ComponentName(context, RemoteControlService::class.java)
                    val found = enabledServicesString
                        .split(':')
                        .map { it.trim() }
                        .filter { it.isNotEmpty() }
                        .any { entry -> ComponentName.unflattenFromString(entry) == target }
                    Log.d(TAG, "isEnabledInSettings [1/2] exact match: $found")
                    if (found) return true
                }
            } catch (e: Exception) {
                Log.e(TAG, "isEnabledInSettings Settings.Secure check failed: ${e.message}")
            }

            // 方式2：AccessibilityManager 列表查询（用 FEEDBACK_ALL_MASK，避免按
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
                    Log.d(TAG, "isEnabledInSettings [2/2] checking: ${ri.packageName}/${ri.name}")
                    if (ri.name == targetServiceName && ri.packageName == targetPackage) {
                        found = true
                        break
                    }
                }
                Log.d(TAG, "isEnabledInSettings [2/2] AccessibilityManager: $found (count: ${enabledServices.size})")
                if (found) return true
            } catch (e: Exception) {
                Log.e(TAG, "isEnabledInSettings AccessibilityManager check failed: ${e.message}")
            }

            Log.d(TAG, "isEnabledInSettings => false (设置项未命中)")
            return false
        }

        /**
         * 综合判定：实例存活 或 设置已启用。
         *
         * 仅用于「是否曾开启过」这类宽松判断；**判定「能否派发手势」必须
         * 使用 [isServiceConnected]**，否则会重演「显示已开启但点了没反应」。
         */
        fun isServiceEnabled(context: Context): Boolean {
            val connected = isServiceConnected()
            Log.d(TAG, "isServiceEnabled [1/2] instance connected: $connected")
            if (connected) return true
            val inSettings = isEnabledInSettings(context)
            Log.d(TAG, "isServiceEnabled [2/2] enabled in settings: $inSettings")
            return inSettings
        }

        /** 供 Dart 侧做远程控制诊断：返回最近一次可解释的失败原因 */
        fun describeDispatchState(context: Context): String {
            return when {
                isServiceConnected() -> "ok"
                isEnabledInSettings(context) -> "settings_enabled_but_not_connected"
                else -> "service_not_enabled"
            }
        }

        /** 最近一次获取 Display 失败的原因（供 Dart 侧诊断上报，避免只看到空的 0x0） */
        @Volatile
        var lastDisplayError: String? = null
            private set

        fun recordDisplayError(e: Exception) {
            lastDisplayError = "${e.javaClass.simpleName}: ${e.message}"
        }

        /**
         * 打开系统无障碍设置，并尽可能直接定位到本 App 的服务开关页。
         *
         * 优先用 ACTION_ACCESSIBILITY_DETAILS_SETTINGS + package: data —— 多数 ROM
         * 会直接落到「AI-Cast-Hub」的开关详情页，用户点一下即可开启；
         * 个别 ROM 不支持该 Intent，回退到列表页（ACTION_ACCESSIBILITY_SETTINGS）。
         */
        fun openAccessibilitySettings(context: Context) {
            val launched = try {
                val detail = Intent(Settings.ACTION_ACCESSIBILITY_DETAILS_SETTINGS).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                    data = android.net.Uri.parse("package:${context.packageName}")
                }
                context.startActivity(detail)
                true
            } catch (e: Exception) {
                Log.w(TAG, "打开无障碍详情页失败，回退列表页: ${e.message}")
                false
            }
            if (!launched) {
                try {
                    val list = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                    }
                    context.startActivity(list)
                } catch (e: Exception) {
                    Log.e(TAG, "打开无障碍设置失败: ${e.message}")
                }
            }
        }
    }

    private var lastTouchPoint: Point? = null
    /** 本次连续手势的起始点（用于区分「点击」与「拖拽」） */
    private var touchStartPoint: Point? = null
    /** 本次连续手势是否发生过移动 */
    private var touchMoved = false
    /** 最近一次 move/up 派发的手势是否被系统受理（供上层回执失败用） */
    private var lastTouchAccepted = false

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
            val p = resolvePoint(xPercent, yPercent, screenSize)
            val x = p.x.toFloat()
            val y = p.y.toFloat()

            Log.d(TAG, "dispatchTap: ($x, $y) screen=${screenSize.x}x${screenSize.y}")

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
            val p = resolvePoint(xPercent, yPercent, screenSize)
            val x = p.x.toFloat()
            val y = p.y.toFloat()
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
            val start = resolvePoint(xPercent, yPercent, screenSize)
            lastTouchPoint = Point(start.x, start.y)
            touchStartPoint = Point(start.x, start.y)
            touchMoved = false

            Log.d(TAG, "dispatchTouchStart: (${start.x}, ${start.y}) screen=${screenSize.x}x${screenSize.y}")
            return true
        } catch (e: Exception) {
            Log.e(TAG, "dispatchTouchStart failed: ${e.message}")
            return false
        }
    }

    fun dispatchTouchMove(xPercent: Double, yPercent: Double): Boolean {
        try {
            val screenSize = getScreenSize()
            val target = resolvePoint(xPercent, yPercent, screenSize)
            val x = target.x
            val y = target.y

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
                lastTouchAccepted = dispatchGesture(gestureBuilder.build(), null, null)
            } else {
                lastTouchAccepted = false
            }

            lastTouchPoint = Point(x, y)
            touchMoved = true
            return true
        } catch (e: Exception) {
            Log.e(TAG, "dispatchTouchMove failed: ${e.message}")
            return false
        }
    }

    fun dispatchTouchEnd(xPercent: Double, yPercent: Double): Boolean {
        try {
            val screenSize = getScreenSize()
            val end = resolvePoint(xPercent, yPercent, screenSize)
            val x = end.x
            val y = end.y

            Log.d(TAG, "dispatchTouchEnd: ($x, $y)")
            // 整段手势没有发生移动（down 之后直接 up）→ 等价于一次点击，补发 tap，
            // 否则纯 touch_start/end 在 Kotlin 侧不会触发任何手势（仅记录坐标）。
            val accepted: Boolean
            if (touchMoved) {
                // 拖拽结束：以最后一次 move 的受理结果为准
                accepted = lastTouchAccepted
            } else {
                // 无位移即一次点按。
                // 若 down 丢失（没收到 / 被 clearGestureState 清掉），这里退回用 up 的坐标
                // 补发点击；原实现此时直接把上一次的 lastTouchAccepted 当结果返回，
                // 既没派发任何手势又报 ok:false —— 正是「点了没反应」的元凶之一。
                val tapPoint = touchStartPoint ?: Point(x, y)
                Log.d(TAG, "dispatchTouchEnd: 无位移，按点击处理 (${tapPoint.x}, ${tapPoint.y})")
                accepted = performTapAt(tapPoint.x, tapPoint.y)
            }
            lastTouchPoint = null
            touchStartPoint = null
            touchMoved = false
            return accepted
        } catch (e: Exception) {
            Log.e(TAG, "dispatchTouchEnd failed: ${e.message}")
            return false
        }
    }

    /** 在指定像素坐标处触发一次短点击（供 touch_end 无移动时补发），返回是否被系统受理 */
    private fun performTapAt(x: Int, y: Int): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return false
        return try {
            val path = Path().apply { moveTo(x.toFloat(), y.toFloat()) }
            val gesture = GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(path, 0, 50))
                .build()
            val accepted = dispatchGesture(gesture, null, null)
            Log.d(TAG, "performTapAt accepted=$accepted")
            accepted
        } catch (e: Exception) {
            Log.e(TAG, "performTapAt failed: ${e.message}")
            false
        }
    }

    fun dispatchScroll(xPercent: Double, yPercent: Double, deltaX: Double, deltaY: Double): Boolean {
        try {
            val screenSize = getScreenSize()
            val target = resolvePoint(xPercent, yPercent, screenSize)
            val x = target.x
            val y = target.y

            val scrollAmountX = (-deltaX * 2).toInt()
            val scrollAmountY = (-deltaY * 2).toInt()

            Log.d(TAG, "dispatchScroll: ($x, $y) delta=($scrollAmountX, $scrollAmountY)")

            // rootInActiveWindow 为 null 很常见（窗口内容不可用 / 刚切窗口），
            // 绝不能因此直接 return false —— 那会让滚轮滚动在大多数界面彻底失效。
            // 正确做法是退化到手势滑动。
            val rootNode = rootInActiveWindow
            val node = if (rootNode != null) findScrollableNode(rootNode, x, y) else null

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
                Log.d(TAG, "dispatchScroll: 无可用滚动节点(root=${rootNode != null})，退化为手势滑动")
                performScrollGesture(x, y, scrollAmountX, scrollAmountY, screenSize)
            } else {
                return false
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
                "power" -> GLOBAL_ACTION_POWER_DIALOG
                "screenshot" -> {
                    // 系统级截图需 Android 12(API 31) 及以上
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        GLOBAL_ACTION_TAKE_SCREENSHOT
                    } else {
                        Log.w(TAG, "截图需要 Android 12(S) 及以上")
                        return false
                    }
                }
                else -> return false
            }
            Log.d(TAG, "performGlobalAction: $action")
            return performGlobalAction(actionId)
        } catch (e: Exception) {
            Log.e(TAG, "performGlobalAction failed: ${e.message}")
            return false
        }
    }

    /**
     * 调节媒体音量。
     * @param direction 1 = 增大，-1 = 减小（其他值视为增大）
     */
    fun dispatchVolumeAdjust(direction: Int): Boolean {
        return try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val flag = AudioManager.FLAG_SHOW_UI
            if (direction > 0) {
                audioManager.adjustStreamVolume(
                    AudioManager.STREAM_MUSIC,
                    AudioManager.ADJUST_RAISE,
                    flag,
                )
            } else {
                audioManager.adjustStreamVolume(
                    AudioManager.STREAM_MUSIC,
                    AudioManager.ADJUST_LOWER,
                    flag,
                )
            }
            Log.d(TAG, "dispatchVolumeAdjust: ${if (direction > 0) "+" else "-"}")
            true
        } catch (e: Exception) {
            Log.e(TAG, "dispatchVolumeAdjust failed: ${e.message}")
            false
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

    /**
     * 与 MediaProjection 录屏同一物理屏幕的可视化 Context。
     *
     * 关键：AccessibilityService 的 base context 不保证关联 Display，直接访问
     * `Context.getDisplay()/display` 会抛
     * `UnsupportedOperationException: Tried to obtain display from a Context not
     * associated with one`（正是「无障碍已开启但触控/诊断全失效」的元凶）。
     * 必须先 [Context.createDisplayContext] 出一个可视化上下文，再从它取
     * Display / WindowManager，才能保证触控注入与录屏落在同一个 Display 上。
     */
    @Volatile
    private var cachedVisualContext: Context? = null

    /** 获取默认物理屏幕（不依赖当前 Context 是否已关联 Display） */
    private fun resolveDefaultDisplay(): Display? {
        return try {
            val dm = getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager
            dm?.getDisplay(Display.DEFAULT_DISPLAY)
        } catch (e: Exception) {
            recordDisplayError(e)
            Log.w(TAG, "resolveDefaultDisplay 失败: ${e.message}")
            null
        }
    }

    /** 创建（并缓存）与默认屏幕绑定的可视化 Context */
    private fun visualContext(): Context {
        cachedVisualContext?.let { return it }
        synchronized(this) {
            cachedVisualContext?.let { return it }
            val ctx = try {
                val display = resolveDefaultDisplay()
                if (display != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR1) {
                    val created = createDisplayContext(display)
                    lastDisplayError = null
                    Log.d(TAG, "已创建 display context: displayId=${display.displayId}")
                    created
                } else {
                    this
                }
            } catch (e: Exception) {
                recordDisplayError(e)
                Log.e(TAG, "createDisplayContext 失败，回退 Service context: ${e.message}")
                this
            }
            cachedVisualContext = ctx
            return ctx
        }
    }

    private fun getScreenSize(): Point {
        // 方式1：DisplayManager 默认屏（与 MediaProjection 录屏同源，最可靠）
        try {
            val display = resolveDefaultDisplay()
            if (display != null) {
                val size = Point()
                display.getRealSize(size)
                if (size.x > 0 && size.y > 0) return size
            }
        } catch (e: Exception) {
            recordDisplayError(e)
            Log.w(TAG, "getScreenSize DisplayManager 方式失败: ${e.message}")
        }

        // 方式2：可视化 Context 的 WindowManager
        try {
            val ctx = visualContext()
            val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as? WindowManager
            val size = Point()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                ctx.display?.getRealSize(size)
            } else {
                @Suppress("DEPRECATION")
                wm?.defaultDisplay?.getRealSize(size)
            }
            if (size.x > 0 && size.y > 0) return size
        } catch (e: Exception) {
            recordDisplayError(e)
            Log.w(TAG, "getScreenSize WindowManager 方式失败: ${e.message}")
        }

        // 方式3：系统度量兜底（宁可给个近似值，也不要 0x0 让上层误判「未生效」）
        return try {
            val metrics = resources.displayMetrics
            Point(metrics.widthPixels, metrics.heightPixels)
        } catch (e: Exception) {
            recordDisplayError(e)
            Point(0, 0)
        }
    }

    /** 供 Dart 侧诊断使用：屏幕尺寸快照（内部已兜底，不会抛异常） */
    fun screenSizeForDiagnostics(): Point {
        return try {
            getScreenSize()
        } catch (e: Exception) {
            recordDisplayError(e)
            Point(0, 0)
        }
    }

    /** 供 Dart 侧诊断使用：当前触控注入所用的 displayId（-1 表示拿不到） */
    fun displayIdForDiagnostics(): Int {
        return try {
            resolveDefaultDisplay()?.displayId ?: -1
        } catch (e: Exception) {
            recordDisplayError(e)
            -1
        }
    }

    /**
     * 把归一化坐标(0~1)换算为屏幕像素，并保证落在 [0, width-1] / [0, height-1] 内。
     *
     * 关键：percent 为 1.0 时 `width * 1.0 == width`，该点已在屏幕外，
     * Android 会直接拒绝整条手势（dispatchGesture 返回 false），
     * 因此必须收敛到 width-1。同时兜住屏幕尺寸异常（0）导致的负坐标。
     */
    private fun resolvePoint(xPercent: Double, yPercent: Double, size: Point): Point {
        val maxX = (size.x - 1).coerceAtLeast(0)
        val maxY = (size.y - 1).coerceAtLeast(0)
        val x = (size.x * xPercent.coerceIn(0.0, 1.0)).toInt().coerceIn(0, maxX)
        val y = (size.y * yPercent.coerceIn(0.0, 1.0)).toInt().coerceIn(0, maxY)
        return Point(x, y)
    }

    private fun clearRuntimeState() {
        lastTouchPoint = null
        touchStartPoint = null
        touchMoved = false
        lastTouchAccepted = false
        // 释放 display context 引用，避免服务重建后沿用旧的屏幕上下文
        cachedVisualContext = null
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
