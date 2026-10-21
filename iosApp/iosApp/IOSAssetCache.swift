import Foundation

/// 应用私有内容寻址缓存；未完成文件只属于本次接收，不作为命中或展示来源。
final class IOSAssetCache {
    private let directory: URL
    private var partial: URL?
    private var writer: FileHandle?
    private var descriptor: LanDisplaySnapshot.Asset?

    /// 固定缓存目录不参与备份；所有调用必须位于连接owner的后台串行队列。
    init() throws {
        let manager = FileManager.default
        var path = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("lan-assets-v1", isDirectory: true)
        try manager.createDirectory(at: path, withIntermediateDirectories: true)
        guard try path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw WidgetSnapshotError.invalid }
        var values = URLResourceValues(); values.isExcludedFromBackup = true; try path.setResourceValues(values)
        directory = path
        try LanAssetFiles.removeOrphanPartials(in: path)
    }

    /// 缓存复用先检查实际完整长度、魔数和SHA-256；损坏文件留待原子替换。
    func cached(_ asset: LanDisplaySnapshot.Asset, bridge: NativeLinkBridge) throws -> URL? {
        let path = directory.appendingPathComponent(asset.hash)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let values = try path.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true,
              values.fileSize == Int(asset.length) else { return nil }
        let bytes = try Data(contentsOf: path)
        guard try bridge.validAsset(asset.json, bytes: bytes) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path)
        return path
    }

    /// 新资源开始前丢弃旧半成品；共享Rust接收器拥有顺序、编码与摘要判断。
    func begin(_ asset: LanDisplaySnapshot.Asset, bridge: NativeLinkBridge) throws {
        cancel()
        _ = try bridge.call(["op": "assetBegin", "descriptor": asset.json])
        let path = directory.appendingPathComponent(".partial-" + UUID().uuidString.lowercased())
        guard FileManager.default.createFile(atPath: path.path, contents: nil,
                                            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
            throw WidgetSnapshotError.unavailable
        }
        partial = path; descriptor = asset
        writer = try FileHandle(forWritingTo: path)
    }

    /// 核心校验一块后才写入；最终同步并重新核验磁盘字节，成功原子替换后返回命中路径。
    func accept(_ chunk: [String: Any], bridge: NativeLinkBridge) throws -> (UInt64, URL?) {
        guard let writer, let descriptor, let partial else { throw WidgetSnapshotError.invalid }
        let result = try bridge.call(["op": "assetChunk", "chunk": chunk])
        guard let encoded = chunk["data"] as? String, let bytes = Data(base64Encoded: encoded),
              let offset = result["offset"] as? NSNumber, let complete = result["complete"] as? Bool else { throw WidgetSnapshotError.invalid }
        try writer.write(contentsOf: bytes)
        if !complete { return (offset.uint64Value, nil) }
        try writer.synchronize(); try writer.close(); self.writer = nil
        let actual = try Data(contentsOf: partial)
        guard try bridge.validAsset(descriptor.json, bytes: actual) else { throw WidgetSnapshotError.invalid }
        let destination = directory.appendingPathComponent(descriptor.hash)
        if FileManager.default.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { throw WidgetSnapshotError.invalid }
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
        } else { try FileManager.default.moveItem(at: partial, to: destination) }
        self.partial = nil; self.descriptor = nil
        guard let verified = try cached(descriptor, bridge: bridge) else { throw WidgetSnapshotError.unavailable }
        return (offset.uint64Value, verified)
    }

    /// 后台保留动画的全部帧与时长；像素、帧数和总解码内存由共享解码器约束。
    func image(_ path: URL, mime: String) throws -> LanImageAsset {
        try LanImageAsset.decode(contentsOf: path, mime: mime)
    }

    /// 保留当前正在展示的最多十二张图片，其余按最后复用顺序收敛到512MiB。
    func prune(keeping hashes: Set<String>) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]) else { return }
        let entries = files.compactMap { path -> (URL, Int, Date)? in
            guard path.lastPathComponent.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  let values = try? path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return (path, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        for (path, length, _) in entries.sorted(by: { $0.2 < $1.2 }) where total > 512 * 1024 * 1024 {
            guard !hashes.contains(path.lastPathComponent) else { continue }
            do { try manager.removeItem(at: path); total -= length } catch { /* 下轮继续，不扩大删除范围。 */ }
        }
    }

    /// 断线、取消及清单失效仅清理本owner的精确临时文件，不删除已经验证的缓存。
    func cancel() {
        try? writer?.close(); writer = nil
        if let partial { try? FileManager.default.removeItem(at: partial) }
        partial = nil; descriptor = nil
    }

    deinit { cancel() }
}
