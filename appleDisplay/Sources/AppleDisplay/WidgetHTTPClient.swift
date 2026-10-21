import CryptoKit
import Foundation

/// Widget 独立读取桌面展示投影；凭据只进入加密请求，地址和响应都受固定边界约束。
struct WidgetHTTPClient {
    static let timeout: TimeInterval = 6
    static let maxResponseBytes = 96 * 1024
    private static let requestContext = Data("loki-widget-request-v1".utf8)
    private static let responseContext = Data("loki-widget-response-v1".utf8)
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
        guard let keyBytes = Data(base64Encoded: target.key), keyBytes.count == 32 else {
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
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        request.httpBody = try SharedJSON.encoder.encode(payload)

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
        guard let responseNonce = Data(base64Encoded: response.nonce), responseNonce.count == 12,
              let ciphertext = Data(base64Encoded: response.ciphertext),
              (16...(WidgetSnapshot.maxBytes + 16)).contains(ciphertext.count) else {
            throw WidgetHTTPError.invalidResponse
        }
        let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: responseNonce),
                                         ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16))
        let plaintext = try ChaChaPoly.open(box, using: key,
                                           authenticating: Self.responseContext + requestNonce)
        guard plaintext.count <= WidgetSnapshot.maxBytes,
              try SharedJSON.decoder.decode(Source.self, from: plaintext).sourceId == target.sourceId else {
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
    private struct Source: Decodable { let sourceId: String }
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
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.mimeType?.lowercased() == "application/json",
              response.url == dataTask.originalRequest?.url else {
            completionHandler(.cancel)
            finish(.failure(WidgetHTTPError.invalidResponse))
            return
        }
        guard response.expectedContentLength <= WidgetHTTPClient.maxResponseBytes else {
            completionHandler(.cancel)
            finish(.failure(WidgetHTTPError.responseTooLarge))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard data.count <= WidgetHTTPClient.maxResponseBytes - bytes.count else {
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
        completionHandler(nil)
        finish(.failure(WidgetHTTPError.redirect))
    }

    /// 不接受系统凭据质询，认证只依赖请求内密钥。
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}
