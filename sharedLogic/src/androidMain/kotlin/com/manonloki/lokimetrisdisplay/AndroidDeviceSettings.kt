package com.manonloki.lokimetrisdisplay

import android.content.Context
import android.os.Build
import java.util.UUID

/** 复用原广播应用的身份位置；损坏的既有UUID失败关闭，不能悄悄建立另一设备身份。 */
class AndroidDeviceSettings(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences("mdns_identity", Context.MODE_PRIVATE)
    val deviceId: String
    @Volatile var name: String; private set
    @Volatile var panel: PanelConfiguration; private set
    init {
        AndroidPairingRecoveryStore.replayPending(context)
        val existing = preferences.getString("device_id", null)
        require(existing == null || MdnsProtocol.isCanonicalDeviceId(existing)) { "device_identity_invalid" }
        deviceId = existing ?: UUID.randomUUID().toString()
        name = preferences.getString("device_name", null)?.takeIf { MdnsProtocol.nameError(it) == null }
            ?: Build.MODEL.trim().takeIf { MdnsProtocol.nameError(it) == null } ?: "Android 显示端"
        val savedPanel = preferences.all
        panel = PanelConfiguration.restore(
            showUsage = savedPanel["panel.show_usage"] as? Boolean ?: true,
            showHooks = savedPanel["panel.show_hooks"] as? Boolean ?: true,
            detail = savedPanel["panel.usage_detail"] as? String,
            hookLayout = savedPanel["panel.hook_layout"] as? String,
        )
        check(preferences.edit().putString("device_id", deviceId).putString("device_name", name).commit()) { "device_identity_unavailable" }
    }
    /** 设置保存只改变下次认证使用的名称，不启动或重启网络。 */
    fun saveName(value: String): Boolean {
        if (MdnsProtocol.nameError(value) != null) return false
        if (!preferences.edit().putString("device_name", value).commit()) return false
        name = value
        return true
    }
    /** 布局一次完整提交，重启和切页恢复同一组显示偏好。 */
    fun savePanel(value: PanelConfiguration): Boolean {
        if (!preferences.edit()
                .putBoolean("panel.show_usage", value.showUsage)
                .putBoolean("panel.show_hooks", value.showHooks)
                .putString("panel.usage_detail", value.usageDetail.key)
                .remove("panel.usage_size") // 旧版卡片尺寸已不再使用，保存时顺带清理。
                .putString("panel.hook_layout", value.hookLayout.key).commit()) return false
        panel = value
        return true
    }
}
