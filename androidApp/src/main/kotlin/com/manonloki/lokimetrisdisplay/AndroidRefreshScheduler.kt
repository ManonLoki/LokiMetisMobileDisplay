package com.manonloki.lokimetrisdisplay

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** 系统持久化周期任务；15分钟是请求间隔，省电、配额和网络状态仍由Android决定。 */
object AndroidRefreshScheduler {
    const val PERIODIC_JOB = 0x4c4d01
    const val MANUAL_JOB = 0x4c4d02
    const val INTERVAL_MS = 15 * 60 * 1000L

    fun ensureScheduled(context: Context) {
        val scheduler = context.getSystemService(JobScheduler::class.java) ?: return
        val owner = context.applicationContext as? DisplayApplication
        val configured = runCatching { AndroidWidgetStore(context).target()?.let { owner?.widgetTargetPermitted(it) } == true }.getOrDefault(false)
        if (!configured) { scheduler.cancel(PERIODIC_JOB); return }
        val network = localNetwork()
        val pending = scheduler.getPendingJob(PERIODIC_JOB)
        if (pending?.intervalMillis == INTERVAL_MS && pending.requiredNetwork == network) return
        runCatching {
            scheduler.schedule(JobInfo.Builder(PERIODIC_JOB, ComponentName(context, AndroidRefreshJob::class.java))
                .setRequiredNetwork(network)
                .setPeriodic(INTERVAL_MS, 5 * 60 * 1000L)
                .setPersisted(true).build())
        }
    }

    /** 组件刷新按钮也只提交系统工作；BroadcastReceiver从不阻塞网络或持有秘密。 */
    fun requestNow(context: Context): Boolean {
        ensureScheduled(context)
        return runCatching {
            context.getSystemService(JobScheduler::class.java).schedule(
                JobInfo.Builder(MANUAL_JOB, ComponentName(context, AndroidRefreshJob::class.java))
                    .setRequiredNetwork(localNetwork())
                    .setMinimumLatency(0).build()) == JobScheduler.RESULT_SUCCESS
        }.getOrDefault(false)
    }

    /** LAN 不要求可访问互联网，避免无WAN的Wi-Fi被NETWORK_TYPE_ANY排除。 */
    private fun localNetwork(): NetworkRequest = NetworkRequest.Builder()
        .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
        .addTransportType(NetworkCapabilities.TRANSPORT_ETHERNET)
        .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        .removeCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        .build()
}

/** 每次系统唤醒仅执行一次有界HTTP拉取，不配对、不下载图片、不另起常驻服务。 */
class AndroidRefreshJob : JobService() {
    private data class Run(val params: JobParameters, val client: AndroidWidgetHttpClient,
        val cancelled: AtomicBoolean = AtomicBoolean(false))
    private var current: Run? = null

    override fun onStartJob(params: JobParameters): Boolean {
        if (current != null || !busy.compareAndSet(false, true)) return false
        val owner = application as DisplayApplication
        if (!owner.permitted() || owner.settings == null) { busy.set(false); return false }
        val run = Run(params, AndroidWidgetHttpClient(this))
        current = run
        executor.submit {
            var saved = false
            try {
                val store = AndroidWidgetStore(this)
                val target = store.target()
                if (target != null && owner.widgetTargetPermitted(target) && !run.cancelled.get()) {
                    val result = run.client.fetch(target)
                    synchronized(run) { if (!run.cancelled.get() && owner.widgetTargetPermitted(target)) saved = store.acceptFetched(target, result) }
                }
            } catch (_: Exception) {
                // 失败保留上次摘要及其真实时间，下次周期或手动刷新继续尝试。
            } finally {
                busy.set(false)
                android.os.Handler(mainLooper).post {
                    if (current === run) {
                        current = null
                        if (saved) MetrisWidgetProvider.updateAll(this)
                        if (!run.cancelled.get()) jobFinished(params, false)
                    }
                }
            }
        }
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean {
        current?.takeIf { it.params.jobId == params.jobId }?.let {
            synchronized(it) { it.cancelled.set(true) }; it.client.cancel(); current = null
        }
        return false
    }

    override fun onDestroy() {
        current?.let { synchronized(it) { it.cancelled.set(true) }; it.client.cancel() }; current = null
        super.onDestroy()
    }

    companion object {
        private val busy = AtomicBoolean(false)
        private val executor = Executors.newSingleThreadExecutor { Thread(it, "loki-widget-refresh").apply { isDaemon = true } }
    }
}
