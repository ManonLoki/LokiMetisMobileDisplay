package com.manonloki.lokimetrisdisplay

import android.content.Context
import android.net.Network
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ext.SdkExtensions
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.util.concurrent.Executor

/** 解析后的临时候选；TXT只能选端点，授信仍唯一由Rust认证决定。 */
data class AndroidLanEndpoint(val id: String, val name: String, val address: InetSocketAddress, val network: Network?)

/** 应用连接有效期内的 DNS-SD 浏览器；主线程拥有注册，迟到回调不能跨浏览代次复活端点。 */
class AndroidLanBrowser(context: Context, private val changed: (List<AndroidLanEndpoint>) -> Unit, private val failed: () -> Unit) {
    private val main = Handler(Looper.getMainLooper())
    private val executor = Executor { main.post(it) }
    private val nsd = context.applicationContext.getSystemService(NsdManager::class.java)
    private val wifi = context.applicationContext.getSystemService(WifiManager::class.java)
    private var generation = 0L
    private var discovery: NsdManager.DiscoveryListener? = null
    private var multicast: WifiManager.MulticastLock? = null
    private val services = linkedMapOf<String, NsdServiceInfo>()
    private val watchers = mutableMapOf<String, NsdManager.ServiceInfoCallback>()
    private val resolved = mutableMapOf<String, AndroidLanEndpoint>()
    private val pending = ArrayDeque<Pair<String, NsdServiceInfo>>()
    // API31/32没有物理取消接口；旧回调终态前不释放唯一解析槽。
    private var physicalResolve: NsdManager.ResolveListener? = null
    private var resolveWatchdog: Runnable? = null
    private var refresh: Runnable? = null

    /** 同一应用只建立一个浏览，失败统一收回前台多播锁。 */
    fun start() { main.post { startNow() } }
    /** 切网或用户重新发现必须重建注册；仅 start 会保留旧网络上的系统浏览与缓存。 */
    fun restart() { main.post { stopNow(); startNow() } }
    private fun startNow() {
        if (discovery != null) return
        val token = ++generation
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(type: String) = Unit
            override fun onDiscoveryStopped(type: String) = Unit
            override fun onStartDiscoveryFailed(type: String, code: Int) { main.post { if (generation == token) { stopNow(); failed() } } }
            override fun onStopDiscoveryFailed(type: String, code: Int) = Unit
            override fun onServiceFound(info: NsdServiceInfo) { main.post {
                if (generation != token) return@post
                val key = key(info)
                if (services.containsKey(key) || services.size >= 64) return@post
                services[key] = info
                if (Build.VERSION.SDK_INT >= 34) watch(key, info, token) else { pending.add(key to info); resolveNext() }
            } }
            override fun onServiceLost(info: NsdServiceInfo) { main.post {
                if (generation != token) return@post
                val key = key(info); services.remove(key); resolved.remove(key); pending.removeAll { it.first == key }
                if (Build.VERSION.SDK_INT >= 34) watchers.remove(key)?.let { runCatching { nsd.unregisterServiceInfoCallback(it) } }
                publish()
            } }
        }
        discovery = listener
        try {
            if (Build.VERSION.SDK_INT < 33 || SdkExtensions.getExtensionVersion(Build.VERSION_CODES.TIRAMISU) < 7) {
                multicast = wifi.createMulticastLock("LokiMetris foreground discovery").apply { setReferenceCounted(false); acquire() }
            }
            nsd.discoverServices(MdnsProtocol.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
            scheduleRefresh(token)
        } catch (_: Exception) { stopNow(); failed() }
    }

    /** 停止仅取消本应用精确注册，已经无法取消的旧解析结果按代次丢弃。 */
    fun stop() { main.post { stopNow() } }
    /** 所有调用处已在主线程，先增代次再清理以拒绝迟到更新。 */
    private fun stopNow() {
        generation++
        discovery?.let { runCatching { nsd.stopServiceDiscovery(it) } }; discovery = null
        if (Build.VERSION.SDK_INT >= 34) watchers.values.forEach { runCatching { nsd.unregisterServiceInfoCallback(it) } }
        watchers.clear(); services.clear(); resolved.clear(); pending.clear()
        refresh?.let(main::removeCallbacks); refresh = null
        // 新系统精确取消；API31/32的系统槽无法取消，仍必须等待其终态，避免平行残留。
        physicalResolve?.let(::cancelResolution)
        multicast?.let { if (it.isHeld) it.release() }; multicast = null
        publish()
    }
    /** 服务key保留网络，不能同名跨网络覆盖。 */
    private fun key(info: NsdServiceInfo): String = info.serviceName + "|" + info.serviceType.trimEnd('.') + "|" +
        if (Build.VERSION.SDK_INT >= 33) info.network.toString() else "default"

    /** API34持续跟踪SRV/TXT/IP；注册成功回调到API37才存在，故不等待它才记录owner。 */
    private fun watch(key: String, info: NsdServiceInfo, token: Long) {
        val callback = object : NsdManager.ServiceInfoCallback {
            override fun onServiceInfoCallbackRegistrationFailed(code: Int) {
                if (generation == token && watchers[key] === this) { watchers.remove(key); resolved.remove(key); publish() }
            }
            override fun onServiceUpdated(value: NsdServiceInfo) {
                if (generation != token || watchers[key] !== this) return
                resolved.remove(key); endpoint(value)?.let { resolved[key] = it }; publish()
            }
            override fun onServiceLost() {
                if (generation == token && watchers[key] === this) { resolved.remove(key); publish() }
            }
            override fun onServiceInfoCallbackUnregistered() = Unit
        }
        watchers[key] = callback
        try { nsd.registerServiceInfoCallback(info, executor, callback) }
        catch (_: Exception) { watchers.remove(key); resolved.remove(key); publish() }
    }

    /** API31–33一次只提交一个系统解析，过期回调也必须先释放物理槽。 */
    @Suppress("DEPRECATION")
    private fun resolveNext() {
        if (physicalResolve != null || discovery == null || pending.isEmpty()) return
        val (key, info) = pending.removeFirst(); val token = generation
        val listener = object : NsdManager.ResolveListener {
            override fun onResolveFailed(value: NsdServiceInfo, code: Int) { main.post { finish(null) } }
            override fun onServiceResolved(value: NsdServiceInfo) { main.post { finish(value) } }
            override fun onResolutionStopped(value: NsdServiceInfo) { main.post { finish(null) } }
            /** 身份和浏览代次分别检查，迟到终态不能释放后继请求或发布旧地址。 */
            private fun finish(value: NsdServiceInfo?) {
                if (physicalResolve !== this) return
                physicalResolve = null
                resolveWatchdog?.let(main::removeCallbacks); resolveWatchdog = null
                if (generation == token && services[key] === info) {
                    resolved.remove(key); value?.let(::endpoint)?.let { resolved[key] = it }; publish()
                }
                resolveNext()
            }
        }
        physicalResolve = listener
        if (canCancelResolution()) {
            val watchdog = Runnable {
                // 取消也必须等待终态释放槽，不能在系统仍有旧请求时提交下一项。
                if (physicalResolve === listener) cancelResolution(listener)
            }
            resolveWatchdog = watchdog; main.postDelayed(watchdog, 15_000)
        }
        try { nsd.resolveService(info, listener) } catch (_: Exception) {
            physicalResolve = null; resolveWatchdog?.let(main::removeCallbacks); resolveWatchdog = null; resolveNext()
        }
    }
    private fun canCancelResolution(): Boolean = Build.VERSION.SDK_INT >= 34 ||
        (Build.VERSION.SDK_INT >= 33 && SdkExtensions.getExtensionVersion(Build.VERSION_CODES.TIRAMISU) >= 7)

    /** API31/32不释放仍被系统持有的请求，避免ALREADY_ACTIVE与无法回收的监听堆积。 */
    private fun cancelResolution(listener: NsdManager.ResolveListener) {
        if (canCancelResolution()) runCatching { nsd.stopServiceResolution(listener) }
    }
    /** 旧系统刷新一次性解析；新系统重试失败的持续监听，避免一次注册失败后永久缺席。 */
    private fun scheduleRefresh(token: Long) {
        val task = Runnable {
            if (generation == token && discovery != null) {
                services.forEach { (key, info) ->
                    if (Build.VERSION.SDK_INT >= 34) {
                        if (key !in watchers) watch(key, info, token)
                    } else if (pending.none { it.first == key }) pending.add(key to info)
                }
                resolveNext(); scheduleRefresh(token)
            }
        }
        refresh = task; main.postDelayed(task, 15_000)
    }
    /** 严格读取TXT及当前SRV，只接受桌面现有监听能力对应的私有IPv4。 */
    @Suppress("DEPRECATION")
    private fun endpoint(info: NsdServiceInfo): AndroidLanEndpoint? = runCatching {
        val attributes = info.attributes
        /** TXT 字段必须存在、有界且为合法 UTF-8。 */
        fun text(key: String): String {
            val bytes = requireNotNull(attributes[key]); require(bytes.size <= 256)
            return Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(bytes)).toString()
        }
        require(text("v") == "1")
        val id = text("id"); val name = text("name")
        require(MdnsProtocol.isCanonicalDeviceId(id) && MdnsProtocol.nameError(name) == null && info.port in 1..65535)
        val addresses = if (Build.VERSION.SDK_INT >= 34) info.hostAddresses else listOfNotNull(info.host)
        val address = addresses.firstOrNull { it is Inet4Address && !it.isLoopbackAddress && (it.isSiteLocalAddress || it.isLinkLocalAddress) }
            ?: return null
        AndroidLanEndpoint(id, name, InetSocketAddress(address, info.port), if (Build.VERSION.SDK_INT >= 33) info.network else null)
    }.getOrNull()
    /** 重复UUID广告拒绝自动选取，输出最多64个元信息且不包含可信状态。 */
    private fun publish() {
        changed(resolved.values.groupBy { it.id }.values.filter { it.size == 1 }.map { it.single() }.take(64))
    }
}
