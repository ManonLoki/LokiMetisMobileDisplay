package com.manonloki.lokimetrisdisplay

import org.json.JSONObject

/** 单一网络owner串行调用；字节数组保留真实UTF-8，不跨JNI传秘密String。 */
class NativeLinkBridge(deviceId: String, name: String) : AutoCloseable {
    /** 核心协议错误与可降级的磁盘IO错误分开，协议失败必须终止当前会话。 */
    class Failure : IllegalStateException("mobile_protocol_failed")
    private var handle = create(JSONObject().put("deviceId", deviceId).put("name", name).toString().toByteArray(Charsets.UTF_8))
    init { check(handle != 0L) { "mobile_native_unavailable" } }

    /** 结果中的material只能交Keystore私有保存，禁止进入日志或界面状态。 */
    fun call(command: JSONObject): JSONObject {
        check(handle != 0L) { "mobile_handle_closed" }
        val input = command.toString().toByteArray(Charsets.UTF_8)
        val raw = try { invoke(handle, input) } finally { input.fill(0) }
            ?: error("mobile_native_unavailable")
        val value = try {
            val text = Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(raw)).toString()
            TerminalJsonBoundary.validateObject(text); JSONObject(text)
        } finally { raw.fill(0) }
        if (!value.bool("ok")) throw Failure()
        return value.obj("result")
    }

    /** 缓存复用前核对真实私有文件正文；缺失或损坏必须重新下载。 */
    fun validAsset(descriptor: JSONObject, bytes: ByteArray): Boolean =
        validateAsset(descriptor.toString().toByteArray(Charsets.UTF_8), bytes)

    override fun close() { if (handle != 0L) { destroy(handle); handle = 0 } }

    private external fun create(identity: ByteArray): Long
    private external fun invoke(handle: Long, input: ByteArray): ByteArray?
    private external fun destroy(handle: Long)
    private external fun validateAsset(descriptor: ByteArray, bytes: ByteArray): Boolean

    companion object {
        init { System.loadLibrary("loki_metris_mobile_bridge"); System.loadLibrary("loki_metris_jni") }
    }
}
