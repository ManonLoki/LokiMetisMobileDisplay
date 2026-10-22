import CryptoKit
import Foundation
import SharedLogic

/// Widget 独立读取桌面展示投影；凭据只进入加密请求，地址和响应都受固定边界约束。
struct WidgetHTTPClient {
    static let timeout = Double(WidgetHttpPolicy.shared.TIMEOUT_MS) / 1000
    static let maxResponseBytes = Int(WidgetHttpPolicy.shared.MAX_RESPONSE_BYTES)
    private static let requestContext = Data(WidgetHttpPolicy.shared.REQUEST_CONTEXT.utf8)
    private let configuration: URLSessionConfiguration
    private let now: () -> Date

    init(configuration: URLSessionConfiguration = .ephemeral, now: @escaping () -> Date = Date.init) {
        self.configuration = configuration
        self.now = now
    }

    /// 接收时间取请求起点，防止慢响应覆盖期间由宿主 App 收到的较新摘要。
    func fetch(_ target: WidgetRefreshTarget) async throws -> WidgetSnapshot {
        try Task.checkCancellation()
        try target.validate()
        let url = try target.requestURL()
        guard let receivedAtMs = Int64(exactly: (now().timeIntervalSince1970 * 1000).rounded(.towardZero)),
              (0...(Int64.max - WidgetSnapshot.leaseMs)).contains(receivedAtMs) else {
            throw WidgetHTTPError.invalidResponse
        }
        guard let keyBytes = WidgetHTTPBinary.decode(target.key, field: .key) else {
            throw WidgetHTTPError.invalidResponse
        }
        let key = SymmetricKey(data: keyBytes)
        let nonce = ChaChaPoly.Nonce()
        let requestNonce = Data(nonce)
        let sealed = try ChaChaPoly.seal(Self.requestContext, using: key, nonce: nonce, authenticating: Self.requestContext)
        let payload = Request(clientId: target.sourceId, deviceId: target.deviceId,
                              nonce: requestNonce.base64EncodedString(),
                              ciphertext: (sealed.ciphertext + sealed.tag).base64EncodedString())
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: Self.timeout)
        request.httpMethod = WidgetHttpPolicy.shared.METHOD
        request.setValue(WidgetHttpPolicy.shared.MEDIA_TYPE, forHTTPHeaderField: "Content-Type")
        request.setValue(WidgetHttpPolicy.shared.MEDIA_TYPE, forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        request.httpBody = try SharedJSON.encoder.encode(payload)
        guard WidgetHttpPolicy.shared.validRequestSize(bytes: Int64(request.httpBody?.count ?? 0), profile: .apple) else {
            throw WidgetHTTPError.invalidResponse
        }

        // 每次独立会话，不共享 Cookie、HTTP 认证、缓存或代理凭据。
        guard let config = configuration.copy() as? URLSessionConfiguration else { throw WidgetHTTPError.invalidResponse }
        config.timeoutIntervalForRequest = Self.timeout
        config.timeoutIntervalForResource = Self.timeout
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.connectionProxyDictionary = [:]
        let data = try await BoundedWidgetRequest().perform(request, configuration: config)
        try Task.checkCancellation()
        let response = try SharedJSON.decoder.decode(Response.self, from: data)
        guard let responseNonce = WidgetHTTPBinary.decode(response.nonce, field: .nonce),
              let ciphertext = WidgetHTTPBinary.decode(response.ciphertext, field: .responseCiphertext),
              WidgetHttpPolicy.shared.validResponseEnvelope(requestNonceBytes: Int64(requestNonce.count),
                  responseNonceBytes: Int64(responseNonce.count), ciphertextBytes: Int64(ciphertext.count)),
              let aad = WidgetHTTPBinary.responseAssociatedData(requestNonce) else {
            throw WidgetHTTPError.invalidResponse
        }
        let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: responseNonce),
                                         ciphertext: ciphertext.dropLast(Int(WidgetHttpPolicy.shared.TAG_BYTES)),
                                         tag: ciphertext.suffix(Int(WidgetHttpPolicy.shared.TAG_BYTES)))
        let plaintext = try ChaChaPoly.open(box, using: key, authenticating: aad)
        guard WidgetHttpPolicy.shared.validPlaintextSize(bytes: Int64(plaintext.count)) else {
            throw WidgetHTTPError.invalidResponse
        }
        let source = try SharedJSON.decoder.decode(Source.self, from: plaintext)
        guard WidgetHttpPolicy.shared.acceptsMessageSource(expectedSourceId: target.sourceId,
            sourceId: source.sourceId, type: source.type) else {
            throw WidgetHTTPError.invalidResponse
        }
        try Task.checkCancellation()
        return try WidgetSnapshot.authenticatedMessage(plaintext, sourceId: target.sourceId, receivedAtMs: receivedAtMs)
    }

    private struct Request: Encodable {
        let clientId: String
        let deviceId: String
        let nonce: String
        let ciphertext: String
    }
    private struct Response: Decodable { let nonce: String; let ciphertext: String }
    private struct Source: Decodable { let sourceId: String; let type: String }
}

/// 平台只负责 Base64 与固定小型字节桥接，字段长度和兼容接纳策略均调用 SharedLogic。
enum WidgetHTTPBinary {
    static func decode(_ text: String, field: WidgetHttpBinaryField) -> Data? {
        guard WidgetHttpPolicy.shared.acceptsBase64Input(characters: Int64(text.utf16.count), field: field, profile: .apple),
              let data = Data(base64Encoded: text),
              WidgetHttpPolicy.shared.acceptsDecodedBase64(field: field, profile: .apple,
                  decodedBytes: Int64(data.count), canonicalEncoding: data.base64EncodedString() == text) else { return nil }
        return data
    }

    static func responseAssociatedData(_ nonce: Data) -> Data? {
        guard WidgetHttpPolicy.shared.validNonceSize(bytes: Int64(nonce.count)) else { return nil }
        let input = KotlinByteArray(size: Int32(nonce.count))
        for (index, byte) in nonce.enumerated() { input.set(index: Int32(index), value: Int8(bitPattern: byte)) }
        guard let result = WidgetHttpPolicy.shared.responseAssociatedData(requestNonce: input) else { return nil }
        return Data((0..<Int(result.size)).map { UInt8(bitPattern: result.get(index: Int32($0))) })
    }
}

/// 错误不包含端点、密钥或服务端原文，调用方保留上次合法摘要。
enum WidgetHTTPError: Error { case invalidResponse, responseTooLarge, redirect }

/// 流式收集且只恢复一次 continuation；Widget 被取消时立即终止底层连接。
private final class BoundedWidgetRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var deadline: DispatchWorkItem?
    private var finished = false
    private var bytes = Data()

    /// 单次请求带截止时间与取消联动，响应体超限即中止。
    func perform(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(request, configuration: configuration, continuation: continuation)
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    private func start(_ request: URLRequest, configuration: URLSessionConfiguration,
                       continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: request)
        let deadline = DispatchWorkItem { [weak self] in self?.finish(.failure(URLError(.timedOut))) }
        self.session = session
        self.task = task
        self.deadline = deadline
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + WidgetHTTPClient.timeout, execute: deadline)
        task.resume()
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        let session = self.session
        let task = self.task
        let deadline = self.deadline
        self.continuation = nil
        self.session = nil
        self.task = nil
        self.deadline = nil
        lock.unlock()
        deadline?.cancel()
        task?.cancel()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse,
              WidgetHttpPolicy.shared.acceptsResponse(status: Int32(clamping: response.statusCode),
                  mediaType: response.mimeType, sameRequestURL: response.url == dataTask.originalRequest?.url) else {
            completionHandler(.cancel)
            finish(.failure(WidgetHTTPError.invalidResponse))
            return
        }
        guard WidgetHttpPolicy.shared.acceptsDeclaredResponseSize(bytes: response.expectedContentLength) else {
            completionHandler(.cancel)
            finish(.failure(WidgetHTTPError.responseTooLarge))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard WidgetHttpPolicy.shared.fitsCapacity(bufferedBytes: Int64(bytes.count), incomingBytes: Int64(data.count),
            maximumBytes: Int64(WidgetHTTPClient.maxResponseBytes)) else {
            lock.unlock()
            finish(.failure(WidgetHTTPError.responseTooLarge))
            return
        }
        bytes.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        lock.lock()
        let result = bytes
        lock.unlock()
        finish(.success(result))
    }

    /// 拒绝任何重定向，防止摘要请求被引向其他主机。
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard WidgetHttpPolicy.shared.FOLLOW_REDIRECTS else {
            completionHandler(nil)
            finish(.failure(WidgetHTTPError.redirect))
            return
        }
        completionHandler(request)
    }

    /// 不接受系统凭据质询，认证只依赖请求内密钥。
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}
