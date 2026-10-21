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
    private enum HookLayout: String { case single, four }
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
    @AppStorage("watch.panel.hookLayout") private var hookLayout = HookLayout.single.rawValue

    private var allowsMotion: Bool {
        phase == .active && !reduceMotion && !reducedLuminance && !showingSettings
    }
    private var fourHooks: Bool { hookLayout == HookLayout.four.rawValue }
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
                            if showHooks { hooksPage.tag(Page.hooks.rawValue) }
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
                            ForEach(tokens.agents, id: \.agent) { amount($0.displayName, value: $0.amount) }
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
                        Label("账户剩余额度", systemImage: "gauge.with.dots.needle.50percent")
                            .font(.caption.weight(.medium)).foregroundStyle(accent)
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

    /// 额度单独成页，更新时间来自上游观测，不把本次手表接收时间当作额度新鲜度。
    private func quotaContent(_ quota: ProviderQuotaSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("账户剩余额度").font(.caption.weight(.semibold)).foregroundStyle(accent)
            Text("额度更新 \(quota.observedDate.formatted(.dateTime.month().day().hour().minute()))")
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("额度更新于 \(quota.observedDate.formatted(.dateTime.month().day().hour().minute()))")
            ForEach(quota.providers, id: \.provider) { provider in
                VStack(alignment: .leading, spacing: 7) {
                    Text(provider.displayName).font(.caption.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(provider.windows, id: \.kind) { value in quotaProgress(value, label: value.label) }
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
                Text(label).font(.caption2)
                Spacer(minLength: 0)
                Text(value.percentText).font(.caption2.monospacedDigit()).fontWeight(.semibold)
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
            if usageDetailed, let reset = value.resetDate {
                Text("重置 \(reset.formatted(.dateTime.month().day().hour().minute()))")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label)额度剩余，\(value.percentText)")
        .accessibilityValue(usageDetailed ? value.resetDate.map { "重置于 \($0.formatted(.dateTime.month().day().hour().minute()))" } ?? "" : "")
    }

    /// 每个插槽按实际滚动视口分配高度，水平手势仅留给三张主卡片翻页。
    private var hooksPage: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Hooks").font(.caption.weight(.medium)).foregroundStyle(accent)
                Spacer(minLength: 0)
                if let snapshot = model.state.envelope?.snapshot, snapshot.hooksAvailable {
                    Text("\(snapshot.hooks.count) 个槽位").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 4)
            GeometryReader { viewport in
                ScrollView {
                    if let snapshot = model.state.envelope?.snapshot {
                        if !snapshot.hooksAvailable {
                            hookPlaceholder("暂不可用")
                        } else if snapshot.hooks.isEmpty {
                            hookPlaceholder("暂无活动槽位")
                        } else {
                            let tileHeight = fourHooks ? max(34, (viewport.size.height - 7) / 2) : max(70, viewport.size.height)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: fourHooks ? 2 : 1), spacing: 7) {
                                ForEach(snapshot.hooks.sorted(by: { $0.slot < $1.slot }), id: \.slot) { hook in
                                    NavigationLink {
                                        hookDetail(hook)
                                    } label: {
                                        hookTile(hook, compact: fourHooks, minimumHeight: tileHeight)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("槽位 \(hook.slot)，\(agentDisplayName(hook.agent))，\(hook.behavior.label)")
                                    .accessibilityHint("打开槽位详情")
                                    .accessibilityIdentifier("watch-hook-\(hook.slot)")
                                }
                            }
                        }
                    } else {
                        waitingPanel
                    }
                }
                .contentMargins(.vertical, 0, for: .scrollContent)
                .frame(width: viewport.size.width, height: viewport.size.height)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Hooks 插槽状态页面")
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

    private func hookTile(_ hook: LanDisplaySnapshot.Hook, compact: Bool, minimumHeight: CGFloat) -> some View {
        let tight = compact && minimumHeight < 49
        let inset: CGFloat = compact ? (tight ? 4 : 9) : 13
        return VStack(alignment: .leading, spacing: compact ? (tight ? 2 : 4) : 9) {
            if compact {
                Text("\(hook.slot) · \(agentDisplayName(hook.agent))").font(.system(size: tight ? 9 : 10, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.7)
            } else {
                HStack(spacing: 3) {
                    Text("槽位 \(hook.slot)").font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text(agentDisplayName(hook.agent)).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
            }
            HStack(spacing: 4) {
                Circle().fill(behaviorColor(hook.behavior)).frame(width: compact ? 4 : 6, height: compact ? 4 : 6)
                Text(hook.behavior.label).font(compact ? .system(size: tight ? 11 : 12, weight: .semibold) : .title3.weight(.semibold))
                    .lineLimit(1).minimumScaleFactor(0.75)
            }.foregroundStyle(behaviorColor(hook.behavior))
        }
        .frame(maxWidth: .infinity, minHeight: max(0, minimumHeight - inset * 2), alignment: .leading)
        .watchPanel(panel, highlighted: updateGlow && allowsMotion, padding: inset)
        .privacySensitive()
        .animation(allowsMotion ? .easeOut(duration: 0.2) : nil, value: hook.behavior)
    }

    /// 正文与图片移入详情，不挤占小屏上的插槽状态。
    private func hookDetail(_ hook: LanDisplaySnapshot.Hook) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(agentDisplayName(hook.agent)).font(.headline)
                Text(hook.behavior.label).font(.title3.weight(.semibold)).foregroundStyle(behaviorColor(hook.behavior))
                if !hook.content.isEmpty {
                    Text(hook.content).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                if hook.contentTruncated { Text("正文已截断").font(.caption2).foregroundStyle(.secondary) }
                if let hash = hook.image {
                    if let image = model.state.images[hash] {
                        Image(decorative: image, scale: 1).resizable().scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        Label("图片未缓存", systemImage: "photo").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if model.state.summaryOnly {
                    Text("HTTP 直连提供用量、账户额度与插槽状态；正文和图片需通过 iPhone 同步。")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if hook.content.isEmpty && hook.image == nil {
                    Text("暂无正文或图片").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.bottom, 12)
        }
        .navigationTitle("槽位 \(hook.slot)")
        .privacySensitive()
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
            if showHooks {
                Picker("Hooks 布局", selection: $hookLayout) {
                    Text("1×1 · 每屏 1 张").tag(HookLayout.single.rawValue)
                    Text("2×2 · 每屏 4 张").tag(HookLayout.four.rawValue)
                }.accessibilityIdentifier("watch-hooks-layout")
            }
            if showUsage && showHooks {
                Text("首次显示 Token 总量，左滑看额度，右滑看 Hooks；自动记住上次查看的页面。")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if visiblePages.count > 1 {
                Text("左右滑动切换卡片，自动记住上次查看的页面。")
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
