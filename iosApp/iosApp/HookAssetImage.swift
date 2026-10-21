import SwiftUI

/// 图片帧已在后台有界解码；仅按可见且允许播放的时长选择位图。
struct HookAssetImage: View {
    let asset: LanImageAsset
    @State private var playback = HookPlaybackClock()
    @State private var finished = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cyberMotionEnabled) private var motionEnabled
    @State private var visible = false
    private var canPlay: Bool {
        asset.isAnimated && !reduceMotion && motionEnabled && scenePhase == .active && !finished
    }
    private var isPlaying: Bool { canPlay && visible }

    var body: some View {
        Group {
            if asset.isAnimated && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPlaying)) { context in
                    frame(asset.frameIndex(at: playback.elapsed(at: context.date)))
                        .onChange(of: context.date) { _, date in
                            if asset.playCount > 0, playback.elapsed(at: date) >= asset.duration * Double(asset.playCount) {
                                playback.setPlaying(false, at: date)
                                finished = true
                            }
                        }
                }
            } else {
                frame(0)
            }
        }
        .onAppear { updateVisibility(true) }.onDisappear { updateVisibility(false) }
        .onScrollVisibilityChange(threshold: 0.01) { updateVisibility($0) }
        .onChange(of: isPlaying, initial: true) { _, playing in playback.setPlaying(playing, at: Date()) }
        .onChange(of: asset.id) { _, _ in
            playback = HookPlaybackClock()
            finished = false
            playback.setPlaying(isPlaying, at: Date())
        }
        .accessibilityLabel("Hook 图片")
    }

    private func updateVisibility(_ value: Bool) {
        visible = value
        playback.setPlaying(value && canPlay, at: Date())
    }

    private func frame(_ index: Int) -> some View {
        Image(decorative: asset.frames[index], scale: 1).resizable().scaledToFit()
    }
}

/// 暂停期间不推进帧时间或消耗有限循环次数；恢复时从上一帧继续。
private struct HookPlaybackClock {
    private var accumulated: TimeInterval = 0
    private var started: Date?

    /// 返回累计播放时长，暂停期间不计时。
    func elapsed(at date: Date) -> TimeInterval {
        accumulated + (started.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }

    mutating func setPlaying(_ playing: Bool, at date: Date) {
        if playing {
            if started == nil { started = date }
        } else {
            accumulated = elapsed(at: date)
            started = nil
        }
    }
}
