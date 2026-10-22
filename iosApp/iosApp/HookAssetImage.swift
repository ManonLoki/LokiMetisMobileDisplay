import SwiftUI

/// 图片帧已在后台有界解码；仅在允许播放时按素材的下一帧边界唤醒。
struct HookAssetImage: View {
    let asset: LanImageAsset
    var playbackEnabled = true
    @State private var playback = LanImagePlaybackClock()
    @State private var displayedFrame = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(watchOS)
    @Environment(\.isLuminanceReduced) private var reducedLuminance
    private var motionEnabled: Bool { !reducedLuminance }
    #else
    @Environment(\.cyberMotionEnabled) private var motionEnabled
    #endif
    @State private var visible = false
    private var canPlay: Bool {
        asset.isAnimated && playbackEnabled && !reduceMotion && motionEnabled && scenePhase == .active
    }
    private var isPlaying: Bool { canPlay && visible }
    private struct PlaybackTaskID: Equatable {
        let assetID: String
        let playing: Bool
    }

    var body: some View {
        frame(reduceMotion || playback.assetID != asset.id ? 0 : displayedFrame)
        .task(id: PlaybackTaskID(assetID: asset.id, playing: isPlaying)) { await playFrames() }
        .onAppear { updateVisibility(true) }.onDisappear { updateVisibility(false) }
        .onChange(of: isPlaying) { _, _ in synchronizePlayback() }
        .onChange(of: asset.id) { _, _ in
            synchronizePlayback()
            displayedFrame = 0
        }
        .accessibilityLabel("Hook 图片")
    }

    /// 出现 / 消失时记录可见性并同步播放时钟。
    private func updateVisibility(_ value: Bool) {
        visible = value
        synchronizePlayback()
    }

    /// 根据当前是否允许播放暂停或继续累计播放时长。
    private func synchronizePlayback() {
        playback.update(assetID: asset.id, playing: isPlaying, at: .now)
    }

    @MainActor
    private func playFrames() async {
        guard !Task.isCancelled else { return }
        synchronizePlayback()
        let clock = ContinuousClock()
        // 用视图任务的取消/重建恢复播放，不依赖 paused Timeline 或滚动容器的可见性回调。
        // Hook 分页由 playbackEnabled / cyberMotionEnabled 控制，离屏、息屏时停止唤醒。
        while !Task.isCancelled {
            let elapsed = playback.elapsed(at: clock.now)
            displayedFrame = asset.frameIndex(at: elapsed)
            guard isPlaying, let interval = asset.timeUntilNextFrame(at: elapsed) else {
                playback.setPlaying(false, at: clock.now)
                return
            }
            do {
                // 极短帧至多60Hz；通常仅按GIF/WebP/APNG原有帧间隔运行。
                try await clock.sleep(for: .seconds(max(1.0 / 60, interval)), tolerance: .milliseconds(2))
            } catch { return }
        }
    }

    /// 取出指定帧；越界时退回最后一帧。
    private func frame(_ index: Int) -> some View {
        Image(decorative: asset.frames[min(index, asset.frames.count - 1)], scale: 1).resizable().scaledToFit()
    }
}
