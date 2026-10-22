import Foundation
import SharedLogic

/// 应用私有内容寻址缓存；未完成文件只属于本次接收，不作为命中或展示来源。
final class IOSAssetCache {
    /// 固定缓存目录；只读校验与解码可在解码队列直接使用该路径。
    let directory: URL
    private var partial: URL?
    private var writer: FileHandle?
    private var descriptor: LanDisplaySnapshot.Asset?
    /// 上次完整收敛时保留的引用集；引用不变且没有新文件落盘时无需重新扫描目录。
    private var settledKeeping: Set<String>?

    /// 固定缓存目录不参与备份；实例接收与清理操作必须位于连接 owner 的后台串行队列。
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

    /// 缓存复用先检查实际完整长度、魔数和SHA-256；缺失、损坏或不可读都按未命中处理，随后重新下载并原子替换。
    func cached(_ asset: LanDisplaySnapshot.Asset) -> URL? { Self.verifiedPath(asset, in: directory) }

    /// 无状态实现，也供解码队列在冷启动时校验；不触碰实例的在途接收文件。
    /// 映射读取：校验最大32MiB的文件时不在堆上整份复制。
    static func verifiedPath(_ asset: LanDisplaySnapshot.Asset, in directory: URL) -> URL? {
        let path = directory.appendingPathComponent(asset.hash)
        guard let values = try? path.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]),
              values.isSymbolicLink != true, values.isRegularFile == true, values.fileSize == Int(asset.length),
              let bytes = try? Data(contentsOf: path, options: .mappedIfSafe),
              (try? NativeLinkBridge.validAsset(asset.json, bytes: bytes)) == true else { return nil }
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

    /// 核心校验一块后才写入；最终同步并核验落盘字节，原子替换后直接返回命中路径，不再整文件重读。
    func accept(_ chunk: [String: Any], bridge: NativeLinkBridge) throws -> (UInt64, URL?) {
        guard let writer, let descriptor, let partial else { throw WidgetSnapshotError.invalid }
        let result = try bridge.call(["op": "assetChunk", "chunk": chunk])
        guard let encoded = chunk["data"] as? String, let bytes = Data(base64Encoded: encoded),
              let offset = result["offset"] as? NSNumber, let complete = result["complete"] as? Bool else { throw WidgetSnapshotError.invalid }
        try writer.write(contentsOf: bytes)
        if !complete { return (offset.uint64Value, nil) }
        try writer.synchronize(); try writer.close(); self.writer = nil
        let actual = try Data(contentsOf: partial, options: .mappedIfSafe)
        guard try NativeLinkBridge.validAsset(descriptor.json, bytes: actual) else { throw WidgetSnapshotError.invalid }
        let destination = directory.appendingPathComponent(descriptor.hash)
        if FileManager.default.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { throw WidgetSnapshotError.invalid }
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
        } else { try FileManager.default.moveItem(at: partial, to: destination) }
        self.partial = nil; self.descriptor = nil; settledKeeping = nil
        // 临时文件已在原名下通过完整校验，原子改名不改变内容；修改时间即最近复用时间。
        return (offset.uint64Value, destination)
    }

    /// 后台保留动画的全部帧与时长；像素、帧数和总解码内存由共享解码器约束。
    /// 读取指定文件但不访问实例接收状态，只在独立解码队列调用。
    static func image(_ path: URL, asset: LanDisplaySnapshot.Asset) throws -> LanImageAsset {
        try LanImageAsset.decode(contentsOf: path, mime: asset.mime, id: asset.hash)
    }

    /// 保留当前引用的最多十二张图片，其余按最近复用顺序淘汰，以 512 MiB 为目标；删除失败可使其超标。
    func prune(keeping hashes: Set<String>) {
        guard hashes != settledKeeping else { return }
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]) else { return }
        let entries = files.compactMap { path -> ImageCacheEntry? in
            guard SharedValidation.validHash(path.lastPathComponent),
                  let values = try? path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return ImageCacheEntry(key: path.lastPathComponent, byteLength: Int64(values.fileSize ?? 0),
                lastUsed: (values.contentModificationDate ?? .distantPast).timeIntervalSinceReferenceDate)
        }
        let plan = ImageCachePolicy.shared.plan(entries: entries, keeping: hashes)
        var occupancy = plan.occupancy
        var settled = true
        for entry in plan.candidates {
            guard ImageCachePolicy.shared.shouldEvict(occupancy: occupancy, profile: .iphone) else { break }
            do {
                try manager.removeItem(at: directory.appendingPathComponent(entry.key))
                occupancy = ImageCachePolicy.shared.removed(occupancy: occupancy, entry: entry)
            } catch { settled = false /* 下轮继续，不扩大删除范围。 */ }
        }
        settledKeeping = settled ? hashes : nil
    }

    /// 断线、取消及清单失效仅清理本owner的精确临时文件，不删除已经验证的缓存。
    func cancel() {
        try? writer?.close(); writer = nil
        if let partial { try? FileManager.default.removeItem(at: partial) }
        partial = nil; descriptor = nil
    }

    deinit { cancel() }
}
