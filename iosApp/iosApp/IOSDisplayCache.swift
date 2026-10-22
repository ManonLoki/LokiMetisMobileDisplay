import Foundation

/// Watch 传输复用 App 已落盘的图片；只读访问，不创建第二个缓存 owner，也不清理在途临时文件。
enum IOSDisplayCache {
    /// 已完整校验过的文件：摘要 → 文件系统身份。缓存文件按内容寻址，只会被整体原子替换，
    /// 替换后文件身份必然改变；身份与长度不变即可跳过整文件 SHA-256。
    private static let lock = NSLock()
    private static var verified: [String: NSObject] = [:]

    /// 后台 Watch 请求每次都会调用：首次校验读全文，之后只读文件属性。
    static func assetPaths(for snapshot: LanDisplaySnapshot) throws -> [String: URL] {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("lan-assets-v1", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [:] }
        let root = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard root.isDirectory == true, root.isSymbolicLink != true else { throw WidgetSnapshotError.invalid }
        let hashes = Set(snapshot.hooks.compactMap(\.image))
        lock.lock(); defer { lock.unlock() }
        // 只记住当前仍被引用的图片，记录数量随快照（最多十二张）有界。
        verified = verified.filter { hashes.contains($0.key) }
        var result: [String: URL] = [:]
        for asset in snapshot.assets where hashes.contains(asset.hash) {
            let path = directory.appendingPathComponent(asset.hash)
            guard let value = try? path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .fileResourceIdentifierKey]),
                  value.isRegularFile == true, value.isSymbolicLink != true, value.fileSize == Int(asset.length),
                  let identity = value.fileResourceIdentifier as? NSObject else { verified[asset.hash] = nil; continue }
            if verified[asset.hash]?.isEqual(identity) == true { result[asset.hash] = path; continue }
            guard let bytes = try? Data(contentsOf: path, options: .mappedIfSafe), bytes.count == Int(asset.length),
                  LanDisplaySnapshot.Asset.validMagic(bytes, mime: asset.mime), WatchProtocol.hash(bytes) == asset.hash else {
                verified[asset.hash] = nil; continue
            }
            verified[asset.hash] = identity
            result[asset.hash] = path
        }
        return result
    }
}
