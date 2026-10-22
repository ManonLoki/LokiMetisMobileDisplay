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

    /// 每个真实执行入口留下有界结果，区分未调度、未授权和实际网络失败。
    /// 诊断写入失败不影响刷新，也不改变缓存中的真实接收时间。
    static func refresh(origin: String) async -> Bool {
        let origin = diagnosticOrigin(origin)
        let attemptedAtMs = Date().epochMs
        recordRefresh(origin: origin, attemptedAtMs: attemptedAtMs, outcome: "running")
        do {
            let store = try store()
            guard let target = try store.loadRefreshTarget() else {
                recordRefresh(origin: origin, attemptedAtMs: attemptedAtMs,
                              completedAtMs: Date().epochMs, outcome: "missingTarget")
                return false
            }
            let snapshot = try await WidgetHTTPClient().fetch(target)
            let saved = try store.saveFetchedSnapshot(snapshot, for: target)
            // 主 App 在请求期间发布了较新摘要时，保留它也算本次刷新成功。
            let newerCache: Bool
            if !saved, try store.loadRefreshTarget() == target,
               let current = try store.loadCached(atMs: Date().epochMs),
               current.sourceId == target.sourceId, current.receivedAtMs >= snapshot.receivedAtMs {
                newerCache = true
            } else { newerCache = false }
            recordRefresh(origin: origin, attemptedAtMs: attemptedAtMs, completedAtMs: Date().epochMs,
                          outcome: saved ? "success" : newerCache ? "newerCache" : "superseded")
            return saved || newerCache
        } catch {
            let error = error as NSError
            recordRefresh(origin: origin, attemptedAtMs: attemptedAtMs, completedAtMs: Date().epochMs,
                          outcome: "error", errorDomain: diagnosticErrorDomain(error.domain), errorCode: error.code)
            return false
        }
    }

    private struct RefreshDiagnostic: Encodable {
        let origin: String
        let attemptedAtMs: Int64
        let completedAtMs: Int64?
        let outcome: String
        let errorDomain: String?
        let errorCode: Int?
    }

    /// 调用点名称只允许短 ASCII 标识，既防路径穿越，也不把任意输入写入诊断。
    private static func diagnosticOrigin(_ value: String) -> String {
        guard !value.isEmpty, value.utf8.count <= 48,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                  (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return "unknown" }
        return value
    }

    /// 错误域同样只保留短 ASCII 标识，其余记为 unknown。
    private static func diagnosticErrorDomain(_ value: String) -> String {
        guard !value.isEmpty, value.utf8.count <= 128,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                  (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95 }) else { return "unknown" }
        return value
    }

    /// 固定目录、拒绝符号链接、原子写入；仅保存状态及稳定错误码，不编码网络或凭据信息。
    private static func recordRefresh(origin: String, attemptedAtMs: Int64, completedAtMs: Int64? = nil,
                                      outcome: String, errorDomain: String? = nil, errorCode: Int? = nil) {
        do {
            let diagnostic = RefreshDiagnostic(origin: origin, attemptedAtMs: attemptedAtMs,
                                               completedAtMs: completedAtMs, outcome: outcome,
                                               errorDomain: errorDomain, errorCode: errorCode)
            let data = try JSONEncoder().encode(diagnostic)
            guard data.count <= 1024 else { return }
            let manager = FileManager.default
            var directory = try store().directory
            let root = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard root.isDirectory == true, root.isSymbolicLink != true else { return }
            for component in ["Library", "Caches", "WidgetRefresh"] {
                directory.appendPathComponent(component, isDirectory: true)
                if !manager.fileExists(atPath: directory.path) {
                    try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                }
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { return }
            }
            try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                      ofItemAtPath: directory.path)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            let file = directory.appendingPathComponent(origin + ".json", isDirectory: false)
            if manager.fileExists(atPath: file.path) {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { return }
            }
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // 诊断不可用时仍继续实际刷新，不能让观测文件成为数据更新的前置条件。
        }
    }
}
