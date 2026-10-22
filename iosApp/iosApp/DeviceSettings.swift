import Foundation
import SharedLogic
import SwiftUI

/// 本机身份与设置独立于连接owner；保存名称不会启停网络，设备UUID由私有钥匙串恢复。
@MainActor
final class DeviceSettings: ObservableObject {
    let deviceId: String
    @Published private(set) var deviceName: String
    let identityError: String?
    private let preferences: UserDefaults

    /// 读取已保存名称与钥匙串身份；身份损坏时不生成替代身份覆盖信任。
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        do { deviceId = try DeviceIdentityStore().load(); identityError = nil }
        catch let error as DeviceIdentityFailure { deviceId = ""; identityError = error.userMessage }
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
}
