import SwiftUI

/// 播放页控件层：右侧操作栏 + 左下信息 + 底部进度 / 播放控制。
///
/// 右侧操作栏按短视频（抖音 / TikTok）的惯例只用白色图标 + 计数，不再套玻璃圆底：
/// 视频画面才是主体，玻璃圆底会把控件做得又重又占地方。底部播放控制属于导航 / 控制层，
/// 继续使用 Liquid Glass。横向（手机横屏 / 全屏）时整套尺寸与间距会收紧，避免按钮挤成一团。
struct FeedOverlay: View {
    let id: Int
    let detail: VideoDetail?
    let ep: Int
    let mode: FeedView.Mode
    let compact: Bool
    /// 外层让开的底部安全区（标签栏 / home indicator），由调用方冻结后传入
    let bottomSafe: CGFloat
    let pip: PiPController
    var onLike: () -> Void
    var onFav: () -> Void
    var onFollow: () -> Void
    var onComments: () -> Void
    var onEpisodes: () -> Void
    var onInfo: () -> Void
    var onImmersive: () -> Void
    var onNextEp: () -> Void

    @Environment(AppModel.self) private var app

    private var engine: PlayerEngine { app.player }

    var body: some View {
        GeometryReader { g in
            // 按真实可用高度决定密度：横屏 / 全屏（尤其是带标签栏时）竖向只有 330–420pt
            let tall = g.size.height >= 560
            let tight = !tall
            let withCounts = g.size.height >= 400
            let m = RailMetrics(tight: tight, counts: withCounts)
            let hidden = app.clean
            // 这里刻意不使用 GlassEffectContainer：容器会把间距内的玻璃件融成一整块，
            // 播放控件（暂停 / 下一集 / 倍速 / 静音 / 画中画 / 全屏）需要各自独立、按键分明。
            VStack(spacing: tight ? 8 : 12) {
                HStack(alignment: .bottom, spacing: tight ? 14 : 18) {
                    info(tight: tight)
                        .offset(x: hidden ? -30 : 0, y: hidden ? 24 : 0)
                        .opacity(hidden ? 0 : 1)
                    Spacer(minLength: 8)
                    actionRail(m)
                        .offset(x: hidden ? 110 : 0)
                        .opacity(hidden ? 0 : 1)
                }
                ControlBar(engine: engine, compact: compact, tight: tight, pip: pip, epLabel: epLabel,
                           onImmersive: onImmersive, onNextEp: onNextEp, immersive: app.immersive,
                           railWidth: m.hit.width)
                    .offset(y: hidden ? 120 : 0)
                    .opacity(hidden ? 0 : 1)
            }
            .padding(.leading, tight ? 18 : 16)
            .padding(.trailing, tight ? 14 : 16)
            .padding(.bottom, (tight ? 4 : bottomInset) + bottomSafe)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            // 竖屏视频页右上角：静音时给一个「取消静音」入口（首页那条要排到搜索键左侧）。
            // 全屏里控制条本身有静音键，这里不再出现，避免两个静音按钮。
            .overlay(alignment: .topTrailing) {
                if showsUnmute(tight: tight) {
                    CircleGlassButton(symbol: "speaker.slash.fill", label: "取消静音") { app.muted = false }
                        .padding(.top, ChromeMetric.top)
                        .padding(.trailing, ChromeMetric.trailing
                                 + (mode == .home ? ChromeMetric.button + ChromeMetric.gap : 0))
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(.smooth(duration: 0.28), value: showsUnmute(tight: tight))
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            // 界面整体滑出屏幕边缘的动画；隐藏时不再拦截点击，单击才能把界面唤回来
            .animation(.smooth(duration: 0.32), value: hidden)
            .allowsHitTesting(!hidden)
        }
        // 铺满整屏、自己补安全区：标签栏显隐不再改变控件层的位置，
        // 单击隐藏时也就不会先往下跳一截再滑出
        .ignoresSafeArea(edges: .bottom)
    }

    /// 只在「首页 / 热门 / 最新」这类视频页、且控制条是精简一行时出现；
    /// iPad 与全屏的控制条本来就有静音键。
    private func showsUnmute(tight: Bool) -> Bool {
        #if os(iOS)
        return mode == .home && app.muted && !app.immersive && !app.clean && (compact || tight)
        #else
        return false
        #endif
    }

    /// 底部安全区已经由外层容器让开（标签栏 / home indicator），这里只补一点呼吸位
    private var bottomInset: CGFloat {
        #if os(iOS)
        return mode == .home && !app.immersive ? 6 : 12
        #else
        return 16
        #endif
    }

    private var epLabel: String {
        guard let d = detail else { return "" }
        return "第 \(ep)/\(d.epCount) 集"
    }

    /* ───────────── 左下信息 ───────────── */

    @ViewBuilder private func info(tight: Bool) -> some View {
        VStack(alignment: .leading, spacing: tight ? 4 : 8) {
            if let d = detail {
                HStack(spacing: 8) {
                    Text("@\(d.author.name.isEmpty ? "黄果官方" : d.author.name)")
                        .font(.headline)
                    if !epLabel.isEmpty {
                        Text(epLabel)
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 8).padding(.vertical, tight ? 2 : 4)
                            .background(.black.opacity(0.35), in: .capsule)
                    }
                    if d.score > 0 {
                        Label(Fmt.score(d.score), systemImage: "star.fill")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(Theme.rating)
                            .labelStyle(.titleAndIcon)
                    }
                }
                Button(action: onInfo) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(d.title).font(.title3.weight(.bold)).lineLimit(tight ? 1 : 2)
                        if !d.description.isEmpty {
                            Text(d.description)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.82))
                                .lineLimit(tight ? 1 : 2)
                        }
                    }
                    .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .accessibilityHint("查看简介")
                if !d.tags.isEmpty, !tight {
                    HStack(spacing: 6) {
                        ForEach(d.tags.prefix(4), id: \.self) { t in
                            Text("#\(t)").font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.85))
                        }
                    }
                }
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.18)).frame(width: 160, height: 18)
                RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.12)).frame(width: 220, height: 14)
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 8, y: 1)
        .frame(maxWidth: tight ? 520 : 560, alignment: .leading)
    }

    /* ───────────── 右侧操作栏 ───────────── */

    @ViewBuilder private func actionRail(_ m: RailMetrics) -> some View {
        let liked = app.isLiked(id)
        let faved = app.isFav(id)

        VStack(spacing: m.gap) {
            if let a = detail?.author, a.id > 0 {
                Button(action: onFollow) {
                    Avatar(name: a.name, size: m.avatar)
                        .overlay(alignment: .bottom) {
                            Image(systemName: app.isFollowing(a.id) ? "checkmark" : "plus")
                                .font(.system(size: m.avatar * 0.26, weight: .heavy))
                                .frame(width: m.avatar * 0.46, height: m.avatar * 0.46)
                                .foregroundStyle(.black)
                                .background(.white, in: .circle)
                                .offset(y: m.avatar * 0.2)
                                .contentTransition(.symbolEffect(.replace))
                        }
                }
                .buttonStyle(RailPressStyle())
                .padding(.bottom, m.avatar * 0.14)
                .accessibilityLabel(app.isFollowing(a.id) ? "已关注 \(a.name)" : "关注 \(a.name)")
            }

            Button(action: onLike) {
                RailIconLabel(symbol: liked ? "heart.fill" : "heart", tint: liked ? Theme.heart : nil,
                              label: m.counts ? Fmt.count((detail?.like ?? 0) + (liked ? 1 : 0)) : nil,
                              bounce: liked, m: m)
            }
            .buttonStyle(RailPressStyle())
            .accessibilityLabel(liked ? "取消喜欢" : "喜欢")

            Button(action: onComments) {
                RailIconLabel(symbol: "bubble.right.fill", label: m.counts ? Fmt.count(detail?.comment ?? 0) : nil, m: m)
            }
            .buttonStyle(RailPressStyle())
            .accessibilityLabel("评论")

            Button(action: onFav) {
                RailIconLabel(symbol: faved ? "star.fill" : "star", tint: faved ? .white : nil,
                              label: m.counts ? Fmt.count((detail?.collect ?? 0) + (faved ? 1 : 0)) : nil,
                              bounce: faved, m: m)
            }
            .buttonStyle(RailPressStyle())
            .accessibilityLabel(faved ? "取消收藏" : "收藏")

            Button(action: onEpisodes) {
                RailIconLabel(symbol: "list.bullet.rectangle.portrait", label: "选集", m: m)
            }
            .buttonStyle(RailPressStyle())
            .accessibilityLabel("选集")

            ShareLink(item: URL(string: "https://huangguoai.com/video/\(id)/")!) {
                RailIconLabel(symbol: "arrowshape.turn.up.right.fill", label: "分享", m: m)
            }
            .buttonStyle(RailPressStyle())
            .accessibilityLabel("分享")

            // 上下翻页键已移除：竖滑翻页本身就是手势，右侧只保留互动按钮
        }
    }
}

/* ───────────── 操作栏尺寸 ───────────── */

/// 竖屏与横屏两套尺寸：横屏时图标、头像、间距一起缩小，保证 6 个按钮仍然好点
struct RailMetrics {
    var avatar: CGFloat
    var icon: CGFloat
    var gap: CGFloat
    var label: CGFloat
    var labelGap: CGFloat
    /// 数字计数（竖屏放得下才显示，横屏只留图标和功能名）
    var counts: Bool

    init(tight: Bool, counts: Bool = true) {
        self.counts = counts
        if tight {
            avatar = 32
            icon = 21
            gap = 6
            label = 10
            labelGap = 2
        } else {
            avatar = 44
            icon = 27
            gap = 14
            label = 11
            labelGap = 3
        }
    }

    /// 图标外框：留出稳定的点击区域，但不画任何底
    var hit: CGSize { CGSize(width: icon + 14, height: icon + 8) }
}

/// 只画图标 + 计数的操作项（无玻璃底，短视频惯例）
private struct RailIconLabel: View {
    let symbol: String
    var tint: Color?
    var label: String?
    var bounce = false
    let m: RailMetrics

    var body: some View {
        VStack(spacing: m.labelGap) {
            Image(systemName: symbol)
                .font(.system(size: m.icon, weight: .semibold))
                .foregroundStyle(tint ?? .white)
                .shadow(color: .black.opacity(0.38), radius: 4, y: 1)
                .symbolEffect(.bounce, value: bounce)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: m.hit.width, height: m.hit.height)
            if let label {
                Text(label)
                    .font(.system(size: m.label, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
            }
        }
        .contentShape(.rect)
    }
}

/// 按下时轻微缩放，和系统按钮的按压反馈一致
private struct RailPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

/* ───────────── 播放控制条 ───────────── */

struct ControlBar: View {
    let engine: PlayerEngine
    let compact: Bool
    /// 竖向空间紧张（手机横屏）：更小的按钮、只留一条精简控制行
    let tight: Bool
    let pip: PiPController
    let epLabel: String
    var onImmersive: () -> Void
    var onNextEp: () -> Void
    var immersive: Bool
    /// 右侧操作栏图标的外框宽度：全屏键按它对齐，圆心与上面那排按钮同一条竖线
    var railWidth: CGFloat = 0

    @Environment(AppModel.self) private var app
    @State private var scrubbing: Double?

    private let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        VStack(spacing: tight ? 6 : 8) {
            Scrubber(time: scrubbing ?? engine.time, duration: engine.duration, buffered: engine.buffered) { v in
                scrubbing = v
            } onEnd: { v in
                engine.seek(to: v)
                scrubbing = nil
            }
            .frame(height: 26)
            .overlay(alignment: .top) {
                if let s = scrubbing {
                    Text("\(Fmt.time(s)) / \(Fmt.time(engine.duration))")
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.black.opacity(0.5), in: .capsule)
                        .offset(y: -60)
                }
            }

            if (!compact && !tight) || immersive {
                HStack(spacing: tight ? 6 : 10) {
                    glassIcon(engine.isPlaying ? "pause.fill" : "play.fill", engine.isPlaying ? "暂停" : "播放") { engine.toggle() }
                    glassIcon("forward.end.fill", "下一集", action: onNextEp)
                    Text("\(Fmt.time(engine.time)) / \(Fmt.time(engine.duration))")
                        .font(.footnote.monospacedDigit())
                        .padding(.horizontal, 12).frame(height: tight ? 30 : 36)
                        .background(.black.opacity(0.35), in: .capsule)
                        .foregroundStyle(.white)
                    Spacer(minLength: 4)
                    Menu {
                        Picker("倍速", selection: Binding(get: { app.rate }, set: { app.rate = $0 })) {
                            ForEach(rates, id: \.self) { r in Text(rateText(r)).tag(r) }
                        }
                    } label: {
                        Text(rateText(app.rate)).font(.footnote.weight(.semibold).monospacedDigit())
                            .frame(minWidth: 44).frame(height: tight ? 30 : 36)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .padding(.horizontal, 6)
                    .glassEffect(.clear.interactive(), in: .capsule)
                    .accessibilityLabel("倍速 \(rateText(app.rate))")

                    glassIcon(app.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", app.muted ? "取消静音" : "静音") {
                        app.muted.toggle()
                    }
                    #if os(macOS)
                    Slider(value: Binding(get: { Double(app.volume) }, set: { app.volume = Float($0); if $0 > 0 { app.muted = false } }), in: 0...1)
                        .frame(width: 90)
                        .controlSize(.small)
                        .accessibilityLabel("音量")
                    #endif
                    if pip.isSupported {
                        glassIcon("pip.enter", "画中画") { pip.toggle() }
                    }
                    // 全屏 / 退出全屏：整套界面里唯一的切换入口，宽度和右侧操作栏一致才对得齐
                    glassIcon(immersive ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                              immersive ? "退出全屏" : "全屏", action: onImmersive)
                        .frame(width: railWidth > 0 ? railWidth : nil)
                }
                .transition(.opacity)
            } else {
                HStack(spacing: 10) {
                    Text("\(Fmt.time(engine.time)) / \(Fmt.time(engine.duration))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    if app.rate != 1 {
                        Text(rateText(app.rate)).font(.caption.weight(.bold))
                    }
                    Button(action: onImmersive) {
                        Image(systemName: immersive ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.footnote.weight(.semibold))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.clear.interactive(), in: .circle)
                    .frame(width: railWidth > 0 ? railWidth : nil)
                    .accessibilityLabel(immersive ? "退出全屏" : "全屏")
                }
                .transition(.opacity)
            }
        }
        // 全屏切换时控制条由「精简一行」长成「完整一行」，给它一个过渡而不是硬跳
        .animation(.smooth(duration: 0.3), value: immersive)
    }

    private func rateText(_ r: Float) -> String {
        r == r.rounded() ? String(format: "%.1fx", r) : "\(String(format: "%g", r))x"
    }

    private func glassIcon(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        #if os(macOS)
        // 鼠标点击比手指粗糙，mac 上把命中区域放到 40，避免点偏变成「没反应」
        let side: CGFloat = tight ? 32 : 40
        #else
        let side: CGFloat = tight ? 30 : 36
        #endif
        return Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: side, height: side)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.clear.interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}

/// 进度条：拖动时放大，显示缓冲段
struct Scrubber: View {
    let time: Double
    let duration: Double
    let buffered: Double
    var onChange: (Double) -> Void
    var onEnd: (Double) -> Void

    @State private var dragging = false

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let frac = duration > 0 ? min(1, max(0, time / duration)) : 0
            let bfrac = duration > 0 ? min(1, max(0, buffered / duration)) : 0
            let h: CGFloat = dragging ? 8 : 3
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(.white.opacity(0.35)).frame(width: w * bfrac)
                Capsule().fill(.white).frame(width: w * frac)
            }
            .frame(height: h)
            .overlay(alignment: .leading) {
                Circle().fill(.white)
                    .frame(width: dragging ? 18 : 10, height: dragging ? 18 : 10)
                    .shadow(radius: 3)
                    .offset(x: max(0, w * frac - (dragging ? 9 : 5)))
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard duration > 0 else { return }
                        if !dragging { withAnimation(.snappy) { dragging = true } }
                        onChange(Double(min(max(0, v.location.x / w), 1)) * duration)
                    }
                    .onEnded { v in
                        guard duration > 0 else { return }
                        withAnimation(.snappy) { dragging = false }
                        onEnd(Double(min(max(0, v.location.x / w), 1)) * duration)
                    }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(Fmt.time(time)) / \(Fmt.time(duration))")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: onEnd(min(duration, time + 10))
            case .decrement: onEnd(max(0, time - 10))
            @unknown default: break
            }
        }
    }
}
