package com.manonloki.lokimetrisdisplay

import android.content.Context
import android.graphics.drawable.AnimatedImageDrawable
import android.graphics.drawable.Drawable
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
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

/** Android图片是私有校验缓存的有界原生图片，保留动图，秘密不进入UI投影。 */
data class AndroidLinkProjection(val view: TerminalLinkView, val images: Map<String, Map<Int, Drawable>> = emptyMap())

/** 应用级单线程网络owner；Activity旋转、菜单和权限弹窗都不重新创建密码窗口。 */
class AndroidLanEngine(context: Context, private val settings: AndroidDeviceSettings,
    private val onSurfaceChanged: () -> Unit = {}) {
    private val app = context.applicationContext
    // 应用级系统配置不使用Activity/Compose当前窗口宽度；本进程内保持同一分类。
    private val deviceType = TerminalDeviceTypeReport(TerminalDeviceType.fromSmallestWidthDp(app.resources.configuration.smallestScreenWidthDp))
    private val main = Handler(Looper.getMainLooper())
    private val selector = Selector.open()
    private val commands = ArrayBlockingQueue<() -> Unit>(32)
    private val foreground = AtomicReference(false to false)
    private val backgroundConnection = AtomicBoolean(false)
    private val userIntent = TerminalPendingIntent()
    private val overflowPending = AtomicBoolean(false)
    private val discovered = AtomicReference<List<AndroidLanEndpoint>?>(null)
    private val projection = AtomicReference<AndroidLinkProjection?>(null)
    private var deliveryQueued = false
    private var listener: ((AndroidLinkProjection) -> Unit)? = null
    var state = AndroidLinkProjection(TerminalLinkView(settings.deviceId, settings.name)); private set
    private var view = state.view
    private var images = emptyMap<String, Map<Int, Drawable>>()
    private var active = false
    private var foregroundVisible = false
    private var widgetStore: AndroidWidgetStore? = null
    private var store: AndroidPairingStore? = null
    private var cache: AndroidAssetCache? = null
    private var paired = emptySet<String>()
    private var endpoints = emptyMap<String, AndroidLanEndpoint>()
    private val intent = TerminalConnectionPolicy()
    private var bridge: NativeLinkBridge? = null
    private var sessionName = settings.name
    private var socket: AndroidLanSocket? = null
    private var phase = Phase.IDLE
    private var offer: JSONObject? = null
    private var pairingDeadline: Long? = null
    private var deadline: Long? = null
    private var retryAt: Long? = null
    private var lastInbound = 0L
    private var currentAsset: TerminalAsset? = null
    private var assetDeadline: Long? = null
    private val failedAssets = mutableSetOf<String>()
    private val browser = AndroidLanBrowser(app, changed = { discovered.set(it); selector.wakeup() }, failed = {
        submit { view = view.copy(error = "发现失败，请检查本地网络权限和Wi-Fi后重试。"); publish() }
    })

    init {
        Thread({ run() }, "loki-lan-owner").apply { isDaemon = true }.start()
    }
    /** Application 在主线程订阅，再向 Activity 与 Service 分发最新投影。 */
    fun setListener(value: (AndroidLinkProjection) -> Unit) { check(Looper.myLooper() == Looper.getMainLooper()); listener = value; value(state) }
    /** 前后台和权限使用最新值槽位，队列满也不会丢弃真实后台变化。 */
    fun setForeground(value: Boolean, permitted: Boolean) { foreground.set(value to permitted); selector.wakeup() }
    /** 仅用户开启的connectedDevice前台服务可延长已配对连接，不允许后台开启配对窗口。 */
    fun setBackgroundConnection(enabled: Boolean) { backgroundConnection.set(enabled); selector.wakeup() }
    /** 发现失败后的重试入口；首次发现由前台生命周期自动开启。 */
    fun discover() { requestIntent(TerminalUserIntent.Discover) }
    /** 用户选择才开启首次密码窗口，已配对候选只做新会话认证。 */
    fun select(id: String) { requestIntent(TerminalUserIntent.Select(id)) }
    /** 最新连接意图不经过可能已满的普通队列，同一轮按真实提交先后覆盖。 */
    private fun requestIntent(value: TerminalUserIntent) { synchronized(userIntent) { userIntent.submit(value) }; selector.wakeup() }
    /** worker消费当前最新意图后才改变发现和密码窗口。 */
    private fun applyIntent(value: TerminalUserIntent) {
        when (value) {
            TerminalUserIntent.Discover -> {
                intent.discover(); view = view.copy(error = null, status = if (active) "正在发现桌面端…" else "需要本地网络权限或返回前台")
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
    /** 忘记精确桌面信任；系统存储失败时保持原信任列表。 */
    fun forget(id: String) {
        synchronized(userIntent) { userIntent.forget(id) }
        submit {
        try {
            check(requireNotNull(widgetStore).clear(id))
            onSurfaceChanged()
            if (view.selectedId == id) { cancelSession(); view = view.copy(selectedId = null) }
            check(requireNotNull(store).forget(id)); paired = paired - id
            view = view.copy(status = "已忘记，可重新配对", error = null); rebuildHosts()
        } catch (_: Exception) { view = view.copy(error = "无法删除配对记录，请重试。") }
        publish()
    } }
    /** 用户命令最多32项，过载返回可见错误而不另建无界任务队列。 */
    private fun submit(command: () -> Unit) {
        if (!commands.offer(command)) overflowPending.set(true)
        selector.wakeup()
    }
    /** 唯一worker处理命令、系统最新状态、socket和单调超时，不使用阻塞读线程。 */
    private fun run() {
        try { store = AndroidPairingStore(app, settings.deviceId); cache = AndroidAssetCache(app) }
        catch (_: Exception) { view = view.copy(error = "私有存储暂不可用，请解锁后重试。") }
        try {
            widgetStore = AndroidWidgetStore(app)
            val source = widgetStore?.target()?.sourceId ?: widgetStore?.read()?.sourceId
            if (source != null && source in (store?.clientIds() ?: emptySet())) view = view.copy(selectedId = source)
        } catch (_: Exception) { view = view.copy(assetWarning = "小组件摘要存储暂不可用，请解锁后重试。") }
        try { AndroidDisplayStore(app).discardLegacy() }
        catch (_: Exception) { view = view.copy(assetWarning = "旧展示快照未能清理，当前不会恢复或使用其中的数据。") }
        while (true) {
            try {
                syncForeground()
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
            } catch (_: LinkageError) { fail(false, "原生协议库不可用，请重新安装完整应用。"); intent.leaveForeground(); browser.stop() }
            catch (_: Exception) { fail(false, "连接状态异常，请重新选择桌面重试。") }
        }
    }
    /** 无可用权限或前台与常驻服务都退出时暂停；后台始终取消首次配对窗口。 */
    private fun syncForeground() {
        val (visible, permitted) = foreground.get()
        val visibilityChanged = foregroundVisible != visible
        foregroundVisible = visible
        val next = (visible || backgroundConnection.get()) && permitted
        if (!visible && pairingDeadline != null) {
            cancelSession()
            view = view.copy(status = "配对已暂停，请回到前台重新选择桌面。")
            publish()
        }
        if (active == next) {
            if (visible && !permitted && view.status != "需要本地网络权限") {
                view = view.copy(status = "需要本地网络权限", error = "允许本地网络权限后会自动发现桌面端。")
                publish()
            }
            if (visibilityChanged && visible && active) {
                intent.enterForeground()
                browser.start()
                if (socket == null && pairingDeadline == null) {
                    retryAt = null; view = view.copy(error = null)
                    browsed(endpoints.values.toList())
                }
                nextAsset(); publish()
            }
            return
        }
        active = next
        if (next) {
            if (phase == Phase.PAUSING) cancelSession()
            view = view.copy(error = null)
            try { paired = requireNotNull(store).clientIds() } catch (_: Exception) { view = view.copy(error = "无法读取配对记录，请解锁后重试。") }
            intent.enterForeground(); rebuildHosts()
            if (socket == null) view = view.copy(status = "正在发现桌面端…")
            browser.start()
        } else {
            clearLiveDisplay()
            intent.leaveForeground()
            browser.stop(); endpoints = emptyMap(); rebuildHosts()
            if (phase == Phase.STREAMING) {
                val paused = socket
                try { phase = Phase.PAUSING; sendSecure(JSONObject().put("type", "pause")) { if (socket === paused && !active) cancelSession() } }
                catch (_: Exception) { cancelSession() }
            } else cancelSession()
            view = view.copy(connected = false, status = if (visible) "需要本地网络权限" else "已暂停，回到前台后恢复")
        }
        publish()
    }
    /** 新地址才续预算，相同广告重复出现不能绕过八次重试。 */
    private fun browsed(values: List<AndroidLanEndpoint>) {
        val previous = endpoints
        endpoints = if (active && intent.requested) values.filter { it.id != settings.deviceId }.associateBy { it.id } else emptyMap()
        val selected = view.selectedId
        if (selected != null && endpoints[selected] != null && (endpoints[selected]?.address != previous[selected]?.address || endpoints[selected]?.network != previous[selected]?.network)) intent.renewedEndpoint()
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
        if (!foregroundVisible && id !in paired) return
        try {
            val retained = widgetStore?.target()?.sourceId ?: widgetStore?.read()?.sourceId
            if (retained != null && retained != id) {
                check(requireNotNull(widgetStore).clear()); onSurfaceChanged()
            }
        } catch (_: Exception) { fail(false, "无法清除上一个桌面的组件摘要，请重试。"); return }
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
    /** 新 TCP 以 Keystore 中的配对秘密恢复认证；端点来自本轮发现，独立 HTTP 目标另行保存。 */
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
        view = view.copy(connected = false, status = if (pairing) "等待在桌面输入手机配对码" else "正在认证桌面…",
            assetWarning = if (cache == null) "图片缓存暂不可用，连接仍可同步文字与用量。" else null)
        lateinit var connection: AndroidLanSocket
        try {
        connection = AndroidLanSocket(endpoint, selector, limit = { TerminalSessionTimingPolicy.frameLimit(phase) }, ready = {
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
                        sendSecure(JSONObject().put("deviceId", settings.deviceId).put("name", sessionName).put("platform", "android").put("appVersion", "1.0"))
                        // Android 保留认证确认写完后重新计时的首快照预算；iOS 沿用 connect 起点。
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
    /** 取消会话与配对窗口并撤下实时展示；图片、组件裁剪摘要及系统凭据由各自存储管理。 */
    private fun cancelSession() {
        clearLiveDisplay()
        retryAt = null; socket?.close(); socket = null; deviceType.reset()
        runCatching { bridge?.call(JSONObject().put("op", "cancelPairing")) }; bridge?.close(); bridge = null
        cache?.close(); currentAsset = null; assetDeadline = null; pairingDeadline = null; deadline = null; offer = null
        failedAssets.clear(); phase = Phase.IDLE; view = view.copy(pairingCode = null, connected = false)
    }
    /** 完整图文只进入本轮内存展示，同时另存不含正文和图片的小组件摘要及独立读取目标。 */
    private fun acceptSnapshot(message: JSONObject) {
        val snapshot = AndroidDisplayJson.snapshot(message); val received = System.currentTimeMillis()
        deviceType.afterAuthenticatedSnapshot(AndroidDisplayJson.capabilities(message))?.let { type ->
            sendSecure(JSONObject().put("type", "deviceFormFactor").put("formFactor", type.wireValue))
        }
        view = view.copy(snapshot = snapshot, receivedAtMs = received, connected = true, status = "已连接，正在同步", error = null)
        try {
            if (requireNotNull(widgetStore).acceptLive(requireNotNull(view.selectedId), settings.deviceId,
                    snapshot, message, requireNotNull(socket).peerHost, received)) onSurfaceChanged()
            else view = view.copy(assetWarning = "小组件摘要未能保存，稍后同步时会重试。")
        } catch (_: Exception) { view = view.copy(assetWarning = "小组件摘要未能保存，稍后同步时会重试。") }
        deadline = null; intent.renewedEndpoint()
        val hashes = snapshot.hooks.mapNotNull { it.image }.toSet()
        // 动画Drawable只有一个Callback，同hash在不同槽位各持独立Drawable实例。
        images = images.filter { (hash, slots) -> hash in hashes &&
            slots.keys == snapshot.hooks.filter { it.image == hash }.map { it.slot }.toSet() }
        cache?.prune(hashes); nextAsset(); publish()
    }
    /** 单资源单块请求，IO允许降级，已消费nonce的发送操作必须在IO异常捕获之外。 */
    private fun nextAsset() {
        if (!foregroundVisible) return
        val bridge = bridge ?: return; val cache = cache ?: return; val snapshot = view.snapshot ?: return
        if (phase != Phase.STREAMING || currentAsset != null) return
        val manifest = snapshot.transferManifest()
        for (index in AssetTransferRules.pendingIndices(manifest, images.keys + failedAssets)) {
            val asset = snapshot.assets[index]
            try {
                val path = cache.cached(AndroidDisplayJson.asset(asset), bridge)
                if (path != null) {
                    val image = imageSlots(asset.hash, path)
                    if (image != null) images = images + (asset.hash to image) else { failedAssets += asset.hash; view = view.copy(assetWarning = "部分图片无法解码或超出像素限制。") }
                    continue
                }
                cache.begin(AndroidDisplayJson.asset(asset), bridge)
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
        val path = result.first
        if (path != null) {
            val image = imageSlots(asset.hash, path)
            if (image != null) images = images + (asset.hash to image) else { failedAssets += asset.hash; view = view.copy(assetWarning = "部分图片无法解码。") }
            cache.prune(snapshot.hooks.mapNotNull { it.image }.toSet()); currentAsset = null; assetDeadline = null; nextAsset(); publish()
        } else requestAsset(asset.hash, result.second)
    }
    /** 每个槽位持有单独实例，避免相同动画摘要覆盖ImageView的唯一回调；静态图只解码一次，其余槽位共享位图的新Drawable。 */
    private fun imageSlots(hash: String, path: java.io.File): Map<Int, Drawable>? {
        val cache = cache ?: return null
        val slots = view.snapshot?.hooks?.filter { it.image == hash }?.map { it.slot } ?: return null
        val first = slots.firstOrNull()?.let { cache.thumbnail(path) } ?: return null
        val decoded = mutableMapOf<Int, Drawable>()
        for (slot in slots) decoded[slot] = when {
            decoded.isEmpty() -> first
            first !is AnimatedImageDrawable -> first.constantState?.newDrawable() ?: cache.thumbnail(path) ?: return null
            else -> cache.thumbnail(path) ?: return null
        }
        return decoded
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
        projection.set(AndroidLinkProjection(view, images))
        synchronized(projection) {
            if (deliveryQueued) return
            deliveryQueued = true
            main.post {
                synchronized(projection) { deliveryQueued = false }
                projection.getAndSet(null)?.let { state = it; listener?.invoke(it) }
            }
        }
    }
    /** 所有传输期限使用单调时钟，与展示接收墙钟分离。 */
    private val now: Long get() = SystemClock.elapsedRealtime()
}
