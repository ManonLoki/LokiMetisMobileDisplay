import Foundation

/// 只负责迁移清理旧完整展示快照；Token与Hooks仅存在当前连接内存中。
struct LanDisplayStore {
    let directory: URL
    /// 只删除固定旧快照，不遍历图片/身份目录，也不跟随链接删除目标。
    func discardLegacy() throws {
        let manager = FileManager.default
        let path = directory.appendingPathComponent("display-lan-v1.json")
        do {
            let attributes = try manager.attributesOfItem(atPath: path.path)
            guard attributes[.type] as? FileAttributeType != .typeDirectory else { throw WidgetSnapshotError.invalid }
            try manager.removeItem(at: path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {}
    }
}
