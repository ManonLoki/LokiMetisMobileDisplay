import Foundation
import XCTest
@testable import AppleDisplay

/// 升级只精确清理历史Token/Hooks文件，图片和配对身份始终保留。
final class LanDisplayStoreTests: XCTestCase {
    func test_legacy_snapshot_is_removed_without_touching_identity_or_images() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["display-lan-v1.json", "watch-display-v1.json", "paired.json", "image.png"] {
            try Data("existing".utf8).write(to: directory.appendingPathComponent(name))
        }
        try LanDisplayStore(directory: directory).discardLegacy()
        try WatchDisplayStore(directory: directory).discardLegacy()
        try LanDisplayStore(directory: directory).discardLegacy()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("display-lan-v1.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("watch-display-v1.json").path))
        for name in ["paired.json", "image.png"] { XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(name)), Data("existing".utf8)) }
    }

    func test_cleanup_does_not_follow_symlinks_or_remove_conflicting_directory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("keep")
        try Data("original".utf8).write(to: target)
        let legacy = directory.appendingPathComponent("display-lan-v1.json")
        try FileManager.default.createSymbolicLink(at: legacy, withDestinationURL: target)
        try LanDisplayStore(directory: directory).discardLegacy()
        XCTAssertEqual(try Data(contentsOf: target), Data("original".utf8))
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false)
        let child = legacy.appendingPathComponent("keep")
        try Data("original".utf8).write(to: child)
        XCTAssertThrowsError(try LanDisplayStore(directory: directory).discardLegacy())
        XCTAssertEqual(try Data(contentsOf: child), Data("original".utf8))
    }
}
