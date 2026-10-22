package com.manonloki.lokimetrisdisplay

import android.app.Activity
import android.app.Application
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import java.util.concurrent.atomic.AtomicBoolean

/** 应用而非Activity持有连接；屏幕旋转不重开配对窗口，真后台才暂停。 */
class DisplayApplication : Application(), Application.ActivityLifecycleCallbacks {
    @Volatile var settings: AndroidDeviceSettings? = null; private set
    var link: AndroidLanEngine? = null; private set
    private val main = Handler(Looper.getMainLooper())
    private var started = 0
    private var delayedStop: Runnable? = null
    private val projectionListeners = linkedSetOf<(AndroidLinkProjection) -> Unit>()
    private val surfaceUpdateQueued = AtomicBoolean(false)

    /** 首次构造复用既有身份；身份存储失败交界面显示，不用新UUID掩盖。 */
    override fun onCreate() {
        super.onCreate()
        try {
            settings = AndroidDeviceSettings(this)
            createLink(requireNotNull(settings))
        }
        catch (_: Exception) { settings = null; link = null }
        registerActivityLifecycleCallbacks(this)
        AndroidRefreshScheduler.ensureScheduled(this)
    }
    private fun createLink(settings: AndroidDeviceSettings) {
        link = AndroidLanEngine(this, settings) {
            if (surfaceUpdateQueued.compareAndSet(false, true)) {
                main.post {
                    surfaceUpdateQueued.set(false)
                    MetrisWidgetProvider.updateAll(this)
                    AndroidRefreshScheduler.ensureScheduled(this)
                }
            }
        }
        link?.setListener { value -> projectionListeners.toList().forEach { it(value) } }
    }
    /** 后台独立读取配置也必须属于当前持久身份及已提交的桌面配对。 */
    fun widgetTargetPermitted(target: AndroidWidgetTarget): Boolean {
        if (settings?.deviceId != target.deviceId) return false
        return runCatching { target.sourceId in AndroidPairingStore(this, target.deviceId).clientIds() }.getOrDefault(false)
    }
    /** 用户完成本地网络权限选择后刷新应用前台事实。 */
    fun permissionChanged() { link?.setForeground(started > 0, permitted()) }
    /** Activity与悬浮窗各自订阅；任一消费者退出不会覆盖另一消费者。 */
    fun addProjectionListener(listener: (AndroidLinkProjection) -> Unit) {
        check(Looper.myLooper() == Looper.getMainLooper())
        projectionListeners.add(listener); link?.state?.let(listener)
    }
    /** 精确移除单个消费者，其余订阅保持不变。 */
    fun removeProjectionListener(listener: (AndroidLinkProjection) -> Unit) { projectionListeners.remove(listener) }
    /** 只有已启动并显示通知的服务延长连接，生命周期结束立即归还。 */
    fun setBackgroundConnection(enabled: Boolean) {
        link?.setBackgroundConnection(enabled)
        permissionChanged()
    }
    /** API37之前不发起不存在的权限申请；系统API负责实际网络访问裁决。 */
    fun permitted(): Boolean = Build.VERSION.SDK_INT < 37 || checkSelfPermission(LOCAL_NETWORK_PERMISSION) == PackageManager.PERMISSION_GRANTED
    /** 新Activity立即接管，取消尚未执行的后台暂停。 */
    override fun onActivityStarted(activity: Activity) {
        if (activity !is MainActivity) return
        started++; delayedStop?.let(main::removeCallbacks); delayedStop = null
        link?.setForeground(true, permitted())
    }
    /** 配置重建期间保留owner，真实离开应用则短暂合并后关闭局域网连接。 */
    override fun onActivityStopped(activity: Activity) {
        if (activity !is MainActivity) return
        started = maxOf(0, started - 1)
        if (started > 0 || activity.isChangingConfigurations) return
        val task = Runnable { if (started == 0) link?.setForeground(false, permitted()) }
        delayedStop = task; main.postDelayed(task, 300)
    }
    /** 其余Activity事件不拥有网络生命周期。 */
    override fun onActivityCreated(activity: Activity, state: Bundle?) = Unit
    /** 恢复事件不重置配对预算。 */
    override fun onActivityResumed(activity: Activity) = Unit
    /** 权限弹窗导致的pause不等于后台。 */
    override fun onActivityPaused(activity: Activity) = Unit
    /** 视图状态由Compose保存，与连接状态独立。 */
    override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) = Unit
    /** Activity销毁不关闭应用owner。 */
    override fun onActivityDestroyed(activity: Activity) = Unit
    companion object { const val LOCAL_NETWORK_PERMISSION = "android.permission.ACCESS_LOCAL_NETWORK" }
}
