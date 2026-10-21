import Foundation
import CryptoKit

/// App、组件与 Watch 共用的身份、文本和内容摘要校验；各宿主不再各自手写同一规则。
enum SharedValidation {
    /// 全零 UUID 只作占位，不能代表任何真实设备或代次。
    static let zeroId = "00000000-0000-0000-0000-000000000000"
    /// 小写规范 UUID 文本；不排除全零，用于只要求格式的文件名或记录键。
    static func isCanonicalUUID(_ id: String) -> Bool { UUID(uuidString: id)?.uuidString.lowercased() == id }
    /// 稳定身份与传输代次：小写规范且非全零。
    static func validId(_ id: String) -> Bool { isCanonicalUUID(id) && id != zeroId }
    /// 名称等展示文本拒绝 C0/C1 控制字符。
    static func containsControl(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 32 || (127...159).contains($0.value) }
    }
    /// 内容摘要只接受 64 位小写十六进制，不接受大小写变体、换行或路径。
    static func validHash(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static let hexDigits = Array("0123456789abcdef".utf8)
    /// 查表生成小写十六进制，避免逐字节 `String(format:)`。
    static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        var out: [UInt8] = []; out.reserveCapacity(bytes.underestimatedCount * 2)
        for byte in bytes { out.append(hexDigits[Int(byte >> 4)]); out.append(hexDigits[Int(byte & 0x0f)]) }
        return String(decoding: out, as: UTF8.self)
    }
    /// 完整正文的 SHA-256 小写十六进制摘要。
    static func sha256Hex(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
}

/// 固定配置的共享 JSON 编解码器；创建后不再修改选项，可在各串行 owner 间复用。
enum SharedJSON {
    static let encoder = JSONEncoder()
    /// 摘要需稳定字节序时使用的有序键编码器。
    static let sortedEncoder: JSONEncoder = { let value = JSONEncoder(); value.outputFormatting = [.sortedKeys]; return value }()
    static let decoder = JSONDecoder()
}

/// 精确文件删除；不存在视为已完成，目录或其它异常仍向调用方披露。
enum SharedFiles {
    /// 系统“文件不存在”错误，读取或删除时都按缺失处理。
    static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
    }
    /// 只删除给定路径的普通文件或链接本身，拒绝删除目录。
    static func removeIfPresent(_ url: URL) throws {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType != .typeDirectory else { throw WidgetSnapshotError.invalid }
            try FileManager.default.removeItem(at: url)
        } catch where isMissing(error) {}
    }
}
