import AVFoundation
import SwiftUI

/// 竖向翻页播放流（首页推荐 / 热门 / 最新，以及从列表点进来的上下文播放页）。
///
/// 布局分三层：底层是内容（封面 / 视频画面，铺满整屏），中间是压暗遮罩（一直铺到屏幕最底部，
/// 会压到标签栏后面，避免一半暗一半不暗），上层是控件层（遵守安全区，不会钻到标签栏 / 刘海下面）。
/// 控件层里的导航 / 播放控件继续使用 Liquid Glass。
struct FeedView: View {
    enum Mode { case home, context }

    let ids: [Int]
    var mode: Mode = .context
    var title: String = ""
    var startIndex: Int = 0
    var startEp: Int?
    var startTime: Double?
    /// 首页：快滑到底时加载下一批
    var onNearEnd: (() -> Void)?
    /// 首页：上报当前条（推荐流累积兴趣标签）
    var onIndex: ((Int) -> Void)?

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize
    @State private var feed = FeedModel()
    @State private var position: Int?
    @State private var visible = false
    @State private var playError: String?
    @State private var loadingPlay = false
    @State private var panel: Panel?
    @State private var heartBurst = 0
    @State private var pip = PiPController()
    @State private var lastSaved: Double = 0
    @State private var retryToken = 0
    #if os(macOS)
    /// 鼠标按住上下拖动时内容跟随位移（松手回弹 / 翻页）
    @State private var dragY: CGFloat = 0
    #endif
    @State private var consumedStart = false
    /// 播放器当前装的是哪一条（id-ep），避免把上一条的画面盖到新页上
    @State private var loadedKey = ""
    /// 有标签栏时的底部安全区（隐藏界面时标签栏一起消失，靠它把控件层钉在原地）
    @State private var safeBottom: CGFloat = 0
    /// 双指缩放（1x ~ 3.5x）与自由平移
    @State private var zoom: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var panBase: CGSize = .zero
    /// 长按上滑锁定的 2.0x
    @State private var boostLocked = false
    /// 根视图尺寸（缩放铺满 / 平移夹取用）
    @State private var viewSize: CGSize = .zero
    /// 左右滑动调进度：拖动中的目标时间（nil 表示没在拖）
    @State private var scrub: Double?
    /// 开始拖时的播放位置
    @State private var scrubStart: Double?
    /// 真卡住了才显示中间的转圈（换条后的前 2.5 秒不显示）
    @State private var slowLoad = false
    @State private var slowToken = 0
    /// 这次播放已经自动切过几次线路（防止来回跳）
    @State private var autoLineTries = 0
    @State private var switchingLine = false
    @FocusState private var focused: Bool

    enum Panel: String, Identifiable { case episodes, comments, info; var id: String { rawValue } }

    /// 横屏看片：只在三个播放标签页里隐藏标签栏
    private var landscapeFeed: Bool {
        guard vSize == .compact else { return false }
        switch app.tab {
        case .rec, .hot, .latest: return true
        default: return false
        }
    }

    /// 精简控制条时才需要这个入口（iPad 与全屏的控制条自带静音键）
    private var showsUnmute: Bool {
        #if os(iOS)
        return app.muted && !app.immersive && !app.clean && (hSize == .compact || vSize == .compact)
        #else
        return false
        #endif
    }

    private var engine: PlayerEngine { app.player }
    private var index: Int { position ?? startIndex }
    private var currentId: Int { ids.indices.contains(index) ? ids[index] : 0 }
    private var currentEp: Int { feed.ep(currentId) }
    private var detail: VideoDetail? { feed.detail(currentId) }

    private struct PlayKey: Hashable { var id: Int; var ep: Int; var visible: Bool; var retry: Int }

    var body: some View {
        ZStack(alignment: .bottom) {
            pages
            scrim
            controls
        }
        .background { Color.black.ignoresSafeArea() }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { v in
            if !app.clean { safeBottom = v }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { s in
            if s != viewSize { viewSize = s }
        }
        .overlay(alignment: .top) {
            if mode == .context, !app.immersive {
                contextBar
                    .offset(y: app.clean ? -80 : 0)
                    .opacity(app.clean ? 0 : 1)
                    .allowsHitTesting(!app.clean)
                    .animation(.smooth(duration: 0.3), value: app.clean)
            }
        }
        #if os(macOS)
        // 顶部那条黑色遮罩就是窗口工具栏的底色：让它透明、标题去掉，画面直接顶到窗口上沿
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar(removing: .title)
        #endif
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        // 只在播放页声明隐藏；平时不声明 .visible，否则后台常驻的首页 FeedView
        // 会和播放页的 .hidden 互相覆盖，标签栏就会反复显隐（上下闪）。
        // 单击只切播放 / 暂停，绝不改标签栏可见性，否则会出现「闪一下 + 突然全屏」。
        // 横屏（iPhone 竖向 compact）不显示标签栏：横过来就是看片，
        // 转回竖屏自动恢复；分类 / 我的 这类竖屏页面不受影响，横屏时仍能导航。
        .modifier(HideTabBar(hidden: mode == .context || app.immersive || app.clean || landscapeFeed))
        .statusBarHidden(app.immersive || app.clean)
        .persistentSystemOverlays(app.immersive || app.clean ? .hidden : .automatic)
        #endif
        .sheet(item: $panel) { p in panelView(p) }
        #if os(macOS)
        // macOS 不走 focusable/focused：可聚焦视图会把第一次点击吃掉（表现为「点好几下才有反应」），
        // 键盘快捷键改用一个窗口级 keyDown 监听，效果一样但不参与点击命中。
        .background {
            MacKeyCatcher { e in handleKey(e) }
        }
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
        #else
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        #endif
        .onKeyPress(.space) { engine.toggle(); return .handled }
        .onKeyPress(.upArrow) { go(-1); return .handled }
        .onKeyPress(.downArrow) { go(1); return .handled }
        .onKeyPress(.leftArrow) { engine.skip(-5); return .handled }
        .onKeyPress(.rightArrow) { engine.skip(5); return .handled }
        .onKeyPress(.escape) {
            if panel != nil { panel = nil; return .handled }
            if app.immersive { setImmersive(false); return .handled }
            if mode == .context { dismiss(); return .handled }
            return .ignored
        }
        .onAppear {
            if position == nil { position = startIndex }
            if !consumedStart, let e = startEp, ids.indices.contains(startIndex) { feed.episode[ids[startIndex]] = e }
            visible = true
            #if os(iOS)
            focused = true
            #endif
            engine.onEnded = { advanceEpisode() }
            feed.prefetch(ids, around: index)
            if mode == .home, let p = DebugRoute.value,
               ["episodes", "comments", "info", "clean", "paused", "immersive", "landscape", "rotate"].contains(p) {
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    switch p {
                    case "episodes": panel = .episodes
                    case "comments": panel = .comments
                    case "info": panel = .info
                    case "paused": engine.pause()
                    case "immersive": setImmersive(true)
                    case "landscape":
                        #if os(iOS)
                        withAnimation(.smooth) { app.immersive = true }
                        Orientation.request(landscape: true)
                        #endif
                    case "rotate":
                        #if os(iOS)
                        Orientation.request(landscape: true)
                        #endif
                    default: withAnimation(.smooth(duration: 0.32)) { app.clean = true }
                    }
                }
            }
        }
        .onDisappear {
            saveProgress()
            visible = false
            engine.pause()
            app.clean = false
        }
        .onChange(of: app.preloadNext) { _, on in
            if on { warmNext() }
        }
        .onChange(of: position) { old, new in
            guard let new, old != new else { return }
            saveProgress()
            playError = nil
            onIndex?(new)
            feed.prefetch(ids, around: new)
            if new >= ids.count - 3 { onNearEnd?() }
            warmNext()
            // 换一条：缩放、平移、锁定的倍速都回到默认
            zoom = 1; zoomBase = 1; panOffset = .zero; panBase = .zero
            if boostLocked { boostLocked = false; engine.boosted = false }
        }
        .onChange(of: ids.count) { _, _ in feed.prefetch(ids, around: index) }
        .onChange(of: engine.time) { _, t in
            if abs(t - lastSaved) >= 5 { saveProgress() }
        }
        .onChange(of: app.lineSwitchToken) { _, _ in retry() }
        .onChange(of: engine.error) { _, e in
            guard let e else { return }
            playError = e
            switchLineIfNeeded()
        }
        .onChange(of: engine.isReady) { _, ok in
            if ok {
                autoLineTries = 0
                app.lineOK()
                slowLoad = false
                // 主播放器接上了，这才轮到预载下下条
                warmNext()
            }
        }
        .onChange(of: engine.isBuffering) { _, b in
            if b { armSlowLoad() } else { slowLoad = false }
        }
        .task(id: PlayKey(id: currentId, ep: currentEp, visible: visible, retry: retryToken)) {
            await loadPlayback()
        }
    }

    /* ───────────── 内容层 ───────────── */

    /// 视频页：铺满整屏，翻页尺寸也按整屏算
    private var pages: some View {
        GeometryReader { geo in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(ids.enumerated()), id: \.offset) { i, id in
                        page(i: i, id: id, size: geo.size)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .id(i)
                    }
                }
                .scrollTargetLayout()
                #if os(iOS)
                // 放在滚动内容里（而不是 ScrollView 的 background），
                // 这样它的祖先里有 UIScrollView，pan 才挂得上去
                .background {
                    HorizontalSeekGesture(
                        boostActive: engine.boosted,
                        onLock: {
                            guard !boostLocked else { return }
                            boostLocked = true
                            haptic()
                            app.toast("已锁定 2.0x 倍速", .ok)
                        },
                        onBegan: { if engine.duration > 1 { scrubStart = engine.time } },
                        onChanged: { dx in
                            guard let base = scrubStart, engine.duration > 1 else { return }
                            scrub = min(max(0, base + Double(dx) * 0.22), engine.duration)
                        },
                        onEnded: { finishScrub() }
                    )
                }
                #endif
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $position)
            // .never：拖动翻页时也不弹出右侧滚动条（macOS 上 .hidden 仍会闪一下）
            .scrollIndicators(.never)
            .scrollDisabled(app.immersive || zoom > 1.01)
            #if os(macOS)
            // 不再给 ScrollView 叠加手写位移：位移 + 原生分页同时动画时中间会露黑
            .gesture(swipePaging)
            #endif
            .background(.black)
        }
        .ignoresSafeArea()
    }

    /// 底部压暗：从视频简介一直压到屏幕最下沿（包括标签栏后面），
    /// 否则标签栏上下会呈现「一半暗一半不暗」的色差。
    private var scrim: some View {
        GeometryReader { g in
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.30), location: 0.45),
                .init(color: .black.opacity(0.55), location: 0.85),
                .init(color: .black.opacity(0.62), location: 1)
            ], startPoint: .top, endPoint: .bottom)
            .frame(height: min(430, max(210, g.size.height * 0.52)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .opacity(app.clean ? 0 : 1)
        .animation(.smooth(duration: 0.25), value: app.clean)
    }

    /* ───────────── 单页 ───────────── */

    @ViewBuilder
    private func page(i: Int, id: Int, size: CGSize) -> some View {
        // 每一页固定用自己那只播放器：翻页时这里什么都不变，天然不会闪
        surface(i, size)
            .frame(width: size.width, height: size.height)
            .contentShape(.rect)
        // 单击：隐藏 / 唤回全部界面（控件滑出屏幕边缘，视频独自占满）；
        // 双击：暂停 / 继续；长按：2x 倍速。
        .gesture(
            TapGesture(count: 2).onEnded { togglePlay() }
                .exclusively(before: TapGesture().onEnded { toggleChrome() })
        )
        // 长按 2.0x；长按期间上滑 = 锁定 2.0x（松手也不掉速）
        .onLongPressGesture(minimumDuration: 0.45, maximumDistance: 60) {
            engine.boosted = true
            haptic()
        } onPressingChanged: { pressing in
            if !pressing, engine.boosted, !boostLocked { engine.boosted = false }
        }
        // 双指无级缩放 1x ~ 3.5x；放大后单指拖动平移
        .simultaneousGesture(
            MagnifyGesture(minimumScaleDelta: 0.01)
                .onChanged { v in
                    guard visible else { return }
                    zoom = min(3.5, max(1, zoomBase * v.magnification))
                    if zoom <= 1.01 { panOffset = .zero }
                }
                .onEnded { _ in
                    zoomBase = zoom
                    if zoom <= 1.01 { zoom = 1; panOffset = .zero; panBase = .zero }
                }
        )
        // 只有放大之后才吃拖动：没放大时用 .infinity 让翻页手势正常工作
        .simultaneousGesture(
            DragGesture(minimumDistance: zoom > 1.01 ? 2 : .infinity)
                .onChanged { v in
                    guard zoom > 1.01 else { return }
                    panOffset = CGSize(width: panBase.width + v.translation.width,
                                       height: panBase.height + v.translation.height)
                }
                .onEnded { _ in if zoom > 1.01 { clampPan(viewSize) } }
        )
    }

    /// 控件层放在滚动内容之外：遵守安全区（不会钻到 Mac 侧边栏 / iPhone 刘海下面），且只有一份
    @ViewBuilder private var controls: some View {
        ZStack {
            VStack {
                scrubHUD.padding(.top, 64)
                Spacer(minLength: 0)
            }
            stateOverlay
            HeartBurst(trigger: heartBurst)
            zoomShortcuts
            boostLockBadge
            FeedOverlay(
                id: currentId, detail: detail, ep: currentEp, mode: mode, compact: hSize == .compact,
                bottomSafe: safeBottom, pip: pip,
                onLike: like, onFav: fav, onFollow: follow,
                onComments: { panel = .comments }, onEpisodes: { panel = .episodes }, onInfo: { panel = .info },
                onImmersive: { setImmersive(!app.immersive) },
                onNextEp: advanceEpisode
            )
        }
        .overlay(alignment: .top) {
            if engine.boosted {
                Label("2x 倍速播放中", systemImage: "forward.fill")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.45), in: .capsule)
                    .foregroundStyle(.white)
                    .padding(.top, 56)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: engine.boosted)
        .animation(.smooth(duration: 0.25), value: app.clean)
    }

    /// 放大状态下的快捷切换：铺满 / 适应 / 还原
    @ViewBuilder private var zoomShortcuts: some View {
        if zoom > 1.01 {
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    zoomButton("放大铺满") { setZoom(fillZoom(viewSize)) }
                    zoomButton("完整适应") { setZoom(1) }
                    zoomButton("还原缩放") { setZoom(1); panOffset = .zero; panBase = .zero }
                }
                .padding(6)
                .glassEffect(.clear, in: .capsule)
                .padding(.bottom, 132)
            }
            .transition(.opacity)
        }
    }

    private func zoomButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private func setZoom(_ z: CGFloat) {
        withAnimation(.smooth(duration: 0.28)) {
            zoom = min(3.5, max(1, z))
            zoomBase = zoom
            panOffset = .zero
            panBase = .zero
        }
    }

    /// 锁定 2.0x 的提示，点一下解除
    @ViewBuilder private var boostLockBadge: some View {
        if boostLocked {
            VStack {
                Button {
                    boostLocked = false
                    engine.boosted = false
                } label: {
                    Label("2.0x 已锁定", systemImage: "lock.fill")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .glassEffect(.clear.interactive(), in: .capsule)
                .padding(.top, 64)
                Spacer()
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// 视频画面：始终按「视频长宽比」铺进整个画面（fit），
    /// 需要铺满时把整层等比放大到刚好盖住屏幕再裁切 —— 用 scaleEffect 做，
    /// 所以在「完整显示 ↔ 裁切铺满」之间切换是连续的缩放动画，不会硬跳。
    private func surface(_ i: Int, _ size: CGSize) -> some View {
        VideoSurface(player: engine.player(for: i), gravity: .resizeAspect) { layer in
            if i == index { pip.attach(layer) }
        }
        .frame(width: size.width, height: size.height)
        .scaleEffect(zoom, anchor: .center)
        .offset(panOffset)
        .frame(width: size.width, height: size.height)
        .clipped()
        .animation(.smooth(duration: 0.28), value: zoom)
        .animation(.smooth(duration: 0.28), value: panOffset)
    }

    /// 「放大铺满」需要的倍数：max(宽比, 高比) / min(宽比, 高比)
    private func fillZoom(_ size: CGSize) -> CGFloat {
        let ps = engine.presentationSize
        guard size.width > 1, size.height > 1, ps.width > 1, ps.height > 1 else { return 1 }
        let k = max(size.width / ps.width, size.height / ps.height) / min(size.width / ps.width, size.height / ps.height)
        guard k.isFinite else { return 1 }
        return min(max(k, 1), 3.5)
    }

    /// 平移范围：放大后最多能推出去多少
    private func clampPan(_ size: CGSize) {
        let maxX = max(0, (zoom - 1) * size.width / 2)
        let maxY = max(0, (zoom - 1) * size.height / 2)
        panOffset = CGSize(width: min(max(panOffset.width, -maxX), maxX),
                           height: min(max(panOffset.height, -maxY), maxY))
        panBase = panOffset
    }

    /// 松手：真正 seek，并清掉预览
    private func finishScrub() {
        if let t = scrub { engine.seek(to: t) }
        withAnimation(.smooth(duration: 0.18)) { scrub = nil }
        scrubStart = nil
    }

    /// 拖动进度时中间偏上的时间预览
    @ViewBuilder private var scrubHUD: some View {
        if let s = scrub {
            let delta = s - engine.time
            HStack(spacing: 10) {
                Image(systemName: delta < 0 ? "gobackward" : "goforward")
                    .font(.system(size: 15, weight: .semibold))
                Text(Fmt.time(s)).font(.system(size: 20, weight: .semibold).monospacedDigit())
                Text(Fmt.time(engine.duration)).font(.footnote.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 12)
            .glassEffect(.clear, in: .capsule)
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
        }
    }

    @ViewBuilder private var stateOverlay: some View {
        if let playError {
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).symbolRenderingMode(.multicolor)
                Text(playError).font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.white)
                Button("重新加载", systemImage: "arrow.clockwise") { retry() }
                    .buttonStyle(.glassProminent)
            }
            .padding(24)
            .frame(maxWidth: 320)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
        } else if slowLoad, playError == nil, !engine.isPlaying, !engine.isReady || engine.isBuffering {
            // 只在「确实卡住了」才转圈：正常切条的前 2.5 秒不打扰
            ProgressView().controlSize(.large).tint(.white)
                .padding(18)
                .glassEffect(.clear, in: .circle)
        } else if engine.isReady, !engine.isPlaying, !engine.isBuffering {
            Button { engine.play() } label: {
                Image(systemName: "play.fill").font(.system(size: 34)).foregroundStyle(.white)
                    .frame(width: 84, height: 84)
            }
            .buttonStyle(.plain)
            .glassEffect(.clear.interactive(), in: .circle)
            .accessibilityLabel("播放")
            .transition(.scale.combined(with: .opacity))
        }
    }

    @ViewBuilder private var contextBar: some View {
        HStack(spacing: 10) {
            // iOS 隐藏了导航栏，返回按钮由这里提供；
            // macOS 的窗口工具栏已经有系统返回，再放一个就重复了
            #if os(iOS)
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.clear.interactive(), in: .circle)
            .accessibilityLabel("返回")
            #endif
            if !title.isEmpty {
                Text(title).font(.headline).foregroundStyle(.white).lineLimit(1)
                    .shadow(color: .black.opacity(0.45), radius: 6, y: 1)
            }
            Spacer()
            // 竖屏播放页同样只精简到「时间 + 全屏」，静音时在这里补一个取消静音的入口，
            // 省得为了开声音先进全屏；全屏里控制条本来就有静音键，不重复放。
            if showsUnmute {
                CircleGlassButton(symbol: "speaker.slash.fill", label: "取消静音") { app.muted = false }
            }
            Text("\(index + 1) / \(ids.count)")
                .font(.footnote.monospacedDigit()).foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.45), radius: 6, y: 1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .safeAreaPadding(.top, 4)
    }

    /* ───────────── 面板 ───────────── */

    @ViewBuilder private func panelContent(_ p: Panel) -> some View {
        switch p {
        case .episodes:
            EpisodesPanel(detail: detail, current: currentEp) { ep in
                feed.episode[currentId] = ep
                panel = nil
            }
        case .comments:
            CommentsPanel(videoId: currentId, ep: currentEp, total: detail?.comment ?? 0)
        case .info:
            if let d = detail { InfoPanel(detail: d) }
        }
    }

    @ViewBuilder private func panelView(_ p: Panel) -> some View {
        panelContent(p)
            .presentationDetents([.medium, .large])
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            #if os(macOS)
            // macOS 的 sheet 没有系统关闭按钮：在左上角补一个和窗口红绿灯同款的关闭点
            .frame(minWidth: 460, minHeight: 560)
            .overlay(alignment: .topLeading) {
                Button { panel = nil } label: { MacCloseDot() }
                    .buttonStyle(.plain)
                    .padding(.top, 14)
                    .padding(.leading, 14)
                    .help("关闭")
                    .accessibilityLabel("关闭")
            }
            #endif
    }

    /* ───────────── 播放 ───────────── */

    private func loadPlayback() async {
        guard visible, currentId > 0 else { return }
        playError = nil
        loadingPlay = true
        armSlowLoad()
        defer { loadingPlay = false }
        // 详情都取不到，多半是线路不通
        if detail == nil, let e = feed.detailErrors[currentId] {
            playError = e
            switchLineIfNeeded()
            return
        }
        do {
            let info = try await feed.play(currentId, ep: currentEp)
            guard !Task.isCancelled else { return }
            var start: Double = 0
            if !consumedStart, index == startIndex, let t = startTime, (startEp ?? currentEp) == currentEp {
                start = t
            } else if let h = app.progress(currentId), h.ep == currentEp, !h.finished, h.t > 5 {
                start = h.t
            }
            consumedStart = true
            lastSaved = start
            engine.prepare(index: index, source: info.url, key: "\(currentId)-\(currentEp)", start: start, autoplay: true)
            loadedKey = "\(currentId)-\(currentEp)"
            app.addHistory(currentId, ep: currentEp)
            warmNext()
        } catch {
            guard !Task.isCancelled else { return }
            playError = Net.describe(error)
            switchLineIfNeeded()
        }
    }

    /// 换条 / 卡顿时起一个 2.5 秒的宽限计时：到点还没画面才转圈
    private func armSlowLoad() {
        slowLoad = false
        slowToken += 1
        let token = slowToken
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, slowToken == token, !engine.isPlaying else { return }
            slowLoad = true
        }
    }

    /// 播放失败且「自动切换线路」打开时：测速挑一条延迟最低的可用线路，换过去再重试。
    /// 同一段视频最多切两次，避免在两条坏线路之间来回跳。
    private func switchLineIfNeeded() {
        guard !switchingLine else { return }
        switchingLine = true
        Task {
            defer { switchingLine = false }
            guard await app.autoSwitchLine() else { return }
            feed.invalidate(currentId, ep: currentEp)
            autoLineTries += 1
            retry()
        }
    }

    /// 预载下一条视频的开头几秒（设置里的开关控制）
    private func warmNext() {
        guard app.preloadNext, visible, ids.indices.contains(index + 1) else { return }
        let nextId = ids[index + 1]
        let ep = feed.ep(nextId)
        Task {
            guard let info = try? await feed.play(nextId, ep: ep) else { return }
            // 期间可能已经滑到别的条了
            guard !Task.isCancelled, app.preloadNext,
                  ids.indices.contains(index + 1), ids[index + 1] == nextId else { return }
            // 相邻页那只播放器提前把这条装好并停在第一帧：翻过去直接是画面
            engine.prepare(index: index + 1, source: info.url, key: "\(nextId)-\(ep)", autoplay: false)
        }
    }

    private func retry() {
        feed.invalidate(currentId, ep: currentEp)
        engine.stop()
        loadedKey = ""
        playError = nil
        retryToken += 1
    }

    private func saveProgress() {
        guard currentId > 0, engine.duration > 0 else { return }
        lastSaved = engine.time
        app.addHistory(currentId, ep: currentEp, t: engine.time, dur: engine.duration)
    }

    private func advanceEpisode() {
        let total = detail?.epCount ?? 1
        if currentEp < total {
            saveProgress()
            feed.episode[currentId] = currentEp + 1
        } else {
            go(1)
        }
    }

    private func go(_ delta: Int) {
        let next = index + delta
        guard ids.indices.contains(next) else {
            if delta > 0 { onNearEnd?() }
            return
        }
        withAnimation(.smooth) { position = next }
    }

    #if os(macOS)
    /// 鼠标左键拖拽：上下 = 翻页（跟手、松手过阈值翻一页否则回弹），
    /// 左右 = 调进度。两个方向合在一个手势里判断，不会互相抢。
    private var swipePaging: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                let dx = v.translation.width, dy = v.translation.height
                // 长按 2x 期间上滑 = 锁定倍速
                if engine.boosted, !boostLocked, dy < -45 {
                    boostLocked = true
                    haptic()
                    app.toast("已锁定 2.0x 倍速", .ok)
                    return
                }
                if scrubStart != nil || abs(dx) > abs(dy) * 1.3 {
                    if scrubStart == nil { scrubStart = engine.time }
                    if let base = scrubStart, engine.duration > 1 {
                        scrub = min(max(0, base + Double(dx) * 0.22), engine.duration)
                    }
                    return
                }
                let atEdge = (dy > 0 && index == 0) || (dy < 0 && index >= ids.count - 1)
                dragY = atEdge ? dy * 0.22 : dy
            }
            .onEnded { v in
                if scrubStart != nil {
                    finishScrub()
                    withAnimation(.smooth(duration: 0.3)) { dragY = 0 }
                    return
                }
                let t = v.predictedEndTranslation.height
                let canNext = index < ids.count - 1, canPrev = index > 0
                if t < -90, canNext {
                    go(1)
                } else if t > 90, canPrev {
                    go(-1)
                }
                withAnimation(.smooth(duration: 0.3)) { dragY = 0 }
            }
    }
    #endif

    /// 双击：暂停 / 继续
    private func togglePlay() {
        guard visible else { return }
        engine.toggle()
    }

    /// 单击：界面滑出 / 滑回（视频独自占满整屏）
    private func toggleChrome() {
        guard visible else { return }
        withAnimation(.smooth(duration: 0.32)) { app.clean.toggle() }
    }

    /* ───────────── 互动（本地先行，登录后同步上游） ───────────── */

    private func like() {
        guard currentId > 0 else { return }
        let on = app.toggleLike(currentId)
        if on { heartBurst += 1 }
        app.toast(on ? "已加入喜欢" : "已取消喜欢", on ? .heart : .info)
        let id = currentId, ep = currentEp
        if app.requireLogin() { Task { try? await API.like(id, ep: ep, on: on) } }
    }

    private func fav() {
        guard currentId > 0 else { return }
        let on = app.toggleFav(currentId)
        app.toast(on ? "已收藏" : "已取消收藏", on ? .star : .info)
        let id = currentId
        if app.requireLogin() { Task { try? await API.collect(id, on: on) } }
    }

    private func follow() {
        guard let a = detail?.author, a.id > 0 else { return }
        let on = app.toggleFollow(a.id)
        app.toast(on ? "已关注 \(a.name)" : "已取消关注", on ? .ok : .info)
        if app.requireLogin() { Task { try? await API.follow(a.id, on: on) } }
    }

    private func setImmersive(_ on: Bool) {
        if !on { zoom = 1; zoomBase = 1; panOffset = .zero; panBase = .zero }
        withAnimation(.smooth) { app.immersive = on }
        #if os(iOS)
        // 退出时一律请求竖屏，避免旋转锁定后卡在横屏全屏里出不来
        Orientation.request(landscape: on && engine.isLandscapeVideo)
        #else
        if let w = NSApp.keyWindow, w.styleMask.contains(.fullScreen) != on { w.toggleFullScreen(nil) }
        #endif
    }

    #if os(macOS)
    /// 窗口级按键处理（返回 true 表示已消费）
    private func handleKey(_ e: NSEvent) -> Bool {
        switch e.keyCode {
        case 49:  engine.toggle(); return true                     // 空格
        case 126: go(-1); return true                              // ↑
        case 125: go(1); return true                               // ↓
        case 123: engine.skip(-5); return true                     // ←
        case 124: engine.skip(5); return true                      // →
        case 53:                                                   // esc
            if panel != nil { panel = nil; return true }
            if app.immersive { setImmersive(false); return true }
            if mode == .context { dismiss(); return true }
            return false
        default: return false
        }
    }
    #endif

    private func haptic() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}

#if os(macOS)
/// 窗口级按键监听：不参与点击命中，所以不会像 focusable 那样吃掉第一次点击。
private struct MacKeyCatcher: NSViewRepresentable {
    var handle: (NSEvent) -> Bool

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.handle = handle
        return v
    }

    func updateNSView(_ v: CatcherView, context: Context) { v.handle = handle }

    static func dismantleNSView(_ v: CatcherView, coordinator: ()) { v.stop() }

    final class CatcherView: NSView {
        var handle: ((NSEvent) -> Bool)?
        private var token: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let handle else { return event }
                // 正在输入文字时不要抢键
                if self.window?.firstResponder is NSTextView { return event }
                return handle(event) ? nil : event
            }
        }

        func stop() {
            if let token { NSEvent.removeMonitor(token) }
            token = nil
        }
    }
}
#endif

#if os(iOS)
/// 全局只装一次的手势控制器。
/// SwiftUI 的 UIViewRepresentable 会被反复重建，之前每重建一次就把 pan 卸掉一次，
/// 结果手势时有时无（这也是「iOS 横滑一直不灵」的真正原因）。
/// 改成单例：pan 装在 keyWindow 上，representable 只负责更新回调。
final class SeekPanController: NSObject, UIGestureRecognizerDelegate {
    static let shared = SeekPanController()

    var onBegan: (() -> Void)?
    var onChanged: ((CGFloat) -> Void)?
    var onEnded: (() -> Void)?
    var onLock: (() -> Void)?
    var boostActive = false
    /// 当前信息流所在滚动视图：用来判断落点是否在信息流里
    weak var container: UIView?

    private weak var pan: UIPanGestureRecognizer?
    private var active = false

    static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }

    func install() {
        if let pan, pan.view != nil { return }
        guard let window = SeekPanController.keyWindow else { return }
        let p = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
        p.delegate = self
        p.cancelsTouchesInView = false
        p.maximumNumberOfTouches = 1
        window.addGestureRecognizer(p)
        pan = p
    }

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let pan = g as? UIPanGestureRecognizer, let view = pan.view else { return false }
        if let container {
            let area = container.convert(container.bounds, to: nil)
            guard area.contains(pan.location(in: nil)) else { return false }
        }
        let t = pan.translation(in: view)
        let v = pan.velocity(in: view)
        if boostActive, t.y < -10, abs(t.y) > abs(t.x) { return true }
        let dx = max(abs(t.x), abs(v.x) * 0.04)
        let dy = max(abs(t.y), abs(v.y) * 0.04)
        guard dx > 2 else { return false }
        return dx > dy * 0.9
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    @objc private func handle(_ pan: UIPanGestureRecognizer) {
        let t = pan.translation(in: pan.view)
        if boostActive {
            if t.y < -45 { onLock?(); active = false; return }
            if abs(t.y) > abs(t.x) { return }
        }
        switch pan.state {
        case .began:
            active = true
            onBegan?()
        case .changed:
            if active { onChanged?(t.x) }
        case .ended, .cancelled, .failed:
            if active { onEnded?(); active = false }
        default:
            break
        }
    }
}

/// 挂载点：只把回调接到单例上，不安装/卸载手势
private struct HorizontalSeekGesture: UIViewRepresentable {
    var boostActive = false
    var onLock: () -> Void = {}
    var onBegan: () -> Void
    var onChanged: (CGFloat) -> Void
    var onEnded: () -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let c = SeekPanController.shared
        c.onBegan = onBegan
        c.onChanged = onChanged
        c.onEnded = onEnded
        c.onLock = onLock
        c.boostActive = boostActive
        var node: UIView? = uiView.superview
        while let cur = node {
            if let s = cur as? UIScrollView { c.container = s; break }
            node = cur.superview
        }
        c.install()
    }
}
#endif

/// 双击 / 点赞的爱心动画
private struct HeartBurst: View {
    let trigger: Int
    @State private var show = false

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 110))
            .foregroundStyle(Theme.heart.gradient)
            .shadow(color: Theme.heart.opacity(0.45), radius: 24)
            .scaleEffect(show ? 1.1 : 0.4)
            .opacity(show ? 1 : 0)
            .allowsHitTesting(false)
            .onChange(of: trigger) { _, _ in
                withAnimation(.spring(duration: 0.35, bounce: 0.5)) { show = true }
                Task {
                    try? await Task.sleep(for: .milliseconds(650))
                    withAnimation(.easeOut(duration: 0.3)) { show = false }
                }
            }
            .accessibilityHidden(true)
    }
}

#if os(iOS)
/// 需要隐藏时才声明 `.toolbarVisibility(.hidden, for: .tabBar)`；
/// 不需要时什么都不声明（保持默认），避免和别的页面声明成 `.visible` 互相覆盖导致标签栏抖动。
struct HideTabBar: ViewModifier {
    let hidden: Bool

    // 只改可见性、不切分支：if/else 会让整个内容视图换掉身份，
    // 播放层被重建（黑一帧）并且动画全部失效。
    // .automatic 表示「不声明」，播放页的 .hidden 依然优先。
    func body(content: Content) -> some View {
        content.toolbar(hidden ? .hidden : .automatic, for: .tabBar)
    }
}
#endif
