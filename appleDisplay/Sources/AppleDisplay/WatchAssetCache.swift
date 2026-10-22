import Foundation
import CryptoKit
import SharedLogic

/// Watch只缓存当前展示引用的内容，系统配套通道传来的文件同样需完整校验。
final class WatchAssetCache {
    private let directory: URL
    private var partial: URL?
    private var writer: FileHandle?
    private var descriptor: LanDisplaySnapshot.Asset?
    private var transferId: String?
    private var offset: UInt64 = 0
    /// 上次完整收敛时保留的引用集；引用不变且没有新文件落盘时无需重新扫描目录。
    private var settledKeeping: Set<String>?
    /// 目录由Watch宿主创建并标记不备份，初始化精确回收本产品半成品。
    init(directory: URL) throws {
        let root = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard root.isDirectory == true, root.isSymbolicLink != true else { throw WidgetSnapshotError.invalid }
        self.directory = directory
        try LanAssetFiles.removeOrphanPartials(in: directory)
    }
    /// 缓存复用核对真实文件长度、魔数与流式SHA-256，避免一次展开32MiB。
    func cached(_ asset: LanDisplaySnapshot.Asset) throws -> URL? {
        try validate(asset)
        let file = directory.appendingPathComponent(asset.hash)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == Int(asset.length) else { return nil }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 16) ?? Data()
        guard LanDisplaySnapshot.Asset.validMagic(prefix, mime: asset.mime) else { return nil }
        try handle.seek(toOffset: 0)
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 65536), !data.isEmpty { hasher.update(data: data) }
        guard SharedValidation.hex(hasher.finalize()) == asset.hash else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return file
    }
    /// 同时只接收一个摘要，UUID临时文件不允许远端指定路径。
    func begin(_ asset: LanDisplaySnapshot.Asset, id: String) throws {
        cancel(); try validate(asset)
        guard SharedValidation.validId(id) else { throw WidgetSnapshotError.invalid }
        let path = directory.appendingPathComponent(".partial-" + UUID().uuidString.lowercased())
        guard FileManager.default.createFile(atPath: path.path, contents: nil) else { throw WidgetSnapshotError.unavailable }
        partial = path
        do { writer = try FileHandle(forWritingTo: path) } catch { cancel(); throw error }
        descriptor = asset; transferId = id; offset = 0
    }
    /// 精确块偏移和大小通过后才写；同步磁盘、完整校验及原子替换完成才返回成功路径。
    func accept(id: String, offset: UInt64, data: Data) throws -> (UInt64, URL?) {
        guard let writer, let asset = descriptor, let partial,
              let length = Int32(exactly: asset.length), let received = Int32(exactly: self.offset),
              let incomingOffset = Int64(exactly: offset), let count = Int32(exactly: data.count)
        else { throw WidgetSnapshotError.invalid }
        let decision = WatchProtocolRules.shared.assetChunk(transferId: transferId, incomingId: id,
            length: length, receivedBytes: received, offset: incomingOffset, byteCount: count)
        guard decision.valid else { throw WidgetSnapshotError.invalid }
        try writer.write(contentsOf: data); self.offset = UInt64(decision.nextOffset)
        if !decision.complete { return (self.offset, nil) }
        try writer.synchronize(); try writer.close(); self.writer = nil
        // 先在临时文件名下验证，不覆盖此前有效的同摘要正文。
        guard try validPartial(partial, asset: asset) else { throw WidgetSnapshotError.invalid }
        let destination = directory.appendingPathComponent(asset.hash)
        if FileManager.default.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw WidgetSnapshotError.invalid }
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
        } else { try FileManager.default.moveItem(at: partial, to: destination) }
        self.partial = nil; descriptor = nil; transferId = nil; settledKeeping = nil
        // 临时文件已完整校验，原子改名不改变内容，无需再整文件重读一次。
        return (asset.length, destination)
    }
    /// 临时完整文件只在接收结束时读取一次，长度上限32MiB且不进入UI线程。
    private func validPartial(_ path: URL, asset: LanDisplaySnapshot.Asset) throws -> Bool {
        let data = try Data(contentsOf: path, options: .mappedIfSafe)
        return data.count == Int(asset.length) && LanDisplaySnapshot.Asset.validMagic(data.prefix(16), mime: asset.mime) && WatchProtocol.hash(data) == asset.hash
    }
    /// 资源元信息与现有展示协议保持同一容量和格式边界。
    private func validate(_ asset: LanDisplaySnapshot.Asset) throws {
        guard asset.isValid else { throw WidgetSnapshotError.invalid }
    }
    /// 后台保留全部动画帧和原始时序；每张最多256像素、2MiB，十二张约24MiB。
    /// 不读写缓存状态，可在独立解码队列执行，不占用配套RPC队列。
    static func image(_ path: URL, asset: LanDisplaySnapshot.Asset) throws -> LanImageAsset {
        let limits = LanImageAsset.Limits(profile: .watch)
        return try LanImageAsset.decode(contentsOf: path, mime: asset.mime, id: asset.hash, limits: limits)
    }
    /// 当前引用优先保留，旧缓存按最近复用时间收敛到512MiB和512个文件。
    func prune(keeping: Set<String>) {
        guard keeping != settledKeeping else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey,.contentModificationDateKey]) else { return }
        let entries = files.compactMap { path -> ImageCacheEntry? in
            guard SharedValidation.validHash(path.lastPathComponent), let value = try? path.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey,.contentModificationDateKey]),
                  value.isRegularFile == true, value.isSymbolicLink != true else { return nil }
            return ImageCacheEntry(key: path.lastPathComponent, byteLength: Int64(value.fileSize ?? 0),
                lastUsed: (value.contentModificationDate ?? .distantPast).timeIntervalSinceReferenceDate)
        }
        let plan = ImageCachePolicy.shared.plan(entries: entries, keeping: keeping)
        var occupancy = plan.occupancy; var settled = true
        for entry in plan.candidates {
            guard ImageCachePolicy.shared.shouldEvict(occupancy: occupancy, profile: .watch) else { break }
            if (try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.key))) != nil {
                occupancy = ImageCachePolicy.shared.removed(occupancy: occupancy, entry: entry)
            } else { settled = false }
        }
        settledKeeping = settled ? keeping : nil
    }
    /// 取消只清理本次部分文件，已完整验证的缓存继续保留。
    func cancel() { try? writer?.close(); writer = nil; if let partial { try? FileManager.default.removeItem(at: partial) }; self.partial = nil; descriptor = nil; transferId = nil; offset = 0 }
    deinit { cancel() }
}
