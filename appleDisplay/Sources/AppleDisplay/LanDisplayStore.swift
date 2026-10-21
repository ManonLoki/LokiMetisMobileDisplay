import Foundation

/// 只负责迁移清理旧完整展示快照；Token与Hooks仅存在当前连接内存中。
struct LanDisplayStore {
    let directory: URL
    /// 只删除固定旧快照，不遍历图片/身份目录，也不跟随链接删除目标。
    func discardLegacy() throws {
        try SharedFiles.removeIfPresent(directory.appendingPathComponent("display-lan-v1.json"))
    }
}
