package com.manonloki.lokimetrisdisplay

import org.json.JSONObject
import java.net.InetSocketAddress
import java.nio.file.Files
import java.util.Comparator
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.swing.SwingUtilities
import kotlin.test.*

/** 真实 JNI + Rust + TCP 配对与同步；发现和用户输入使用隔离夹具，不接触真实采集端。 */
class DesktopConnectionIntegrationTest {
    @Test fun pairsPersistsResumesSynchronizesImagesAndClearsOnDisconnect() {
        val directory = Files.createTempDirectory("loki-desktop-protocol-test-")
        val errors = directory.resolve("fixture-errors.log")
        val process = ProcessBuilder(requireNotNull(System.getProperty("loki.desktop.testServer")))
            .redirectError(errors.toFile()).start()
        val reader = process.inputStream.bufferedReader()
        val writer = process.outputStream.bufferedWriter()
        val input = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "fixture-events").apply { isDaemon = true } }
        fun event(): JSONObject = JSONObject(requireNotNull(input.submit<String?> { reader.readLine() }.get(30, TimeUnit.SECONDS)))
        var engine: DesktopLanEngine? = null
        try {
            val port = event().getInt("port")
            val settings = DesktopDeviceSettings(directory)
            val hostId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
            val owner = DesktopLanEngine(settings) { changed, _ ->
                object : DesktopDiscovery {
                    override fun start() { changed(listOf(DesktopLanEndpoint(hostId, "Isolated collector", InetSocketAddress("127.0.0.1", port)))) }
                    override fun close() = Unit
                }
            }
            engine = owner
            SwingUtilities.invokeAndWait { owner.setListener { assertTrue(SwingUtilities.isEventDispatchThread()) } }
            awaitState { owner.state.view.hosts.any { it.id == hostId && it.available } }
            assertFalse(owner.state.view.connected)
            assertNull(owner.state.view.pairingCode, "Discovery must not open a pairing window")
            owner.select(hostId)
            awaitState { owner.state.view.pairingCode != null }
            writer.write(requireNotNull(owner.state.view.pairingCode)); writer.newLine(); writer.flush()
            assertTrue(event().getBoolean("streaming"), "Rust peer must verify PAD identity, image request and pong")
            awaitState { owner.state.view.connected && owner.state.images.isNotEmpty() }
            val view = owner.state.view
            assertEquals("1000000001", view.snapshot?.tokens?.all?.total)
            assertEquals("桌面真实通道测试 🖥️🚀 中文与 emoji", view.snapshot?.hooks?.single()?.content)
            val asset = requireNotNull(view.snapshot).assets.single()
            val bytes = requireNotNull(owner.state.images[asset.hash])
            assertEquals(asset.length, bytes.size.toLong())
            assertEquals(1, decodeDesktopHookImage(bytes).frames.size)
            assertTrue(view.hosts.single().paired)
            assertNull(view.pairingCode)
            assertEquals(setOf(hostId), DesktopPairingStore(directory, settings.deviceId).clientIds())
            assertEquals(settings.deviceId, DesktopDeviceSettings(directory).deviceId)

            writer.write("disconnect"); writer.newLine(); writer.flush()
            assertTrue(event().getBoolean("disconnected"))
            awaitState { !owner.state.view.connected && owner.state.view.snapshot == null && owner.state.images.isEmpty() }
            assertTrue(DesktopPairingStore(directory, settings.deviceId).clientIds().contains(hostId))
            assertTrue(process.waitFor(5, TimeUnit.SECONDS))
            assertEquals(0, process.exitValue(), "Isolated Rust collector must finish successfully")
            owner.close()
            awaitState { owner.state.view.status == "连接已关闭" }
        } finally {
            engine?.close()
            process.destroyForcibly(); process.waitFor(5, TimeUnit.SECONDS)
            input.shutdownNow()
            Files.walk(directory).use { files -> files.sorted(Comparator.reverseOrder()).forEach(Files::deleteIfExists) }
        }
    }

    private fun awaitState(predicate: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(20)
        while (!predicate()) {
            check(System.nanoTime() < deadline) { "Desktop connection did not reach expected state" }
            Thread.sleep(10)
        }
    }
}
