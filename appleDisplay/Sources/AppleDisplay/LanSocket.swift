import Foundation
import SharedLogic
import Network

/// 一个Apple Network连接拥有读进度、有限写队列和半写超时；与iOS App编译同一源码进行宿主socket回归。
final class LanSocket {
    enum Failure: Error, Equatable { case network, invalid, timeout, overloaded }
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let limit: () -> Int
    private let ready: () -> Void
    private let frame: ([String: Any]) throws -> Void
    private let ended: (Failure) -> Void
    private var decoder = LanFrames()
    private var writes: [(Data, () -> Void)] = []
    private var writeId: UUID?
    private var writeTimeout: DispatchWorkItem?
    private var closed = false

    /// 系统完成Bonjour解析后实际连接的对端，仅供认证成功后记录服务地址。
    var connectedHost: String? {
        guard !closed else { return nil }
        return Self.connectedHost(from: connection.currentPath?.remoteEndpoint)
    }

    /// Network 的 IPv4 描述可能附带 %en0；持久化纯地址，IPv6 则保留路由所需的作用域。
    static func connectedHost(from endpoint: NWEndpoint?) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address): return address.rawValue.map { String($0) }.joined(separator: ".")
        case .ipv6(let address): return String(describing: address)
        case .name(let name, _): return name
        @unknown default: return nil
        }
    }

    /// 使用Bonjour解析出的服务端点，不接受远端URL、路径或任意命令。
    init(endpoint: NWEndpoint, queue: DispatchQueue, limit: @escaping () -> Int,
         ready: @escaping () -> Void, frame: @escaping ([String: Any]) throws -> Void,
         ended: @escaping (Failure) -> Void) {
        self.queue = queue; self.limit = limit; self.ready = ready; self.frame = frame; self.ended = ended
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        connection = NWConnection(to: endpoint, using: parameters)
    }

    /// 回调和I/O始终使用owner串行队列，旧连接由上层代次阻止覆盖新状态。
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready: self.ready(); self.read()
            case .failed, .waiting, .cancelled: self.close(reason: .network)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    /// 队列最多八帧，任何半写失败都销毁连接，绝不重发已经消费nonce的密文。
    func send(_ json: [String: Any], limit: Int, completion: @escaping () -> Void = {}) throws {
        guard !closed, TerminalWritePolicy.shared.canEnqueue(queuedFrames: Int32(clamping: writes.count), separateInFlight: writeId != nil) else { throw Failure.overloaded }
        let bytes = try JSONSerialization.data(withJSONObject: json)
        writes.append((try LanFrames.encode(bytes, limit: limit), completion))
        writeNext()
    }

    /// 主动收尾不触发上层重试；错误收尾只通知一次并回收所有队列和定时器。
    func close(reason: Failure? = nil) {
        guard !closed else { return }
        closed = true
        writeTimeout?.cancel(); writeTimeout = nil; writes = []; writeId = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        if let reason { ended(reason) }
    }

    /// 一次只写一帧，完成回调之后才发送下一帧，保持密码序号与网络字节顺序一致。
    private func writeNext() {
        guard !closed, writeId == nil, !writes.isEmpty else { return }
        let (data, completion) = writes.removeFirst()
        let id = UUID(); writeId = id
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.writeId == id else { return }
            self.close(reason: .timeout)
        }
        writeTimeout = timeout
        queue.asyncAfter(deadline: .now() + Double(TerminalWritePolicy.shared.TIMEOUT_MS) / 1000, execute: timeout)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed, self.writeId == id else { return }
            self.writeTimeout?.cancel(); self.writeTimeout = nil; self.writeId = nil
            guard error == nil else { self.close(reason: .network); return }
            completion()
            self.writeNext()
        })
    }

    /// 半帧进度由decoder保留，阶段上限在每个完整头部出现后立即检查。
    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Int(TerminalFramePolicy.shared.MAX_READ_BYTES)) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            do {
                if let data, !data.isEmpty {
                    try self.decoder.append(data)
                    while !self.closed, let bytes = try self.decoder.next(limit: self.limit()) {
                        guard let json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Failure.invalid }
                        try self.frame(json)
                    }
                }
                guard !complete, error == nil else { self.close(reason: .network); return }
                self.read()
            } catch { self.close(reason: .invalid) }
        }
    }

    deinit { writeTimeout?.cancel(); connection.cancel() }
}
