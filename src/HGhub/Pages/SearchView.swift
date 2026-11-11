import SwiftUI

struct SearchView: View {
    static let hotTags = ["都市", "逆袭", "古风", "系统", "后宫", "校园", "仙侠", "职场", "大男主", "御姐", "脑洞", "奇幻"]

    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var submitted = ""
    @State private var items: [VideoCard] = []
    @State private var page = 0
    @State private var pages = 1
    @State private var total = 0
    @State private var loading = false
    @State private var error: String?
    @State private var hot: [RankItem] = []
    @State private var ticket = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if submitted.isEmpty { discover } else { results }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .navigationTitle("搜索")
        .searchable(text: $query, placement: searchPlacement, prompt: "剧名、标签、演员")
        .searchSuggestions {
            if query.isEmpty {
                ForEach(app.searchHist, id: \.self) { h in
                    Label(h, systemImage: "clock.arrow.circlepath").searchCompletion(h)
                }
            }
        }
        .onSubmit(of: .search) { submit(query) }
        .onChange(of: query) { _, q in if q.isEmpty { submitted = ""; items = [] } }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("排行榜", systemImage: "trophy") { app.push(.ranks) }
            }
        }
        .task {
            if DebugRoute.has(prefix: "search:"), submitted.isEmpty, let q = DebugRoute.argument { submit(q) }
            if hot.isEmpty { hot = (try? await API.rank(.hot)) ?? [] }
        }
    }

    private var searchPlacement: SearchFieldPlacement {
        #if os(iOS)
        .navigationBarDrawer(displayMode: .always)
        #else
        .toolbar
        #endif
    }

    /* ───────────── 发现 ───────────── */

    @ViewBuilder private var discover: some View {
        if !app.searchHist.isEmpty {
            section("搜索历史", trailing: AnyView(Button("清空", role: .destructive) { app.clearSearchHist() }.font(.subheadline))) {
                TagChips(tags: app.searchHist) { submit($0) }
            }
        }

        section("热门标签", trailing: AnyView(
            Button("手气不错", systemImage: "dice") { submit(Self.hotTags.randomElement() ?? "都市") }
                .font(.subheadline)
        )) {
            TagChips(tags: Self.hotTags) { submit($0) }
        }

        section("HG 热榜", trailing: AnyView(Button("完整榜单") { app.push(.ranks) }.font(.subheadline))) {
            if hot.isEmpty {
                LoadingView()
            } else {
                AdaptiveGrid(items: Array(hot.prefix(12)), minWidth: 150) { it in
                    Button {
                        app.open(hot.map(\.videoId), at: hot.firstIndex(of: it) ?? 0, title: "HG 热榜")
                    } label: {
                        RankPoster(rank: it.rank, cover: it.cover, title: it.title,
                                   subtitle: "\(it.categoryName) · \(Fmt.count(it.metricValue))")
                    }
                    .pressable()
                }
            }
        }
    }

    /* ───────────── 结果 ───────────── */

    @ViewBuilder private var results: some View {
        HStack {
            Text("“\(submitted)”").font(.title2.weight(.bold))
            Spacer()
            if total > 0 { Text("\(total) 部").font(.subheadline).foregroundStyle(.secondary) }
        }
        if let error, items.isEmpty {
            ErrorStateView(message: error) { submit(submitted) }
        } else if items.isEmpty, !loading {
            ContentUnavailableView {
                Label("没有找到相关内容", systemImage: "magnifyingglass")
            } description: {
                Text("换个关键词试试")
            } actions: {
                Button("看看热榜") { app.push(.ranks) }.buttonStyle(.glassProminent)
            }
        } else {
            AdaptiveGrid(items: items) { v in
                Button {
                    app.open(items.map(\.id), at: items.firstIndex(of: v) ?? 0, title: "搜索 · \(submitted)")
                } label: { PosterCard(video: v, progress: app.progress(v.id)) }
                .pressable()
            }
            LoadMoreFooter(loading: loading, done: page >= pages, count: items.count) { load() }
        }
    }

    private func section<C: View>(_ title: String, trailing: AnyView? = nil, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.title3.weight(.bold))
                Spacer()
                trailing
            }
            content()
        }
    }

    private func submit(_ q: String) {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        query = t
        submitted = t
        app.addSearch(t)
        items = []
        page = 0
        pages = 1
        total = 0
        error = nil
        loading = false
        ticket += 1
        load()
    }

    private func load() {
        guard !loading, page < pages else { return }
        loading = true
        let my = ticket, kw = submitted, next = page + 1
        Task {
            defer { if my == ticket { loading = false } }
            do {
                let res = try await API.search(kw, page: next, size: 20)
                guard my == ticket else { return }
                let known = Set(items.map(\.id))
                items += res.items.filter { !known.contains($0.id) }
                page = next
                pages = res.pagination.pages
                total = res.pagination.total
            } catch {
                guard my == ticket else { return }
                self.error = Net.describe(error)
            }
        }
    }
}

/* ───────────── 排行榜 ───────────── */

struct RanksView: View {
    @Environment(AppModel.self) private var app
    @State private var kind: API.RankKind = .hot
    @State private var data: [API.RankKind: [RankItem]] = [:]
    @State private var error: String?

    var body: some View {
        Group {
            if let list = data[kind] {
                ScrollView {
                    AdaptiveGrid(items: list, minWidth: 150) { it in
                        Button { app.open(list.map(\.videoId), at: list.firstIndex(of: it) ?? 0, title: kind.title) } label: {
                            RankPoster(rank: it.rank, cover: it.cover, title: it.title,
                                       subtitle: "\(it.metricLabel) \(Fmt.count(it.metricValue)) · 播放 \(Fmt.count(it.play))")
                        }
                        .pressable()
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 20)
                }
                .background(Theme.background)
            } else if let error {
                ErrorStateView(message: error) { Task { await load(force: true) } }
            } else {
                LoadingView()
            }
        }
        .navigationTitle("排行榜")
        .safeAreaInset(edge: .top) {
            Picker("榜单", selection: $kind) {
                ForEach(API.RankKind.allCases) { k in Label(k.title, systemImage: k.symbol).tag(k) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(maxWidth: 520)
        }
        .refreshable { await load(force: true) }
        .task(id: kind) { await load() }
    }

    private func load(force: Bool = false) async {
        if !force, data[kind] != nil { return }
        error = nil
        do { data[kind] = try await API.rank(kind) } catch { self.error = Net.describe(error) }
    }
}
