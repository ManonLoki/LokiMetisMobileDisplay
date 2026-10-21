import Foundation
import CryptoKit

/// 用户单独保管的 256 位恢复码保护主配对材料；文件不包含正文、地址或组件授权。
enum PairingRecovery {
    enum Failure: Error { case invalid, tooLarge, authentication }
    static let maxBytes = 256 * 1024
    static let maxPlaintextBytes = 64 * 1024
    static let maxRecords = 64
    private static let format = "loki-metris-pairing-recovery"
    private static let aad = Data("LokiMetris/pairing-recovery/mobile/1".utf8)

    struct Exported: CustomStringConvertible {
        let data: Data
        let recoveryCode: String
        var description: String { "PairingRecovery.Exported(redacted)" }
    }

    struct Payload: CustomStringConvertible {
        let deviceId: String
        let materials: [[String: Any]]
        var description: String { "PairingRecovery.Payload(redacted)" }
    }

    /// 先完整验证再生成随机恢复码；恢复码不会写入导出的 JSON。
    static func export(deviceId: String, materials: [[String: Any]]) throws -> Exported {
        let key = SymmetricKey(size: .bits256)
        let code = key.withUnsafeBytes { Data($0).base64EncodedString() }
        let data = try seal(deviceId: deviceId, materials: materials, recoveryCode: code, nonce: AES.GCM.Nonce())
        return Exported(data: data, recoveryCode: code)
    }

    /// 固定 AAD 区分移动端和桌面恢复文件；只有 AEAD 认证通过才解析配对秘密。
    static func open(data: Data, recoveryCode: String) throws -> Payload {
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        let value = try object(data)
        guard Set(value.keys) == ["format", "version", "algorithm", "nonce", "ciphertext", "tag"],
              value["format"] as? String == format, value["version"] as? Int == 1,
              value["algorithm"] as? String == "AES-256-GCM",
              let nonceText = value["nonce"] as? String, let ciphertextText = value["ciphertext"] as? String,
              let tagText = value["tag"] as? String else { throw Failure.invalid }
        let nonce = try base64(nonceText, count: 12)
        let tag = try base64(tagText, count: 16)
        let ciphertext = try base64(ciphertextText)
        guard !ciphertext.isEmpty, ciphertext.count <= maxPlaintextBytes else { throw Failure.tooLarge }
        let key = try recoveryKey(recoveryCode)
        var plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
            plaintext = try AES.GCM.open(box, using: key, authenticating: aad)
        } catch { throw Failure.authentication }
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        let payload = try object(plaintext)
        guard Set(payload.keys) == ["version", "role", "deviceId", "records"],
              payload["version"] as? Int == 1, payload["role"] as? String == "mobile",
              let deviceId = payload["deviceId"] as? String,
              let materials = payload["records"] as? [[String: Any]] else { throw Failure.invalid }
        try validate(deviceId: deviceId, materials: materials)
        return Payload(deviceId: deviceId, materials: materials)
    }

    /// 与 Rust 已提交材料的四字段合同一致；拒绝重复桌面和不同手机身份。
    static func validate(deviceId: String, materials: [[String: Any]]) throws {
        guard SharedValidation.validId(deviceId), !materials.isEmpty, materials.count <= maxRecords else { throw Failure.invalid }
        var clients = Set<String>()
        for material in materials {
            guard Set(material.keys) == ["clientId", "deviceId", "name", "secret"],
                  let client = material["clientId"] as? String, SharedValidation.validId(client), client != deviceId,
                  clients.insert(client).inserted, material["deviceId"] as? String == deviceId,
                  let name = material["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  name.utf8.count <= 160, !SharedValidation.containsControl(name),
                  let text = material["secret"] as? String else { throw Failure.invalid }
            let secret = try base64(text, count: 32)
            guard secret.contains(where: { $0 != 0 }) else { throw Failure.invalid }
        }
    }

    /// 内部确定性入口供跨平台测试向量使用；生产导出始终使用系统随机 key/nonce。
    static func seal(deviceId: String, materials: [[String: Any]], recoveryCode: String, nonce: AES.GCM.Nonce) throws -> Data {
        try validate(deviceId: deviceId, materials: materials)
        var plaintext = try JSONSerialization.data(withJSONObject: ["version": 1, "role": "mobile", "deviceId": deviceId,
            "records": materials], options: [.sortedKeys, .withoutEscapingSlashes])
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        guard plaintext.count <= maxPlaintextBytes else { throw Failure.tooLarge }
        let sealed = try AES.GCM.seal(plaintext, using: recoveryKey(recoveryCode), nonce: nonce, authenticating: aad)
        let data = try JSONSerialization.data(withJSONObject: ["format": format, "version": 1, "algorithm": "AES-256-GCM",
            "nonce": Data(nonce).base64EncodedString(), "ciphertext": sealed.ciphertext.base64EncodedString(),
            "tag": sealed.tag.base64EncodedString()], options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        return data
    }

    private static func recoveryKey(_ code: String) throws -> SymmetricKey {
        SymmetricKey(data: try base64(code.trimmingCharacters(in: .whitespacesAndNewlines), count: 32))
    }

    private static func base64(_ text: String, count: Int? = nil) throws -> Data {
        guard let bytes = Data(base64Encoded: text), bytes.base64EncodedString() == text,
              count == nil || bytes.count == count else { throw Failure.invalid }
        return bytes
    }

    /// 独立有界解析器拒绝重复键、非整数版本和平台 JSON 的宽松扩展。
    private static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= maxBytes, String(data: data, encoding: .utf8) != nil else { throw Failure.invalid }
        var parser = StrictJSON(bytes: Array(data))
        let value = try parser.value(depth: 0)
        parser.space()
        guard parser.index == parser.bytes.count, let object = value as? [String: Any] else { throw Failure.invalid }
        return object
    }

    private struct StrictJSON {
        let bytes: [UInt8]
        var index = 0
        mutating func space() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        mutating func take(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1; return true
        }
        mutating func value(depth: Int) throws -> Any {
            guard depth <= 8 else { throw Failure.invalid }
            space()
            if take(123) {
                var result: [String: Any] = [:]
                space(); if take(125) { return result }
                while true {
                    space(); let key = try string(); space()
                    guard result[key] == nil, result.count < 128, take(58) else { throw Failure.invalid }
                    result[key] = try value(depth: depth + 1); space()
                    if take(125) { return result }
                    guard take(44) else { throw Failure.invalid }
                }
            }
            if take(91) {
                var result: [Any] = []
                space(); if take(93) { return result }
                while true {
                    guard result.count < maxRecords else { throw Failure.invalid }
                    result.append(try value(depth: depth + 1)); space()
                    if take(93) { return result }
                    guard take(44) else { throw Failure.invalid }
                }
            }
            guard index < bytes.count else { throw Failure.invalid }
            if bytes[index] == 34 { return try string() }
            // 唯一数字字段是协议版本；不接受 true、1.0、1e0 或字符串版本。
            guard take(49) else { throw Failure.invalid }
            return 1
        }
        mutating func string() throws -> String {
            let start = index
            guard take(34) else { throw Failure.invalid }
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 {
                    let fragment = Data(bytes[start..<index])
                    guard fragment.count <= maxPlaintextBytes * 2,
                          let text = try JSONSerialization.jsonObject(with: fragment, options: [.fragmentsAllowed]) as? String else { throw Failure.invalid }
                    return text
                }
                guard byte >= 32 else { throw Failure.invalid }
                if byte == 92 {
                    guard index < bytes.count else { throw Failure.invalid }
                    index += 1
                }
            }
            throw Failure.invalid
        }
    }
}
