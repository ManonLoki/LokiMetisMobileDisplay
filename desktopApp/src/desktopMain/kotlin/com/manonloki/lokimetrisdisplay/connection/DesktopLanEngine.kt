package com.manonloki.lokimetrisdisplay

import org.json.JSONObject
import java.nio.channels.Selector
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.atomic.AtomicBoolean
import java.io.IOException
import org.json.JSONException

private typealias Phase = TerminalSessionPhase

/** 只映射小型元信息，原始清单顺序、引用与完整长度保持不变。 */
private fun TerminalSnapshot.transferManifest(): AssetTransferManifest = AssetTransferManifest(
    assets.map { it.transferDescriptor() }, hooks.mapNotNull { it.image }.toSet(),
)
private fun TerminalAsset.transferDescriptor(): AssetTransferDescriptor = AssetTransferDescriptor(hash, mime, length.toString())

/** 已认证文字与已核验编码图片；秘密不进入 UI 投影。 */
data class DesktopLinkProjection(val view: TerminalLinkView, val images: Map<String, ByteArray> = emptyMap())

/** 窗口从创建到关闭持续连接，最小化和焦点变化不会重新开启配对窗口。 */
class DesktopLanEngine internal constructor(
    private val settings: DesktopDeviceSettings,
    browserFactory: ((List<DesktopLanEndpoint>) -> Unit, () -> Unit) -> DesktopDiscovery,
) : AutoCloseable {
    constructor(settings: DesktopDeviceSettings) : this(settings, { changed, failed -> DesktopLanBrowser(changed, failed) })
    private val clockOrigin = System.nanoTime()
    private val deviceType = DesktopPadIdentity(settings.deviceId)
    private val running = AtomicBoolean(true)
    private val selector = Selector.open()
    private val commands = ArrayBlockingQueue<() -> Unit>(32)
    private val userIntent = TerminalPendingIntent()
    private val overflowPending = AtomicBoolean(false)
    private val discovered = AtomicReference<List<DesktopLanEndpoint>?>(null)
    private val projection = AtomicReference<DesktopLinkProjection?>(null)
    private var deliveryQueued = false
    private var listener: ((DesktopLinkProjection) -> Unit)? = null
    @Volatile var state = DesktopLinkProjection(TerminalLinkView(settings.deviceId, settings.name)); private set
    private var view = state.view
    private var images = emptyMap<String, ByteArray>()
    private var active = true
    private var store: DesktopPairingStore? = null
    private var cache: DesktopAssetCache? = null
    private var paired = emptySet<String>()
    private var endpoints = emptyMap<String, DesktopLanEndpoint>()
    private val intent = TerminalConnectionPolicy()
    private var bridge: NativeLinkBridge? = null
    private var sessionName = settings.name
    private var socket: DesktopLanSocket? = null
    private var phase = Phase.IDLE
    private var offer: JSONObject? = null
    private var pairingDeadline: Long? = null
    private var deadline: Long? = null
    private var retryAt: Long? = null
    private var lastInbound = 0L
    private var currentAsset: TerminalAsset? = null
    private var assetDeadline: Long? = null
    private val failedAssets = mutableSetOf<String>()
    private val browser = browserFactory( { discovered.set(it); selector.wakeup() }, {
        submit { view = view.copy(error = "发现失败，请检查本地网络权限和Wi-Fi后重试。"); publish() }
    })

    private val worker = Thread({ run() }, "loki-desktop-lan-owner").apply { isDaemon = true; start() }
    /** 界面只在 Swing EDT 接收不可变投影；订阅立即提供最新状态。 */
    fun setListener(value: (DesktopLinkProjection) -> Unit) {
        check(javax.swing.SwingUtilities.isEventDispatchThread())
        listener = value; value(state)
    }
    /** 发现失败后的重试入口；首次发现由窗口创建自动开启。 */
    fun discover() { requestIntent(TerminalUserIntent.Discover) }
    /** 用户选择才开启首次密码窗口，已配对候选只做新会话认证。 */
    fun select(id: String) { requestIntent(TerminalUserIntent.Select(id)) }
    /** 最新连接意图不经过可能已满的普通队列，同一轮按真实提交先后覆盖。 */
    private fun requestIntent(value: TerminalUserIntent) { if (!running.get()) return; synchronized(userIntent) { userIntent.submit(value) }; selector.wakeup() }
    /** worker消费当前最新意图后才改变发现和密码窗口。 */
    private fun applyIntent(value: TerminalUserIntent) {
        when (value) {
            TerminalUserIntent.Discover -> {
                intent.discover(); view = view.copy(error = null, status = if (active) "正在发现桌面端…" else "连接已关闭")
                if (active) {
                    browser.start()
                    if (socket == null) { retryAt = null; if (pairingDeadline != null) connect(true) else browsed(endpoints.values.toList()) }
                }
            }
            is TerminalUserIntent.Select -> { intent.discover(); selectNow(value.id) }
        }
        publish()
    }
    /** 设置保存不重启网络，也不修改密码窗口的身份快照。 */
    fun nameChanged() { submit { view = view.copy(deviceName = settings.name); publish() } }
    /** 原子删除成功后才修改本轮信任与会话；失败保留全部配对记录。 */
    fun forget(id: String) {
        synchronized(userIntent) { userIntent.forget(id) }
        submit {
            try {
                check(requireNotNull(store).forget(id))
                if (view.selectedId == id) { cancelSession(); view = view.copy(selectedId = null) }
                paired = paired - id
                view = view.copy(status = "已忘记，可重新配对", error = null); rebuildHosts()
            } catch (_: Exception) { view = view.copy(error = "无法删除配对记录，请重试。") }
            publish()
        }
    }
    /** 用户命令最多32项，过载返回可见错误而不另建无界任务队列。 */
    private fun submit(command: () -> Unit) {
        if (!running.get()) return
        if (!commands.offer(command)) overflowPending.set(true)
        selector.wakeup()
    }
    /** 唯一worker处理命令、系统最新状态、socket和单调超时，不使用阻塞读线程。 */
    private fun run() {
        try { store = DesktopPairingStore(settings.directory, settings.deviceId); cache = DesktopAssetCache(settings.directory) }
        catch (_: Exception) { view = view.copy(error = "本机私有存储不可用，请检查用户数据目录权限后重试。") }
        try { paired = store?.clientIds().orEmpty() }
        catch (_: Exception) { view = view.copy(error = "无法读取配对记录，请检查用户数据目录。") }
        intent.enterForeground(); rebuildHosts(); browser.start(); publish()
        try {
        while (running.get()) {
            try {
                for (index in 0 until 32) {
                    commands.poll()?.invoke()
                }
                synchronized(userIntent) { userIntent.take() }?.let(::applyIntent)
                if (overflowPending.getAndSet(false)) { view = view.copy(error = "操作过快，请稍后重试。"); publish() }
                discovered.getAndSet(null)?.let(::browsed)
                tick()
                val selected = selector.select(selectTimeoutMs())
                if (selected > 0) {
                    try { socket?.process(now) } catch (error: Exception) { socketFailed(error) }
                    selector.selectedKeys().clear()
                }
            } catch (_: LinkageError) { fail(false, "原生协议库不可用，请重新安装完整应用。"); }
            catch (_: Exception) { fail(false, "连接状态异常，请重新选择桌面重试。") }
        }
        } finally {
            active = false; intent.leaveForeground(); cancelSession()
            view = view.copy(status = "连接已关闭"); publish()
            try { browser.close() } finally { selector.close(); commands.clear() }
        }
    }
    /** 新地址才续预算，相同广告重复出现不能绕过八次重试。 */
    private fun browsed(values: List<DesktopLanEndpoint>) {
        val previous = endpoints
        endpoints = if (active && intent.requested) values.filter { it.id != settings.deviceId }.associateBy { it.id } else emptyMap()
        val selected = view.selectedId
        if (selected != null && endpoints[selected] != null && (endpoints[selected]?.address != previous[selected]?.address || endpoints[selected]?.interfaceIndex != previous[selected]?.interfaceIndex)) intent.renewedEndpoint()
        rebuildHosts()
        if (active && socket == null && retryAt == null) {
            intent.automaticSelection(selected, paired, view.hosts.filter { it.available }.map { it.id })?.let { id ->
                if (selected == id) resumeSelected() else selectNow(id)
            }
        }
        publish()
    }
    /** 已配对但未发现的桌面保留忘记入口，不能假称在线。 */
    private fun rebuildHosts() {
        val found = endpoints.values.sortedBy { it.id }.map { TerminalHost(it.id, it.name, it.id in paired, true) }
        view = view.copy(hosts = found + (paired - endpoints.keys).sorted().map { TerminalHost(it, "已配对桌面 · ${it.take(8)}", true, false) })
    }
    /** 每次明确选择建立新bridge；同一次配对的传输重试继续复用该bridge及offer。 */
    private fun selectNow(id: String) {
        if (!active || !intent.requested || id !in endpoints) return
        cancelSession(); intent.renewedEndpoint(); view = view.copy(selectedId = id, error = null)
        try {
            sessionName = settings.name; bridge = NativeLinkBridge(settings.deviceId, sessionName)
            if (requireNotNull(store).load(id) != null) resumeSelected()
            else {
                val result = requireNotNull(bridge).call(JSONObject().put("op", "openPairing").put("clientId", id))
                offer = result.obj("offer"); pairingDeadline = now + TerminalSessionTimingPolicy.PAIRING_WINDOW_MS
                view = view.copy(pairingCode = result.string("code")); connect(true)
            }
        } catch (_: Exception) { fail(false, "无法开始连接，请检查设备身份或配对存储后重试。") }
        publish()
    }
    /** 新 TCP 以 本机私有文件中的配对秘密恢复认证；端点来自本轮发现。 */
    private fun resumeSelected() {
        val id = view.selectedId ?: return
        if (!active || !intent.requested || id !in endpoints) return
        try {
            if (bridge == null) { sessionName = settings.name; bridge = NativeLinkBridge(settings.deviceId, sessionName) }
            val material = requireNotNull(requireNotNull(store).load(id))
            offer = requireNotNull(bridge).call(JSONObject().put("op", "resume").put("clientId", id).put("secret", material.string("secret"))).obj("introduction")
            connect(false)
        } catch (_: Exception) { fail(false, "无法读取配对凭据，请解锁后重试，或忘记此桌面后重新配对。") }
    }
    /** socket所有回调都校验实例，旧连接绝不修改新会话。 */
    private fun connect(pairing: Boolean) {
        val endpoint = endpoints[view.selectedId] ?: return
        val introduction = offer ?: return
        clearLiveDisplay()
        socket?.close(); socket = null; deviceType.reset(); failedAssets.clear()
        phase = if (pairing) Phase.PAIR_HELLO else Phase.RESUME_REPLY
        deadline = now + TerminalSessionTimingPolicy.HANDSHAKE_TIMEOUT_MS
        view = view.copy(connected = false, status = if (pairing) "等待在采集端输入此配对码" else "正在认证采集端…",
            assetWarning = if (cache == null) "图片缓存暂不可用，连接仍可同步文字与用量。" else null)
        lateinit var connection: DesktopLanSocket
        try {
        connection = DesktopLanSocket(endpoint, selector, limit = { TerminalSessionTimingPolicy.frameLimit(phase) }, ready = {
            if (socket === connection) {
                if (pairing) deadline = pairingDeadline
                connection.send(introduction, TerminalSessionTimingPolicy.HANDSHAKE_FRAME_BYTES)
            }
        }, received = { json -> if (socket === connection) received(json) })
        socket = connection; connection.begin(); publish()
        } catch (_: IOException) { fail(true, "连接中断，正在等待桌面恢复…") }
    }
    /** 线对象由Rust生成，不包错层；保存成功且commit仍有效后才能生成ACK。 */
    private fun received(json: JSONObject) {
        val bridge = requireNotNull(bridge); val socket = requireNotNull(socket)
        when (phase) {
            Phase.PAIR_HELLO -> {
                val result = bridge.call(JSONObject().put("op", "pairHello").put("hello", json))
                phase = Phase.PAIR_CONFIRMATION
                deadline = minOf(pairingDeadline ?: now, now + TerminalSessionTimingPolicy.HANDSHAKE_TIMEOUT_MS)
                socket.send(result.obj("reply"), TerminalSessionTimingPolicy.HANDSHAKE_FRAME_BYTES)
            }
            Phase.PAIR_CONFIRMATION -> {
                val pending = bridge.call(JSONObject().put("op", "pairConfirmation").put("confirmation", json))
                val commit = pending.string("commitId"); val material = pending.obj("material")
                bridge.call(JSONObject().put("op", "checkCommit").put("commitId", commit))
                val saved = runCatching { requireNotNull(store).save(material) }.getOrDefault(false)
                if (saved) { paired = paired + material.string("clientId"); rebuildHosts(); publish() }
                val result = bridge.call(JSONObject().put("op", "pairingStored").put("commitId", commit).put("stored", saved))
                phase = Phase.PAIR_CLOSE; deadline = now + TerminalSessionTimingPolicy.PAIR_CLOSE_TIMEOUT_MS
                socket.send(result.obj("ack"), TerminalSessionTimingPolicy.HANDSHAKE_FRAME_BYTES)
            }
            Phase.RESUME_REPLY -> {
                val result = bridge.call(JSONObject().put("op", "resumeReply").put("reply", json)); phase = Phase.METADATA
                socket.send(result.obj("confirmation"), TerminalSessionTimingPolicy.HANDSHAKE_FRAME_BYTES) {
                    if (this.socket === socket) {
                        sendSecure(deviceType.metadata(sessionName))
                        // 认证确认完整写出后重新计时首快照预算。
                        phase = Phase.STREAMING
                        deadline = now + TerminalSessionTimingPolicy.FIRST_SNAPSHOT_TIMEOUT_MS; lastInbound = now
                    }
                }
            }
            Phase.STREAMING -> {
                val message = bridge.call(JSONObject().put("op", "open").put("packet", json)).obj("message")
                lastInbound = now
                when (message.string("type")) {
                    "ping" -> sendSecure(JSONObject().put("type", "pong").put("nonce", message.long("nonce")))
                    "snapshot" -> acceptSnapshot(message)
                    "assetChunk" -> acceptAsset(message.obj("chunk"))
                    "assetUnavailable" -> {
                        require(message.string("hash") == currentAsset?.hash)
                        failedAssets += message.string("hash"); cache?.close(); currentAsset = null; assetDeadline = null; nextAsset()
                    }
                    else -> error("lan_message_invalid")
                }
            }
            Phase.PAUSING -> Unit
            else -> error("lan_phase_invalid")
        }
    }
    /** 完整配对socket关闭后等待桌面同步保存，再以新TCP恢复；尚不报告在线。 */
    private fun pairingCompleted() {
        offer = null; pairingDeadline = null; view = view.copy(pairingCode = null)
        socket?.close(); socket = null; deviceType.reset(); phase = Phase.IDLE; deadline = null; scheduleRetry()
    }
    /** seal消费序号后任何入队/写失败都必须关闭原连接。 */
    private fun sendSecure(message: JSONObject, completed: () -> Unit = {}) {
        val packet = requireNotNull(bridge).call(JSONObject().put("op", "seal").put("message", message)).obj("packet")
        requireNotNull(socket).send(packet, TerminalSessionTimingPolicy.SECURE_FRAME_BYTES, completed)
    }
    /** 传输关闭与认证错误分离；只有网络失败允许同一配对窗口内新TCP重试。 */
    private fun socketFailed(error: Exception) {
        if (phase == Phase.PAIR_CLOSE && error.message == "lan_socket_ended") pairingCompleted()
        else fail(error !is NativeLinkBridge.Failure && error !is IllegalArgumentException && error !is JSONException && error !is java.nio.charset.CharacterCodingException,
            if (error is NativeLinkBridge.Failure || error is IllegalArgumentException || error is JSONException || error is java.nio.charset.CharacterCodingException) "认证或消息校验失败，请重试或重新配对。" else "连接中断，正在等待桌面恢复…")
    }
    /** 只睡到最近的期限；有待写数据时保持100ms检查写超时。命令、发现和生命周期变化都会wakeup，空闲最长30秒兜底以减少唤醒耗电。 */
    private fun selectTimeoutMs(): Long {
        val now = now
        var next = now + 30_000
        for (at in listOfNotNull(pairingDeadline, deadline, assetDeadline, retryAt,
            lastInbound.takeIf { phase == Phase.STREAMING }?.plus(TerminalSessionTimingPolicy.INBOUND_IDLE_TIMEOUT_MS))) next = minOf(next, at)
        if (socket?.hasPendingWrites == true) next = minOf(next, now + 100)
        return (next - now).coerceIn(1, 30_000)
    }
    /** 单调期限覆盖密码、首次快照、心跳及图片请求。 */
    private fun tick() {
        val now = now
        when (TerminalSessionTimingPolicy.timeout(phase,
            pairingDue = pairingDeadline?.let { TerminalSessionTimingPolicy.deadlineReached(now, it) } == true,
            phaseDue = deadline?.let { TerminalSessionTimingPolicy.deadlineReached(now, it) } == true,
            heartbeatDue = TerminalSessionTimingPolicy.elapsedAtLeast(now, lastInbound, TerminalSessionTimingPolicy.INBOUND_IDLE_TIMEOUT_MS),
            assetDue = assetDeadline?.let { TerminalSessionTimingPolicy.deadlineReached(now, it) } == true)) {
            TerminalSessionTimeout.NONE -> Unit
            TerminalSessionTimeout.PAIRING_EXPIRED -> { fail(false, "配对窗口已过期，请重新选择桌面。"); return }
            TerminalSessionTimeout.PAIRING_COMPLETED -> { pairingCompleted(); return }
            TerminalSessionTimeout.PHASE_TIMEOUT -> { fail(true, "连接超时，正在等待桌面恢复…"); return }
            TerminalSessionTimeout.HEARTBEAT_TIMEOUT -> { fail(true, "桌面暂不可达，恢复网络后重新连接。"); return }
            TerminalSessionTimeout.ASSET_TIMEOUT -> { fail(true, "图片响应超时，正在恢复连接…"); return }
        }
        try { socket?.tick(now) } catch (error: Exception) { socketFailed(error) }
        if (retryAt?.let { now >= it } == true) { retryAt = null; if (active && intent.requested) { if (pairingDeadline != null) connect(true) else resumeSelected() } }
    }
    /** 只用固定八次退避，不能通过socket错误重开Rust密码窗口。 */
    private fun scheduleRetry() {
        retryAt = if (active) intent.nextDelayMs()?.let { now + it } else null
        if (retryAt == null) view = view.copy(status = "暂未连接，请重新选择桌面重试")
        publish()
    }
    /** 保留有效配对记录；协议失败关闭密码窗口，传输失败可复用尚有效的窗口。 */
    private fun fail(retry: Boolean, message: String) {
        clearLiveDisplay()
        retryAt = null; socket?.close(); socket = null; deviceType.reset(); cache?.close(); currentAsset = null; assetDeadline = null
        runCatching { bridge?.call(JSONObject().put("op", "disconnect")) }
        phase = Phase.IDLE; deadline = null; view = view.copy(connected = false, error = message, status = "暂未连接")
        if (retry) scheduleRetry() else {
            runCatching { bridge?.call(JSONObject().put("op", "cancelPairing")) }
            pairingDeadline = null; offer = null; view = view.copy(pairingCode = null)
        }
        publish()
    }
    /** 取消会话与配对窗口并撤下实时展示；已配对凭据和完整图片仍由私有存储管理。 */
    private fun cancelSession() {
        clearLiveDisplay()
        retryAt = null; socket?.close(); socket = null; deviceType.reset()
        runCatching { bridge?.call(JSONObject().put("op", "cancelPairing")) }; bridge?.close(); bridge = null
        cache?.close(); currentAsset = null; assetDeadline = null; pairingDeadline = null; deadline = null; offer = null
        failedAssets.clear(); phase = Phase.IDLE; view = view.copy(pairingCode = null, connected = false)
    }
    /** 完整图文只进入本轮内存展示，断线立即撤下；磁盘仅缓存经过验证的图片。 */
    private fun acceptSnapshot(message: JSONObject) {
        val snapshot = DesktopDisplayJson.snapshot(message); val received = System.currentTimeMillis()
        deviceType.afterSnapshot(DesktopDisplayJson.capabilities(message))?.let(::sendSecure)
        view = view.copy(snapshot = snapshot, receivedAtMs = received, connected = true, status = "已连接，正在同步", error = null)
        deadline = null; intent.renewedEndpoint()
        val hashes = snapshot.hooks.mapNotNull { it.image }.toSet()
        images = images.filterKeys { it in hashes }
        runCatching { cache?.prune(hashes) }.onFailure { view = view.copy(assetWarning = "图片缓存清理暂不可用。") }
        nextAsset(); publish()
    }
    /** 单资源单块请求，IO允许降级，已消费nonce的发送操作必须在IO异常捕获之外。 */
    private fun nextAsset() {
        val bridge = bridge ?: return; val cache = cache ?: return; val snapshot = view.snapshot ?: return
        if (phase != Phase.STREAMING || currentAsset != null) return
        val manifest = snapshot.transferManifest()
        for (index in AssetTransferRules.pendingIndices(manifest, images.keys + failedAssets)) {
            val asset = snapshot.assets[index]
            try {
                val bytes = cache.cached(DesktopDisplayJson.asset(asset), bridge)
                if (bytes != null) { images = images + (asset.hash to bytes); continue }
                cache.begin(DesktopDisplayJson.asset(asset), bridge)
            } catch (error: Exception) {
                if (error is NativeLinkBridge.Failure) throw error
                failedAssets += asset.hash; cache.close(); view = view.copy(assetWarning = "部分图片缓存暂不可用，重新连接后可补取。"); continue
            }
            currentAsset = asset; requestAsset(asset.hash, 0); return
        }
    }
    /** 清单变化时只排空已经在途的一块，再创建新资源接收器。 */
    private fun acceptAsset(chunk: JSONObject) {
        val asset = requireNotNull(currentAsset); val bridge = requireNotNull(bridge); val cache = requireNotNull(cache)
        require(chunk.string("hash") == asset.hash)
        val snapshot = requireNotNull(view.snapshot)
        if (!AssetTransferRules.keepInFlight(asset.transferDescriptor(), snapshot.transferManifest())) {
            cache.close(); currentAsset = null; assetDeadline = null; nextAsset(); publish(); return
        }
        val result = try { cache.accept(chunk, bridge) } catch (error: Exception) {
            if (error is NativeLinkBridge.Failure) throw error
            failedAssets += asset.hash; cache.close(); currentAsset = null; assetDeadline = null
            view = view.copy(assetWarning = "部分图片未能保存，重新连接后可补取。"); nextAsset(); publish(); return
        }
        val bytes = result.first
        if (bytes != null) {
            images = images + (asset.hash to bytes)
            runCatching { cache.prune(snapshot.hooks.mapNotNull { it.image }.toSet()) }
                .onFailure { view = view.copy(assetWarning = "图片缓存清理暂不可用。") }
            currentAsset = null; assetDeadline = null; nextAsset(); publish()
        } else requestAsset(asset.hash, result.second)
    }
    /** 摘要与严格偏移都由当前资源核心决定。 */
    private fun requestAsset(hash: String, offset: Long) {
        sendSecure(JSONObject().put("type", "assetRequest").put("hash", hash).put("offset", offset))
        assetDeadline = now + TerminalSessionTimingPolicy.ASSET_TIMEOUT_MS
    }
    /** 实时投影和已解码图片一并失效；磁盘图片仅由新快照重新引用后复用。 */
    private fun clearLiveDisplay() { view = view.withoutLiveDisplay(); images = emptyMap() }
    /** 主线程最多排一个投影任务，最新值覆盖旧值，慢UI不累积图片和快照。 */
    private fun publish() {
        view = view.copy(deviceName = settings.name)
        projection.set(DesktopLinkProjection(view, images))
        synchronized(projection) {
            if (deliveryQueued) return
            deliveryQueued = true
            javax.swing.SwingUtilities.invokeLater {
                synchronized(projection) { deliveryQueued = false }
                projection.getAndSet(null)?.let { state = it; listener?.invoke(it) }
            }
        }
    }
    /** 所有传输期限使用单调时钟，与展示接收墙钟分离。 */
    private val now: Long get() = (System.nanoTime() - clockOrigin) / 1_000_000
    override fun close() {
        if (running.getAndSet(false)) selector.wakeup()
        if (!javax.swing.SwingUtilities.isEventDispatchThread() && worker !== Thread.currentThread()) worker.join(3_000)
    }
}
