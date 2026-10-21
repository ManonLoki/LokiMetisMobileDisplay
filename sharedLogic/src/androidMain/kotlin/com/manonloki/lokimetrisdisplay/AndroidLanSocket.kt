package com.manonloki.lokimetrisdisplay

import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.channels.SelectionKey
import java.nio.channels.Selector
import java.nio.channels.SocketChannel
import java.util.ArrayDeque

/** 单一selector线程持有非阻塞TCP、帧和八项写队列；所有异常交owner关闭原连接。 */
class AndroidLanSocket(endpoint: AndroidLanEndpoint, selector: Selector,
    private val limit: () -> Int, private val ready: () -> Unit,
    private val received: (JSONObject) -> Unit,
) : AutoCloseable {
    /** 每个写操作都有独立完成点，握手确认完整写出后才发送加密设备信息。 */
    private data class Write(val buffer: ByteBuffer, val completed: () -> Unit, var started: Long = 0)
    private val channel = SocketChannel.open()
    private val key: SelectionKey
    private val frames = TerminalFrames()
    private val writes = ArrayDeque<Write>()
    private val readBuffer = ByteBuffer.allocate(16_384)
    private var closed = false
    init {
        try {
            channel.configureBlocking(false); endpoint.network?.bindSocket(channel.socket())
            channel.connect(endpoint.address)
            key = channel.register(selector, if (channel.isConnected) SelectionKey.OP_READ else SelectionKey.OP_CONNECT)
        } catch (error: Exception) { channel.close(); throw error }
    }
    /** 已立即建立的本地连接仍在owner赋值socket后才触发ready。 */
    fun begin() { if (channel.isConnected) ready() }
    /** 一次就绪事件只操作本实例精确key，收发错误不在原nonce流重试。 */
    fun process(now: Long) {
        if (closed || !key.isValid) return
        if (key.isConnectable && channel.finishConnect()) { key.interestOps(SelectionKey.OP_READ); ready() }
        if (closed || !key.isValid) return
        if (key.isWritable) {
            while (writes.isNotEmpty()) {
                val write = writes.first()
                if (write.started == 0L) write.started = now
                channel.write(write.buffer)
                if (write.buffer.hasRemaining()) break
                writes.removeFirst(); write.completed()
                if (closed) return
            }
            if (writes.isEmpty()) key.interestOps(key.interestOps() and SelectionKey.OP_WRITE.inv())
        }
        if (closed || !key.isValid) return
        if (key.isReadable) {
            readBuffer.clear(); val count = channel.read(readBuffer)
            check(count >= 0) { "lan_socket_ended" }
            if (count > 0) {
                val bytes = ByteArray(count); readBuffer.flip(); readBuffer.get(bytes)
                frames.append(bytes, limit) { raw ->
                    val text = Charsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(raw)).toString()
                    TerminalJsonBoundary.validateObject(text)
                    received(JSONObject(text))
                }
            }
        }
    }
    /** 密文已经生成后入队也可能失败；调用方必须把任何失败提升到连接终止。 */
    fun send(value: JSONObject, max: Int, completed: () -> Unit = {}) {
        check(!closed && writes.size < 8) { "lan_write_overflow" }
        val bytes = value.toString().toByteArray(Charsets.UTF_8); require(bytes.size in 1..max)
        val buffer = ByteBuffer.allocate(bytes.size + 4).putInt(bytes.size).put(bytes).apply { flip() }
        writes.add(Write(buffer, completed))
        if (channel.isConnected) key.interestOps(key.interestOps() or SelectionKey.OP_WRITE)
    }
    /** 首项写从入队即限两秒，慢对端不能累积无界内存或永久占有连接。 */
    fun tick(now: Long) {
        writes.peekFirst()?.let { if (it.started == 0L) it.started = now else check(now - it.started < 2_000) { "lan_write_timeout" } }
    }
    /** 关闭自身channel及排队回调，代次由owner管理，不误关后继连接。 */
    override fun close() { if (!closed) { closed = true; key.cancel(); channel.close(); writes.clear() } }
}
