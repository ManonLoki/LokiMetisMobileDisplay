package com.manonloki.lokimetrisdisplay.storage

import com.manonloki.lokimetrisdisplay.domain.TerminalSnapshot
import com.manonloki.lokimetrisdisplay.rules.TerminalValueRules

/** 系统小组件的持久化摘要只保留用量和 Hook 四态；正文、图片及长期配对秘密不进入此模型。 */
data class TerminalWidgetSnapshot(val sourceId: String, val receivedAtMs: Long, val snapshot: TerminalSnapshot) {
    val stamp: SnapshotStamp get() = SnapshotStamp(sourceId, receivedAtMs)

    /** 校验摘要已裁剪：不含正文、图片或资源目录。 */
    fun validate() {
        require(TerminalValueRules.validDeviceId(sourceId) && receivedAtMs >= 0)
        snapshot.validate()
        require(snapshot.assets.isEmpty() && snapshot.catalogError == null)
        require(snapshot.hooks.all { it.content.isEmpty() && !it.contentTruncated && it.image == null })
    }

    companion object {
        const val MAX_BYTES = 64 * 1024

        /** 只接受 owner 已验证的完整快照；新对象不引用任何 Hook 正文或图片。 */
        fun fromLive(sourceId: String, receivedAtMs: Long, snapshot: TerminalSnapshot): TerminalWidgetSnapshot {
            snapshot.validate()
            return TerminalWidgetSnapshot(sourceId, receivedAtMs, snapshot.copy(
                tokens = snapshot.tokens?.let { it.copy(agents = it.agents.toList()) },
                hooks = snapshot.hooks.map { it.copy(content = "", contentTruncated = false, image = null) },
                assets = emptyList(), catalogError = null,
                enabledAgents = snapshot.enabledAgents?.toList(),
            )).also { it.validate() }
        }
    }
}
