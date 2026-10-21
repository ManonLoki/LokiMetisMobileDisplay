import SwiftUI

/// Shared visual tokens stay in the app target; extensions use their own native palette.
enum DisplayStyle {
    static let accent = Color(red: 103 / 255, green: 232 / 255, blue: 249 / 255)
    static let violet = Color(red: 174 / 255, green: 140 / 255, blue: 255 / 255)
    static let amber = Color(red: 0.98, green: 0.76, blue: 0.40)
    static let canvas = Color(red: 8 / 255, green: 13 / 255, blue: 23 / 255)
    static let graphite = Color(red: 12 / 255, green: 21 / 255, blue: 35 / 255)
    static let surface = Color(red: 17 / 255, green: 29 / 255, blue: 45 / 255)
}

/// Only accepted snapshots supply numbers and activity. Offline facts remain labeled as cache.
struct LanDisplayPage: View {
    let state: LanLinkView
    let snapshot: LanDisplaySnapshot?
    var widgetSharingError = false
    var showUsage = true
    var showHooks = true
    var usageDetail: UsageDetail = .compact
    var hookLayout: HookLayout = .single
    var openSettings: () -> Void = {}
    var refreshSnapshot: () -> Void = {}
    var motionEnabled = true
    @State private var preview: HookPreview?
    @State private var selectedHookPage = 0

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 16) {
                if !showUsage && !showHooks {
                    ScrollView { emptyPanel }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .cyberEntrance(delay: 0.06)
                } else if snapshot == nil {
                    ScrollView { firstConnection }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .cyberEntrance(delay: 0.06)
                } else {
                    splitPanels(horizontal: geometry.size.width > geometry.size.height)
                }
                if widgetSharingError {
                    Label("小组件同步暂不可用", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background { CyberBackdrop() }
        .environment(\.cyberMotionEnabled, motionEnabled && preview == nil)
        .onChange(of: state.connected) { _, connected in
            if !connected { preview = nil; selectedHookPage = 0 }
        }
        .onChange(of: state.selectedId) { _, _ in preview = nil; selectedHookPage = 0 }
        .onChange(of: snapshot) { _, value in
            if let shown = preview, value?.hooks.contains(shown.hook) != true { preview = nil }
        }
        .sheet(item: $preview) { item in
            NavigationStack {
                GeometryReader { geometry in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            hookStatus(item.hook)
                            if !item.hook.content.isEmpty {
                                Text(item.hook.content).font(.body).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if item.hook.contentTruncated {
                                Text("正文已截断").font(.caption).foregroundStyle(.secondary)
                            }
                            if let asset = item.hook.image.flatMap({ state.images[$0] }) ?? item.asset {
                                HookAssetImage(asset: asset)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: max(160, geometry.size.height - (item.hook.content.isEmpty ? 100 : 220)))
                            } else {
                                Label(item.hook.image == nil ? "暂无图片" : "图片未缓存", systemImage: "photo")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .background(DisplayStyle.canvas).privacySensitive()
                .navigationTitle(agentDisplayName(item.hook.agent)).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { preview = nil } } }
            }.tint(DisplayStyle.accent)
                .environment(\.cyberMotionEnabled, motionEnabled)
        }
    }

    private func splitPanels(horizontal: Bool) -> some View {
        GeometryReader { geometry in
            let count = showUsage && showHooks ? 2 : 1
            let gap = CGFloat(count - 1) * 12
            let size = CGSize(width: max(1, horizontal ? (geometry.size.width - gap) / CGFloat(count) : geometry.size.width),
                              height: max(1, horizontal ? geometry.size.height : (geometry.size.height - gap) / CGFloat(count)))
            let layout = horizontal ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 12))
            layout {
                if showUsage {
                    UsagePanelCard(tokens: snapshot?.tokens, hasError: snapshot?.tokenError != nil,
                                   detail: usageDetail, quota: snapshot?.providerQuota,
                                   canRefresh: state.canQuerySnapshot && state.connected, onRefresh: refreshSnapshot)
                        .frame(width: size.width, height: size.height)
                        .accessibilityIdentifier("panel-usage-card")
                        .cyberEntrance(delay: 0.05)
                }
                if showHooks {
                    hooksPane(size: size)
                        .frame(width: size.width, height: size.height)
                        .accessibilityIdentifier("panel-hooks-card")
                        .cyberEntrance(delay: 0.1)
                }
            }
        }.accessibilityIdentifier("panel-split")
    }

    private func hooksPane(size: CGSize) -> some View {
        let hooks = snapshot?.hooks.sorted(by: { $0.slot < $1.slot }) ?? []
        let warning = state.assetWarning ?? (snapshot?.catalogError != nil ? "图片配置暂不可用" : nil)
        let pageCount = snapshot?.hooksAvailable == true ? max(1, (hooks.count + hookLayout.pageSize - 1) / hookLayout.pageSize) : 1
        return VStack(spacing: 8) {
            GeometryReader { content in
                if snapshot?.hooksAvailable != true {
                    hookPlaceholder("Hooks 暂不可用").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if pageCount == 1 {
                    hookPage(hooks, page: 0, size: content.size)
                } else {
                    TabView(selection: $selectedHookPage) {
                        ForEach(0..<pageCount, id: \.self) { page in
                            hookPage(hooks, page: page, size: content.size)
                                .environment(\.cyberMotionEnabled, motionEnabled && preview == nil && selectedHookPage == page)
                                .tag(page)
                        }
                    }.tabViewStyle(.page(indexDisplayMode: .never))
                        .frame(width: content.size.width, height: content.size.height)
                }
            }
            if pageCount > 1 {
                HStack(spacing: 16) {
                    Button { selectedHookPage = (selectedHookPage + pageCount - 1) % pageCount } label: {
                        Image(systemName: "chevron.left").frame(width: 44, height: 32)
                    }.accessibilityLabel("上一页活动")
                    Text("\(selectedHookPage + 1) / \(pageCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityIdentifier("panel-hook-page")
                    Button { selectedHookPage = (selectedHookPage + 1) % pageCount } label: {
                        Image(systemName: "chevron.right").frame(width: 44, height: 32)
                    }.accessibilityLabel("下一页活动")
                }.buttonStyle(.plain).fixedSize(horizontal: false, vertical: true)
            }
            if let warning {
                ScrollView {
                    Text(warning).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 64)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .onChange(of: hookLayout) { _, _ in selectedHookPage = 0 }
        .onChange(of: pageCount, initial: true) { _, count in
            selectedHookPage = min(selectedHookPage, count - 1)
        }
    }

    private func hookPage(_ hooks: [LanDisplaySnapshot.Hook], page: Int, size: CGSize) -> some View {
        let columns = hookLayout.columns
        let gap: CGFloat = columns == 2 ? 8 : 0
        let cell = CGSize(width: max(1, (size.width - gap) / CGFloat(columns)),
                          height: max(1, (size.height - gap) / CGFloat(columns)))
        return VStack(spacing: gap) {
            ForEach(0..<columns, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<columns, id: \.self) { column in
                        let index = page * hookLayout.pageSize + row * columns + column
                        if index < hooks.count {
                            let hook = hooks[index]
                            HookPanelTile(hook: hook, asset: hook.image.flatMap { state.images[$0] },
                                          connected: state.connected, grid: hookLayout == .grid,
                                          statusColor: behaviorColor(hook.behavior)) {
                                preview = HookPreview(hook: hook, asset: hook.image.flatMap { state.images[$0] })
                            }
                            .id(hook.slot).frame(width: cell.width, height: cell.height)
                        } else {
                            hookPlaceholder(hooks.isEmpty ? "暂无活动" : "空闲")
                                .frame(width: cell.width, height: cell.height)
                                .accessibilityIdentifier("panel-hook-empty-\(row * columns + column)")
                        }
                    }
                }
            }
        }.frame(width: size.width, height: size.height)
    }

    private func hookPlaceholder(_ title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "tray").accessibilityHidden(true)
            Text(title).font(.caption)
        }.foregroundStyle(.secondary).padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .cyberSurface(tint: DisplayStyle.violet)
    }

    private func hookStatus(_ hook: LanDisplaySnapshot.Hook) -> some View {
        Text(hook.behavior.label).font(.caption.weight(.medium))
            .foregroundStyle(behaviorColor(hook.behavior))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(behaviorColor(hook.behavior).opacity(0.09), in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }

    private var emptyPanel: some View {
        ContentUnavailableView {
            Label("添加你的内容", systemImage: "square.grid.2x2")
        } actions: { Button("前往设置", action: openSettings).buttonStyle(.borderedProminent) }
            .frame(minHeight: 300)
    }

    private var firstConnection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "desktopcomputer").font(.system(size: 34, weight: .light)).foregroundStyle(.white.opacity(0.8))
            VStack(alignment: .leading, spacing: 8) {
                Text(state.pairingCode != nil ? "完成桌面配对" : "连接你的桌面").font(.title2.weight(.semibold))
                Text(state.pairingCode != nil ? "在桌面输入手机上的配对码。" : "同一 Wi-Fi，配对后同步用量与 Hooks。")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.7))
            }
            Button(state.pairingCode != nil ? "查看配对码" : "连接桌面", action: openSettings)
                .font(.subheadline.weight(.semibold)).buttonStyle(.borderedProminent)
                .tint(DisplayStyle.accent).foregroundStyle(DisplayStyle.canvas)
                .accessibilityIdentifier("display-open-settings")
        }.padding(26).frame(maxWidth: .infinity, minHeight: 250, alignment: .leading)
            .foregroundStyle(.white).cyberSurface(sweeping: true)
    }

    private func behaviorColor(_ behavior: WidgetHook.Behavior) -> Color {
        switch behavior { case .running: return DisplayStyle.accent; case .asking: return DisplayStyle.amber; case .error: return .red; case .idle: return .secondary }
    }
}

private struct HookPreview: Identifiable {
    let hook: LanDisplaySnapshot.Hook
    let asset: LanImageAsset?
    var id: Int { hook.slot }
}

/// The header is measured at its real text size; the image receives the tile's remaining viewport.
private struct HookPanelTile: View {
    let hook: LanDisplaySnapshot.Hook
    let asset: LanImageAsset?
    let connected: Bool
    let grid: Bool
    let statusColor: Color
    let openDetails: () -> Void
    @State private var headerHeight: CGFloat = 24

    var body: some View {
        GeometryReader { geometry in
            let padding: CGFloat = grid ? 9 : 16
            let gap: CGFloat = grid ? 6 : 10
            let width = max(1, geometry.size.width - padding * 2)
            let available = geometry.size.height - padding * 2 - headerHeight - gap
            // Only extremely short/a11y cards overflow; their image stays reachable by scrolling.
            let imageHeight = max(min(44, width), available)
            ScrollView {
                Button(action: openDetails) {
                    VStack(spacing: gap) {
                        header
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                        imageContent.frame(width: width, height: imageHeight)
                            .clipped()
                    }.padding(padding)
                }.buttonStyle(CyberPressStyle())
                    .accessibilityLabel("\(agentDisplayName(hook.agent))，\(hook.behavior.label)，查看活动详情")
            }.scrollIndicators(.visible)
        }
        .cyberSurface(tint: DisplayStyle.violet)
        .accessibilityIdentifier("panel-hook-card-\(hook.slot)")
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                title.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                status.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 4) {
                title.lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                status
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: some View {
        Text(agentDisplayName(hook.agent)).font(grid ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
            .foregroundStyle(.primary)
    }

    private var status: some View {
        Text(hook.behavior.label).font(.caption2.weight(.medium)).foregroundStyle(statusColor)
    }

    @ViewBuilder private var imageContent: some View {
        if let asset {
            HookAssetImage(asset: asset).frame(maxWidth: .infinity, maxHeight: .infinity)
                .privacySensitive()
        } else {
            VStack(spacing: 6) {
                Image(systemName: "photo").accessibilityHidden(true)
                Text(hook.image == nil ? (hook.content.isEmpty ? "暂无图片" : "查看活动内容") : connected ? "图片同步中" : "图片未缓存")
                    .font(.caption2).multilineTextAlignment(.center)
            }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct UsagePanelCard: View {
    let tokens: WidgetTokens?
    let hasError: Bool
    let detail: UsageDetail
    var quota: ProviderQuotaSnapshot? = nil
    var canRefresh = false
    var onRefresh: () -> Void = {}
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cyberMotionEnabled) private var motionEnabled
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .largeTitle) private var numberScale = 1.0
    @ScaledMetric(relativeTo: .body) private var rowScale = 1.0
    @ScaledMetric(relativeTo: .caption2) private var exactLineHeight = 16.0
    @State private var headerHeight: CGFloat = 16

    var body: some View {
        GeometryReader { card in
            let padding: CGFloat = detail == .detailed || card.size.width < 280 || card.size.height < 220 ? 12 : 20
            let hasQuota = quota?.providers.isEmpty == false
            let availableHeight = max(0, card.size.height - padding * 2 - headerHeight - 10)
            let size = CGSize(width: max(1, card.size.width - padding * 2),
                              height: hasQuota ? max(72, min(180, availableHeight * 0.42)) : availableHeight)
            ScrollView {
                VStack(spacing: detail == .detailed ? 6 : 10) {
                    header.fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                    VStack(spacing: rowSpacing(size)) {
                        if let tokens {
                            summary(tokens, size: size)
                        } else {
                            Text("—").font(.system(size: numberSize(size), weight: .medium, design: .rounded))
                                .foregroundStyle(DisplayStyle.accent)
                            Text(hasError ? "Token 暂不可用" : hasQuota ? "Token 尚未同步" : "等待同步")
                                .font(.caption).foregroundStyle(.white.opacity(0.65))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    // 明细紧跟总量，不为主数字预留整块空白挤走Agent行。
                    .frame(minHeight: detail == .compact ? size.height : 0,
                           alignment: detail == .compact ? .center : .top)
                    if detail == .detailed, let tokens {
                        agents(tokens, size: size)
                    } else if let quota, !quota.providers.isEmpty {
                        Divider().overlay(.white.opacity(0.12))
                        ProviderQuotaRows(quota: quota, detailed: detail == .detailed, contentWidth: size.width)
                    }
                }.padding(padding)
            }.scrollIndicators(.visible)
        }
        .foregroundStyle(.white)
        .cyberSurface(sweeping: true)
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Text("Token 用量").font(.caption.weight(.medium)).fixedSize()
                if canRefresh { Button("刷新", action: onRefresh).font(.caption).accessibilityIdentifier("quota-refresh") }
                Spacer(minLength: 8)
                if let tokens { Text(tokens.day.date).font(.caption2.monospacedDigit()).fixedSize() }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Token 用量").font(.caption.weight(.medium))
                if canRefresh { Button("刷新", action: onRefresh).font(.caption).accessibilityIdentifier("quota-refresh") }
                if let tokens { Text(tokens.day.date).font(.caption2.monospacedDigit()) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.foregroundStyle(.white.opacity(0.6))
    }

    private func rowSpacing(_ size: CGSize) -> CGFloat {
        min(20, max(8, size.height * 0.035))
    }

    private func numberSize(_ size: CGSize) -> CGFloat {
        let compact = detail == .compact
        let widthLimit = size.width * (compact ? 0.22 : 0.14)
        let heightLimit = size.height * (compact ? 0.45 : 0.20)
        let base = min(compact ? 160.0 : 44.0, max(compact ? 34.0 : 26.0, min(widthLimit, heightLimit)))
        return base * numberScale
    }

    private func summary(_ tokens: WidgetTokens, size: CGSize) -> some View {
        VStack(spacing: detail == .detailed ? 2 : 5) {
            if dynamicType.isAccessibilitySize {
                ScrollView(.horizontal) {
                    total(tokens, size: size).fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: size.width)
                }.scrollIndicators(.visible).frame(height: numberSize(size) * 1.3)
            } else {
                total(tokens, size: size).lineLimit(1).minimumScaleFactor(0.3)
                    .frame(maxWidth: .infinity)
            }
            amountNote(tokens.all, centered: true)
        }.frame(maxWidth: .infinity)
    }

    private func agents(_ tokens: WidgetTokens, size: CGSize) -> some View {
        let spacing: CGFloat = dynamicType.isAccessibilitySize ? 8 : 6
        let columns = Array(repeating: GridItem(.flexible(), spacing: 24, alignment: .topLeading),
                            count: size.width >= 600 && dynamicType < .xxxLarge ? 2 : 1)
        let rows = tokens.displayRows(quota: quota)
        let rowWidth = (size.width - CGFloat(columns.count - 1) * 24) / CGFloat(columns.count)
        return VStack(alignment: .leading, spacing: spacing) {
            Divider().overlay(.white.opacity(0.12))
            HStack(alignment: .top, spacing: 8) {
                Text("设备时区").fixedSize(horizontal: true, vertical: false)
                GeometryReader { geometry in
                    ScrollView(.horizontal) {
                        Text(tokens.day.zone).fixedSize(horizontal: true, vertical: false)
                            .frame(minWidth: geometry.size.width, alignment: .trailing)
                    }.scrollIndicators(.visible)
                }.frame(height: exactLineHeight)
            }.font(.caption2).foregroundStyle(.white.opacity(0.5))
            if rows.isEmpty {
                Text("暂无明细").font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                ForEach(rows) { row in
                    if let tokenText = row.tokenText {
                        VStack(alignment: .leading, spacing: 2) {
                            GeometryReader { geometry in
                                ViewThatFits(in: .horizontal) {
                                    agentHeadline(row, tokenText: tokenText, size: size)
                                    ScrollView(.horizontal) {
                                        agentHeadline(row, tokenText: tokenText, size: size)
                                            .frame(minWidth: geometry.size.width)
                                    }.scrollIndicators(.visible)
                                }
                            }.frame(height: agentNumberSize(size) * 1.3)
                            if row.quotaEntry != nil || row.tokenAmount?.hasNumericValue == true {
                                agentDetailLine(row.tokenAmount, quota: row.quotaEntry)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    } else if let entry = row.quotaEntry {
                        ProviderQuotaEntryRow(provider: entry, detailed: true, contentWidth: rowWidth)
                    }
                }
            }
            if let quota, !quota.providers.isEmpty {
                quotaObservedTime(quota)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func agentHeadline(_ row: WidgetUsageRow, tokenText: String, size: CGSize) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            agentName(row.displayName, size: size).fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel(row.quotaEntry?.plan.map { "\(row.displayName)，\($0)" } ?? row.displayName)
            Spacer(minLength: 0)
            agentTotal(tokenText, size: size).fixedSize(horizontal: true, vertical: false)
        }
    }

    /// 先按真实文字宽度缩短细条；极窄和大字只横滚本行，不截断完整整数。
    private func agentDetailLine(_ amount: WidgetAmount?, quota: ProviderQuotaEntry?) -> some View {
        GeometryReader { geometry in
            ViewThatFits(in: .horizontal) {
                agentDetailContents(amount, quota: quota, barWidth: 44)
                agentDetailContents(amount, quota: quota, barWidth: 28)
                agentDetailContents(amount, quota: quota, barWidth: 18)
                ScrollView(.horizontal) {
                    agentDetailContents(amount, quota: quota, barWidth: 18)
                        .frame(minWidth: geometry.size.width)
                }.scrollIndicators(.visible)
            }
        }.frame(height: exactLineHeight)
    }

    private func agentDetailContents(_ amount: WidgetAmount?, quota: ProviderQuotaEntry?, barWidth: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 6) {
            if let quota { inlineQuota(quota, barWidth: barWidth) }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let amount, amount.hasNumericValue { exactText(amount) }
            }.fixedSize(horizontal: true, vertical: false)
        }
    }

    private func inlineQuota(_ entry: ProviderQuotaEntry, barWidth: CGFloat) -> some View {
        HStack(spacing: 6) {
            ForEach(entry.windows, id: \.kind) { window in
                HStack(spacing: 2) {
                    Text(window.label).foregroundStyle(.white.opacity(0.6))
                    Text(window.percentText).fontWeight(.semibold).monospacedDigit()
                    ProgressView(value: Double(window.remainingTenths), total: 1000)
                        .tint(window.level == 0 ? .red : window.level == 1 ? .yellow : .green)
                        .frame(width: barWidth).accessibilityHidden(true)
                }.font(.caption2).fixedSize(horizontal: true, vertical: false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(entry.label)\(window.label)剩余\(window.percentText)\(window.resetDate.map { "，" + $0.formatted(.dateTime.month().day().hour().minute()) + "重置" } ?? "")")
            }
        }
    }

    private func agentName(_ name: String, size: CGSize) -> some View {
        Text(name)
            .font(.system(size: min(24, max(16, size.width * 0.04)) * rowScale, weight: .bold))
            .foregroundStyle(.white.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
    }

    private func agentNumberSize(_ size: CGSize) -> CGFloat {
        min(26, max(16, size.width * 0.045)) * rowScale
    }

    private func agentTotal(_ tokenText: String, size: CGSize) -> some View {
        Text(TokenNumber.compact(tokenText))
            .font(.system(size: agentNumberSize(size), weight: .medium).monospacedDigit())
            .accessibilityLabel(tokenText)
    }

    @ViewBuilder private func amountNote(_ amount: WidgetAmount, centered: Bool = false) -> some View {
        if amount.hasNumericValue {
            ViewThatFits(in: .horizontal) {
                exactText(amount)
                VStack(alignment: centered ? .center : .trailing, spacing: 0) {
                    GeometryReader { geometry in
                        ScrollView(.horizontal) {
                            exactText(amount).frame(minWidth: geometry.size.width, alignment: centered ? .center : .trailing)
                        }.scrollIndicators(.visible)
                    }.frame(height: exactLineHeight)
                }
            }.frame(maxWidth: .infinity, alignment: centered ? .center : .trailing)
                .multilineTextAlignment(centered ? .center : .trailing)
        }
    }

    private func total(_ tokens: WidgetTokens, size: CGSize) -> some View {
        Text(tokens.all.compactText)
            .font(.system(size: numberSize(size), weight: .medium, design: .rounded).monospacedDigit())
            .tracking(-1).foregroundStyle(DisplayStyle.accent).textSelection(.enabled)
            .contentTransition(.numericText())
            .animation(reduceMotion || !motionEnabled || scenePhase != .active ? nil : .smooth(duration: 0.38), value: tokens.all.compactText)
            .accessibilityLabel("总 Token \(tokens.all.text)")
    }

    private func exactText(_ amount: WidgetAmount) -> some View {
        Text(amount.exactText + " Token").font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.65))
            .fixedSize(horizontal: true, vertical: false).textSelection(.enabled)
            .accessibilityLabel("完整用量 \(amount.text) Token")
    }
}


/// 额度独立于Token数值展示，缺失的窗口不生成占位；比例同时提供读屏文本。
private struct ProviderQuotaRows: View {
    let quota: ProviderQuotaSnapshot
    let detailed: Bool
    let contentWidth: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("账户剩余额度").font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.6))
            ForEach(quota.providers, id: \.provider) { provider in
                ProviderQuotaEntryRow(provider: provider, detailed: detailed, contentWidth: contentWidth)
            }
            quotaObservedTime(quota)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 同一额度行既可独立显示，也可加入按账户排序的 Token 明细网格。
private struct ProviderQuotaEntryRow: View {
    let provider: ProviderQuotaEntry
    let detailed: Bool
    let contentWidth: CGFloat
    @Environment(\.dynamicTypeSize) private var dynamicType
    @ScaledMetric(relativeTo: .caption2) private var minimumWindowWidth = 140.0

    var body: some View {
        let windows = provider.windows
        let columnCount = windows.count > 1 && !dynamicType.isAccessibilitySize
            && contentWidth >= minimumWindowWidth * 2 + 14 ? 2 : 1
        VStack(alignment: .leading, spacing: 6) {
            Text(provider.displayName).font(.caption.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .topLeading),
                                     count: columnCount), spacing: 8) {
                ForEach(windows, id: \.kind) { window in
                    row(window, label: window.label)
                }
            }
        }.accessibilityIdentifier("quota-\(provider.provider)")
    }

    private func row(_ window: ProviderQuotaWindow, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text(window.percentText).fontWeight(.semibold).monospacedDigit()
            }.font(.caption2)
            ProgressView(value: Double(window.remainingTenths), total: 1000)
                .tint(window.level == 0 ? .red : window.level == 1 ? .yellow : .green)
                .accessibilityLabel(label).accessibilityValue(window.percentText)
            if detailed, let reset = window.resetDate {
                Text("\(reset.formatted(.dateTime.month().day().hour().minute())) 重置")
                    .font(.caption2).foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private func quotaObservedTime(_ quota: ProviderQuotaSnapshot) -> some View {
    Text("额度更新 \(quota.observedDate.formatted(.dateTime.month().day().hour().minute()))")
        .font(.caption2).foregroundStyle(.white.opacity(0.5))
        .accessibilityLabel("额度更新于 \(quota.observedDate.formatted(.dateTime.year().month().day().hour().minute()))")
}
