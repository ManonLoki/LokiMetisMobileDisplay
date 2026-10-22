import SwiftUI

/// 页面级动效开关：不在当前菜单、正在看详情时由上层关闭，所有装饰动画随之暂停。
private struct CyberMotionEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var cyberMotionEnabled: Bool {
        get { self[CyberMotionEnabledKey.self] }
        set { self[CyberMotionEnabledKey.self] = newValue }
    }
}

/// 全屏氛围背景：两团光晕缓慢漂移，网格静止；只是装饰，不持有任何应用状态。
/// 漂移幅度 24pt、周期约 50 秒，最快每秒约 3pt，8 帧/秒已看不出跳动；
/// 相比原来 24 帧/秒，全屏重绘次数降到三分之一。静态网格单独绘制一次，不随时间线重画。
struct CyberBackdrop: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cyberMotionEnabled) private var motionEnabled
    @State private var visible = false

    private var animating: Bool { visible && motionEnabled && scenePhase == .active && !reduceMotion }

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 1.0 / 8, paused: !animating)) { timeline in
                Canvas(rendersAsynchronously: true) { context, size in
                    let time = animating ? timeline.date.timeIntervalSinceReferenceDate : 0
                    let drift = sin(time / 8) * 24
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(DisplayStyle.canvas))
                    let cyan = CGPoint(x: size.width * 0.1 + drift, y: size.height * 0.12)
                    let violet = CGPoint(x: size.width * 0.95, y: size.height * 0.65 + drift)
                    for (center, color, radius) in [(cyan, DisplayStyle.accent, CGFloat(420)), (violet, DisplayStyle.violet, CGFloat(360))] {
                        context.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
                            Gradient(colors: [color.opacity(0.10), color.opacity(0)]), center: center, startRadius: 0, endRadius: radius))
                    }
                }
            }
            CyberGrid().stroke(DisplayStyle.accent.opacity(0.035), lineWidth: 0.5)
        }
        .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
        .onAppear { visible = true }.onDisappear { visible = false }
    }
}

/// 静态 28pt 网格；作为 Shape 只在尺寸变化时重新生成路径。
private struct CyberGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var grid = Path()
        for x in stride(from: CGFloat(0), through: rect.width, by: 28) {
            grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: rect.height))
        }
        for y in stride(from: CGFloat(0), through: rect.height, by: 28) {
            grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: rect.width, y: y))
        }
        return grid
    }
}

/// 卡片内容静止，只有一圈高光沿边框缓慢旋转（8 秒一圈）。
/// 15 帧/秒时每帧约转 3°，细边框上看不出跳帧，比 24 帧/秒少约四成唤醒；未开启扫光的卡片时间线暂停。
private struct CyberSurface: ViewModifier {
    var tint: Color
    var sweeping: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cyberMotionEnabled) private var motionEnabled
    @State private var visible = false
    private var animating: Bool { sweeping && visible && motionEnabled && scenePhase == .active && !reduceMotion }

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 17).fill(
                    LinearGradient(colors: [DisplayStyle.surface, DisplayStyle.graphite], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay {
                TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !animating)) { timeline in
                    let phase = animating ? timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 8) / 8 : 0.15
                    RoundedRectangle(cornerRadius: 17).strokeBorder(
                        AngularGradient(stops: [
                            .init(color: tint.opacity(0.16), location: 0),
                            .init(color: tint.opacity(0.16), location: 0.36),
                            .init(color: tint.opacity(sweeping ? 0.9 : 0.35), location: 0.46),
                            .init(color: DisplayStyle.violet.opacity(0.4), location: 0.53),
                            .init(color: tint.opacity(0.16), location: 0.65),
                            .init(color: tint.opacity(0.16), location: 1)
                        ], center: .center, angle: .degrees(phase * 360)), lineWidth: 1)
                }
                .allowsHitTesting(false).accessibilityHidden(true)
            }
            .overlay(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 1).fill(tint.opacity(0.8)).frame(width: 32, height: 2)
                    .padding(.leading, 18).allowsHitTesting(false).accessibilityHidden(true)
            }
            .shadow(color: tint.opacity(sweeping ? 0.09 : 0.025), radius: sweeping ? 18 : 8, y: 4)
            .onAppear { visible = true }.onDisappear { visible = false }
    }
}

/// 首次出现时的淡入上移；减弱动态效果、非当前页或后台时直接显示终态。
private struct CyberEntrance: ViewModifier {
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cyberMotionEnabled) private var motionEnabled
    @Environment(\.scenePhase) private var scenePhase
    @State private var entered = false

    func body(content: Content) -> some View {
        let settled = entered || reduceMotion || !motionEnabled || scenePhase != .active
        content.opacity(settled ? 1 : 0)
            .offset(y: settled ? 0 : 16).scaleEffect(settled ? 1 : 0.985, anchor: .top)
            .animation(reduceMotion || !motionEnabled || scenePhase != .active ? nil : .spring(response: 0.52, dampingFraction: 0.88).delay(delay), value: entered)
            .onAppear { entered = true }.onDisappear { entered = false }
    }
}

/// 按压缩放反馈，尊重系统减弱动态效果设置。
struct CyberPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .brightness(configuration.isPressed ? 0.06 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.75), value: configuration.isPressed)
            .hoverEffect(.highlight)
    }
}

/// 连接状态指示点，仅前台播放脉冲。
struct CyberConnectionDot: View {
    let connected: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cyberMotionEnabled) private var motionEnabled
    @State private var visible = false

    var body: some View {
        Group {
            if connected && visible && motionEnabled && scenePhase == .active && !reduceMotion {
                Circle().fill(DisplayStyle.accent)
                    .phaseAnimator([0.6, 1.0]) { dot, phase in
                        dot.opacity(phase).shadow(color: DisplayStyle.accent.opacity(phase * 0.7), radius: 4)
                    } animation: { _ in .easeInOut(duration: 1.4) }
            } else {
                Circle().fill(connected ? DisplayStyle.accent : Color.secondary.opacity(0.6))
            }
        }.frame(width: 6, height: 6).accessibilityHidden(true)
            .onAppear { visible = true }.onDisappear { visible = false }
    }
}

extension View {
    /// 卡片底色与边框；`sweeping` 为 true 时边框高光旋转。
    func cyberSurface(tint: Color = DisplayStyle.accent, sweeping: Bool = false) -> some View {
        modifier(CyberSurface(tint: tint, sweeping: sweeping))
    }
    /// 卡片入场动画，`delay` 用于错开多张卡片。
    func cyberEntrance(delay: Double = 0) -> some View { modifier(CyberEntrance(delay: delay)) }
}
