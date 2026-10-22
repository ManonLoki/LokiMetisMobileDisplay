import SwiftUI
import SharedLogic

/// SwiftUI 的名称与标识适配；选项集合及持久化键由共享枚举提供。
struct UsageDetail: Equatable, CaseIterable, Identifiable {
    let shared: SharedLogic.UsageDetail
    static var compact: UsageDetail { UsageDetail(shared: .compact) }
    static var detailed: UsageDetail { UsageDetail(shared: .detailed) }
    static var allCases: [UsageDetail] { SharedLogic.UsageDetail.entries.map { UsageDetail(shared: $0) } }
    var rawValue: String { shared.key }
    var id: String { shared.key }
    var title: String { self == .compact ? "精简" : "详细" }
}

/// SwiftUI 仅适配整数与空槽表示，列数、每页数量和来源位置均调用共享布局。
struct HookLayout: Equatable, CaseIterable, Identifiable {
    let shared: SharedLogic.HookLayout
    static var single: HookLayout { HookLayout(shared: .single) }
    static var grid: HookLayout { HookLayout(shared: .grid) }
    static var allCases: [HookLayout] { SharedLogic.HookLayout.entries.map { HookLayout(shared: $0) } }
    var rawValue: String { shared.key }
    var id: String { shared.key }
    var title: String { self == .single ? "1×1" : "2×2" }
    var columns: Int { Int(shared.columns) }
    var pageSize: Int { Int(shared.pageSize) }

    func pageCount(itemCount: Int) -> Int {
        Int(shared.pageCount(itemCount: Int32(clamping: itemCount)))
    }

    func itemIndex(itemCount: Int, page: Int, cell: Int) -> Int? {
        let index = shared.itemIndex(itemCount: Int32(clamping: itemCount), page: Int32(clamping: page), cell: Int32(clamping: cell))
        return index >= 0 ? Int(index) : nil
    }
}

/// 面板偏好只影响本机显示，不改变发现、连接或桌面快照。
struct PanelPreferencesView: View {
    @Binding var showUsage: Bool
    @Binding var showHooks: Bool
    @Binding var usageDetail: String
    @Binding var hookLayout: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var configuration: PanelConfiguration {
        PanelConfiguration.companion.restore(showUsage: showUsage, showHooks: showHooks,
                                             detail: usageDetail, hookLayout: hookLayout)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("选择显示内容，调整每页布局。更改立即生效。")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                usageSettings
                hookSettings
                SettingsCard {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "rectangle.split.2x1")
                            .font(.body).foregroundStyle(.secondary).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("随屏幕自动布局").font(.subheadline.weight(.medium))
                            Text("竖屏上下各半，横屏左右各半。只开启一项时铺满内容区。")
                                .font(.footnote).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: 640)
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .background(DisplayStyle.canvas)
        .navigationTitle("自定义面板").navigationBarTitleDisplayMode(.inline)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: showUsage)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: showHooks)
    }

    private var usageSettings: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 18) {
                Toggle(isOn: $showUsage) {
                    SettingsLabel(title: "Token 用量", subtitle: "掌握当前用量", symbol: "chart.bar.xaxis")
                }
                .tint(DisplayStyle.accent)
                .accessibilityIdentifier("panel-show-usage")
                if showUsage {
                    Divider().overlay(Color.white.opacity(0.04))
                    Text("用量详情").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("panel-usage-detail")
                    choices {
                        ForEach(UsageDetail.allCases) { detail in
                            PanelChoiceTile(title: detail.title,
                                            subtitle: detail == .compact ? "仅显示总用量" : "总用量与 Agent 明细",
                                            selected: configuration.usageDetail == detail.shared,
                                            accessibilityLabel: "Token 用量，" + detail.title,
                                            action: { usageDetail = detail.rawValue }) {
                                usagePreview(detail)
                            }
                            .accessibilityIdentifier("panel-usage-detail-" + detail.rawValue)
                        }
                    }
                }
            }
        }
    }

    private var hookSettings: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 18) {
                Toggle(isOn: $showHooks) {
                    SettingsLabel(title: "Hooks", subtitle: "展示 Agent 动态与图片", symbol: "square.stack.3d.up")
                }
                .tint(DisplayStyle.accent)
                .accessibilityIdentifier("panel-show-hooks")
                if showHooks {
                    Divider().overlay(Color.white.opacity(0.04))
                    Text("每页卡片").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("panel-hook-layout")
                    choices {
                        ForEach(HookLayout.allCases) { layout in
                            PanelChoiceTile(title: layout.title,
                                            subtitle: layout == .single ? "每页一张，聚焦内容" : "每页四张，一览动态",
                                            selected: configuration.hookLayout == layout.shared,
                                            accessibilityLabel: "Hooks 布局，" + layout.title + (layout == .single ? "，每页一张" : "，每页四张"),
                                            action: { hookLayout = layout.rawValue }) {
                                hookPreview(layout)
                            }
                            .accessibilityIdentifier("panel-hook-layout-" + layout.rawValue)
                        }
                    }
                    Text("左右滑动面板可查看更多。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func choices<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 12, content: content)
        } else {
            HStack(alignment: .top, spacing: 12, content: content)
        }
    }

    /// 用量卡片样式的缩略预览。
    private func usagePreview(_ detail: UsageDetail) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Capsule().fill(Color.white.opacity(0.22)).frame(width: 30, height: 4)
            Capsule().fill(DisplayStyle.accent.opacity(0.7)).frame(width: detail == .compact ? 64 : 50, height: detail == .compact ? 15 : 11)
            if detail == .detailed {
                ForEach(0..<2) { index in
                    HStack(spacing: 7) {
                        Circle().fill(Color.white.opacity(0.24)).frame(width: 4, height: 4)
                        Capsule().fill(Color.white.opacity(0.16)).frame(width: index == 0 ? 42 : 32, height: 4)
                        Spacer(minLength: 0)
                        Capsule().fill(Color.white.opacity(0.26)).frame(width: 18, height: 4)
                    }
                }
            } else {
                Capsule().fill(Color.white.opacity(0.14)).frame(width: 44, height: 4)
            }
            Spacer(minLength: 0)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading).frame(height: 82)
        .background(DisplayStyle.canvas.opacity(0.85), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityHidden(true)
    }

    /// Hooks 布局的缩略预览。
    private func hookPreview(_ layout: HookLayout) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: layout.columns), spacing: 5) {
            ForEach(0..<layout.pageSize, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 5)
                    .fill(DisplayStyle.accent.opacity(0.09))
                    .overlay {
                        Image(systemName: "photo")
                            .font(.system(size: layout == .single ? 21 : 12, weight: .regular))
                            .foregroundStyle(DisplayStyle.accent.opacity(0.55))
                    }
                    .frame(height: layout == .single ? 62 : 28.5)
            }
        }
        .padding(10).frame(height: 82)
        .background(DisplayStyle.canvas.opacity(0.85), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityHidden(true)
    }
}

private struct PanelChoiceTile<Preview: View>: View {
    let title: String
    let subtitle: String
    let selected: Bool
    let accessibilityLabel: String
    let action: () -> Void
    @ViewBuilder let preview: Preview

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                preview
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.body).foregroundStyle(selected ? DisplayStyle.accent : Color.secondary.opacity(0.6))
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 32, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(selected ? DisplayStyle.accent.opacity(0.07) : Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(selected ? DisplayStyle.accent.opacity(0.7) : Color.white.opacity(0.08), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(CyberPressStyle()).foregroundStyle(.primary)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 设置页通用卡片，视觉层级比实时展示台更克制。
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(DisplayStyle.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20).strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
            }
    }
}

struct SettingsLabel: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SettingsIconTile(symbol: symbol)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SettingsIconTile: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(DisplayStyle.accent.opacity(0.9))
            .frame(width: 42, height: 42)
            .background(DisplayStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
    }
}
