import SwiftUI

/// 我的：资料卡 + 我的收藏 / 观看历史（本地记录，未登录也展示）
struct ProfileView: View {
    enum Section: String, CaseIterable, Identifiable {
        case fav, history
        var id: String { rawValue }
        var title: String { self == .fav ? "我的收藏" : "观看历史" }
        var symbol: String { self == .fav ? "star.fill" : "clock.fill" }
    }

    @Environment(AppModel.self) private var app
    @State private var section: Section = .fav
    @State private var cards: [Int: VideoDetail] = [:]
    @State private var loading = false
    @State private var confirmLogout = false
    @State private var confirmClear = false

    private var ids: [Int] { section == .fav ? app.favs : app.history.map(\.id) }

    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            if hSize == .regular {
                PageHeaderRow("我的") { headerActions }
            } else {
                PageHeader("我的")
            }
            #endif
            pageBody
        }
        .background(Theme.background)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topTrailing) {
            if hSize != .regular {
                HStack(spacing: ChromeMetric.gap) {
                    if section == .history, !app.history.isEmpty {
                        CircleGlassButton(symbol: "trash", label: "清空观看历史") { confirmClear = true }
                    }
                    CircleGlassButton(symbol: "gearshape", label: "设置") { app.push(.settings) }
                }
                .chromeCorner()
            }
        }
        #else
        .navigationTitle("我的")
        #endif
        .confirmationDialog("退出登录？", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { Task { await app.logout() } }
        } message: {
            Text("本地收藏与观看记录会保留")
        }
        .confirmationDialog("清空全部观看历史？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { app.clearHistory() }
        }
        .task(id: ids.prefix(24).map(String.init).joined(separator: ",")) { await loadCards() }
    }

    /// iPad 标题行右侧：清空历史（仅历史页）+ 设置
    @ViewBuilder private var headerActions: some View {
        HStack(spacing: 2) {
            if section == .history, !app.history.isEmpty {
                CircleGlassButton(symbol: "trash", label: "清空观看历史") { confirmClear = true }
            }
            CircleGlassButton(symbol: "gearshape", label: "设置") { app.push(.settings) }
        }
    }

    private var pageBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                profileCard
                Picker("内容", selection: $section) {
                    ForEach(Section.allCases) { s in Label(s.title, systemImage: s.symbol).tag(s) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                // 分段控件在整列里居中（iPad / Mac 上不会贴左）
                .frame(maxWidth: .infinity)

                content
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            // 内容列给一个舒服的最大宽度，整块在页面里居中；iPad / Mac 的大屏上不再一边堆
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear { if DebugRoute.is("history") { section = .history } }
        .refreshable {
            if app.user != nil, let me = try? await API.me() { app.user = me; app.mergeInteractions(me) }
            await loadCards(force: true)
        }
    }

    @ViewBuilder private var profileCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let u = app.user {
                HStack(spacing: 14) {
                    Avatar(url: u.avatar, name: u.nickname, color: u.avatarColor, size: 54)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(u.nickname).font(.title3.weight(.bold))
                        Text("@\(u.username)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Button("退出", systemImage: "rectangle.portrait.and.arrow.right") { confirmLogout = true }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .controlSize(.large)
                        .accessibilityLabel("退出登录")
                }
                HStack(spacing: 28) {
                    stat("点赞", u.likeCount)
                    stat("收藏", u.collectCount)
                    stat("关注", u.followingCount)
                }
            } else {
                Button { app.loginPresented = true } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 46))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("登录 / 注册").font(.title3.weight(.bold))
                            Text("同步点赞、收藏、关注，参与评论").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 20))
    }

    private func stat(_ t: String, _ v: Int) -> some View {
        Text("\(Text(t).foregroundStyle(.secondary)) \(Text(Fmt.count(v)).fontWeight(.semibold))")
            .font(.caption)
    }

    @ViewBuilder private var content: some View {
        if ids.isEmpty {
            ContentUnavailableView(
                section == .fav ? "还没有收藏" : "还没有观看记录",
                systemImage: section == .fav ? "star" : "clock",
                description: Text(section == .fav ? "在播放页点 ☆ 收藏喜欢的剧" : "看过的剧会出现在这里，并记住进度")
            )
        } else if section == .history {
            AdaptiveGrid(items: Array(app.history.prefix(60)), minWidth: 150) { h in
                let d = cards[h.id]
                Button {
                    let list = app.history.prefix(60).map(\.id)
                    app.open(Array(list), at: list.firstIndex(of: h.id) ?? 0, title: "观看历史",
                             startEp: h.ep, startTime: h.finished ? 0 : h.t)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Cover(url: d?.cover ?? "")
                            .aspectRatio(3 / 4, contentMode: .fit)
                            .clipShape(.rect(cornerRadius: 14, style: .continuous))
                            .overlay(alignment: .bottom) {
                                if h.dur > 0 {
                                    GeometryReader { g in
                                        Capsule().fill(.tint).frame(width: g.size.width * h.fraction)
                                    }
                                    .frame(height: 3)
                                }
                            }
                        Text(d?.title ?? "加载中…").font(.subheadline.weight(.semibold)).lineLimit(2, reservesSpace: true)
                        Text("第 \(h.ep) 集" + (h.dur > 0 ? " · \(Fmt.time(h.t)) / \(Fmt.time(h.dur))" : "") + " · " + relative(h.at))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .pressable()
                .contextMenu {
                    Button("从记录中移除", systemImage: "trash", role: .destructive) {
                        app.history.removeAll { $0.id == h.id }
                    }
                }
            }
        } else {
            let list = Array(app.favs.prefix(60))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 16, alignment: .top)], spacing: 20) {
                ForEach(list, id: \.self) { id in
                    Button { app.open(list, at: list.firstIndex(of: id) ?? 0, title: "我的收藏") } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Cover(url: cards[id]?.cover ?? "")
                                .aspectRatio(3 / 4, contentMode: .fit)
                                .clipShape(.rect(cornerRadius: 14, style: .continuous))
                            Text(cards[id]?.title ?? "加载中…").font(.subheadline.weight(.semibold)).lineLimit(2, reservesSpace: true)
                        }
                    }
                    .pressable()
                    .contextMenu {
                        Button("取消收藏", systemImage: "star.slash", role: .destructive) {
                            app.toggleFav(id)
                            if app.requireLogin() { Task { try? await API.collect(id, on: false) } }
                        }
                    }
                }
            }
        }
        if loading, cards.isEmpty { LoadingView() }
    }

    private func relative(_ ms: Double) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f.localizedString(for: Date(timeIntervalSince1970: ms / 1000), relativeTo: .now)
    }

    private func loadCards(force: Bool = false) async {
        let need = ids.prefix(24).filter { force || cards[$0] == nil }
        guard !need.isEmpty else { return }
        loading = true
        defer { loading = false }
        await withTaskGroup(of: (Int, VideoDetail?).self) { g in
            for id in need { g.addTask { (id, try? await API.video(id)) } }
            for await (id, d) in g { if let d { cards[id] = d } }
        }
    }
}
