import SwiftUI

/// Watch应用固定持有一个配套owner，普通菜单切换不重建前台代次。
@main
struct LokiMetrisWatchApp: App {
    @Environment(\.scenePhase) private var phase
    @StateObject private var model = WatchLinkModel()
    var body: some Scene {
        WindowGroup { WatchRootView(model: model) }
            .onChange(of: phase, initial: true) { _, value in model.setActive(value == .active) }
    }
}

/// 主线程薄模型仅发布最新视图，所有协议和私有文件工作留在串行owner。
@MainActor
final class WatchLinkModel: ObservableObject {
    @Published private(set) var state = WatchLinkView()
    private var engine: WatchLinkEngine?
    private var delivery: LanProjectionDelivery<WatchLinkView>?
    /// 初始化不会把无缓存状态伪装成已连接或使用示例数据。
    init() {
        let delivery = LanProjectionDelivery<WatchLinkView> { [weak self] value in self?.state = value }
        self.delivery = delivery; engine = WatchLinkEngine { value in delivery.submit(value) }
    }
    func setActive(_ active: Bool) { engine?.setActive(active) }
    func synchronize() { engine?.synchronize() }
    func saveName(_ value: String) { engine?.saveName(value) }
}

/// 手表先呈现可一眼读取的数字，编辑与连接操作收进原生设置页。
@MainActor
private struct WatchRootView: View {
    private let panel = Color(red: 17 / 255, green: 29 / 255, blue: 45 / 255)
    private let accent = Color(red: 103 / 255, green: 232 / 255, blue: 249 / 255)
    private let violet = Color(red: 174 / 255, green: 140 / 255, blue: 255 / 255)
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var reducedLuminance
    @ObservedObject var model: WatchLinkModel
    @State private var showingSettings = false
    @State private var name = ""
    @State private var entered = false
    @State private var updateGlow = false
    @State private var glowRevision = 0
    @AppStorage("watch.panel.showUsage") private var showUsage = true
    @AppStorage("watch.panel.showHooks") private var showHooks = true
    @AppStorage("watch.panel.usageDetailed") private var usageDetailed = false

    private var allowsMotion: Bool {
        phase == .active && !reduceMotion && !reducedLuminance && !showingSettings
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) { display }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 12)
                    .opacity(entered || !allowsMotion ? 1 : 0.5)
                    .scaleEffect(entered || !allowsMotion ? 1 : 0.98, anchor: .top)
            }
            .background(Color.black)
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape.fill").foregroundStyle(accent)
                    }
                        .tint(panel)
                        .accessibilityLabel("设置")
                        .accessibilityIdentifier("watch-menu")
                }
            }
            .navigationDestination(isPresented: $showingSettings) {
                List { settings }
                    .navigationTitle("设置")
            }
        }
        .tint(accent)
        .onChange(of: model.state.info?.name, initial: true) { _, value in if let value { name = value } }
        .onChange(of: phase, initial: true) { _, value in
            if value == .active {
                if allowsMotion {
                    glowRevision += 1
                } else { stopMotion() }
            } else { stopMotion() }
        }
        .onChange(of: model.state.envelope?.snapshot) { old, new in
            if old != new, allowsMotion { glowRevision += 1 }
        }
        .onChange(of: reduceMotion) { _, _ in if !allowsMotion { stopMotion() } }
        .onChange(of: reducedLuminance) { _, _ in if !allowsMotion { stopMotion() } }
        .onChange(of: showingSettings) { _, _ in if !allowsMotion { stopMotion() } }
        .task(id: phase) {
            guard allowsMotion else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { entered = false }
            do { try await Task.sleep(for: .milliseconds(35)) }
            catch { return }
            guard allowsMotion else { return }
            withAnimation(.easeOut(duration: 0.3)) { entered = true }
        }
        .task(id: glowRevision) {
            guard allowsMotion else { return }
            withAnimation(.easeOut(duration: 0.2)) { updateGlow = true }
            do { try await Task.sleep(for: .milliseconds(450)) }
            catch { return }
            guard allowsMotion else { return }
            withAnimation(.easeOut(duration: 0.35)) { updateGlow = false }
        }
    }

    private func stopMotion() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { entered = true; updateGlow = false }
        glowRevision += 1
    }

    @ViewBuilder private var display: some View {
        if !showUsage && !showHooks {
            emptyPanel(title: "未选择卡片", detail: nil, action: "选择卡片", identifier: "watch-configure-panel")
        } else if let envelope = model.state.envelope {
            cacheStatus
            if showUsage {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Image(systemName: "number").foregroundStyle(accent)
                        Text("Token 用量").font(.caption.weight(.medium))
                    }
                    if let tokens = envelope.snapshot.tokens {
                        amount("总 Token", value: tokens.all, prominent: true)
                        Text(tokens.day.date).font(.caption2).foregroundStyle(.secondary)
                        if usageDetailed {
                            Divider().overlay(.white.opacity(0.08))
                            ForEach(tokens.agents, id: \.agent) { amount($0.agent, value: $0.amount) }
                            Text(tokens.day.zone).font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text(envelope.snapshot.tokenError == nil ? "尚未同步" : "暂不可用")
                            .font(.title3.weight(.semibold))
                    }
                }
                .watchPanel(panel, highlighted: updateGlow && allowsMotion)
            }
            if showHooks {
                HStack {
                    Text("Hooks").font(.headline)
                    Spacer()
                    if envelope.snapshot.hooksAvailable {
                        Text("\(envelope.snapshot.hooks.count) 个槽位").font(.caption2).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 4)
                if !envelope.snapshot.hooksAvailable {
                    Text("暂不可用").font(.caption).foregroundStyle(.secondary).watchPanel(panel)
                } else if envelope.snapshot.hooks.isEmpty {
                    Text("暂无活动槽位").font(.caption).foregroundStyle(.secondary).watchPanel(panel)
                }
                ForEach(envelope.snapshot.hooks.sorted(by: { $0.slot < $1.slot }), id: \.slot) { hook in
                    hookCard(hook)
                }
            }
        } else {
            emptyPanel(title: "尚未同步", detail: "在 iPhone 中连接桌面", action: "连接设置", identifier: "watch-open-settings")
        }
    }

    /// 通信资格与历史数据分开表达，时间始终来自真实接收记录。
    private var cacheStatus: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Circle().fill(model.state.canSync ? accent : Color.secondary).frame(width: 4, height: 4)
            Text(model.state.envelope != nil ? "本次同步" : "等待同步")
                .font(.system(size: 10, weight: .medium)).fixedSize()
            Spacer(minLength: 0)
            if let received = model.state.receivedAt {
                Text(received.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day().hour().minute()))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .accessibilityLabel("接收于 \(received.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).year().month().day().hour().minute()))")
            }
        }.padding(.horizontal, 4)
    }

    /// 大字便于扫读，小字保留完整整数；两者均来自同一精确值。
    private func amount(_ title: String, value: WidgetAmount, prominent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if !prominent { Text(title).font(.caption2).foregroundStyle(.secondary) }
            Text(value.compactText)
                .font(prominent ? .system(size: 31, weight: .semibold, design: .monospaced) : .system(.body, design: .monospaced, weight: .medium))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.25)
                .frame(maxWidth: .infinity, alignment: .leading)
                .privacySensitive()
                .contentTransition(allowsMotion ? .numericText() : .identity)
                .animation(allowsMotion ? .easeOut(duration: 0.28) : nil, value: value.text)
            if value.hasNumericValue {
                Text(value.exactText).font(.system(size: 11, weight: .medium, design: .monospaced))
                    .monospacedDigit().foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !value.quality.isEmpty {
                Text(value.quality).font(.caption2.weight(.medium)).foregroundStyle(violet)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，\(value.text)\(value.quality.isEmpty ? "" : "，" + value.quality)")
        .privacySensitive()
    }

    private func hookCard(_ hook: LanDisplaySnapshot.Hook) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(hook.agent).font(.headline).lineLimit(1)
                Spacer(minLength: 0)
                Text(hook.behavior.label).font(.caption2.weight(.medium))
                    .foregroundStyle(behaviorColor(hook.behavior))
            }
            Text("槽位 \(hook.slot)").font(.caption2).foregroundStyle(.secondary)
            if !hook.content.isEmpty {
                Text(hook.content).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            if hook.contentTruncated { Text("正文已截断").font(.caption2).foregroundStyle(.secondary) }
            if let hash = hook.image {
                if let image = model.state.images[hash] {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 112)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Label("图片未缓存", systemImage: "photo").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .watchPanel(panel, highlighted: updateGlow && allowsMotion)
        .privacySensitive()
        .animation(allowsMotion ? .easeOut(duration: 0.2) : nil, value: hook.behavior)
    }

    private func behaviorColor(_ behavior: WidgetHook.Behavior) -> Color {
        switch behavior {
        case .running: return accent
        case .asking: return violet
        case .error: return .orange
        case .idle: return .white.opacity(0.7)
        }
    }

    private func emptyPanel(title: String, detail: String?, action: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "square.grid.2x2").font(.title2).foregroundStyle(accent)
            Text(title).font(.headline)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            Button(action) { showingSettings = true }
                .buttonStyle(.borderedProminent).tint(accent)
                .foregroundStyle(Color(red: 5 / 255, green: 10 / 255, blue: 18 / 255))
                .accessibilityIdentifier(identifier)
        }.watchPanel(panel)
    }

    /// 系统配对和实际应用同步各自披露，手机IP不作为Watch网络信息。
    @ViewBuilder private var connectionSettings: some View {
        Section("iPhone 同步") {
            Text(model.state.status).font(.caption)
            Text("使用已配对的 iPhone，两端 App 需在前台。")
                .font(.caption2).foregroundStyle(.secondary)
            if let date = model.state.receivedAt {
                LabeledContent("最近接收") { Text(date, format: .dateTime.month().day().hour().minute()).font(.caption2) }
            }
            Button("请求同步", action: model.synchronize)
                .buttonStyle(.bordered).accessibilityIdentifier("watch-sync")
            if let error = model.state.error { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
        if let source = model.state.envelope {
            Section("同步来源") {
                identity("iPhone ID", value: source.phoneId)
                identity("桌面 ID", value: source.sourceId)
            }
        }
    }

    @ViewBuilder private var settings: some View {
        Section("显示内容") {
            Toggle("Token 用量", isOn: $showUsage).accessibilityIdentifier("watch-show-usage")
            Toggle("Hooks", isOn: $showHooks).accessibilityIdentifier("watch-show-hooks")
            if showUsage {
                Picker("用量详情", selection: $usageDetailed) {
                    Text("总量").tag(false)
                    Text("分项").tag(true)
                }.accessibilityIdentifier("watch-usage-detail")
            }
        }
        connectionSettings
        Section("本机") {
            TextField("设备名称", text: $name).accessibilityIdentifier("watch-device-name")
            Button("保存名称") { model.saveName(name) }
                .buttonStyle(.bordered).disabled(model.state.info == nil || name == model.state.info?.name)
            if let feedback = model.state.nameFeedback { Text(feedback).font(.caption) }
            identity("设备 ID", value: model.state.info?.deviceId ?? "身份暂不可用")
        }
    }

    private func identity(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption2.monospaced()).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension View {
    func watchPanel(_ color: Color, highlighted: Bool = false) -> some View {
        modifier(WatchCyberPanel(color: color, highlighted: highlighted))
    }
}

private struct WatchCyberPanel: ViewModifier {
    @Environment(\.isLuminanceReduced) private var reducedLuminance
    let color: Color
    let highlighted: Bool
    private let cyan = Color(red: 103 / 255, green: 232 / 255, blue: 249 / 255)
    private let violet = Color(red: 174 / 255, green: 140 / 255, blue: 255 / 255)

    func body(content: Content) -> some View {
        content.padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [color, Color(red: 5 / 255, green: 10 / 255, blue: 18 / 255)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        if !reducedLuminance {
                            WatchCircuitGrid().stroke(cyan.opacity(0.055), lineWidth: 0.5)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [cyan.opacity(reducedLuminance ? 0.12 : (highlighted ? 0.85 : 0.38)), .white.opacity(0.05), violet.opacity(reducedLuminance ? 0.08 : 0.3)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7)
                    }
                    .overlay(alignment: .topLeading) {
                        if !reducedLuminance {
                            Capsule().fill(cyan.opacity(highlighted ? 0.9 : 0.55))
                                .frame(width: 28, height: 1).padding(.leading, 17)
                        }
                    }
                    .shadow(color: cyan.opacity(highlighted && !reducedLuminance ? 0.18 : 0), radius: 8)
                    .accessibilityHidden(true)
            }
    }
}

/// 静态几何网格无需逐帧绘制或常驻计时器。
private struct WatchCircuitGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for x in stride(from: CGFloat(0), through: rect.width, by: 18) {
            path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: rect.height))
        }
        for y in stride(from: CGFloat(0), through: rect.height, by: 18) {
            path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: rect.width, y: y))
        }
        return path
    }
}
