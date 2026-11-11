import SwiftUI

/// 首页：推荐（客户端加权随机）/ 热门（sort=hot）/ 最新（sort=new）
struct HomeView: View {
    enum FeedTab: String, CaseIterable, Identifiable {
        case rec, hot, new
        var id: String { rawValue }
        var title: String { switch self { case .rec: "推荐"; case .hot: "热门"; case .new: "最新" } }
        var symbol: String { switch self { case .rec: "sparkles"; case .hot: "flame.fill"; case .new: "clock.fill" } }
        /// macOS 侧栏中对应的条目
        var appTab: AppTab { switch self { case .rec: .rec; case .hot: .hot; case .new: .latest } }
    }

    /// 非 nil 时（macOS 侧栏）固定显示该 Feed，不再显示顶部浮动切换
    private let feed: FeedTab?

    init(feed: FeedTab? = nil) {
        self.feed = feed
        _tab = State(initialValue: feed ?? .rec)
    }

    /// 侧栏切走后移除 FeedView，停止后台播放
    private var isActive: Bool { feed.map { app.tab == $0.appTab } ?? true }

    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var tab: FeedTab
    @State private var items: [VideoCard] = []
    @State private var loading = false
    @State private var done = false
    @State private var error: String?
    @State private var epoch = 0
    @State private var page = 1
    @State private var pool: [VideoCard] = []
    @State private var seen = Set<Int>()
    @State private var watchedTags: [String: Double] = [:]
    @State private var ticket = 0
    @Namespace private var tabGlass

    private let batch = 12

    private var navTitle: String {
        #if os(macOS)
        return feed == .rec ? "首页" : (feed?.title ?? "")
        #else
        return ""
        #endif
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.background.ignoresSafeArea()
            if !items.isEmpty {
                if isActive {
                    FeedView(ids: items.map(\.id), mode: .home, onNearEnd: { loadMore() }, onIndex: track)
                        .id("\(tab.rawValue)-\(epoch)")
                }
            } else if let error {
                ErrorStateView(message: error) { reload() }
                    .environment(\.colorScheme, .dark)
            } else {
                ProgressView().controlSize(.large).tint(.white)
            }

            if feed == nil, !app.clean, !app.immersive { topBar }
        }
        .navigationTitle(navTitle)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        // 自动切线路成功后（token 变）立刻重新拉取
        .onChange(of: app.lineSwitchToken) { _, _ in reload() }
        .task(id: isActive) {
            guard isActive else { return }
            if feed == nil {
                if DebugRoute.is("hot") { tab = .hot } else if DebugRoute.is("new") { tab = .new }
            }
            if items.isEmpty, !loading { reload() }
        }
        #if os(iOS)
        // 首页 / 热门 / 最新 都隐藏了导航栏，搜索入口浮在右上角
        .overlay(alignment: .topTrailing) {
            if !app.clean, !app.immersive {
                if hSize == .compact {
                    CircleGlassButton(symbol: "magnifyingglass", label: "搜索") { app.push(.search) }
                        .chromeCorner()
                } else {
                    // iPad：还是同一个圆形玻璃按钮，只是和顶部标签栏对齐
                    CircleGlassButton(symbol: "magnifyingglass", label: "搜索") { app.push(.search) }
                        .padding(.top, 2)
                        .padding(.trailing, ChromeMetric.trailing)
                }
            }
        }
        #endif
    }

    /* ───────────── 顶栏：玻璃分段 + 静音 / 搜索 ───────────── */

    @ViewBuilder private var topBar: some View {
        ZStack {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 2) {
                    ForEach(FeedTab.allCases) { t in
                        Button {
                            guard t != tab else { return }
                            withAnimation(.bouncy(duration: 0.4)) { tab = t }
                            switchTab()
                        } label: {
                            Label(t.title, systemImage: t.symbol)
                                .font(.subheadline.weight(t == tab ? .bold : .medium))
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(t == tab ? Color.white : Color.white.opacity(0.72))
                                .padding(.horizontal, 14)
                                .frame(height: 36)
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(t == tab ? .regular.tint(Theme.selection).interactive() : .identity, in: .capsule)
                        .glassEffectID(t == tab ? "thumb" : t.rawValue, in: tabGlass)
                        .accessibilityAddTraits(t == tab ? [.isSelected, .isButton] : .isButton)
                    }
                }
                .padding(3)
                .glassEffect(.clear, in: .capsule)
            }

            #if os(iOS)
            if hSize == .compact {
            HStack {
                Spacer()
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        Button { app.muted.toggle() } label: {
                            Image(systemName: app.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .contentTransition(.symbolEffect(.replace))
                                .frame(width: 40, height: 40)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.clear.interactive(), in: .circle)
                        .accessibilityLabel(app.muted ? "取消静音" : "静音")
                    }
                }
            }
            .padding(.trailing, 14)
            }
            #endif
        }
        .foregroundStyle(.white)
        .padding(.top, 6)
        .environment(\.colorScheme, .dark)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /* ───────────── 数据 ───────────── */

    private func switchTab() {
        ticket += 1
        items = []
        pool = []
        seen = []
        watchedTags = [:]
        page = 1
        done = false
        error = nil
        loading = false
        epoch += 1
        reload()
    }

    private func reload() {
        error = nil
        done = false
        loading = false          // 允许强制重来（自动切换线路后要立刻重试）
        if tab == .rec { loadRec(replace: true) } else { loadPage(1, replace: true) }
    }

    private func loadMore() {
        guard !loading, !done else { return }
        if tab == .rec { loadRec(replace: false) } else { loadPage(page + 1, replace: false) }
    }

    private func append(_ list: [VideoCard], replace: Bool) {
        var base = replace ? [] : items
        let known = Set(base.map(\.id))
        let add = list.filter { !known.contains($0.id) }
        add.forEach { seen.insert($0.id) }
        base += add
        items = base
    }

    private func loadPage(_ p: Int, replace: Bool) {
        guard !loading else { return }
        loading = true
        ticket += 1
        let my = ticket
        let sort: API.FeedSort = tab == .new ? .new : .hot
        Task {
            defer { if my == ticket { loading = false } }
            do {
                let res = try await API.feed(page: p, size: batch, sort: sort)
                guard my == ticket else { return }
                append(res.items, replace: replace && p == 1)
                page = p
                if res.items.isEmpty || p >= res.pagination.pages { done = true }
            } catch {
                guard my == ticket else { return }
                if items.isEmpty { self.error = Net.describe(error) } else { app.toast(Net.describe(error)) }
                // 线路可能是坏的：自动测速换一条再重试
                // 注意要等本轮 loading 复位（defer 在 Task 结束时才跑）再 reload，否则会被 guard 挡掉
                _ = await app.autoSwitchLine()   // 切换成功后由 lineSwitchToken 触发的 reload 接手
            }
        }
    }

    private func refillPool() async throws -> [VideoCard] {
        let p = try await Recommend.pool(size: 100, samples: 2) { page, size in
            try await API.feed(page: page, size: size, sort: .hot)
        }
        pool = p
        return p
    }

    private func loadRec(replace: Bool) {
        guard !loading else { return }
        loading = true
        ticket += 1
        let my = ticket
        Task {
            defer { if my == ticket { loading = false } }
            do {
                var p = pool.isEmpty ? try await refillPool() : pool
                guard my == ticket else { return }
                if p.isEmpty { done = true; return }
                let taste = Recommend.Taste(history: app.history.map(\.id), likes: app.likes, favs: app.favs,
                                            follows: app.follows, watchedTags: watchedTags)
                var picked = Recommend.pick(p, seen: seen, taste: taste, count: batch)
                if picked.isEmpty {
                    // 当前池子刷完了：换一批随机页再试
                    p = try await refillPool()
                    guard my == ticket else { return }
                    picked = Recommend.pick(p, seen: seen, taste: taste, count: batch)
                }
                if picked.isEmpty { done = true; return }
                append(picked, replace: replace)
                // 池子快见底时后台补池
                if p.filter({ !seen.contains($0.id) }).count < batch {
                    Task { _ = try? await refillPool() }
                }
            } catch {
                guard my == ticket else { return }
                if items.isEmpty { self.error = Net.describe(error) } else { app.toast(Net.describe(error)) }
                // 线路可能是坏的：自动测速换一条再重试
                // 注意要等本轮 loading 复位（defer 在 Task 结束时才跑）再 reload，否则会被 guard 挡掉
                _ = await app.autoSwitchLine()   // 切换成功后由 lineSwitchToken 触发的 reload 接手
            }
        }
    }

    /// Feed 每换一条就上报：累积本次会话看过的题材
    private func track(_ i: Int) {
        guard items.indices.contains(i) else { return }
        for t in items[i].tags { watchedTags[t, default: 0] += 0.3 }
        if watchedTags.count > 120 { watchedTags = watchedTags.mapValues { $0 * 0.85 } }
    }
}
