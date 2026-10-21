import Foundation
import XCTest
@testable import AppleDisplay

/// 崩溃恢复只回收产品自己的半成品，已验证内容与无关对象必须保留。
final class LanAssetFilesTests: XCTestCase {
    /// 隔离目录模拟前一个进程终止后留下的部分文件，清理可重复执行。
    func test_orphan_partial_is_removed_while_valid_cache_is_preserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let partial = root.appendingPathComponent(".partial-12345678-1234-4234-8234-123456789abc")
        let valid = root.appendingPathComponent(String(repeating: "a", count: 64))
        let unrelated = root.appendingPathComponent(".partial-not-a-product-file")
        try Data(repeating: 1, count: 32).write(to: partial)
        try Data("verified".utf8).write(to: valid)
        try Data("preserved".utf8).write(to: unrelated)
        try LanAssetFiles.removeOrphanPartials(in: root)
        try LanAssetFiles.removeOrphanPartials(in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(try Data(contentsOf: valid), Data("verified".utf8))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("preserved".utf8))
    }

    /// 链接与目录即使名字形似临时文件也不删除或跟随，不触及其目标。
    func test_cleanup_does_not_follow_symlinks_or_remove_directories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = root.appendingPathComponent("keep")
        try Data("original".utf8).write(to: sentinel)
        let link = root.appendingPathComponent(".partial-12345678-1234-4234-8234-123456789abc")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sentinel)
        let folder = root.appendingPathComponent(".partial-12345678-1234-4234-8234-123456789abd", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try LanAssetFiles.removeOrphanPartials(in: root)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("original".utf8))
        XCTAssertTrue(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }
}
