import SwiftUI

/// 额度页只显示账户名称、独立套餐 Tag 与实际窗口余额。
struct WatchProviderQuotaContent: View {
    let quota: ProviderQuotaSnapshot
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(quota.providers, id: \.provider) { provider in
                VStack(alignment: .leading, spacing: 7) {
                    ProviderQuotaTitle(name: provider.label, plan: provider.planLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    let layout = dynamicType.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                        : AnyLayout(HStackLayout(spacing: 8))
                    layout {
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
}
