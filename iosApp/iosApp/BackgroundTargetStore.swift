import Foundation

/// 仅保留成功认证桌面的Bonjour服务元数据；网络地址每次由系统重新解析。
struct BackgroundTarget: Codable, Equatable {
    let id: String
    let name: String
    let type: String
    let domain: String
}

/// App私有、按本机身份隔离的后台目标。文件不含配对秘密，不进入共享小组件容器。
final class BackgroundTargetStore {
    enum Failure: Error { case invalid; case storage }
    private struct Record: Codable {
        let version: Int
        let deviceId: String
        let target: BackgroundTarget
    }
    private static let lock = NSLock()
    private let deviceId: String
    private let directory: URL?

    init(deviceId: String, directory: URL? = nil) {
        self.deviceId = deviceId
        self.directory = directory
    }

    /// 只有文件不存在代表尚无后台目标，损坏或锁定读取失败不会当作空记录。
    func load() throws -> BackgroundTarget? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try loadRecord()
    }

    /// 先校验并编码，再原子替换；失败不会先删除已有目标，也不会影响Keychain。
    func save(_ target: BackgroundTarget) throws {
        let canonical = try validated(target)
        let record = Record(version: 1, deviceId: deviceId, target: canonical)
        let data = try SharedJSON.encoder.encode(record)
        guard data.count <= 4096 else { throw Failure.invalid }
        Self.lock.lock(); defer { Self.lock.unlock() }
        let file = try fileURL()
        var folder = file.deletingLastPathComponent()
        #if os(iOS)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        #else
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #endif
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file, options: .atomic)
        #endif
    }

    /// 仅清除本机当前记录中精确匹配的桌面，避免旧会话清除新选择。
    func forget(_ id: String) throws {
        guard SharedValidation.validId(id) else { throw Failure.invalid }
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let target = try loadRecord(), target.id == id else { return }
        try FileManager.default.removeItem(at: fileURL())
    }

    /// 用户显式换桌面或忘记配对时，可撤销当前设备损坏的可选元数据。
    /// 不解码记录，不访问其他设备文件，也不沿符号链接删除任何目标。
    func reset() throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let file = try fileURL()
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: file.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw Failure.storage }
        try FileManager.default.removeItem(at: file)
    }

    /// 读取并校验后台刷新目标记录；文件不存在返回 nil。
    private func loadRecord() throws -> BackgroundTarget? {
        let file = try fileURL()
        let data: Data
        do {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= 4096 else { throw Failure.storage }
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        guard data.count <= 4096 else { throw Failure.storage }
        let record = try SharedJSON.decoder.decode(Record.self, from: data)
        guard record.version == 1, record.deviceId == deviceId else { throw Failure.storage }
        return try validated(record.target)
    }

    /// 目标记录固定位于应用私有目录，不进入 App Group。
    private func fileURL() throws -> URL {
        guard SharedValidation.validId(deviceId) else { throw Failure.invalid }
        let folder: URL
        if let directory { folder = directory }
        else {
            guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { throw Failure.storage }
            folder = support.appendingPathComponent("BackgroundRefresh", isDirectory: true)
        }
        return folder.appendingPathComponent(deviceId + ".json", isDirectory: false)
    }

    /// 只接受本产品服务类型与 local. 域，并重新校验名称长度与控制字符；类型与域按规范写法返回。
    private func validated(_ target: BackgroundTarget) throws -> BackgroundTarget {
        guard SharedValidation.validId(deviceId), SharedValidation.validId(target.id), target.id != deviceId,
              !target.name.isEmpty, target.name.utf8.count <= 63,
              !SharedValidation.containsControl(target.name),
              ["_loki-host._tcp", "_loki-host._tcp."].contains(target.type.lowercased()),
              target.domain.lowercased() == "local." else { throw Failure.invalid }
        return BackgroundTarget(id: target.id, name: target.name, type: "_loki-host._tcp", domain: "local.")
    }
}
