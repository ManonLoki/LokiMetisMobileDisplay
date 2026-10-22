import CryptoKit
import Foundation
import Network
import XCTest
@testable import AppleDisplay

/// 可控 URLProtocol 验证真实客户端加解密、流边界和取消；环回 HTTP 验证系统重定向行为。
final class WidgetHTTPClientTests: XCTestCase {
    private let source = "12345678-1234-4234-8234-123456789abc"
    private let device = "23456789-2345-4345-8345-23456789abcd"
    private let key = Data(0..<32)
    private var fixtureIds: [String] = []
    private var message: Data {
        Data((#"{"type":"snapshot","sourceId":""# + source +
              #"","snapshot":{"version":1,"tokens":null,"tokenError":"unavailable","hooksAvailable":true,"hooks":[{"agent":"codex","slot":1,"behavior":"running","content":"private-hook-body"}]}}"#).utf8)
    }

    override func tearDown() {
        fixtureIds.forEach { WidgetHTTPFixture.remove($0) }
        fixtureIds = []
        super.tearDown()
    }

    private func target(port: Int = 12345) throws -> WidgetRefreshTarget {
        try WidgetRefreshTarget(sourceId: source, deviceId: device, host: "127.0.0.1", port: port,
                                key: key.base64EncodedString())
    }

    private func client(_ handler: @escaping WidgetHTTPFixture.Handler) -> WidgetHTTPClient {
        let id = WidgetHTTPFixture.install(handler)
        fixtureIds.append(id)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WidgetHTTPFixture.self]
        configuration.httpAdditionalHeaders = ["X-Widget-Test-ID": id]
        return WidgetHTTPClient(configuration: configuration, now: { Date(timeIntervalSince1970: 3) })
    }

    private func request(_ fixture: WidgetHTTPFixture) throws -> (nonce: Data, ciphertext: Data) {
        struct Request: Decodable { let clientId: String; let deviceId: String; let nonce: String; let ciphertext: String }
        let body: Data
        if let data = fixture.request.httpBody { body = data }
        else if let stream = fixture.request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0, data.count + count <= 4096 else { throw WidgetHTTPError.invalidResponse }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            body = data
        } else { throw WidgetHTTPError.invalidResponse }
        let value = try JSONDecoder().decode(Request.self, from: body)
        XCTAssertEqual(value.clientId, source)
        XCTAssertEqual(value.deviceId, device)
        XCTAssertEqual(fixture.request.httpMethod, "POST")
        XCTAssertEqual(fixture.request.url?.path, "/api/widget/v1/snapshot")
        XCTAssertNil(fixture.request.url?.query)
        XCTAssertNil(fixture.request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(fixture.request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains(key.base64EncodedString()))
        let nonce = try XCTUnwrap(Data(base64Encoded: value.nonce))
        let ciphertext = try XCTUnwrap(Data(base64Encoded: value.ciphertext))
        XCTAssertEqual(nonce.count, 12)
        let sealed = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce),
                                            ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16))
        let plaintext = try ChaChaPoly.open(sealed, using: SymmetricKey(data: key),
                                           authenticating: Data("loki-widget-request-v1".utf8))
        XCTAssertEqual(plaintext, Data("loki-widget-request-v1".utf8))
        return (nonce, ciphertext)
    }

    private func encrypted(_ plaintext: Data, requestNonce: Data, responseKey: Data? = nil) throws -> Data {
        let nonce = try ChaChaPoly.Nonce(data: Data(32..<44))
        let sealed = try ChaChaPoly.seal(plaintext, using: SymmetricKey(data: responseKey ?? key), nonce: nonce,
                                        authenticating: Data("loki-widget-response-v1".utf8) + requestNonce)
        return try JSONSerialization.data(withJSONObject: ["nonce": Data(nonce).base64EncodedString(),
                                                          "ciphertext": (sealed.ciphertext + sealed.tag).base64EncodedString()])
    }

    @discardableResult
    private func failure(_ client: WidgetHTTPClient, target: WidgetRefreshTarget? = nil,
                         file: StaticString = #filePath, line: UInt = #line) async throws -> Error {
        do {
            _ = try await client.fetch(try target ?? self.target())
            XCTFail("Invalid HTTP response must not become a snapshot", file: file, line: line)
            return WidgetHTTPError.invalidResponse
        } catch { return error }
    }

    /// 固定服务器密钥/Nonce 夹具验证双向 ChaCha20-Poly1305 与请求起点时间。
    func test_encrypted_request_and_bound_response_create_projected_snapshot() async throws {
        let client = client { fixture in
            let request = try self.request(fixture)
            fixture.respond(try self.encrypted(self.message, requestNonce: request.nonce))
        }
        let value = try await client.fetch(target())
        XCTAssertEqual(value.sourceId, source)
        XCTAssertEqual(value.receivedAtMs, 3000)
        XCTAssertEqual(value.validUntilMs, 48_000)
        XCTAssertEqual(value.snapshot.hooks.first?.behavior, .running)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(value), as: UTF8.self).contains("private-hook-body"))
    }

    /// 与桌面 Rust 测试共享固定公开夹具，验证 HKDF 和 AEAD 的字节级兼容性。
    func test_cross_language_hkdf_and_encrypted_request_vector() throws {
        let source = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let device = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(repeating: 0xa7, count: 32)),
            salt: Data((source + "/" + device).utf8), info: Data("LokiMetris/widget-http/1/read-only".utf8), outputByteCount: 32)
        XCTAssertEqual(key.withUnsafeBytes { Data($0).base64EncodedString() }, "lRknhcPotblkxFclfQ/VvPvqBMbhA3J+2WPJ+fIB+eo=")
        let context = Data("loki-widget-request-v1".utf8)
        let nonce = try ChaChaPoly.Nonce(data: Data(repeating: 3, count: 12))
        let sealed = try ChaChaPoly.seal(context, using: key, nonce: nonce, authenticating: context)
        XCTAssertEqual(Data(nonce).base64EncodedString(), "AwMDAwMDAwMDAwMD")
        XCTAssertEqual((sealed.ciphertext + sealed.tag).base64EncodedString(),
                       "Xb0+fryh6yKmj9ynUJN1ibves2wo6z40FJxtUvoAbZtNdXluBiI=")
    }

    /// Foundation 继续决定响应 Base64 可解码性，读取密钥仍要求规范；共享层校验字段界限。
    func test_shared_binary_policy_preserves_apple_decoder_and_exact_aad_bytes() throws {
        let canonicalKey = Data(repeating: 0, count: 32).base64EncodedString()
        let noncanonicalKey = String(canonicalKey.dropLast(2)) + "B="
        XCTAssertNil(WidgetHTTPBinary.decode(noncanonicalKey, field: .key))
        XCTAssertEqual(WidgetHTTPBinary.decode(canonicalKey, field: .key), Data(repeating: 0, count: 32))
        let canonicalCipher = Data(repeating: 0, count: 16).base64EncodedString()
        let noncanonicalCipher = String(canonicalCipher.dropLast(3)) + "B=="
        XCTAssertEqual(WidgetHTTPBinary.decode(noncanonicalCipher, field: .responseCiphertext),
                       Data(base64Encoded: noncanonicalCipher))
        XCTAssertNil(WidgetHTTPBinary.decode(Data(repeating: 0, count: 11).base64EncodedString(), field: .nonce))
        XCTAssertNil(WidgetHTTPBinary.decode(Data(repeating: 0, count: 15).base64EncodedString(), field: .responseCiphertext))
        let nonce = Data(128..<140)
        XCTAssertEqual(WidgetHTTPBinary.responseAssociatedData(nonce), Data("loki-widget-response-v1".utf8) + nonce)
        XCTAssertNil(WidgetHTTPBinary.responseAssociatedData(Data(repeating: 0, count: 11)))
    }

    /// 请求使用新随机 Nonce，上一轮响应不能重放到下一轮。
    func test_fresh_request_nonce_rejects_replayed_response() async throws {
        var response: Data?
        var nonces: [Data] = []
        let client = client { fixture in
            let request = try self.request(fixture)
            nonces.append(request.nonce)
            if response == nil { response = try self.encrypted(self.message, requestNonce: request.nonce) }
            fixture.respond(try XCTUnwrap(response))
        }
        _ = try await client.fetch(target())
        _ = try await failure(client)
        XCTAssertEqual(nonces.count, 2)
        XCTAssertNotEqual(nonces.first, nonces.last)
    }

    /// 完整性失败、错误密钥、错误请求绑定、其他桌面与无效展示值都拒绝入库。
    func test_rejects_tampered_unbound_and_invalid_snapshots() async throws {
        for mode in 0..<5 {
            let client = client { fixture in
                let request = try self.request(fixture)
                var message = self.message
                if mode == 3 {
                    message = Data(String(decoding: message, as: UTF8.self).replacingOccurrences(of: self.source, with: self.device).utf8)
                }
                if mode == 4 {
                    message = Data(String(decoding: message, as: UTF8.self).replacingOccurrences(of: "\"slot\":1", with: "\"slot\":0").utf8)
                }
                var response = try self.encrypted(message,
                    requestNonce: mode == 2 ? Data(repeating: 0, count: 12) : request.nonce,
                    responseKey: mode == 1 ? Data(repeating: 0, count: 32) : nil)
                if mode == 0 {
                    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: String])
                    var ciphertext = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(json["ciphertext"])))
                    ciphertext[0] ^= 1
                    json["ciphertext"] = ciphertext.base64EncodedString()
                    response = try JSONSerialization.data(withJSONObject: json)
                }
                fixture.respond(response)
            }
            _ = try await failure(client)
        }
    }

    /// 声明大小和真实流大小分别受限，不能先无限分配再检查。
    func test_rejects_declared_and_streamed_oversized_responses() async throws {
        let declared = client { fixture in
            fixture.respond(Data(), headers: ["Content-Length": String(WidgetHTTPClient.maxResponseBytes + 1)])
        }
        let declaredError = try await failure(declared)
        XCTAssertTrue(declaredError is WidgetHTTPError)
        let streamed = client { fixture in
            fixture.respond(Data(repeating: 32, count: WidgetHTTPClient.maxResponseBytes + 1), chunkSize: 40_000)
        }
        let streamedError = try await failure(streamed)
        XCTAssertTrue(streamedError is WidgetHTTPError)
    }

    /// 有效密文也不能超过展示协议原有的 64 KiB 上限。
    func test_rejects_decrypted_payload_above_snapshot_limit() async throws {
        let client = client { fixture in
            let request = try self.request(fixture)
            fixture.respond(try self.encrypted(Data(repeating: 32, count: WidgetSnapshot.maxBytes + 1), requestNonce: request.nonce))
        }
        _ = try await failure(client)
    }

    /// 非 JSON、失败状态、短 Nonce 或缺失密文不能冒充成功摘要。
    func test_rejects_status_content_type_and_malformed_envelopes() async throws {
        for (status, type, body) in [(401, "application/json", "{}"), (200, "text/plain", "{}"),
                                     (200, "application/json", #"{"nonce":"AA==","ciphertext":"AA=="}"#),
                                     (200, "application/json", "broken")] {
            let client = client { $0.respond(Data(body.utf8), status: status, headers: ["Content-Type": type]) }
            _ = try await failure(client)
        }
    }

    /// 调用取消传播到底层会话，不等待资源超时且不会二次恢复 continuation。
    func test_cancellation_stops_inflight_request() async throws {
        let started = expectation(description: "request started")
        let stopped = expectation(description: "request cancelled")
        let client = client { fixture in fixture.onStop = { stopped.fulfill() }; started.fulfill() }
        let target = try target()
        let task = Task { try await client.fetch(target) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request returned a snapshot") }
        catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [stopped], timeout: 2)
    }

    /// 无响应服务器也受整个请求的六秒期限约束，不由对端继续传字节拖延。
    func test_stalled_request_has_total_deadline() async throws {
        let client = client { _ in }
        let start = Date()
        let error = try await failure(client)
        XCTAssertEqual((error as? URLError)?.code, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 8)
    }

    /// 使用真实环回 HTTP 302，确认 URLSession 不将加密请求转发给重定向地址。
    func test_real_http_redirect_is_rejected_without_following() async throws {
        let queue = DispatchQueue(label: "test.widget.http." + UUID().uuidString)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let ready = expectation(description: "HTTP listener ready")
        // 状态仅由 listener 的串行队列访问。
        final class ServerState: @unchecked Sendable {
            var peers: [NWConnection] = []
            var connections = 0
        }
        let state = ServerState()
        listener.newConnectionHandler = { peer in
            state.connections += 1
            state.peers.append(peer)
            peer.start(queue: queue)
            peer.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                guard let port = listener.port else { return }
                let response = "HTTP/1.1 302 Found\r\nContent-Type: application/json\r\nContent-Length: 0\r\nLocation: http://127.0.0.1:\(port.rawValue)/redirected\r\nConnection: close\r\n\r\n"
                peer.send(content: Data(response.utf8), completion: .contentProcessed { _ in peer.cancel() })
            }
        }
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: queue)
        defer {
            queue.sync {
                state.peers.forEach { $0.cancel() }
                listener.newConnectionHandler = nil
                listener.stateUpdateHandler = nil
                listener.cancel()
            }
        }
        await fulfillment(of: [ready], timeout: 2)
        let port = try XCTUnwrap(listener.port)
        let error = try await failure(WidgetHTTPClient(), target: target(port: Int(port.rawValue)))
        guard case WidgetHTTPError.redirect = error else { XCTFail("Expected rejected redirect, got \(type(of: error))"); return }
        XCTAssertEqual(queue.sync { state.connections }, 1)
    }
}

/// 每个会话以测试专用标识隔离夹具，避免并发测试互换响应。
private final class WidgetHTTPFixture: URLProtocol {
    typealias Handler = (WidgetHTTPFixture) throws -> Void
    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]
    var onStop: (() -> Void)?

    static func install(_ handler: @escaping Handler) -> String {
        let id = UUID().uuidString
        lock.lock(); defer { lock.unlock() }
        handlers[id] = handler
        return id
    }

    static func remove(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        handlers.removeValue(forKey: id)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = request.value(forHTTPHeaderField: "X-Widget-Test-ID").flatMap { Self.handlers[$0] }
        Self.lock.unlock()
        do {
            guard let handler else { throw WidgetHTTPError.invalidResponse }
            try handler(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    override func stopLoading() { onStop?() }

    func respond(_ body: Data, status: Int = 200, headers: [String: String] = [:], chunkSize: Int = 32_000) {
        var headers = headers
        if headers["Content-Type"] == nil { headers["Content-Type"] = "application/json" }
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for offset in stride(from: 0, to: body.count, by: chunkSize) {
            client?.urlProtocol(self, didLoad: body.subdata(in: offset..<min(offset + chunkSize, body.count)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}
