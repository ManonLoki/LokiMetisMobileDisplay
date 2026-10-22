package com.manonloki.lokimetrisdisplay

import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.StandardProtocolFamily
import java.net.StandardSocketOptions
import java.nio.ByteBuffer
import java.nio.channels.DatagramChannel
import java.nio.channels.Selector
import java.nio.channels.SelectionKey
import java.util.concurrent.atomic.AtomicBoolean

/** DNS-SD 只是临时连接候选，授信与实际展示始终等待 Rust 认证。 */
data class DesktopLanEndpoint(val id: String, val name: String, val address: InetSocketAddress, val interfaceIndex: Int = 0)

internal interface DesktopDiscovery : AutoCloseable { fun start() }

/** 每张有效 IPv4 网卡独立加入 mDNS 组；网卡变更、TTL、goodbye 都会撤销旧候选。 */
internal class DesktopLanBrowser(private val changed: (List<DesktopLanEndpoint>) -> Unit, private val failed: () -> Unit) : DesktopDiscovery {
    private data class InterfaceSocket(val network: NetworkInterface, val channel: DatagramChannel, val cache: DesktopDnsCache)
    private val clockOrigin = System.nanoTime()
    private val running = AtomicBoolean(false)
    private val refresh = AtomicBoolean(false)
    private val selector = Selector.open()
    private var worker: Thread? = null
    private var lastPublished = emptyList<DesktopLanEndpoint>()
    private val multicast = InetSocketAddress(InetAddress.getByName("224.0.0.251"), 5353)

    @Synchronized override fun start() {
        if (running.getAndSet(true)) { refresh.set(true); selector.wakeup(); return }
        check(selector.isOpen)
        worker = Thread(::run, "loki-desktop-mdns").apply { isDaemon = true; start() }
    }
    private fun run() {
        val sockets = mutableMapOf<Int, InterfaceSocket>()
        var nextInterfaces = 0L; var nextQuery = 0L; var reportedFailure = false
        val buffer = ByteBuffer.allocate(16_385)
        try {
            while (running.get()) {
                val now = (System.nanoTime() - clockOrigin) / 1_000_000
                if (refresh.getAndSet(false)) { nextInterfaces = 0; nextQuery = 0 }
                if (now >= nextInterfaces) {
                    val available = NetworkInterface.getNetworkInterfaces()?.toList().orEmpty().filter { network ->
                        runCatching { network.isUp && network.supportsMulticast() && !network.isLoopback && network.inetAddresses.toList().any { it is Inet4Address } }.getOrDefault(false)
                    }.take(16).associateBy { it.index }
                    (sockets.keys - available.keys).forEach { index -> sockets.remove(index)?.channel?.close() }
                    available.forEach { (index, network) -> if (index !in sockets) {
                        var channel: DatagramChannel? = null
                        try {
                            channel = DatagramChannel.open(StandardProtocolFamily.INET)
                            channel.setOption(StandardSocketOptions.SO_REUSEADDR, true)
                            channel.bind(InetSocketAddress(5353)); channel.configureBlocking(false)
                            channel.setOption(StandardSocketOptions.IP_MULTICAST_IF, network)
                            channel.setOption(StandardSocketOptions.IP_MULTICAST_TTL, 255)
                            channel.join(multicast.address, network)
                            val value = InterfaceSocket(network, channel, DesktopDnsCache())
                            channel.register(selector, SelectionKey.OP_READ, value); sockets[index] = value
                        } catch (_: Exception) { runCatching { channel?.close() } }
                    } }
                    if (sockets.isEmpty() && !reportedFailure) { failed(); reportedFailure = true }
                    if (sockets.isNotEmpty()) reportedFailure = false
                    nextInterfaces = now + 15_000
                }
                sockets.values.forEach { it.cache.expire(now) }
                if (now >= nextQuery) {
                    sockets.values.forEach { value -> runCatching {
                        value.channel.send(ByteBuffer.wrap(DesktopDnsCodec.query(value.cache.questions())), multicast)
                    } }
                    nextQuery = now + 5_000
                }
                publish(sockets.values.toList())
                selector.select(1_000)
                val selected = selector.selectedKeys().iterator()
                while (selected.hasNext()) {
                    val key = selected.next(); selected.remove()
                    if (!key.isValid || !key.isReadable) continue
                    val value = key.attachment() as InterfaceSocket
                    // 每轮最多处理 32 包，持续广播也不能饿死网卡和 TTL 检查。
                    repeat(32) {
                        buffer.clear()
                        val source = value.channel.receive(buffer) as? InetSocketAddress ?: return@repeat
                        if (source.port != 5353 || buffer.position() > 16_384) return@repeat
                        val bytes = ByteArray(buffer.position()); buffer.flip(); buffer.get(bytes)
                        runCatching { value.cache.accept(DesktopDnsCodec.parse(bytes), (System.nanoTime() - clockOrigin) / 1_000_000) }
                    }
                }
            }
        } catch (_: Exception) { if (running.get()) failed() }
        finally {
            running.set(false)
            sockets.values.forEach { runCatching { it.channel.close() } }
            if (lastPublished.isNotEmpty()) { lastPublished = emptyList(); changed(emptyList()) }
        }
    }
    private fun publish(sockets: List<InterfaceSocket>) {
        data class Candidate(val endpoint: DesktopLanEndpoint, val serviceIdentity: String)
        val candidates = sockets.flatMap { value ->
            value.cache.values(DesktopDnsCodec.SERVICE, 12).filterIsInstance<DesktopDnsData.Pointer>().take(64).mapNotNull { pointer ->
                val txt = value.cache.values(pointer.target, 16).filterIsInstance<DesktopDnsData.Text>().singleOrNull()?.fields ?: return@mapNotNull null
                val service = value.cache.values(pointer.target, 33).filterIsInstance<DesktopDnsData.Service>().singleOrNull() ?: return@mapNotNull null
                val id = txt["id"] ?: return@mapNotNull null; val name = txt["name"] ?: return@mapNotNull null
                if (txt["v"] != "1" || !MdnsProtocol.isCanonicalDeviceId(id) || MdnsProtocol.nameError(name) != null || service.port !in 1..65535) return@mapNotNull null
                val addresses = (value.cache.values(service.host, 1) + value.cache.values(service.host, 28))
                    .filterIsInstance<DesktopDnsData.Address>().mapNotNull { data -> runCatching {
                        val bytes = data.bytes.toByteArray()
                        if (bytes.size == 16) Inet6Address.getByAddress(null, bytes, value.network) else InetAddress.getByAddress(bytes)
                    }.getOrNull() }.filter { address ->
                        !address.isAnyLocalAddress && !address.isMulticastAddress && (address.isLoopbackAddress || address.isSiteLocalAddress ||
                            address.isLinkLocalAddress || address.address.size == 16 && address.address[0].toInt() and 0xfe == 0xfc)
                    }.sortedWith(compareBy<InetAddress> { it.isLoopbackAddress }.thenBy { it !is Inet4Address }.thenBy { it.hostAddress })
                val address = addresses.firstOrNull() ?: return@mapNotNull null
                Candidate(DesktopLanEndpoint(id, name, InetSocketAddress(address, service.port), value.network.index),
                    "${pointer.target}|${service.host}|${service.port}|$name")
            }
        }
        // 同一服务跨网卡仅选一个可路由地址；同 UUID 不同服务拒绝自动选取。
        val endpoints = candidates.groupBy { it.endpoint.id }.values.mapNotNull { group ->
            if (group.map { it.serviceIdentity }.distinct().size == 1) group.minBy { it.endpoint.interfaceIndex }.endpoint else null
        }.sortedBy { it.id }.take(64)
        if (endpoints != lastPublished) { lastPublished = endpoints; changed(endpoints) }
    }
    override fun close() {
        running.set(false); selector.wakeup()
        if (worker !== Thread.currentThread()) worker?.join(2_000)
        selector.close()
    }
}
