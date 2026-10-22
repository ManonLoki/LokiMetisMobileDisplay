package com.manonloki.lokimetrisdisplay

import org.json.JSONObject

/** 按用户选择兼容既有 Android PAD 协议；本机 UUID 与名称仍属于此 Desktop 安装。 */
internal class DesktopPadIdentity(private val deviceId: String) {
    private val report = TerminalDeviceTypeReport(TerminalDeviceType.TABLET)
    fun metadata(name: String): JSONObject = JSONObject().put("deviceId", deviceId).put("name", name)
        .put("platform", "android").put("appVersion", "1.0.7-desktop-experimental")
    fun afterSnapshot(capabilities: List<String>): JSONObject? = report.afterAuthenticatedSnapshot(capabilities)?.let {
        JSONObject().put("type", "deviceFormFactor").put("formFactor", it.wireValue)
    }
    fun reset() = report.reset()
}
