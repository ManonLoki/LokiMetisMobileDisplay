import Foundation

/// 网络owner串行拥有一个句柄，换socket不会重建配对窗口或尝试预算。
final class NativeLinkBridge {
    enum Failure: Error { case invalid(String) }
    private var handle: UInt64
    /// 调用方串行使用同一句柄，因此复用一块输出缓冲；每次返回前只清零实际写入部分。
    private var output = [UInt8](repeating: 0, count: 192 * 1024)

    init(deviceId: String, name: String) throws {
        let identity = try JSONSerialization.data(withJSONObject: ["deviceId": deviceId, "name": name])
        handle = identity.withUnsafeBytes { buffer in
            loki_mobile_create(buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count)
        }
        guard handle != 0 else { throw Failure.invalid("mobile_native_unavailable") }
    }

    /// material和commitId仅交Keychain保存及同次回调，不进入Published或日志。
    func call(_ command: [String: Any]) throws -> [String: Any] {
        guard handle != 0 else { throw Failure.invalid("mobile_handle_closed") }
        let input = try JSONSerialization.data(withJSONObject: command)
        var count = 0
        let status = output.withUnsafeMutableBufferPointer { destination in
            input.withUnsafeBytes { source in
                loki_mobile_call(handle, source.bindMemory(to: UInt8.self).baseAddress, source.count,
                                 destination.baseAddress, destination.count, &count)
            }
        }
        defer { output.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress.map { _ = memset($0, 0, min(count, buffer.count)) }
        } }
        guard status >= 0, count <= output.count,
              let value = try JSONSerialization.jsonObject(with: Data(output.prefix(count))) as? [String: Any] else {
            throw Failure.invalid("mobile_native_unavailable")
        }
        guard value["ok"] as? Bool == true, let result = value["result"] as? [String: Any] else {
            throw Failure.invalid(value["error"] as? String ?? "mobile_native_unavailable")
        }
        return result
    }

    /// 私有持久缓存每次复用前验证完整内容，损坏文件不能被当作缓存命中。
    func validAsset(_ descriptor: [String: Any], bytes: Data) throws -> Bool {
        let metadata = try JSONSerialization.data(withJSONObject: descriptor)
        return metadata.withUnsafeBytes { a in
            bytes.withUnsafeBytes { b in
                loki_mobile_asset_valid(a.bindMemory(to: UInt8.self).baseAddress, a.count,
                                        b.bindMemory(to: UInt8.self).baseAddress, b.count) == 1
            }
        }
    }

    func close() { if handle != 0 { loki_mobile_destroy(handle); handle = 0 } }
    deinit { close() }
}
