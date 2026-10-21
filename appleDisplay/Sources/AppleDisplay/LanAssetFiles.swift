import Foundation

/// 私有缓存目录的精确临时文件清理，独立于UIKit和密码桥以便隔离验证崩溃恢复。
enum LanAssetFiles {
    /// 仅独占缓存owner初始化时调用；清理旧进程留下的规范临时文件，保留链接及其它文件。
    static func removeOrphanPartials(in directory: URL) throws {
        let manager = FileManager.default
        let root = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard root.isDirectory == true, root.isSymbolicLink != true else { throw WidgetSnapshotError.invalid }
        for file in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            guard file.lastPathComponent.hasPrefix(".partial-") else { continue }
            let id = String(file.lastPathComponent.dropFirst(9))
            guard UUID(uuidString: id)?.uuidString.lowercased() == id,
                  let attributes = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  attributes.isRegularFile == true, attributes.isSymbolicLink != true else { continue }
            try manager.removeItem(at: file)
        }
    }
}
