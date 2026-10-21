package com.manonloki.lokimetrisdisplay

import org.json.JSONObject
import org.json.JSONArray

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
            value.optionalString("catalogError"), value.optionalObject("providerQuota")?.let(::providerQuota))
        result.validate()
        return result
    }
    /** 额度JSON只做严格类型映射，值域与排序交由共享领域模型。 */
    private fun providerQuota(value: JSONObject): ProviderQuotaSnapshot = ProviderQuotaSnapshot(
        value.long("observedAtUnix"), value.array("providers", 3).map { item ->
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
        require(values is JSONArray && values.length() <= 16)
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

/** 必填字符串不接受数字、布尔或JSON空值的隐式转换。 */
internal fun JSONObject.string(key: String): String = get(key).let { require(it is String); it }
/** 可空字符串允许省略或null，其余类型失败。 */
internal fun JSONObject.optionalString(key: String): String? = if (!has(key) || isNull(key)) null else string(key)
/** 必填布尔只接受JSON布尔。 */
internal fun JSONObject.bool(key: String): Boolean = get(key).let { require(it is Boolean); it }
/** i64只接受解析器整数，不接受double或数字字符串。 */
internal fun JSONObject.long(key: String): Long = get(key).let { require(it is Int || it is Long); (it as Number).toLong() }
/** 小整数同时检查i32边界。 */
internal fun JSONObject.int(key: String): Int = long(key).let { require(it in Int.MIN_VALUE..Int.MAX_VALUE); it.toInt() }
/** 必填对象拒绝数组或JSON字符串。 */
internal fun JSONObject.obj(key: String): JSONObject = get(key).let { require(it is JSONObject); it }
/** 可空对象允许协议缺失值，不能静默丢弃类型错误。 */
internal fun JSONObject.optionalObject(key: String): JSONObject? = if (!has(key) || isNull(key)) null else obj(key)
/** 数组有宿主容量边界，全部元素必须为对象。 */
internal fun JSONObject.array(key: String, max: Int): List<JSONObject> {
    val value = get(key); require(value is JSONArray && value.length() <= max)
    return (0 until value.length()).map { index -> value.get(index).let { require(it is JSONObject); it } }
}
