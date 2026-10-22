package com.manonloki.lokimetrisdisplay

/** 只共享容量与长度规则，平台保留原生字节缓冲，避免跨语言复制大块网络数据。 */
object TerminalFramePolicy {
    const val PREFIX_BYTES = 4
    const val MAX_READ_BYTES = 16_384
    const val MAX_FRAME_BYTES = 98_304
    const val MAX_BUFFER_BYTES = MAX_FRAME_BYTES + PREFIX_BYTES + MAX_READ_BYTES

    /** 用减法检查容量，恶意大小输入不会使 Int 加法先溢出。 */
    fun canAppend(bufferedBytes: Int, incomingBytes: Int): Boolean =
        bufferedBytes >= 0 && incomingBytes in 0..MAX_READ_BYTES && bufferedBytes <= MAX_BUFFER_BYTES - incomingBytes

    /** 包头解出为无符号 32 位长度后，以 Long 搬运，未收到正文也能拒绝超界。 */
    fun validPayloadLength(length: Long, limit: Int): Boolean = length >= 1 && length <= limit.toLong()
}

/** 两种 Socket 适配共用的有界写队列合同，不拥有平台完成回调。 */
object TerminalWritePolicy {
    const val MAX_PENDING_FRAMES = 8
    const val TIMEOUT_MS = 2_000L

    fun canEnqueue(queuedFrames: Int, separateInFlight: Boolean): Boolean =
        queuedFrames >= 0 && queuedFrames < MAX_PENDING_FRAMES - (if (separateInFlight) 1 else 0)

    fun timedOut(startedAtMs: Long, nowMs: Long): Boolean =
        nowMs >= startedAtMs && startedAtMs >= 0 && nowMs - startedAtMs >= TIMEOUT_MS
}
