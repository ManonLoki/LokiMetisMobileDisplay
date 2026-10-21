import Foundation

/// 具体App沙箱路径只在iOS驱动定位，Widget永远不读取完整Hook正文缓存。
enum IOSDisplayCache {
    /// 固定私有子目录不备份，不接受远端目录、用户路径或App Group回退。
    static func store() throws -> LanDisplayStore {
        let manager = FileManager.default
        var directory = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("DisplayCache", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw WidgetSnapshotError.invalid }
        var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true
        try directory.setResourceValues(attributes)
        return LanDisplayStore(directory: directory)
    }
}
