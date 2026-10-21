import SwiftUI

private struct CyberMotionEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var cyberMotionEnabled: Bool {
        get { self[CyberMotionEnabledKey.self] }
        set { self[CyberMotionEnabledKey.self] = newValue }
    }
}

/// One low-frequency canvas supplies the ambient layer; it never owns application state.
struct CyberBackdrop: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cyberMotionEnabled) private var motionEnabled
    @State private var visible = false

    private var animating: Bool { visible && motionEnabled && scenePhase == .active && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !animating)) { timeline in
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
                var grid = Path()
                stride(from: CGFloat(0), through: size.width, by: 28).forEach { x in
                    grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
                }
                stride(from: CGFloat(0), through: size.height, by: 28).forEach { y in
                    grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(grid, with: .color(DisplayStyle.accent.opacity(0.035)), lineWidth: 0.5)
            }
        }
        .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
        .onAppear { visible = true }.onDisappear { visible = false }
    }
}

/// Content stays still while a slow edge highlight traverses the usage surface.
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
                TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !animating)) { timeline in
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
            .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
    }
}

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
            .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
    }
}

extension View {
    func cyberSurface(tint: Color = DisplayStyle.accent, sweeping: Bool = false) -> some View {
        modifier(CyberSurface(tint: tint, sweeping: sweeping))
    }
    func cyberEntrance(delay: Double = 0) -> some View { modifier(CyberEntrance(delay: delay)) }
}
