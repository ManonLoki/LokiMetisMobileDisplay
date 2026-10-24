package com.manonloki.lokimetrisdisplay.json

import com.manonloki.lokimetrisdisplay.domain.ProviderQuotaEntry
import com.manonloki.lokimetrisdisplay.domain.ProviderQuotaSnapshot
import com.manonloki.lokimetrisdisplay.domain.ProviderQuotaWindow
import com.manonloki.lokimetrisdisplay.domain.TerminalAgent
import com.manonloki.lokimetrisdisplay.domain.TerminalAmount
import com.manonloki.lokimetrisdisplay.domain.TerminalAsset
import com.manonloki.lokimetrisdisplay.domain.TerminalDay
import com.manonloki.lokimetrisdisplay.domain.TerminalHook
import com.manonloki.lokimetrisdisplay.domain.TerminalSnapshot
import com.manonloki.lokimetrisdisplay.domain.TerminalTokens
import com.manonloki.lokimetrisdisplay.protocol.TerminalCapabilities
import org.json.JSONArray
import org.json.JSONObject

/** Android线协议语法映射；语义校验统一交KMP领域模型，不使用JSONObject的类型强制转换。 */
object AndroidDisplayJson {
    /** 解密结果仍需验证完整snapshot，不能只凭AEAD成功报告在线。 */
    fun snapshot(message: JSONObject): TerminalSnapshot {
        require(message.string("type") == "snapshot")
        val value = message.obj("snapshot")
        val result = TerminalSnapshot(value.int("version"), value.optionalObject("tokens")?.let(::tokens), value.optionalString("tokenError"),
            value.bool("hooksAvailable"), value.array("hooks", 12).map { item ->
                TerminalHook(item.string("agent"), item.int("slot"), item.string("behavior"), item.string("content"),
                    item.bool("contentTruncated"), item.optionalString("image"))
            }, value.array("assets", 64).map { TerminalAsset(it.string("hash"), it.string("mime"), it.long("length")) },
            value.optionalString("catalogError"), value.optionalObject("providerQuota")?.let(::providerQuota),
            value.optionalStringArray("enabledAgents", 14))
        result.validate()
        return result
    }
    /** 额度JSON只做严格类型映射，值域与排序交由共享领域模型。 */
    private fun providerQuota(value: JSONObject): ProviderQuotaSnapshot = ProviderQuotaSnapshot(
        value.long("observedAtUnix"), value.array("providers", 4).map { item ->
            ProviderQuotaEntry(item.string("provider"), item.optionalString("plan"),
                item.optionalObject("fiveHour")?.let(::quotaWindow), item.optionalObject("weekly")?.let(::quotaWindow),
                item.optionalObject("monthly")?.let(::quotaWindow))
        })
    /** 百分比必须为整数千分比，不接受数字字符串或小数。 */
    private fun quotaWindow(value: JSONObject) = ProviderQuotaWindow(value.string("kind"), value.int("usedTenths"),
        if (!value.has("resetAtUnix") || value.isNull("resetAtUnix")) null else value.long("resetAtUnix"))
    /** 只解析当前解密快照外壳的有界能力，不将缓存当作协商来源。 */
    fun capabilities(message: JSONObject): List<String> {
        if (!message.has("capabilities")) return emptyList()
        val values = message.get("capabilities")
        require(values is JSONArray && values.length() <= TerminalCapabilities.MAX_COUNT)
        return (0 until values.length()).map { values.get(it).let { value -> require(value is String); value } }
    }
    /** 总量与Agent以同轮日界传递，u64字段只接受字符串。 */
    private fun tokens(value: JSONObject): TerminalTokens {
        val day = value.obj("day")
        return TerminalTokens(TerminalDay(day.string("date"), day.string("zone"), day.long("startMs"), day.long("endMs")),
            value.long("observedMs"), amount(value.obj("all")), value.array("agents", 14).map { TerminalAgent(it.string("agent"), amount(it.obj("amount"))) })
    }
    /** JSON整数或浮点不能偷偷转成u64字符串。 */
    private fun amount(value: JSONObject) = TerminalAmount(value.optionalString("total"), value.string("availability"), value.string("completeness"), value.string("confidence"))
    /** 内容寻址资源保持整数字节长度，交同一Rust验证器。 */
    fun asset(value: TerminalAsset): JSONObject = JSONObject().put("hash", value.hash).put("mime", value.mime).put("length", value.length)
}
