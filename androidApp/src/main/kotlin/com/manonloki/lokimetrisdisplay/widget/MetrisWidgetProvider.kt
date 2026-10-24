package com.manonloki.lokimetrisdisplay

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.TextPaint
import android.text.style.BackgroundColorSpan
import android.text.style.ForegroundColorSpan
import android.text.style.RelativeSizeSpan
import android.util.SizeF
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import com.manonloki.lokimetrisdisplay.domain.ProviderQuotaSnapshot
import com.manonloki.lokimetrisdisplay.domain.TerminalSnapshot
import com.manonloki.lokimetrisdisplay.presentation.TokenFormatting
import com.manonloki.lokimetrisdisplay.presentation.quality
import com.manonloki.lokimetrisdisplay.storage.TerminalWidgetSnapshot
import com.manonloki.lokimetrisdisplay.widget.AndroidWidgetStore
import java.text.DateFormat
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** 桌面仅呈现已认证快照的持久化摘要；网络连接由应用统一调度。 */
class MetrisWidgetProvider : AppWidgetProvider() {
    override fun onEnabled(context: Context) {
        AndroidRefreshScheduler.ensureScheduled(context)
    }

    override fun onUpdate(context: Context, manager: AppWidgetManager, appWidgetIds: IntArray) {
        updateIds(context, manager, appWidgetIds)
        AndroidRefreshScheduler.ensureScheduled(context)
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        updateIds(context, appWidgetManager, intArrayOf(appWidgetId))
    }

    override fun onDisabled(context: Context) {
        // 周期任务取决于仍有效的独立读取目标，不以小组件数量或悬浮窗可见性决定。
        AndroidRefreshScheduler.ensureScheduled(context)
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ACTION_REFRESH) {
            AndroidRefreshScheduler.requestNow(context)
        } else {
            super.onReceive(context, intent)
        }
    }

    companion object {
        private const val ACTION_REFRESH = "com.manonloki.lokimetrisdisplay.WIDGET_REFRESH"
        private const val COLOR_TEXT = 0xFFDCEBF0.toInt()
        private const val COLOR_MUTED = 0xFF9BB1BC.toInt()
        private const val COLOR_CYAN = 0xFF64E5E3.toInt()
        private const val COLOR_AMBER = 0xFFF4C675.toInt()
        private const val COLOR_ERROR = 0xFFFF8D99.toInt()
        private const val COLOR_QUOTA_GREEN = 0xFF40C057.toInt()
        private const val COLOR_PLAN_BACKGROUND = 0x3364E5E3
        private const val PLAN_TEXT_SCALE = 0.9f

        /** App、后台轮询或前台推送收到快照后统一刷新所有实例。 */
        fun updateAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            updateIds(context, manager, manager.getAppWidgetIds(ComponentName(context, MetrisWidgetProvider::class.java)))
        }

        /** 返回启动器是否接受了添加请求；最终放置仍由系统确认。 */
        fun requestPin(context: Context): Boolean {
            val manager = AppWidgetManager.getInstance(context)
            if (!manager.isRequestPinAppWidgetSupported) return false
            return manager.requestPinAppWidget(ComponentName(context, MetrisWidgetProvider::class.java), null, null)
        }

        private fun updateIds(context: Context, manager: AppWidgetManager, ids: IntArray) {
            if (ids.isEmpty()) return
            val cached = AndroidWidgetStore(context).read()
            for (id in ids) {
                // Android 12+ 在旋转和折叠时直接选择合适视图，避免一次尺寸变化再唤醒网络。
                val layouts = linkedMapOf(
                    SizeF(130f, 110f) to render(context, id, cached, compact = true, wide = false),
                    SizeF(240f, 110f) to render(context, id, cached, compact = true, wide = true),
                    SizeF(130f, 196f) to render(context, id, cached, compact = false, wide = false),
                    SizeF(240f, 196f) to render(context, id, cached, compact = false, wide = true),
                    SizeF(130f, 232f) to render(context, id, cached, compact = false, wide = false, quotaProviderLimit = 2),
                    SizeF(240f, 232f) to render(context, id, cached, compact = false, wide = true, quotaProviderLimit = 2),
                    SizeF(130f, 268f) to render(context, id, cached, compact = false, wide = false, quotaProviderLimit = 3),
                    SizeF(240f, 268f) to render(context, id, cached, compact = false, wide = true, quotaProviderLimit = 3),
                )
                manager.updateAppWidget(id, RemoteViews(layouts))
            }
        }

        private fun render(
            context: Context,
            id: Int,
            cached: TerminalWidgetSnapshot?,
            compact: Boolean,
            wide: Boolean,
            quotaProviderLimit: Int = 1,
        ): RemoteViews {
            val views = RemoteViews(context.packageName, if (compact) R.layout.metris_widget_compact else R.layout.metris_widget)
            val open = PendingIntent.getActivity(
                context, id, Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val refresh = PendingIntent.getBroadcast(
                context, id, Intent(context, MetrisWidgetProvider::class.java).setAction(ACTION_REFRESH),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            views.setOnClickPendingIntent(R.id.metris_widget_root, open)
            views.setOnClickPendingIntent(R.id.metris_widget_refresh, refresh)
            if (compact) views.setViewVisibility(R.id.metris_widget_side, if (wide) View.VISIBLE else View.GONE)

            val snapshot = cached?.snapshot
            val tokens = snapshot?.displayTokens
            val amount = tokens?.all
            val precise = amount?.text ?: context.getString(R.string.metris_widget_waiting_data)
            val amountText = amount?.let { TokenFormatting.compactForWidget(it.text) } ?: if (snapshot != null) "不可用" else "—"
            val quality = when {
                amount == null && snapshot == null -> context.getString(R.string.metris_widget_open_to_pair)
                amount == null -> "Token 暂不可用"
                amount.quality.isNotEmpty() -> amount.quality
                amount.availability == "available" -> "完整 · 精确"
                else -> amount.text
            }
            val hooks = hookSummary(context, snapshot)
            val status = if (snapshot == null) context.getString(R.string.metris_widget_open_to_pair) else null
            val quota = if (!compact || wide) quotaSummary(context, snapshot?.displayProviderQuota, quotaProviderLimit, compact, wide) else null
            val syncTime = cached?.let { dateTime(it.receivedAtMs) }
            val syncText = cached?.let {
                if (compact || quota != null) compactSyncTime(it.receivedAtMs) else "上次同步 $syncTime"
            } ?: context.getString(R.string.metris_widget_never_synced)

            views.setTextViewText(R.id.metris_widget_title,
                if (compact && tokens != null) tokens.day.date else context.getString(R.string.metris_widget_title))
            views.setTextViewText(R.id.metris_widget_amount, amountText)
            views.setContentDescription(R.id.metris_widget_amount, "Token 用量：$precise，$quality")
            views.setTextColor(R.id.metris_widget_amount, if (amount?.availability == "available") COLOR_CYAN else COLOR_MUTED)
            // 此行只保留首次连接提示；统计质量仅进入辅助功能描述。
            views.setTextViewText(R.id.metris_widget_quality, status.orEmpty())
            views.setTextColor(R.id.metris_widget_quality, COLOR_MUTED)
            views.setViewVisibility(R.id.metris_widget_quality, if (status == null) View.GONE else View.VISIBLE)
            views.setViewVisibility(R.id.metris_widget_quota, if (quota == null) View.GONE else View.VISIBLE)
            views.setTextViewText(R.id.metris_widget_quota, quota?.text ?: "")
            views.setContentDescription(R.id.metris_widget_quota, quota?.description.orEmpty())
            views.setTextColor(R.id.metris_widget_quota, COLOR_TEXT)
            if (!compact && quota != null) {
                views.setInt(R.id.metris_widget_quota, "setMaxLines", quota.rows)
                views.setViewLayoutHeight(R.id.metris_widget_quota, 18f * quota.rows, TypedValue.COMPLEX_UNIT_DIP)
            }
            views.setTextViewText(R.id.metris_widget_hooks, hooks)
            views.setTextViewText(R.id.metris_widget_synced, syncText)
            views.setContentDescription(R.id.metris_widget_synced,
                syncTime?.let { "最近同步 $it，显示最近一次同步的数据" } ?: context.getString(R.string.metris_widget_never_synced))
            if (!compact) {
                val exact = if (wide) TokenFormatting.exact(precise) else precise
                views.setTextViewText(R.id.metris_widget_exact, exact)
                views.setContentDescription(R.id.metris_widget_exact, "精确 Token 用量：$precise")
                views.setTextViewText(R.id.metris_widget_day, tokens?.day?.date ?: context.getString(R.string.metris_widget_waiting_day))
                views.setContentDescription(R.id.metris_widget_day,
                    tokens?.day?.let { "桌面统计日期 ${it.date}，时区 ${it.zone}" } ?: context.getString(R.string.metris_widget_waiting_day))
            }
            views.setContentDescription(R.id.metris_widget_root, buildString {
                append("${context.getString(R.string.app_name)}，Token 用量：$precise，$quality。")
                tokens?.day?.let { append("桌面统计日期 ${it.date}，时区 ${it.zone}。") }
                quota?.let { append(it.description).append("。") }
                append(hooks.toString().replace('\n', '，'))
                append("。")
                append(syncTime?.let { "最近同步 $it。" } ?: "尚未同步。")
                append("点击打开应用查看详情。")
            })
            return views
        }

        private data class QuotaSummary(val text: CharSequence, val description: String, val rows: Int)

        /** 按尺寸限制可见账户数；每个可见账户依次展示已有的每月、每周、5h 窗口。 */
        private fun quotaSummary(context: Context, quota: ProviderQuotaSnapshot?, providerLimit: Int, compact: Boolean, wide: Boolean): QuotaSummary? {
            val providers = quota?.providers.orEmpty().filter { it.windows.isNotEmpty() }
            if (providers.isEmpty()) return null
            val visible = providers.take(providerLimit)
            val hiddenCount = providers.size - visible.size
            val description = providers.flatMap { provider -> provider.windows.map { window ->
                "${provider.label}${provider.planLabel?.let { "，套餐 $it" }.orEmpty()} ${window.kindLabel}额度剩余 ${window.percentText}"
            } }.joinToString("；")
            val metrics = context.resources.displayMetrics
            val paint = TextPaint().apply {
                textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, 11f, metrics)
            }
            // 使用各响应式布局的最小可用宽度；只有完整行在常规字号下放得下才补充套餐。
            val availableWidth = (if (compact) 80f else if (wide) 216f else 106f) * metrics.density
            val text = SpannableStringBuilder().apply {
                visible.forEachIndexed { index, provider ->
                    if (index > 0) append("\n")
                    append(provider.label)
                    provider.planLabel?.let { plan ->
                        val tag = "\u00a0$plan\u00a0"
                        val suffix = if (compact) {
                            if (hiddenCount > 0) " +$hiddenCount" else ""
                        } else {
                            provider.windows.joinToString(" ", prefix = " ") { "${it.kindLabel}${it.percentText}" } +
                                if (wide && index == visible.lastIndex && hiddenCount > 0) " +$hiddenCount" else ""
                        }
                        val plainWidth = paint.measureText(provider.label + " " + suffix)
                        val tagWidth = paint.measureText(tag) * PLAN_TEXT_SCALE
                        if (plainWidth + tagWidth <= availableWidth) {
                            append(" ")
                            val start = length
                            append(tag)
                            // RemoteViews 仅携带 Android 系统 spans，启动器无需加载应用内自定义类。
                            setSpan(BackgroundColorSpan(COLOR_PLAN_BACKGROUND), start, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                            setSpan(ForegroundColorSpan(COLOR_CYAN), start, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                            setSpan(RelativeSizeSpan(PLAN_TEXT_SCALE), start, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                        }
                    }
                    if (compact && hiddenCount > 0) append(" +$hiddenCount")
                    if (compact) append("\n") else append(" ")
                    provider.windows.forEachIndexed { windowIndex, window ->
                        if (windowIndex > 0) append(" ")
                        val start = length
                        append("${window.kindLabel}${window.percentText}")
                        val color = when (window.level) { 0 -> COLOR_ERROR; 1 -> COLOR_AMBER; else -> COLOR_QUOTA_GREEN }
                        setSpan(ForegroundColorSpan(color), start, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    }
                }
                if (!compact && wide && hiddenCount > 0) append(" +$hiddenCount")
            }
            return QuotaSummary(text, description, if (compact) 2 else visible.size)
        }

        private fun hookSummary(context: Context, snapshot: TerminalSnapshot?): CharSequence {
            if (snapshot == null) return context.getString(R.string.metris_widget_waiting_hooks)
            if (!snapshot.hooksAvailable) return "Hooks 暂不可用"
            val counts = snapshot.hooks.groupingBy { it.behavior }.eachCount()
            val parts = listOf("运行" to "running", "询问" to "asking", "出错" to "error", "空闲" to "idle")
            return SpannableStringBuilder().apply {
                parts.forEachIndexed { index, (label, state) ->
                    if (index > 0) append(if (index == 2) "\n" else " · ")
                    val start = length
                    append("$label ${counts[state] ?: 0}")
                    val color = when (state) { "running" -> COLOR_CYAN; "asking" -> COLOR_AMBER; "error" -> COLOR_ERROR; else -> COLOR_TEXT }
                    setSpan(ForegroundColorSpan(color), start, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
            }
        }

        private fun dateTime(ms: Long): String = DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date(ms))

        private fun compactSyncTime(ms: Long): String {
            val today = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault())
            val pattern = if (today.format(Date()) == today.format(Date(ms))) "HH:mm" else "MM-dd HH:mm"
            return "上次 " + SimpleDateFormat(pattern, Locale.getDefault()).format(Date(ms))
        }

    }
}
