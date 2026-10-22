package com.manonloki.lokimetrisdisplay

/** 仅成功提交的记录才成为当前进程权威状态；系统偏好写失败后的内存变化不能冒充落盘。 */
class CommittedRecords(initial: Map<String, String>) {
    private var records = initial.toMap()
    /** 返回只读 Map；调用方须通过 update 提交，不得强制转换后修改底层集合。 */
    fun snapshot(): Map<String, String> = records
    /** 持久层总是接收完整下一版，失败时保留所有旧记录和忘记入口。 */
    fun update(key: String, value: String?, persist: (Map<String, String>) -> Boolean): Boolean {
        val next = if (value == null) records - key else records + (key to value)
        if (!persist(next)) return false
        records = next
        return true
    }
}
