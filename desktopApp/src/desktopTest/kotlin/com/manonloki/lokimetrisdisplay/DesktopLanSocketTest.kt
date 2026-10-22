package com.manonloki.lokimetrisdisplay

import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.nio.ByteBuffer
import java.nio.channels.Selector
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.*

class DesktopLanSocketTest {
    @Test fun realSelectorWritesAndReadsLengthFramedJson() {
        val server = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        val executor = Executors.newSingleThreadExecutor()
        val peer = executor.submit<String> {
            server.accept().use { client ->
                client.soTimeout = 5000
                val input = DataInputStream(client.getInputStream()); val size = input.readInt()
                val request = ByteArray(size); input.readFully(request)
                val response = "{\"type\":\"reply\",\"value\":123}".toByteArray()
                val frame = ByteBuffer.allocate(response.size + 4).putInt(response.size).put(response).array()
                val output = client.getOutputStream()
                output.write(frame, 0, 2); output.flush(); output.write(frame, 2, frame.size - 2); output.flush()
                request.toString(Charsets.UTF_8)
            }
        }
        Selector.open().use { selector ->
            var response: JSONObject? = null; var writeCompleted = false
            lateinit var socket: DesktopLanSocket
            var created = false
            try {
                socket = DesktopLanSocket(DesktopLanEndpoint("fixture", "Fixture", InetSocketAddress("127.0.0.1", server.localPort)), selector,
                    { 4096 }, { socket.send(JSONObject().put("type", "hello"), 4096) { writeCompleted = true } }, { response = it })
                created = true; socket.begin()
                val end = System.nanoTime() + 5_000_000_000
                while (response == null && System.nanoTime() < end) {
                    if (selector.select(100) > 0) { socket.process(System.nanoTime() / 1_000_000); selector.selectedKeys().clear() }
                }
                assertTrue(writeCompleted); assertEquals(123, assertNotNull(response).int("value"))
                assertEquals("hello", JSONObject(peer.get(5, TimeUnit.SECONDS)).string("type"))
            } finally { if (created) socket.close(); server.close(); executor.shutdownNow() }
        }
    }
    @Test fun oversizedInboundFrameIsRejectedBeforePayloadAllocation() {
        val server = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        val executor = Executors.newSingleThreadExecutor()
        executor.submit { server.accept().use { DataOutputStream(it.getOutputStream()).apply { writeInt(Int.MAX_VALUE); flush() } } }
        Selector.open().use { selector ->
            val socket = DesktopLanSocket(DesktopLanEndpoint("fixture", "Fixture", InetSocketAddress("127.0.0.1", server.localPort)), selector,
                { 4096 }, {}, { fail("oversized frame reached JSON parser") })
            try {
                socket.begin(); val end = System.nanoTime() + 5_000_000_000
                var rejected = false
                while (!rejected && System.nanoTime() < end) {
                    if (selector.select(100) > 0) {
                        try { socket.process(System.nanoTime() / 1_000_000) } catch (_: IllegalArgumentException) { rejected = true }
                        selector.selectedKeys().clear()
                    }
                }
                assertTrue(rejected)
            } finally { socket.close(); server.close(); executor.shutdownNow() }
        }
    }
}
