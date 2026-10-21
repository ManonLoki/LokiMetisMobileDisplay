import Foundation
import Network
import XCTest
@testable import AppleDisplay

/// 真实环回TCP验证适配器收帧与失败收尾，不替代iOS App或实际局域网E2E。
final class LanSocketTests: XCTestCase {
    /// 只在环回临时端口运行，测试结束在owner队列关闭两端及监听器。
    private func run(serverBytes: Data, expected: XCTestExpectation,
                     received: @escaping (LanSocket, [String: Any]) throws -> Void,
                     ended: @escaping (LanSocket.Failure) -> Void) throws {
        let queue = DispatchQueue(label: "test.loki.socket." + UUID().uuidString)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        var peers: [NWConnection] = []
        var client: LanSocket?
        listener.newConnectionHandler = { peer in
            peers.append(peer)
            peer.stateUpdateHandler = { state in
                if case .ready = state { peer.send(content: serverBytes, completion: .contentProcessed { _ in }) }
            }
            peer.start(queue: queue)
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port, client == nil {
                client = LanSocket(endpoint: .hostPort(host: .ipv4(.loopback), port: port), queue: queue,
                    limit: { 4096 }, ready: {}, frame: { json in
                        guard let client else { throw WidgetSnapshotError.invalid }
                        try received(client, json)
                    }, ended: ended)
                client?.start()
            }
        }
        listener.start(queue: queue)
        wait(for: [expected], timeout: 5)
        queue.sync {
            client?.close(); client = nil
            peers.forEach { $0.stateUpdateHandler = nil; $0.cancel() }; peers = []
            listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil; listener.cancel()
        }
    }

    /// 与真实Network连接收发的UTF-8 JSON保持一致，EOF或额外包装不会被误当业务载荷。
    func test_real_socket_delivers_one_complete_json_frame() throws {
        let expected = expectation(description: "received complete frame")
        let bytes = try LanFrames.encode(Data(#"{"hello":"你好"}"#.utf8), limit: 4096)
        try run(serverBytes: bytes, expected: expected, received: { socket, json in
            XCTAssertEqual(json["hello"] as? String, "你好")
            XCTAssertEqual(socket.connectedHost, "127.0.0.1")
            socket.close(); expected.fulfill()
        }, ended: { _ in XCTFail("valid socket unexpectedly closed"); expected.fulfill() })
    }

    /// Bonjour 的 IPv4 可带接口限定；原描述会被目标校验拒绝，提取后可保存独立刷新凭据。
    func test_scoped_ipv4_peer_produces_a_valid_widget_refresh_target() throws {
        let address = try XCTUnwrap(IPv4Address("127.0.0.1%lo0"))
        let scoped = String(describing: address)
        XCTAssertTrue(scoped.contains("%"))
        let endpoint = NWEndpoint.hostPort(host: .ipv4(address), port: 8123)
        let host = try XCTUnwrap(LanSocket.connectedHost(from: endpoint))
        XCTAssertEqual(host, "127.0.0.1")
        let source = "12345678-1234-4234-8234-123456789abc"
        let device = "22345678-1234-4234-8234-123456789abc"
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        XCTAssertThrowsError(try WidgetRefreshTarget(sourceId: source, deviceId: device,
                                                    host: scoped, port: 8123, key: key))
        let target = try WidgetRefreshTarget(sourceId: source, deviceId: device,
                                             host: host, port: 8123, key: key)
        XCTAssertEqual(try target.requestURL().host, "127.0.0.1")
    }

    /// IPv6 链路本地的接口作用域参与实际路由，不能按 IPv4 规则移除。
    func test_scoped_ipv6_peer_preserves_its_routing_scope() throws {
        let address = try XCTUnwrap(IPv6Address("fe80::1%lo0"))
        let scoped = String(describing: address)
        XCTAssertTrue(scoped.contains("%"))
        let endpoint = NWEndpoint.hostPort(host: .ipv6(address), port: 8123)
        XCTAssertEqual(LanSocket.connectedHost(from: endpoint), scoped)
        let target = try WidgetRefreshTarget(sourceId: "12345678-1234-4234-8234-123456789abc",
                                             deviceId: "22345678-1234-4234-8234-123456789abc",
                                             host: try XCTUnwrap(LanSocket.connectedHost(from: endpoint)),
                                             port: 8123, key: Data(repeating: 7, count: 32).base64EncodedString())
        XCTAssertTrue(try target.requestURL().absoluteString.contains("%25lo0"))
    }

    /// 只发送过大头部而不发送载荷，接收器必须立即失败并关闭连接。
    func test_real_socket_rejects_oversized_header_without_waiting_for_body() throws {
        let expected = expectation(description: "bad header closed")
        try run(serverBytes: Data([0, 0, 16, 1]), expected: expected,
                received: { _, _ in XCTFail("oversized frame reached consumer") },
                ended: { error in XCTAssertEqual(error, .invalid); expected.fulfill() })
    }

    /// 接收回调排满八帧后第九帧发送失败，异常必须触发原socket终态而非继续跳序号。
    func test_send_queue_failure_in_receive_callback_terminates_original_socket() throws {
        let expected = expectation(description: "queue overflow closed")
        let bytes = try LanFrames.encode(Data(#"{"trigger":true}"#.utf8), limit: 4096)
        var writesAccepted = 0
        try run(serverBytes: bytes, expected: expected, received: { socket, _ in
            for sequence in 0..<9 {
                try socket.send(["sequence": sequence], limit: 4096)
                writesAccepted += 1
            }
            XCTFail("ninth pending write must throw")
        }, ended: { error in
            XCTAssertEqual(writesAccepted, 8)
            XCTAssertEqual(error, .invalid)
            expected.fulfill()
        })
    }
}
