package com.manonloki.lokimetrisdisplay

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.Proxy
import java.net.URL
import java.nio.ByteBuffer
import java.util.concurrent.CancellationException
import java.util.concurrent.ExecutionException
import java.util.concurrent.FutureTask
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** 短时只读 HTTP；JobService 的 worker 同步等待结果，取消或超时先结束等待，再异步断开连接。 */
class AndroidWidgetHttpClient @JvmOverloads constructor(
    private val now: () -> Long = System::currentTimeMillis,
    private val connectionFactory: (URL) -> HttpURLConnection = { it.openConnection(Proxy.NO_PROXY) as HttpURLConnection },
) : AutoCloseable {
    constructor(context: Context) : this(connectionFactory = { AndroidWidgetNetwork.open(context.applicationContext, it) })

    private class Attempt(val started: Long, val receivedAtMs: Long) {
        val expired = AtomicBoolean(false)
        val connection = AtomicReference<HttpURLConnection?>(null)
        val task = AtomicReference<FutureTask<TerminalWidgetSnapshot>?>(null)
    }
    private val cancelled = AtomicBoolean(false)
    private val current = AtomicReference<Attempt?>(null)

    /** 请求起点作为接收时间，避免慢响应覆盖请求期间到达的更新快照。 */
    fun fetch(target: AndroidWidgetTarget): TerminalWidgetSnapshot {
        if (cancelled.get()) throw AndroidWidgetHttpException("cancelled")
        val attempt = Attempt(System.nanoTime(), now())
        val task = FutureTask { perform(target, attempt) }
        attempt.task.set(task)
        if (!current.compareAndSet(null, attempt)) throw AndroidWidgetHttpException("busy")
        try {
            if (cancelled.get()) throw AndroidWidgetHttpException("cancelled")
            workers.execute(task)
            return task.get((TIMEOUT_NS - (System.nanoTime() - attempt.started)).coerceAtLeast(1), TimeUnit.NANOSECONDS)
        } catch (_: TimeoutException) {
            attempt.expired.set(true); abort(attempt)
            throw AndroidWidgetHttpException("timeout")
        } catch (_: CancellationException) {
            throw AndroidWidgetHttpException(if (attempt.expired.get()) "timeout" else "cancelled")
        } catch (_: InterruptedException) {
            abort(attempt); Thread.currentThread().interrupt(); throw AndroidWidgetHttpException("cancelled")
        } catch (_: RejectedExecutionException) {
            abort(attempt); throw AndroidWidgetHttpException("busy")
        } catch (error: ExecutionException) {
            throw (error.cause as? AndroidWidgetHttpException ?: AndroidWidgetHttpException("invalid_response"))
        } finally { current.compareAndSet(attempt, null) }
    }

    private fun perform(target: AndroidWidgetTarget, attempt: Attempt): TerminalWidgetSnapshot {
        var http: HttpURLConnection? = null
        try {
            target.validate(); require(attempt.receivedAtMs >= 0)
            checkActive(attempt)
            val nonce = AndroidWidgetCrypto.nonce()
            val body = JSONObject().put("clientId", target.sourceId).put("deviceId", target.deviceId)
                .put("nonce", AndroidWidgetCrypto.encode(nonce))
                .put("ciphertext", AndroidWidgetCrypto.request(target.key, nonce)).toString().toByteArray(Charsets.UTF_8)
            require(WidgetHttpPolicy.validRequestSize(body.size.toLong(), WidgetHttpClientProfile.ANDROID))
            val url = URL(WidgetHttpPolicy.SCHEME, target.host, target.port, WidgetHttpPolicy.PATH)
            http = connectionFactory(url)
            attempt.connection.set(http)
            checkActive(attempt)
            http.requestMethod = WidgetHttpPolicy.METHOD; http.instanceFollowRedirects = WidgetHttpPolicy.FOLLOW_REDIRECTS
            http.connectTimeout = TIMEOUT_MS; http.readTimeout = TIMEOUT_MS
            http.useCaches = false; http.defaultUseCaches = false; http.allowUserInteraction = false; http.doOutput = true
            http.setRequestProperty("Content-Type", WidgetHttpPolicy.MEDIA_TYPE)
            http.setRequestProperty("Accept", WidgetHttpPolicy.MEDIA_TYPE)
            http.setRequestProperty("Cache-Control", "no-store")
            http.setRequestProperty("Connection", "close")
            http.setRequestProperty("Cookie", ""); http.setRequestProperty("Cookie2", "")
            http.setFixedLengthStreamingMode(body.size)
            http.outputStream.use { it.write(body) }
            checkActive(attempt)
            require(WidgetHttpPolicy.acceptsResponse(http.responseCode, http.contentType, http.url == url))
            require(WidgetHttpPolicy.acceptsDeclaredResponseSize(http.contentLengthLong))
            val bytes = http.inputStream.use { stream -> readBounded(stream, MAX_RESPONSE_BYTES) { checkActive(attempt) } }
            checkActive(attempt)
            val envelope = json(bytes)
            val responseNonce = AndroidWidgetCrypto.decode(envelope.string("nonce"), WidgetHttpBinaryField.NONCE)
            val ciphertext = AndroidWidgetCrypto.decode(envelope.string("ciphertext"), WidgetHttpBinaryField.RESPONSE_CIPHERTEXT)
            val plaintext = AndroidWidgetCrypto.response(target.key, nonce, responseNonce, ciphertext)
            val message = try { json(plaintext) } finally { plaintext.fill(0) }
            require(WidgetHttpPolicy.acceptsMessageSource(target.sourceId, message.string("sourceId"), message.string("type")))
            val result = TerminalWidgetSnapshot(target.sourceId, attempt.receivedAtMs, summary(message)).also { it.validate() }
            checkActive(attempt)
            return result
        } catch (error: Exception) {
            if (cancelled.get()) throw AndroidWidgetHttpException("cancelled")
            if (attempt.expired.get() || System.nanoTime() - attempt.started >= TIMEOUT_NS) throw AndroidWidgetHttpException("timeout")
            if (error is AndroidWidgetHttpException) throw error
            throw AndroidWidgetHttpException(if (error is IOException) "network" else "invalid_response")
        } finally {
            attempt.connection.compareAndSet(http, null); http?.disconnect()
        }
    }

    /** disconnect 在部分系统会等待底层 I/O；先结束等待者，再在有界清理池中关闭 socket。 */
    fun cancel() { cancelled.set(true); current.get()?.let(::abort) }
    override fun close() = cancel()

    private fun abort(attempt: Attempt) {
        attempt.task.get()?.cancel(true)
        attempt.connection.getAndSet(null)?.let { connection -> aborters.execute { connection.disconnect() } }
    }

    private fun checkActive(attempt: Attempt) {
        if (cancelled.get()) throw AndroidWidgetHttpException("cancelled")
        if (attempt.expired.get() || System.nanoTime() - attempt.started >= TIMEOUT_NS) throw AndroidWidgetHttpException("timeout")
    }

    private fun json(bytes: ByteArray): JSONObject {
        val text = Charsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(bytes)).toString()
        TerminalJsonBoundary.validateObject(text)
        return JSONObject(text)
    }

    /** HTTP 的 Hook 只取四态，补齐空的图文字段后复用领域校验；用量和额度仍保留。 */
    private fun summary(message: JSONObject): TerminalSnapshot {
        val source = message.obj("snapshot")
        val hooks = JSONArray()
        source.array("hooks", 12).forEach { hook -> hooks.put(JSONObject()
            .put("agent", hook.string("agent")).put("slot", hook.int("slot")).put("behavior", hook.string("behavior"))
            .put("content", "").put("contentTruncated", false).put("image", JSONObject.NULL)) }
        val reduced = JSONObject().put("version", source.int("version"))
            .put("tokens", source.optionalObject("tokens") ?: JSONObject.NULL)
            .put("tokenError", source.optionalString("tokenError") ?: JSONObject.NULL)
            .put("hooksAvailable", source.bool("hooksAvailable")).put("hooks", hooks).put("assets", JSONArray())
            .put("catalogError", JSONObject.NULL).put("providerQuota", source.optionalObject("providerQuota") ?: JSONObject.NULL)
            .put("enabledAgents", source.optionalStringArray("enabledAgents", 14)?.let { JSONArray(it) } ?: JSONObject.NULL)
        return AndroidDisplayJson.snapshot(JSONObject().put("type", "snapshot").put("snapshot", reduced))
    }

    companion object {
        const val TIMEOUT_MS = WidgetHttpPolicy.TIMEOUT_MS
        private const val TIMEOUT_NS = TIMEOUT_MS * 1_000_000L
        const val MAX_RESPONSE_BYTES = WidgetHttpPolicy.MAX_RESPONSE_BYTES
        private val workers = ThreadPoolExecutor(0, 2, 30, TimeUnit.SECONDS, SynchronousQueue(),
            { task -> Thread(task, "loki-widget-http").apply { isDaemon = true } }, ThreadPoolExecutor.AbortPolicy())
        private val aborters = ThreadPoolExecutor(0, 2, 30, TimeUnit.SECONDS, SynchronousQueue(),
            { task -> Thread(task, "loki-widget-close").apply { isDaemon = true } }, ThreadPoolExecutor.DiscardPolicy())

        /** 逐块读取并在超出上限前失败；每块前调用 check 以响应取消。 */
        internal fun readBounded(stream: InputStream, max: Int, check: () -> Unit = {}): ByteArray {
            val output = ByteArrayOutputStream(minOf(max, 4096)); val buffer = ByteArray(4096)
            while (true) {
                check()
                val read = stream.read(buffer)
                if (read < 0) return output.toByteArray()
                require(WidgetHttpPolicy.fitsCapacity(output.size().toLong(), read.toLong(), max.toLong()))
                output.write(buffer, 0, read)
            }
        }
    }
}

/** 稳定错误不包含端点、密钥或服务端原文。 */
class AndroidWidgetHttpException(val reason: String) : IOException("widget_http_$reason")
