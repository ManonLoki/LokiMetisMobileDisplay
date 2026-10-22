package com.manonloki.lokimetrisdisplay

/** 有界半帧累积器；阶段上限每次读帧重新取值，拒绝超大头后无需分配正文。 */
class TerminalFrames {
    private var bytes = ByteArray(0)
    /** 单次socket读取最多16KiB，处理回调可在同一包内切换握手阶段。 */
    fun append(input: ByteArray, limit: () -> Int, received: (ByteArray) -> Unit) {
        require(TerminalFramePolicy.canAppend(bytes.size, input.size))
        bytes += input
        while (bytes.size >= 4) {
            val size = (bytes[0].toLong() and 255 shl 24) or (bytes[1].toLong() and 255 shl 16) or
                (bytes[2].toLong() and 255 shl 8) or (bytes[3].toLong() and 255)
            require(TerminalFramePolicy.validPayloadLength(size, limit()))
            if (bytes.size < size + 4) return
            val count = size.toInt() + 4
            val frame = bytes.copyOfRange(4, count)
            bytes = bytes.copyOfRange(count, bytes.size)
            received(frame)
        }
    }
}

/** 前台自动发现与有界传输重试，不拥有密码预算或首次配对动作。 */
class TerminalConnectionPolicy {
    var requested = false; private set
    var attempts = 0; private set
    /** 首次启动与返回前台都发现候选，无配对记录也无需手动开启。 */
    fun enterForeground() { requested = true; attempts = 0 }
    /** 后台或权限不可用时暂停，重试操作不能在后台重新开启。 */
    fun leaveForeground() { requested = false; attempts = 0 }
    /** 用户重试只刷新当前前台连接的传输预算。 */
    fun discover() { attempts = 0 }
    /** 新端点或成功快照重置传输预算，不重置Rust密码窗口。 */
    fun renewedEndpoint() { attempts = 0 }
    /** 已认证完整快照成功后，为下一次断开重置传输预算。 */
    fun connected() { attempts = 0 }
    /** 只有已保存信任才自动连接；未配对候选始终等待用户明确选择。 */
    fun automaticSelection(selectedId: String?, paired: Set<String>, available: List<String>): String? {
        if (!requested || attempts >= 8) return null
        return if (selectedId != null) selectedId.takeIf { it in paired && it in available }
        else available.firstOrNull { it in paired }
    }
    /** 最多八次新socket，之后等待真实新端点、前台恢复或用户重试。 */
    fun nextDelayMs(): Long? {
        if (!requested || attempts >= 8) return null
        return minOf(8_000L, 500L shl attempts++)
    }
}

/** 同一轮只保留用户最后明确的连接操作。 */
sealed interface TerminalUserIntent {
    /** 重试当前前台发现，不创建新的密码窗口。 */
    data object Discover : TerminalUserIntent
    /** 选择确切桌面，首次配对窗口由执行时的信任状态决定。 */
    data class Select(val id: String) : TerminalUserIntent
}

/** 有界最新意图槽；跨线程调用的同步由宿主adapter提供。 */
class TerminalPendingIntent {
    private var latest: TerminalUserIntent? = null
    /** 后提交的明确操作替换旧操作，不依赖普通命令队列的执行顺序。 */
    fun submit(value: TerminalUserIntent) { latest = value }
    /** worker一次取走当前最新意图，不重复执行已处理操作。 */
    fun take(): TerminalUserIntent? = latest.also { latest = null }
    /** 忘记某桌面撤销尚未执行的同桌面选择，不能意外重新打开密码窗口。 */
    fun forget(id: String) { if ((latest as? TerminalUserIntent.Select)?.id == id) latest = null }
}
