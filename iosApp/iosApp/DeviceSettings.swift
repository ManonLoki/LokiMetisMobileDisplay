import Foundation
import SharedLogic
import SwiftUI

/// 本机身份与设置独立于连接owner；保存名称不会启停网络，设备UUID沿用原有路径。
@MainActor
final class DeviceSettings: ObservableObject {
    let deviceId: String
    @Published private(set) var deviceName: String
    private(set) var identityError: String?
    private let preferences: UserDefaults

    /// 兼容已保存名称和旧发现UUID，身份损坏时不生成替代身份覆盖信任。
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        do { deviceId = try Self.loadDeviceId() }
        catch { deviceId = ""; identityError = "无法读取或保存设备身份，请检查存储空间后重新打开应用。" }
        let saved = preferences.string(forKey: "mdns.deviceName") ?? MdnsProtocol.shared.DEFAULT_NAME
        deviceName = MdnsProtocol.shared.nameError(name: saved) == nil ? saved : MdnsProtocol.shared.DEFAULT_NAME
    }

    /// 名称沿用共享Kotlin校验，存储只属于本设备设置。
    func saveDeviceName(_ name: String) -> Bool {
        guard identityError == nil, MdnsProtocol.shared.nameError(name: name) == nil else { return false }
        preferences.set(name, forKey: "mdns.deviceName")
        deviceName = name
        return true
    }

    /// UUID文件不备份，防止恢复备份后多个设备复制同一配对身份。
    private static func loadDeviceId() throws -> String {
        let manager = FileManager.default
        var directory = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Discovery", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let file = directory.appendingPathComponent("device-id")
        if manager.fileExists(atPath: file.path) {
            let stored = try String(contentsOf: file, encoding: .utf8)
            guard MdnsProtocol.shared.isCanonicalDeviceId(id: stored) else { throw CocoaError(.fileReadCorruptFile) }
            return stored
        }
        let id = UUID().uuidString.lowercased()
        try id.write(to: file, atomically: true, encoding: .utf8)
        return id
    }
}
