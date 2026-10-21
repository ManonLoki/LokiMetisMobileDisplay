import Foundation

/// 两个进程从各自Info.plist读取同一组标识；配置缺失时不使用任何替代容器。
enum WidgetContainer {
    /// 只返回系统授予的App Group根目录，不创建或访问其他目录。
    static func store() throws -> WidgetSnapshotStore {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "LokiWidgetAppGroup") as? String,
              group.hasPrefix("group."), !group.contains("$("),
              let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw WidgetSnapshotError.unavailable
        }
        return WidgetSnapshotStore(directory: directory)
    }
}
