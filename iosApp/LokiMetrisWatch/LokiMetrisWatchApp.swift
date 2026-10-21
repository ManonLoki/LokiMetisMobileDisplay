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
    /// 以下操作都转发给引擎；引擎未就绪时忽略。
    func setActive(_ active: Bool) { engine?.setActive(active) }
    func synchronize() { engine?.synchronize() }
    func saveName(_ value: String) { engine?.saveName(value) }
}

/// Hooks、Token、额度从左到右独立分页；首次显示Token，以语义ID记住上次页面。
@MainActor
private struct WatchRootView: View {
    private enum Page: String, Hashable { case hooks, tokens, quota }
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
    @AppStorage("watch.panel.selectedPage") private var selectedPage = Page.tokens.rawValue
    @AppStorage("watch.panel.showUsage") private var showUsage = true
    @AppStorage("watch.panel.showHooks") private var showHooks = true
    @AppStorage("watch.panel.usageDetailed") private var usageDetailed = false

    private var allowsMotion: Bool {
        phase == .active && !reduceMotion && !reducedLuminance && !showingSettings
    }
    private var visiblePages: [Page] {
        (showHooks ? [.hooks] : []) + (showUsage ? [.tokens, .quota] : [])
    }

    var body: some View {
        NavigationStack {
            Group {
                if visiblePages.isEmpty {
                    ScrollView {
                        emptyPanel(title: "未选择卡片", detail: nil, action: "选择卡片", identifier: "watch-configure-panel")
                            .padding(.horizontal, 4)
                    }
                } else {
                    GeometryReader { pageArea in
                        TabView(selection: $selectedPage) {
                            if showHooks { hooksPage(size: pageArea.size).tag(Page.hooks.rawValue) }
                            if showUsage { tokensPage.tag(Page.tokens.rawValue) }
                            if showUsage { quotaPage.tag(Page.quota.rawValue) }
                        }
                        .frame(width: pageArea.size.width, height: pageArea.size.height)
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .accessibilityIdentifier("watch-pages")
                        .overlay(alignment: .bottom) {
                            if visiblePages.count > 1 {
                                HStack(spacing: 5) {
                                    ForEach(visiblePages, id: \.rawValue) { page in
                                        Circle().fill(selectedPage == page.rawValue ? .white : .white.opacity(0.35))
                                            .frame(width: 4, height: 4)
                                    }
                                }
                                .frame(height: 4)
                                .padding(.bottom, 5)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                            }
                        }
                    }
                    .ignoresSafeArea(.container, edges: .bottom)
                }
            }
            .opacity(entered || !allowsMotion ? 1 : 0.5)
            .scaleEffect(entered || !allowsMotion ? 1 : 0.98, anchor: .top)
            .background(Color.black)
            .navigationTitle("")
            .navigationDestination(isPresented: $showingSettings) {
                List { settings }
                    .navigationTitle("设置")
            }
        }
        .tint(accent)
        .onAppear { reconcilePage() }
        .onChange(of: showUsage) { _, _ in reconcilePage() }
        .onChange(of: showHooks) { _, _ in reconcilePage() }
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

    /// 已隐藏或无效的历史页只回退到有效页；全隐藏时保留用户最后的语义ID。
    private func reconcilePage() {
        guard !visiblePages.isEmpty, !visiblePages.contains(where: { $0.rawValue == selectedPage }) else { return }
        selectedPage = (showUsage ? Page.tokens : .hooks).rawValue
    }

    private func stopMotion() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { entered = true; updateGlow = false }
        glowRevision += 1
    }

    private var tokensPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let envelope = model.state.envelope {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("Token 总量", systemImage: "number")
                            .font(.caption.weight(.medium)).foregroundStyle(accent)
                        if let tokens = envelope.snapshot.tokens {
                            amount("总 Token", value: tokens.all, prominent: true)
                            Text(tokens.day.date).font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Text(envelope.snapshot.tokenError == nil ? "Token 尚未同步" : "Token 暂不可用")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if usageDetailed, let tokens = envelope.snapshot.tokens {
                            Divider().overlay(.white.opacity(0.08))
                            ForEach(tokens.displayAgents, id: \.agent) { amount($0.displayName, value: $0.amount) }
                            Text(tokens.day.zone).font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .watchPanel(panel, highlighted: updateGlow && allowsMotion)
                    .accessibilityIdentifier("watch-token-card")
                } else {
                    waitingPanel
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, visiblePages.count > 1 ? 22 : 8)
        }
        .accessibilityLabel("Token 总量页面")
    }

    private var quotaPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let quota = model.state.envelope?.snapshot.providerQuota, !quota.providers.isEmpty {
                    quotaContent(quota)
                        .watchPanel(panel, highlighted: updateGlow && allowsMotion)
                        .accessibilityIdentifier("watch-quota-card")
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("等待额度数据").font(.headline)
                        Text(model.state.envelope == nil
                            ? "先在 iPhone 中连接桌面，再同步账户额度。"
                            : "桌面尚未提供账户额度，获取后会自动同步。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.state.envelope == nil {
                            Button("连接设置") { showingSettings = true }
                                .accessibilityIdentifier("watch-quota-settings")
                        } else {
                            Button("请求同步", action: model.synchronize)
                                .accessibilityIdentifier("watch-quota-sync")
                        }
                    }
                    .watchPanel(panel)
                    .accessibilityIdentifier("watch-quota-waiting")
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, visiblePages.count > 1 ? 22 : 8)
        }
        .accessibilityLabel("账户剩余额度页面")
    }

    /// 额度页只保留账户类型及其各窗口的剩余额度。
    private func quotaContent(_ quota: ProviderQuotaSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(quota.providers, id: \.provider) { provider in
                VStack(alignment: .leading, spacing: 7) {
                    Text(provider.displayName).font(.caption.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        ForEach(provider.windows, id: \.kind) { value in
                            quotaProgress(value, label: value.label)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .privacySensitive()
        .accessibilityIdentifier("watch-provider-quota")
    }

    /// 直接显示桌面给出的剩余比例；缺少的窗口不占位，不按Token用量推算。
    private func quotaProgress(_ value: ProviderQuotaWindow, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label).font(.caption2).lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                Text(value.percentText).font(.caption2.monospacedDigit()).fontWeight(.semibold)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            GeometryReader { geometry in
                let color: Color = value.level == 0 ? .red : value.level == 1 ? .yellow : .green
                Capsule().fill(color.opacity(0.2))
                    .overlay(alignment: .leading) {
                        Capsule().fill(color)
                            .frame(width: geometry.size.width * CGFloat(value.remainingTenths) / 1000)
                    }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label)额度剩余，\(value.percentText)")
    }

    /// 每屏固定一张活动卡；沿用外层页尺寸，避免Watch分页压缩内层测量高度。
    /// 上下滚动吸附切换，左右手势留给主页面；底部只为分页圆点留空。
    private func hooksPage(size: CGSize) -> some View {
        let width = max(0, size.width - 8)
        let bottomInset: CGFloat = visiblePages.count > 1 ? 14 : 6
        let height = max(0, size.height - bottomInset)
        return GeometryReader { _ in
            ScrollView(.vertical) {
                if let snapshot = model.state.envelope?.snapshot {
                    if !snapshot.hooksAvailable {
                        hookPlaceholder("暂不可用")
                    } else if snapshot.hooks.isEmpty {
                        hookPlaceholder("暂无活动")
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(snapshot.hooks.sorted(by: { $0.slot < $1.slot }), id: \.slot) { hook in
                                hookTile(hook, height: height)
                                    .frame(width: width, height: height)
                                    .accessibilityElement(children: .combine)
                                    .accessibilityLabel("\(agentDisplayName(hook.agent))，\(hook.behavior.label)")
                                    .accessibilityIdentifier("watch-hook-\(hook.slot)")
                            }
                        }.scrollTargetLayout()
                    }
                } else {
                    waitingPanel
                }
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .contentMargins(.vertical, 0, for: .scrollContent)
            .frame(width: width, height: height)
            .clipped()
            .padding(.horizontal, 4)
            .padding(.bottom, bottomInset)
        }
        .accessibilityLabel("活动状态页面")
    }

    private var waitingPanel: some View {
        emptyPanel(title: "尚未同步", detail: "先在 iPhone 中连接桌面，同步连接配置。", action: "连接设置", identifier: "watch-open-settings")
    }

    private func hookPlaceholder(_ title: String) -> some View {
        Text(title).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).watchPanel(panel)
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
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，\(value.text)\(value.quality.isEmpty ? "" : "，" + value.quality)")
        .privacySensitive()
    }

    private func hookTile(_ hook: LanDisplaySnapshot.Hook, height: CGFloat) -> some View {
        let inset: CGFloat = 9
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(agentDisplayName(hook.agent))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.65)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 3) {
                    Circle().fill(behaviorColor(hook.behavior)).frame(width: 5, height: 5)
                    Text(hook.behavior.label).font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(behaviorColor(hook.behavior))
                .fixedSize(horizontal: true, vertical: false)
            }
            .fixedSize(horizontal: false, vertical: true)
            hookImage(hook)
        }
        .frame(maxWidth: .infinity)
        .frame(height: max(0, height - inset * 2))
        .watchPanel(panel, highlighted: updateGlow && allowsMotion, padding: inset)
        .privacySensitive()
        .animation(allowsMotion ? .easeOut(duration: 0.2) : nil, value: hook.behavior)
    }

    private func hookImage(_ hook: LanDisplaySnapshot.Hook) -> some View {
        let image = hook.image.flatMap { model.state.images[$0] }
        let placeholder = hook.image == nil ? "暂无图片" : "图片未缓存"
        return GeometryReader { area in
            Group {
                if let image {
                    HookAssetImage(asset: image, playbackEnabled: selectedPage == Page.hooks.rawValue && !showingSettings)
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "photo").accessibilityHidden(true)
                        Text(placeholder).font(.caption2)
                    }.foregroundStyle(.secondary)
                }
            }
            .frame(width: area.size.width, height: area.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .frame(minHeight: 44)
        .accessibilityLabel(image == nil ? placeholder : "活动图片")
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

    /// 手机优先，无法取得手机数据时自动使用已同步的 HTTP 配置。
    @ViewBuilder private var connectionSettings: some View {
        Section("数据连接") {
            Text(model.state.status).font(.caption)
            LabeledContent("当前方式") { Text(model.state.connectionMode).font(.caption2) }
            Text("优先通过 iPhone 同步完整数据。手机 App 在后台时可提供连接配置；无法完成手机同步时，手表自动通过 HTTP 直连桌面。")
                .font(.caption2).foregroundStyle(.secondary)
            if model.state.summaryOnly {
                Text("HTTP 直连提供用量、账户额度与插槽状态；正文与图片通过 iPhone 同步。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let date = model.state.receivedAt {
                LabeledContent("上次同步") {
                    Text(date.formatted(SyncTimeFormat.full)).font(.caption2)
                        .accessibilityLabel("上次同步于 \(date.formatted(SyncTimeFormat.full))")
                }
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
            Toggle("用量与额度", isOn: $showUsage).accessibilityIdentifier("watch-show-usage")
            Toggle("Hooks", isOn: $showHooks).accessibilityIdentifier("watch-show-hooks")
            if showUsage {
                Picker("显示详情", selection: $usageDetailed) {
                    Text("简洁").tag(false)
                    Text("详细").tag(true)
                }.accessibilityIdentifier("watch-usage-detail")
            }
            if showUsage && showHooks {
                Text("首次显示 Token 总量，左滑看额度，右滑看 Hooks；自动记住上次查看的页面。")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if visiblePages.count > 1 {
                Text("左右滑动切换卡片，自动记住上次查看的页面。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if showHooks {
                Text("Hooks 每屏显示一张活动卡，上下滚动切换。")
                    .font(.caption2).foregroundStyle(.secondary)
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
    func watchPanel(_ color: Color, highlighted: Bool = false, padding: CGFloat = 13) -> some View {
        modifier(WatchCyberPanel(color: color, highlighted: highlighted, padding: padding))
    }
}

private struct WatchCyberPanel: ViewModifier {
    @Environment(\.isLuminanceReduced) private var reducedLuminance
    let color: Color
    let highlighted: Bool
    let padding: CGFloat
    private let cyan = Color(red: 103 / 255, green: 232 / 255, blue: 249 / 255)
    private let violet = Color(red: 174 / 255, green: 140 / 255, blue: 255 / 255)

    func body(content: Content) -> some View {
        content.padding(padding)
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
