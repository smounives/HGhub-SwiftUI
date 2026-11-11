import AVFoundation
import AVKit
import Observation
import SwiftUI

/// 播放器池：每个页面固定一只 AVPlayer（按页面序号分配）。
///
/// 短视频 App 的做法是「每张卡片各自一只播放器、预取相邻卡片」，翻页时只切谁在出声。
/// 之前整条信息流共用一只播放器，翻页要换 item、页面还要从「预览播放器」切到「主播放器」，
/// 就必然会出现首帧跳一下 / 淡入淡出闪一下。现在页面渲染的 player 对象始终不变，
/// 相邻页面的画面在翻页前就已经解出来了。
@MainActor
@Observable
final class PlayerEngine {
    /// 同时保留的播放器数量（当前页 + 前后各一页，再多一个余量）
    static let maxSlots = 4

    final class Slot {
        let player = AVPlayer()
        var source = ""
        var key = ""
        var loader: HLSLoader?
        var itemObservers: [NSKeyValueObservation] = []
        var playerObservers: [NSKeyValueObservation] = []
        var noteObservers: [NSObjectProtocol] = []
        var ready = false
        var wantPlay = false
        var pendingSeek: Double?
        var error: String?
    }

    @ObservationIgnored private var slots: [Int: Slot] = [:]
    @ObservationIgnored private var tickers: [Int: Any] = [:]
    private(set) var active = -1

    private(set) var source: String = ""
    private(set) var time: Double = 0
    private(set) var duration: Double = 0
    private(set) var buffered: Double = 0
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var isReady = false
    private(set) var presentationSize: CGSize = .zero
    var error: String?

    var baseRate: Float = 1 { didSet { applyRate() } }
    var boosted = false { didSet { applyRate() } }
    var muted: Bool = true { didSet { applyAudio() } }
    var volume: Float = 0.7 { didSet { applyAudio() } }

    var onEnded: (() -> Void)?

    init(muted: Bool, volume: Float) {
        self.muted = muted
        self.volume = volume
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    /* ───────────── 槽位 ───────────── */

    /// 页面渲染用：同一个 index 永远拿到同一只 player（不要换对象，换了就会闪）
    func player(for index: Int) -> AVPlayer {
        if let s = slots[index] { return s.player }
        evictIfNeeded(keeping: index)
        let s = Slot()
        s.player.isMuted = true
        s.player.volume = volume
        s.player.automaticallyWaitsToMinimizeStalling = true
        s.player.preventsDisplaySleepDuringVideoPlayback = true
        slots[index] = s
        observePlayer(index: index, slot: s)
        return s.player
    }

    private func evictIfNeeded(keeping index: Int) {
        guard slots.count >= Self.maxSlots else { return }
        let keep = Set([index, active, active - 1, active + 1])
        let victims = slots.keys.filter { !keep.contains($0) }
            .sorted { abs($0 - index) > abs($1 - index) }
        for v in victims.prefix(max(1, slots.count - Self.maxSlots + 1)) { release(v) }
    }

    /// 丢掉某一页的播放器（页面被回收时调用）
    func release(_ index: Int) {
        guard let s = slots.removeValue(forKey: index) else { return }
        if let t = tickers.removeValue(forKey: index) { s.player.removeTimeObserver(t) }
        teardown(slot: s)
        if active == index { active = -1 }
    }

    /* ───────────── 装载 / 切换 ───────────── */

    /// 给某一页准备播放地址。相邻页提前调用，画面在翻页前就解出来了。
    func prepare(index: Int, source url: String, key: String, start: Double = 0, autoplay: Bool = false) {
        let p = player(for: index)
        guard let slot = slots[index] else { return }
        if slot.source != url {
            loadItem(slot, index: index, url: url, key: key)
        }
        if start > 0.5 { slot.pendingSeek = start }
        if autoplay {
            activate(index)
        } else {
            slot.wantPlay = false
            p.pause()
            // 停在开头，翻到这一页时和正片起点对得上
            if slot.ready { p.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) }
        }
    }

    /// 把某一页设为「正在播放」（出声、驱动进度条）
    func activate(_ index: Int) {
        guard let slot = slots[index] else { return }
        if active != index {
            if active >= 0, let old = slots[active] {
                old.wantPlay = false
                old.player.pause()
            }
            active = index
            source = slot.source
            error = slot.error
            isReady = slot.ready
            time = slot.player.currentTime().seconds.isFinite ? max(0, slot.player.currentTime().seconds) : 0
            refreshMeta(slot)
        }
        applyAudio()
        applyRate()
        slot.wantPlay = true
        if slot.ready { slot.player.playImmediately(atRate: currentRate) }
    }

    /// 当前页播完（自动下一集）时才需要知道「谁在播」
    var activeIndex: Int { active }

    private func loadItem(_ slot: Slot, index: Int, url: String, key: String) {
        slot.player.pause()
        slot.player.replaceCurrentItem(with: nil)
        clearObservers(slot)
        slot.source = url
        slot.key = key
        slot.ready = false
        slot.error = nil
        slot.pendingSeek = nil

        guard let assetURL = HLSLoader.assetURL(for: url) else {
            slot.error = "播放地址无效"
            if active == index { error = slot.error }
            return
        }
        let asset = AVURLAsset(url: assetURL, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["Referer": "\(Net.shared.base)/", "User-Agent": Net.userAgent],
        ])
        let l = HLSLoader()
        asset.resourceLoader.setDelegate(l, queue: HLSLoader.queue)
        slot.loader = l

        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 12
        observeItem(slot, index: index, item: item)
        slot.player.replaceCurrentItem(with: item)
        if slot.wantPlay || active == index {
            slot.player.playImmediately(atRate: currentRate)
        }
    }

    /// 兼容单页播放器（帖子详情、菜单命令）：固定用 9000 号槽
    var player: AVPlayer { player(for: 9000) }

    func load(_ url: String, start: Double = 0, autoplay: Bool = true) {
        prepare(index: 9000, source: url, key: url, start: start, autoplay: autoplay)
    }

    /* ───────────── 播放控制（作用于当前页） ───────────── */

    func play() {
        guard let slot = slots[active] else { return }
        slot.wantPlay = true
        if duration > 0, time >= duration - 0.3 { seek(to: 0) }
        slot.player.playImmediately(atRate: currentRate)
    }

    func pause() {
        guard let slot = slots[active] else { return }
        slot.wantPlay = false
        slot.player.pause()
    }

    func toggle() { isPlaying || (slots[active]?.wantPlay == true && isBuffering) ? pause() : play() }

    func seek(to seconds: Double) {
        guard let slot = slots[active] else { return }
        let t = max(0, duration > 0 ? min(seconds, duration - 0.2) : seconds)
        time = t
        slot.player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                         toleranceBefore: .zero, toleranceAfter: CMTime(value: 1, timescale: 2))
    }

    func skip(_ delta: Double) { seek(to: time + delta) }

    /// 停止当前页（换线路 / 重试时用）
    func stop() {
        guard let slot = slots[active] else { return }
        slot.wantPlay = false
        slot.player.pause()
        slot.player.replaceCurrentItem(with: nil)
        clearObservers(slot)
        slot.source = ""
        slot.ready = false
        source = ""
        time = 0
        duration = 0
        buffered = 0
        isReady = false
        isPlaying = false
        isBuffering = false
    }

    func teardown() {
        for (i, s) in slots {
            if let t = tickers.removeValue(forKey: i) { s.player.removeTimeObserver(t) }
            teardown(slot: s)
        }
        slots.removeAll()
        active = -1
    }

    /* ───────────── 内部 ───────────── */

    private var currentRate: Float { boosted ? max(2, baseRate) : baseRate }

    private func applyRate() {
        guard let slot = slots[active] else { return }
        slot.player.defaultRate = currentRate
        if slot.wantPlay { slot.player.rate = currentRate }
    }

    private func applyAudio() {
        for (i, s) in slots {
            s.player.isMuted = (i == active) ? muted : true
            s.player.volume = volume
        }
    }

    private func refreshMeta(_ slot: Slot) {
        guard let item = slot.player.currentItem else { return }
        let d = item.duration.seconds
        duration = d.isFinite ? max(0, d) : 0
        presentationSize = item.presentationSize
        buffered = 0
    }

    private func observePlayer(index: Int, slot: Slot) {
        let token = slot.player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 4), queue: .main
        ) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(index: index, t) }
        }
        tickers[index] = token
        slot.playerObservers.append(slot.player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let status = p.timeControlStatus
            Task { @MainActor in
                guard let self, self.active == index else { return }
                self.isPlaying = status == .playing
                self.isBuffering = status == .waitingToPlayAtSpecifiedRate
            }
        })
    }

    private func tick(index: Int, _ t: CMTime) {
        guard index == active else { return }
        let s = t.seconds
        if s.isFinite { time = max(0, s) }
        if let item = slots[index]?.player.currentItem {
            let d = item.duration.seconds
            if d.isFinite, d > 0 { duration = d }
            if let r = item.loadedTimeRanges.last?.timeRangeValue {
                let end = (r.start + r.duration).seconds
                if end.isFinite { buffered = end }
            }
        }
    }

    private func observeItem(_ slot: Slot, index: Int, item: AVPlayerItem) {
        slot.itemObservers.append(item.observe(\.status, options: [.new, .initial]) { [weak self] it, _ in
            let status = it.status
            let err = it.error
            let duration = it.duration.seconds
            let size = it.presentationSize
            Task { @MainActor in
                guard let self, let slot = self.slots[index], slot.player.currentItem === it else { return }
                switch status {
                case .readyToPlay:
                    slot.ready = true
                    _ = duration
                    _ = size
                    if self.active == index {
                        self.isReady = true
                        self.refreshMeta(slot)
                        if let s = slot.pendingSeek { slot.pendingSeek = nil; self.seekIn(slot, to: s) }
                        if slot.wantPlay { slot.player.playImmediately(atRate: self.currentRate) }
                    } else {
                        // 相邻页：停在第一帧，翻过去直接有画面
                        slot.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                case .failed:
                    slot.error = PlayerEngine.describe(err)
                    if self.active == index { self.error = slot.error }
                default: break
                }
            }
        })
        slot.itemObservers.append(item.observe(\.presentationSize, options: [.new]) { [weak self] it, _ in
            let size = it.presentationSize
            Task { @MainActor in
                guard let self, self.active == index, size.width > 0 else { return }
                self.presentationSize = size
            }
        })
        slot.noteObservers.append(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, index == self.active else { return }
                if let cb = self.onEnded { cb() } else { self.seek(to: 0); self.play() }
            }
        })
        slot.noteObservers.append(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] n in
            let e = n.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            MainActor.assumeIsolated {
                guard let self, index == self.active else { return }
                self.error = PlayerEngine.describe(e)
            }
        })
    }

    private func seekIn(_ slot: Slot, to seconds: Double) {
        slot.player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600),
                         toleranceBefore: .zero, toleranceAfter: CMTime(value: 1, timescale: 2))
    }

    private func clearObservers(_ slot: Slot) {
        slot.itemObservers.removeAll()
        slot.noteObservers.forEach { NotificationCenter.default.removeObserver($0) }
        slot.noteObservers.removeAll()
    }

    private func teardown(slot: Slot) {
        slot.wantPlay = false
        slot.player.pause()
        slot.player.replaceCurrentItem(with: nil)
        clearObservers(slot)
        slot.playerObservers.removeAll()
        slot.loader = nil
        slot.ready = false
    }

    static func describe(_ e: Error?) -> String {
        guard let e else { return "视频加载失败" }
        let ns = e as NSError
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError, ns.domain == AVFoundationErrorDomain {
            return "视频加载失败：\(u.localizedDescription)"
        }
        return "视频加载失败：\(e.localizedDescription)"
    }

    var isLandscapeVideo: Bool { presentationSize.width > presentationSize.height * 1.05 }
}
/* ───────────── 画面 ───────────── */

#if os(iOS)
final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect
    var onLayer: ((AVPlayerLayer) -> Void)?

    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.backgroundColor = .clear
        v.playerLayer.player = player
        v.playerLayer.videoGravity = gravity
        onLayer?(v.playerLayer)
        return v
    }

    func updateUIView(_ v: PlayerLayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        if v.playerLayer.videoGravity != gravity {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.25)
            v.playerLayer.videoGravity = gravity
            CATransaction.commit()
        }
    }
}
#else
final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect
    var onLayer: ((AVPlayerLayer) -> Void)?

    func makeNSView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = gravity
        onLayer?(v.playerLayer)
        return v
    }

    func updateNSView(_ v: PlayerLayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        if v.playerLayer.videoGravity != gravity { v.playerLayer.videoGravity = gravity }
    }
}
#endif

/// 画中画控制（iOS / macOS 都基于 AVPlayerLayer）
@MainActor
final class PiPController: NSObject, AVPictureInPictureControllerDelegate {
    private var controller: AVPictureInPictureController?

    func attach(_ layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        if controller?.playerLayer === layer { return }
        controller = AVPictureInPictureController(playerLayer: layer)
        controller?.delegate = self
        #if os(iOS)
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        #endif
    }

    var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    func toggle() {
        guard let c = controller else { return }
        if c.isPictureInPictureActive { c.stopPictureInPicture() } else { c.startPictureInPicture() }
    }
}