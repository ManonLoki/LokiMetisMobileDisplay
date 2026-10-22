import SwiftUI
import WatchKit

/// Watch应用固定持有一个手机配套owner，分页切换不重建前台代次。
@main
struct LokiMetrisWatchApp: App {
    @Environment(\.scenePhase) private var phase
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    @StateObject private var model = WatchLinkModel.shared
    var body: some Scene {
        WindowGroup {
            // Frontmost inactive默认冻结UI；按系统低频节奏重绘已收到的缓存。
            // Timeline只请求显示更新，不承担网络唤醒或后台保活。
            TimelineView(.everyMinute) { _ in WatchRootView(model: model) }
        }
            .onChange(of: phase, initial: true) { _, value in
                // Always On/frontmost是inactive，仍保留展示与同步资格。
                model.setActive(value != .background)
                if value == .active { model.resume() }
                if value == .background { WatchAppDelegate.scheduleRefresh() }
            }
    }
}

/// 主线程薄模型仅发布最新视图，所有协议和私有文件工作留在串行owner。
@MainActor
final class WatchLinkModel: ObservableObject {
    static let shared = WatchLinkModel()
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
    /// 抬腕或回到前台时立即向手机要一次最新缓存。
    func resume() { engine?.resume() }
    /// 系统后台刷新窗口：先读手机缓存，不可达再走 HTTP 后备。
    func refreshInBackground(completion: @escaping () -> Void) { engine?.refreshInBackground(completion: completion) }
    /// 系统为配套通道唤醒时，处理完待收的应用上下文再结束任务。
    func processBackgroundConnectivity(completion: @escaping () -> Void) { engine?.processBackgroundConnectivity(completion: completion) }
}

/// 只在系统分配的执行窗口刷新；不借用音频、运动或扩展运行会话保活。
@MainActor
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    /// 启动即创建唯一引擎并申请第一次后台刷新。
    func applicationDidFinishLaunching() {
        _ = WatchLinkModel.shared
        Self.scheduleRefresh()
    }

    /// 申请约 5 分钟后的后台刷新；系统可按电量与使用习惯推迟。
    static func scheduleRefresh() {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(WatchRefreshPolicy.interval), userInfo: nil
        ) { error in
            if error != nil { NSLog("Watch background refresh scheduling deferred") }
        }
    }

    /// 逐个完成系统交来的后台任务，每个任务都必须调用完成回调，否则会被系统扣减预算。
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            switch task {
            case let refresh as WKApplicationRefreshBackgroundTask:
                Self.scheduleRefresh()
                WatchLinkModel.shared.refreshInBackground {
                    Task { @MainActor in refresh.setTaskCompletedWithSnapshot(true) }
                }
            case let connectivity as WKWatchConnectivityRefreshBackgroundTask:
                WatchLinkModel.shared.processBackgroundConnectivity {
                    Task { @MainActor in connectivity.setTaskCompletedWithSnapshot(true) }
                }
            case let snapshot as WKSnapshotRefreshBackgroundTask:
                snapshot.setTaskCompleted(restoredDefaultState: true,
                    estimatedSnapshotExpiration: Date().addingTimeInterval(WatchRefreshPolicy.interval), userInfo: nil)
            default:
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}

/// Hooks、Token、额度从左到右独立分页；首次显示Token，以语义ID记住上次页面。
@MainActor
private struct WatchRootView: View {
    private enum Page: String, Hashable, CaseIterable { case hooks, tokens, quota }
    private let panel = Color(red: 17 / 255, green: 29 / 255, blue: 45 / 255)
    private let accent = Color(red: 103 / 255, green: 232 / 255, blue: 249 / 255)
    private let violet = Color(red: 174 / 255, green: 140 / 255, blue: 255 / 255)
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var reducedLuminance
    @ObservedObject var model: WatchLinkModel
    @State private var entered = false
    @State private var updateGlow = false
    @State private var glowRevision = 0
    @State private var visibleHookSlot: Int?
    @AppStorage("watch.panel.selectedPage") private var selectedPage = Page.tokens.rawValue

    private var allowsMotion: Bool {
        phase == .active && !reduceMotion && !reducedLuminance
    }

    var body: some View {
        GeometryReader { pageArea in
            TabView(selection: $selectedPage) {
                hooksPage(size: pageArea.size).tag(Page.hooks.rawValue)
                tokensPage.tag(Page.tokens.rawValue)
                quotaPage.tag(Page.quota.rawValue)
            }
            .frame(width: pageArea.size.width, height: pageArea.size.height)
            .tabViewStyle(.page(indexDisplayMode: .never))
            .accessibilityIdentifier("watch-pages")
            .overlay(alignment: .bottom) {
                HStack(spacing: 5) {
                    ForEach(Page.allCases, id: \.rawValue) { page in
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
        .ignoresSafeArea(.container, edges: .bottom)
        .opacity(entered || !allowsMotion ? 1 : 0.5)
        .scaleEffect(entered || !allowsMotion ? 1 : 0.98, anchor: .top)
        .background(Color.black)
        .tint(accent)
        .onAppear {
            if Page(rawValue: selectedPage) == nil { selectedPage = Page.tokens.rawValue }
        }
        .onChange(of: model.state.envelope?.snapshot.hooks.map(\.slot), initial: true) { _, slots in
            guard let slots, !slots.isEmpty else { visibleHookSlot = nil; return }
            // 初始位置交给滚动容器报告，避免恢复 Hooks 页时程序定位覆盖系统安全区。
            if let slot = visibleHookSlot, !slots.contains(slot) { visibleHookSlot = nil }
        }
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

    /// 息屏、减弱动态效果或离开前台时，无动画地直接回到静止终态。
    private func stopMotion() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { entered = true; updateGlow = false }
        glowRevision += 1
    }

    private var tokensPage: some View {
        ScrollView {
            Group {
                if let envelope = model.state.envelope {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("Token 总量", systemImage: "number")
                            .font(.caption.weight(.medium)).foregroundStyle(accent)
                        if let tokens = envelope.snapshot.displayTokens {
                            tokenTotal(tokens.all)
                            Text(tokens.day.date).font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Text(envelope.snapshot.tokenError == nil ? "Token 尚未同步" : "Token 暂不可用")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("在 iPhone 中连接桌面后自动同步")
                                .font(.caption2).foregroundStyle(.secondary)
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
            .padding(.bottom, 22)
        }
        .accessibilityLabel("Token 总量页面")
    }

    private var quotaPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let quota = model.state.envelope?.snapshot.displayProviderQuota, !quota.providers.isEmpty {
                    WatchProviderQuotaContent(quota: quota)
                        .watchPanel(panel, highlighted: updateGlow && allowsMotion)
                        .accessibilityIdentifier("watch-quota-card")
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("等待额度数据").font(.headline)
                        Text("在 iPhone 中连接桌面后自动同步")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .watchPanel(panel)
                    .accessibilityIdentifier("watch-quota-waiting")
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 22)
        }
        .accessibilityLabel("账户剩余额度页面")
    }

    /// 每屏固定一张活动卡；沿用外层页尺寸，避免Watch分页压缩内层测量高度。
    /// 上下滚动吸附切换，左右手势留给主页面；底部只为分页圆点留空。
    private func hooksPage(size: CGSize) -> some View {
        let width = max(0, size.width - 8)
        let bottomInset: CGFloat = 14
        let height = max(0, size.height - bottomInset)
        return ScrollView(.vertical) {
            if let snapshot = model.state.envelope?.snapshot {
                if !snapshot.hooksAvailable {
                    hookPlaceholder("暂不可用")
                } else if snapshot.hooks.isEmpty {
                    hookPlaceholder("暂无活动")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(snapshot.hooks.sorted(by: { $0.slot < $1.slot }), id: \.slot) { hook in
                            hookTile(hook, height: height)
                                .id(hook.slot)
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
        // 按活动卡自身对齐；系统安全区会使滚动视口与固定卡高不同，按视口分页会逐页偏移。
        .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
        .scrollPosition(id: $visibleHookSlot)
        .scrollIndicators(.hidden)
        .contentMargins(.vertical, 0, for: .scrollContent)
        .frame(width: width, height: height)
        .clipped()
        .padding(.horizontal, 4)
        .padding(.bottom, bottomInset)
        .accessibilityLabel("活动状态页面")
    }

    private var waitingPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "iphone").font(.title2).foregroundStyle(accent)
            Text("等待 iPhone 同步").font(.headline)
            Text("在 iPhone 中连接桌面后自动同步")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .watchPanel(panel)
        .accessibilityIdentifier("watch-waiting")
    }

    /// Hooks 不可用或为空时的占位卡片。
    private func hookPlaceholder(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption)
            Text("在 iPhone 中连接桌面后自动同步").font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading).watchPanel(panel)
    }

    /// 大字便于扫读，小字保留完整整数；两者均来自同一精确值。
    private func tokenTotal(_ value: WidgetAmount) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value.compactText)
                .font(.system(size: 31, weight: .semibold, design: .monospaced))
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
        .accessibilityLabel("总 Token，\(value.text)\(value.quality.isEmpty ? "" : "，" + value.quality)")
        .privacySensitive()
    }

    /// 单张活动卡：顶部一行显示 Agent 与状态，其余空间留给图片。
    private func hookTile(_ hook: LanDisplaySnapshot.Hook, height: CGFloat) -> some View {
        let inset: CGFloat = 9
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 6) {
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

    /// 只有当前可见页、当前卡片且允许动效时才播放动图，其余情况停在当前帧不唤醒。
    private func hookImage(_ hook: LanDisplaySnapshot.Hook) -> some View {
        let image = hook.image.flatMap { model.state.images[$0] }
        let placeholder = hook.image == nil ? "暂无图片" : "图片未缓存"
        let visibleSlot = visibleHookSlot ?? model.state.envelope?.snapshot.hooks.map(\.slot).min()
        return GeometryReader { area in
            Group {
                if let image {
                    HookAssetImage(asset: image, playbackEnabled: selectedPage == Page.hooks.rawValue && allowsMotion && hook.slot == visibleSlot)
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

    /// 活动状态到颜色的固定映射。
    private func behaviorColor(_ behavior: WidgetHook.Behavior) -> Color {
        switch behavior {
        case .running: return accent
        case .asking: return violet
        case .error: return .orange
        case .idle: return .white.opacity(0.7)
        }
    }

}

private extension View {
    /// 统一的 Watch 卡片外观；`highlighted` 为 true 时边框短暂高亮提示有更新。
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
