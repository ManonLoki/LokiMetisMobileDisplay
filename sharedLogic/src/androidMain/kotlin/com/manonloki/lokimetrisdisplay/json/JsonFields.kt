package com.manonloki.lokimetrisdisplay.json

import org.json.JSONArray
import org.json.JSONObject

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
/** 缺省/null保留旧端语义，显式空数组保留为已知空集合，不转换其他JSON类型。 */
internal fun JSONObject.optionalStringArray(key: String, max: Int): List<String>? {
    if (!has(key) || isNull(key)) return null
    val value = get(key); require(value is JSONArray && value.length() <= max)
    return (0 until value.length()).map { index -> value.get(index).let { require(it is String); it } }
}
