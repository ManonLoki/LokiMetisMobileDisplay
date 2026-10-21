import Foundation

/// 网络队列独占半帧，读取中断不丢失头部进度；最多保留一帧加一次16KiB接收的数据。
struct LanFrames {
    private var buffer = Data()

    /// 不根据不可信头部预分配载荷，接收块与累计缓冲都保持有界。
    mutating func append(_ bytes: Data) throws {
        guard bytes.count <= 16 * 1024, buffer.count + bytes.count <= 98304 + 4 + 16 * 1024 else {
            throw WidgetSnapshotError.tooLarge
        }
        buffer.append(bytes)
    }

    /// 每帧按当前握手/业务上限重新检查，任何坏长度均由连接owner关闭socket。
    mutating func next(limit: Int) throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let count = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= limit else { throw WidgetSnapshotError.invalid }
        guard buffer.count >= count + 4 else { return nil }
        let value = Data(buffer.dropFirst(4).prefix(count))
        buffer.removeFirst(count + 4)
        return value
    }

    /// 写入前验证固定上限，长度前缀只使用网络字节序。
    static func encode(_ data: Data, limit: Int) throws -> Data {
        guard !data.isEmpty, data.count <= limit else { throw WidgetSnapshotError.tooLarge }
        var size = UInt32(data.count).bigEndian
        var output = withUnsafeBytes(of: &size) { Data($0) }
        output.append(data)
        return output
    }
}
