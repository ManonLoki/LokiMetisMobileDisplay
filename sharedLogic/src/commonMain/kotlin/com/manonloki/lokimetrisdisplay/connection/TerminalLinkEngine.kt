package com.manonloki.lokimetrisdisplay.connection

/** 应用 owner 面向界面的连接合同；发现、socket、配对存储与线程模型都留在平台实现内。 */
interface TerminalLinkEngine<P> {
    /** 最新平台投影；P 可携带平台已解码的图片等不可序列化内容。 */
    val state: P
    /** 设置唯一订阅者并立即回放当前投影；多消费者由应用 owner 自行分发。 */
    fun setListener(value: (P) -> Unit)
    /** 前后台与本地网络权限事实，决定是否允许发现与连接。 */
    fun setForeground(value: Boolean, permitted: Boolean)
    /** 仅用户开启的后台服务可延长已配对连接，不允许后台开启配对窗口。 */
    fun setBackgroundConnection(enabled: Boolean)
    /** 发现失败后的重试入口；首次发现由前台生命周期自动开启。 */
    fun discover()
    /** 用户选择才开启首次密码窗口，已配对候选只做新会话认证。 */
    fun select(id: String)
    /** 本机名称已保存，刷新投影但不重启网络。 */
    fun nameChanged()
    /** 忘记精确桌面信任；存储失败时保持原信任列表。 */
    fun forget(id: String)
}
