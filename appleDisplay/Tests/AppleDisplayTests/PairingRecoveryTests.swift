import Foundation
import CryptoKit
import XCTest
@testable import AppleDisplay

/// 只使用固定合成材料；不访问本机 Keychain 或真实配对文件。
final class PairingRecoveryTests: XCTestCase {
    private let device = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    private let client = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private var secret: String { Data(repeating: 17, count: 32).base64EncodedString() }
    private var code: String { Data((0..<32).map(UInt8.init)).base64EncodedString() }
    private var material: [String: Any] { ["clientId": client, "deviceId": device, "name": "演示端", "secret": secret] }

    func test_cryptokit_and_android_jca_share_a_fixed_wire_vector() throws {
        let nonce = try AES.GCM.Nonce(data: Data((0..<12).map(UInt8.init)))
        let data = try PairingRecovery.seal(deviceId: device, materials: [material], recoveryCode: code, nonce: nonce)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(envelope["ciphertext"] as? String, "PCCyfrOMoX7EJbWxk4obDuC15FeTVjwfWwTIsX4KY585c82fgqJx+xfHHI7r5EtbjXtMryizwLVN81k7IriOzJNQrx+9pW8FPm6ID47ub4lZ66hPFwIyCdDJ/60Z3YHsqpl0h8UgqXv/fV/TKRRAXZZFBs6VrEb/BJt196CFDW3YMWOl1/qoMGuCZZVeuS/vDpeAVhhy8CnvPIsUmbGKjfC1sjeHnqEbhVn/HGMUYR8nKWGNqYdRzwC8sqIF543RVh7PqEiPk5tyBJa0/xOc1qQsvSR4Uv+jNMPflQQayqgGcZH9o3JGdxcV/TWXbCF9iuHWGfgSs4d6BAUa5/lgrTanl+LusydQVeVDeg==")
        XCTAssertEqual(envelope["tag"] as? String, "l6gFI6oTPSNRrzy1egeAaQ==")
        XCTAssertEqual(try PairingRecovery.open(data: data, recoveryCode: code).deviceId, device)
    }

    func test_roundtrip_uses_independent_random_keys_and_contains_no_private_fields() throws {
        let first = try PairingRecovery.export(deviceId: device, materials: [material])
        let second = try PairingRecovery.export(deviceId: device, materials: [material])
        XCTAssertNotEqual(first.recoveryCode, second.recoveryCode)
        XCTAssertNotEqual(first.data, second.data)
        let text = String(decoding: first.data, as: UTF8.self)
        for privateValue in [device, client, secret, first.recoveryCode, "演示端"] { XCTAssertFalse(text.contains(privateValue)) }
        let restored = try PairingRecovery.open(data: first.data, recoveryCode: "\n" + first.recoveryCode + " ")
        XCTAssertEqual(restored.deviceId, device)
        XCTAssertEqual(restored.materials as NSArray, [material] as NSArray)
        XCTAssertFalse(String(describing: first).contains(first.recoveryCode))
        XCTAssertFalse(String(describing: restored).contains(secret))
    }

    func test_wrong_code_tampering_and_noncanonical_envelope_fail() throws {
        let output = try PairingRecovery.export(deviceId: device, materials: [material])
        XCTAssertThrowsError(try PairingRecovery.open(data: output.data, recoveryCode: code))
        for invalid in ["1234", output.recoveryCode.dropLast().description, output.recoveryCode + "\nX"] {
            XCTAssertThrowsError(try PairingRecovery.open(data: output.data, recoveryCode: invalid))
        }
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: output.data) as? [String: Any])
        for field in ["ciphertext", "nonce", "tag"] {
            var value = original
            var bytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(value[field] as? String)))
            bytes[0] ^= 1; value[field] = bytes.base64EncodedString()
            XCTAssertThrowsError(try PairingRecovery.open(data: JSONSerialization.data(withJSONObject: value), recoveryCode: output.recoveryCode))
        }
        for replacement: Any in [true, 1.0, "1", 2] {
            var value = original; value["version"] = replacement
            // NSNumber(1.0) serializes as 1; exercise noninteger wire spellings separately below.
            if replacement is Double { continue }
            XCTAssertThrowsError(try PairingRecovery.open(data: JSONSerialization.data(withJSONObject: value), recoveryCode: output.recoveryCode))
        }
        let text = String(decoding: output.data, as: UTF8.self)
        for changed in [text.replacingOccurrences(of: "\"version\":1", with: "\"version\":1.0"),
                        text.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"version\":1"),
                        text.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"\\u0076ersion\":1"),
                        text.replacingOccurrences(of: "\"AES-256-GCM\"", with: "\"OTHER\""),
                        "[" + text + "]"] {
            XCTAssertThrowsError(try PairingRecovery.open(data: Data(changed.utf8), recoveryCode: output.recoveryCode))
        }
        XCTAssertThrowsError(try PairingRecovery.open(data: Data(repeating: 32, count: PairingRecovery.maxBytes + 1), recoveryCode: code))
    }

    func test_material_validation_rejects_rebinding_duplicates_and_extra_content() throws {
        XCTAssertThrowsError(try PairingRecovery.validate(deviceId: device, materials: []))
        XCTAssertThrowsError(try PairingRecovery.validate(deviceId: device, materials: [material, material]))
        for (key, value) in [("deviceId", client), ("clientId", device), ("clientId", client.uppercased()),
                             ("name", "\u{0001}"), ("name", " "), ("name", String(repeating: "字", count: 54)),
                             ("secret", Data(repeating: 0, count: 32).base64EncodedString()),
                             ("secret", secret.dropLast().description), ("hook", "private")] {
            var changed = material; changed[key] = value
            XCTAssertThrowsError(try PairingRecovery.validate(deviceId: device, materials: [changed]))
        }
        XCTAssertThrowsError(try PairingRecovery.validate(deviceId: device, materials: Array(repeating: material, count: 65)))
    }

    func test_authenticated_payload_still_requires_mobile_role_and_exact_material_contract() throws {
        let valid: [String: Any] = ["version": 1, "role": "mobile", "deviceId": device, "records": [material]]
        for (field, value): (String, Any) in [("role", "desktop"), ("deviceId", client), ("version", 2), ("endpoint", "192.168.1.5")] {
            var changed = valid; changed[field] = value
            XCTAssertThrowsError(try PairingRecovery.open(data: authenticated(changed), recoveryCode: code))
        }
    }

    private func authenticated(_ payload: [String: Any]) throws -> Data {
        let key = SymmetricKey(data: try XCTUnwrap(Data(base64Encoded: code)))
        let box = try AES.GCM.seal(JSONSerialization.data(withJSONObject: payload), using: key,
            authenticating: Data("LokiMetris/pairing-recovery/mobile/1".utf8))
        return try JSONSerialization.data(withJSONObject: ["format": "loki-metris-pairing-recovery", "version": 1,
            "algorithm": "AES-256-GCM", "nonce": Data(box.nonce).base64EncodedString(),
            "ciphertext": box.ciphertext.base64EncodedString(), "tag": box.tag.base64EncodedString()])
    }
}
