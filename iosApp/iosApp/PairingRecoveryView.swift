import SwiftUI
import UniformTypeIdentifiers

/// 仅导出加密配对材料，恢复码由用户单独保管，不写入偏好或系统日志。
struct PairingRecoveryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, data.count <= 262_144 else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

@MainActor
struct PairingRecoveryView: View {
    @ObservedObject var settings: DeviceSettings
    @ObservedObject var link: LanLinkModel
    @State private var busy = false
    @State private var feedback: String?
    @State private var recoveryCode = ""
    @State private var exportCode: String?
    @State private var document: PairingRecoveryDocument?
    @State private var exporting = false
    @State private var importing = false
    @State private var encryptedData: Data?
    @State private var payload: PairingRecovery.Payload?
    @State private var confirming = false
    @State private var visible = false
    @State private var operationGeneration: UInt64 = 0

    var body: some View {
        Form {
            Section {
                Text("卸载前保存加密恢复文件和恢复码，重装后可恢复设备身份与配对。文件不包含 Token、Hooks 或图片。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("导出配对恢复文件", action: exportRecovery).disabled(busy)
                if let exportCode {
                    Text("请另外妥善保存恢复码，恢复时需要同时提供文件和恢复码。持有两者的人可以恢复这份配对。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(exportCode).font(.footnote.monospaced()).textSelection(.enabled).privacySensitive()
                    Button("保存加密文件") { exporting = true }.disabled(busy)
                    Button("已保存恢复码") { self.exportCode = nil; document = nil }
                }
            } header: { Text("备份配对") }
            Section {
                Button("选择配对恢复文件") { importing = true }.disabled(busy)
                if encryptedData != nil {
                    SecureField("恢复码", text: $recoveryCode).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().privacySensitive().disabled(busy)
                    Button("解密并预览", action: unlock).disabled(busy || recoveryCode.isEmpty)
                }
                Text("常规恢复需要没有其他配对。若发现多组旧身份，可用完整匹配的恢复包选择其中一组。旧备份可能包含后来忘记的配对；对端已撤销的授权仍需重新配对。")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("恢复配对") }
            if busy { ProgressView("正在处理…") }
            if let feedback { Section { Text(feedback).font(.footnote) } }
        }
        .navigationTitle("配对备份与恢复").navigationBarTitleDisplayMode(.inline)
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "LokiMetris-mobile-pairing") { result in
            switch result {
            case .success: feedback = "加密文件已保存。请将恢复码另外妥善保管。"
            case .failure: feedback = "恢复文件未能保存，请重试。"
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .data]) { result in
            guard visible, case .success(let url) = result else { return }
            operationGeneration &+= 1
            let token = operationGeneration
            busy = true; feedback = nil
            DispatchQueue.global(qos: .userInitiated).async {
                let read = Result { try Self.readBounded(url) }
                DispatchQueue.main.async {
                    guard visible, operationGeneration == token else { return }
                    busy = false
                    switch read {
                    case .success(let data): encryptedData = data; recoveryCode = ""
                    case .failure: feedback = "无法读取恢复文件，文件上限为256 KiB。"
                    }
                }
            }
        }
        .alert("恢复此设备的配对？", isPresented: $confirming) {
            Button("恢复配对", role: .destructive) {
                guard let payload else { return }
                self.payload = nil
                operationGeneration &+= 1
                let token = operationGeneration
                busy = true
                link.restorePairing(payload) { success in
                    guard visible, operationGeneration == token else { return }
                    busy = false
                    feedback = success ? "配对已恢复，正在查找原桌面。" : (settings.identityError ?? "恢复未完成：已有不同配对或存储不可用。请保留文件和恢复码，检查后重试。")
                }
            }
            Button("取消", role: .cancel) { payload = nil }
        } message: {
            if let payload { Text("设备 ID：\(payload.deviceId)\n桌面配对：\(payload.materials.count) 个\n\n恢复后使用原身份认证连接。") }
        }
        .onAppear { visible = true }
        .onDisappear {
            visible = false; operationGeneration &+= 1; busy = false
            recoveryCode = ""; exportCode = nil; document = nil; encryptedData = nil; payload = nil
        }
    }

    private func exportRecovery() {
        operationGeneration &+= 1
        let token = operationGeneration
        busy = true; feedback = nil
        link.exportPairingRecovery { result in
            guard visible, operationGeneration == token else { return }
            busy = false
            switch result {
            case .success(let value): document = PairingRecoveryDocument(data: value.data); exportCode = value.recoveryCode
            case .failure: feedback = "无法导出，请先完成配对并确认设备已解锁。"
            }
        }
    }
    private func unlock() {
        guard let data = encryptedData else { return }
        let code = recoveryCode
        operationGeneration &+= 1
        let token = operationGeneration
        busy = true; feedback = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try PairingRecovery.open(data: data, recoveryCode: code) }
            DispatchQueue.main.async {
                guard visible, operationGeneration == token else { return }
                busy = false
                switch result {
                case .success(let value): payload = value; confirming = true; recoveryCode = ""; encryptedData = nil
                case .failure: feedback = "恢复码不正确，或文件已损坏／不受支持。"
                }
            }
        }
    }
    nonisolated private static func readBounded(_ url: URL) throws -> Data {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let stream = InputStream(url: url) else { throw CocoaError(.fileReadUnknown) }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw CocoaError(.fileReadUnknown) }
            if count == 0 { return data }
            guard data.count + count <= 262_144 else { throw CocoaError(.fileReadTooLarge) }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}
