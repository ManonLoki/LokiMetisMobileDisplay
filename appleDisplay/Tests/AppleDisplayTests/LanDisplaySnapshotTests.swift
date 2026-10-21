import Foundation
import XCTest
@testable import AppleDisplay

/// 完整手机展示解析与Widget摘要必须保持相同的质量/释放语义。
final class LanDisplaySnapshotTests: XCTestCase {
    /// 有效的完整快照包含真实协议字段，测试只覆盖解析，不冒充网络E2E。
    private func message() -> [String: Any] {
        ["type": "snapshot", "snapshot": ["version": 1, "tokens": NSNull(), "tokenError": "unavailable",
            "hooksAvailable": true, "hooks": [["agent": "codex", "slot": 1, "behavior": "running", "content": "正在处理",
                "contentTruncated": false, "image": String(repeating: "a", count: 64)]],
            "assets": [["hash": String(repeating: "a", count: 64), "mime": "image/gif", "length": 6]], "catalogError": NSNull()]]
    }

    /// Hook正文、图片摘要与截断标记保留给App，质量缺失不会被改成零值。
    func test_full_projection_preserves_hook_text_and_missing_tokens() throws {
        let snapshot = try LanDisplaySnapshot.decode(message())
        XCTAssertEqual(snapshot.hooks.first?.content, "正在处理")
        XCTAssertEqual(snapshot.hooks.first?.contentTruncated, false)
        XCTAssertEqual(snapshot.hooks.first?.image, snapshot.assets.first?.hash)
        XCTAssertEqual(snapshot.assets.first?.length, 6)
        XCTAssertNil(snapshot.tokens)
    }

    /// 五种主流格式进入同一有界清单；JPEG的jpg/jpeg文件后缀均映射规范MIME。
    func test_main_image_mime_types_are_allowed() throws {
        for mime in ["image/bmp", "image/png", "image/jpeg", "image/webp", "image/gif"] {
            var raw = message(); var snapshot = raw["snapshot"] as! [String: Any]
            snapshot["assets"] = [["hash": String(repeating: "a", count: 64), "mime": mime, "length": 12]]
            raw["snapshot"] = snapshot
            XCTAssertEqual(try LanDisplaySnapshot.decode(raw).assets.first?.mime, mime)
        }
    }

    /// 无效摘要、超大资源和重复清单拒绝，远端路径不能用作缓存文件名。
    func test_invalid_asset_catalog_is_rejected() throws {
        for asset in [["hash": "../private", "mime": "image/png", "length": 1],
                      ["hash": String(repeating: "a", count: 64), "mime": "text/html", "length": 1],
                      ["hash": String(repeating: "a", count: 64), "mime": "image/png", "length": 33_554_433]] as [[String: Any]] {
            var raw = message(); var snapshot = raw["snapshot"] as! [String: Any]
            snapshot["assets"] = [asset]; raw["snapshot"] = snapshot
            XCTAssertThrowsError(try LanDisplaySnapshot.decode(raw))
        }
        var raw = message(); var snapshot = raw["snapshot"] as! [String: Any]
        let assets = snapshot["assets"] as! [[String: Any]]
        snapshot["assets"] = assets + assets; raw["snapshot"] = snapshot
        XCTAssertThrowsError(try LanDisplaySnapshot.decode(raw))
    }

    /// 与Widget相同的“不可用不能保留运行槽位”规则在完整App入口生效。
    func test_unavailable_hooks_cannot_keep_old_slots() throws {
        var raw = message(); var snapshot = raw["snapshot"] as! [String: Any]
        snapshot["hooksAvailable"] = false; raw["snapshot"] = snapshot
        XCTAssertThrowsError(try LanDisplaySnapshot.decode(raw))
        snapshot["hooks"] = []; raw["snapshot"] = snapshot
        let empty = try LanDisplaySnapshot.decode(raw)
        XCTAssertTrue(empty.hooks.isEmpty)
        XCTAssertFalse(empty.hooksAvailable)
    }

    /// 协议文案按UTF-8字节限制，避免中文/emoji绕过有界完整快照。
    func test_unicode_content_limit_is_checked_in_bytes() throws {
        var raw = message(); var snapshot = raw["snapshot"] as! [String: Any]
        var hooks = snapshot["hooks"] as! [[String: Any]]
        hooks[0]["content"] = String(repeating: "界", count: 171)
        snapshot["hooks"] = hooks; raw["snapshot"] = snapshot
        XCTAssertThrowsError(try LanDisplaySnapshot.decode(raw))
    }
}
