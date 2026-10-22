import Foundation
import XCTest
@testable import AppleDisplay

/// 精确删除缓存文件时不跟随链接、不删除同名目录，避免误删身份或图片。
final class SharedFilesTests: XCTestCase {
    func test_remove_does_not_follow_symlinks_or_remove_conflicting_directory() throws {
        let directory = try temporaryFolder()
        let target = directory.appendingPathComponent("keep")
        try Data("original".utf8).write(to: target)
        let link = directory.appendingPathComponent("watch-display-v2.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try SharedFiles.removeIfPresent(link)
        XCTAssertEqual(try Data(contentsOf: target), Data("original".utf8))
        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: false)
        let child = link.appendingPathComponent("keep")
        try Data("original".utf8).write(to: child)
        XCTAssertThrowsError(try SharedFiles.removeIfPresent(link))
        XCTAssertEqual(try Data(contentsOf: child), Data("original".utf8))
        try SharedFiles.removeIfPresent(directory.appendingPathComponent("missing"))
    }
}
