import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// App 与组件共享有界摘要及独立只读凭据；文件锁使撤销和在途 HTTP 提交跨进程有序。
struct WidgetSnapshotStore {
    let directory: URL
    private var file: URL { directory.appendingPathComponent("display-widget-v1.json", isDirectory: false) }
    private var targetFile: URL { directory.appendingPathComponent("display-widget-refresh-v1.json", isDirectory: false) }

    /// 加锁读取并校验摘要，不判断租约或缓存时效。
    func load() throws -> WidgetSnapshot { try withLock { try loadSnapshot() } }

    /// 连接 owner 只加载租约内摘要；过期缓存不能凭自身恢复认证连接。
    func loadLive(atMs now: Int64) throws -> WidgetSnapshot? {
        let snapshot = try load(); return snapshot.isLive(atMs: now) ? snapshot : nil
    }

    /// 小组件离线时继续显示真实的最近一次同步与统计日期。
    func loadCached(atMs now: Int64) throws -> WidgetSnapshot? {
        let snapshot = try load(); return snapshot.isCached(atMs: now) ? snapshot : nil
    }

    /// 加锁读取独立只读刷新凭据；未授权时返回 nil。
    func loadRefreshTarget() throws -> WidgetRefreshTarget? { try withLock { try loadTarget() } }

    /// 已认证来源不再支持独立获取时撤销凭据，保留最近一次合法摘要。
    func clearRefreshTarget(sourceId: String) throws {
        guard SharedValidation.validId(sourceId) else { throw WidgetSnapshotError.invalid }
        try withLock {
            if (try? loadTarget())?.sourceId == sourceId { try remove(targetFile) }
        }
    }

    /// 成功认证后才调用。相同地址和密钥保留代次，改变服务地址会使旧请求失效。
    @discardableResult
    func saveRefreshTarget(_ target: WidgetRefreshTarget) throws -> WidgetRefreshTarget {
        try target.validate()
        return try withLock {
            if let previous = try? loadTarget(), previous.sameConnection(as: target) { return previous }
            try write(try SharedJSON.encoder.encode(target), to: targetFile, limit: 4096)
            return target
        }
    }

    /// 摘要和独立获取能力在同一锁内提交；先撤销旧目标，进程中断也不会留下跨来源凭据。
    func saveAuthenticatedSnapshot(_ snapshot: WidgetSnapshot, refreshTarget: WidgetRefreshTarget?) throws {
        try snapshot.validate(); try refreshTarget?.validate()
        guard refreshTarget == nil || refreshTarget?.sourceId == snapshot.sourceId else { throw WidgetSnapshotError.invalid }
        let snapshotData = try SharedJSON.encoder.encode(snapshot)
        guard snapshotData.count <= WidgetSnapshot.maxBytes else { throw WidgetSnapshotError.tooLarge }
        try withLock {
            let previous = try? loadTarget()
            let next: WidgetRefreshTarget?
            if let refreshTarget, let previous, previous.sameConnection(as: refreshTarget) { next = previous }
            else { next = refreshTarget }
            let targetData = try next.map { try SharedJSON.encoder.encode($0) }
            if let targetData, targetData.count > 4096 { throw WidgetSnapshotError.tooLarge }
            if previous != next || next == nil { try remove(targetFile) }
            let current = try? loadSnapshot()
            if current?.sourceId != snapshot.sourceId || (current?.receivedAtMs ?? -1) <= snapshot.receivedAtMs {
                try write(snapshotData, to: file, limit: WidgetSnapshot.maxBytes)
            }
            if let targetData, previous != next { try write(targetData, to: targetFile, limit: 4096) }
        }
    }

    /// 心跳只续已有来源，不能用内存中的旧事实覆盖更晚的独立 HTTP 摘要。
    @discardableResult
    func saveIfNotOlder(_ snapshot: WidgetSnapshot) throws -> Bool {
        try snapshot.validate()
        return try withLock {
            if let current = try? loadSnapshot(),
               current.sourceId != snapshot.sourceId || current.receivedAtMs > snapshot.receivedAtMs { return false }
            try writeSnapshot(snapshot)
            return true
        }
    }

    /// 明确选择另一来源时同时撤销其摘要和凭据，即使其中一个文件不存在也检查另一个。
    func selectSource(_ id: String) throws {
        guard SharedValidation.validId(id) else { throw WidgetSnapshotError.invalid }
        try withLock {
            if FileManager.default.fileExists(atPath: targetFile.path), (try? loadTarget())?.sourceId != id { try remove(targetFile) }
            if FileManager.default.fileExists(atPath: file.path), (try? loadSnapshot())?.sourceId != id { try remove(file) }
        }
    }

    /// 只撤销被忘记来源，保留另一个桌面留下的最近同步摘要。
    func forgetSource(_ id: String) throws {
        guard SharedValidation.validId(id) else { throw WidgetSnapshotError.invalid }
        try withLock {
            if (try? loadTarget())?.sourceId == id { try remove(targetFile) }
            if (try? loadSnapshot())?.sourceId == id { try remove(file) }
        }
    }

    /// 配置或密钥已换代时，HTTP 响应不能恢复被清除的旧来源。
    /// 请求期间到达的较新 App 摘要也优先保留。
    @discardableResult
    func saveFetchedSnapshot(_ snapshot: WidgetSnapshot, for target: WidgetRefreshTarget, startedAtMs: Int64? = nil) throws -> Bool {
        try snapshot.validate(); try target.validate()
        if let startedAtMs, startedAtMs < 0 { throw WidgetSnapshotError.invalid }
        guard snapshot.sourceId == target.sourceId else { throw WidgetSnapshotError.invalid }
        return try withLock {
            guard try loadTarget() == target else { return false }
            if let current = try? loadSnapshot() {
                guard current.sourceId == snapshot.sourceId else { return false }
                if current.receivedAtMs > snapshot.receivedAtMs { return false }
                if let startedAtMs, current.receivedAtMs > startedAtMs { return false }
            }
            try writeSnapshot(snapshot)
            return true
        }
    }

    /// 明确撤销共享同时删除摘要和刷新凭据；不清理容器内其他文件。
    func clear() throws { try withLock { try remove(targetFile); try remove(file) } }

    /// 先校验再加锁原子写入，非法摘要不覆盖现有文件。
    func save(_ snapshot: WidgetSnapshot) throws {
        try snapshot.validate()
        try withLock { try writeSnapshot(snapshot) }
    }

    private func loadSnapshot() throws -> WidgetSnapshot {
        let snapshot = try SharedJSON.decoder.decode(WidgetSnapshot.self, from: read(file, limit: WidgetSnapshot.maxBytes))
        try snapshot.validate()
        return snapshot
    }

    private func loadTarget() throws -> WidgetRefreshTarget? {
        let data: Data
        do { data = try read(targetFile, limit: 4096) }
        catch where SharedFiles.isMissing(error) { return nil }
        let target = try SharedJSON.decoder.decode(WidgetRefreshTarget.self, from: data)
        try target.validate()
        return target
    }

    private func writeSnapshot(_ snapshot: WidgetSnapshot) throws {
        try write(try SharedJSON.encoder.encode(snapshot), to: file, limit: WidgetSnapshot.maxBytes)
    }

    private func read(_ url: URL, limit: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= limit else { throw WidgetSnapshotError.tooLarge }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= limit else { throw WidgetSnapshotError.tooLarge }
        return bytes
    }

    private func write(_ data: Data, to url: URL, limit: Int) throws {
        guard data.count <= limit else { throw WidgetSnapshotError.tooLarge }
        if FileManager.default.fileExists(atPath: url.path) {
            let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw WidgetSnapshotError.unavailable }
        }
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        if url == targetFile {
            var target = url
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try target.setResourceValues(values)
        }
    }

    private func remove(_ url: URL) throws { try SharedFiles.removeIfPresent(url) }

    /// 固定锁文件不删除，避免不同进程锁住不同 inode；短时非阻塞重试限制挂起进程的影响。
    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw WidgetSnapshotError.unavailable }
        let lockFile = directory.appendingPathComponent("display-widget.lock", isDirectory: false)
        let descriptor = lockFile.path.withCString { open($0, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR) }
        guard descriptor >= 0 else { throw WidgetSnapshotError.unavailable }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { throw WidgetSnapshotError.unavailable }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: lockFile.path)
        #endif
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        // 指数退避（5ms 起、上限 100ms），短竞争快速拿锁，长时间占用时少空转。
        var backoff: TimeInterval = 0.005
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard (errno == EWOULDBLOCK || errno == EINTR), DispatchTime.now().uptimeNanoseconds < deadline else {
                throw WidgetSnapshotError.unavailable
            }
            Thread.sleep(forTimeInterval: backoff)
            backoff = min(backoff * 2, 0.1)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }
}
