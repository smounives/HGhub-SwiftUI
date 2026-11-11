import SwiftUI

/// 分类总览：排行榜入口 + 4 个频道横滑行 + 吃瓜帖子行
struct CategoryView: View {
    @Environment(AppModel.self) private var app
    @State private var rows: [String: [VideoCard]] = [:]
    @State private var posts: [Post] = []
    @State private var loaded = false

    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            if hSize == .regular {
                PageHeaderRow("分类", maxWidth: 980) {
                    CircleGlassButton(symbol: "magnifyingglass", label: "搜索") { app.push(.search) }
                }
            } else {
                PageHeader("分类")
            }
            #endif
            content
        }
        .background(Theme.background)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topTrailing) {
            if hSize != .regular {
                CircleGlassButton(symbol: "magnifyingglass", label: "搜索") { app.push(.search) }
                    .chromeCorner()
            }
        }
        #else
        .navigationTitle("分类")
        #endif
        .task { if !loaded { await load() } }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                #if !os(macOS)
                Button { app.push(.ranks) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "trophy.fill")
                            .font(.title2)
                            .foregroundStyle(.primary)
                            .frame(width: 52, height: 52)
                            .glassEffect(.regular, in: .rect(cornerRadius: 16))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("排行榜").font(.headline)
                            Text("热播榜 · 推荐榜 · 潜力榜").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
                #endif

                ForEach(Channel.all) { c in channelRow(c) }

                postsRow
            }
            .padding(.vertical)
            // 和标题行同宽并居中（iPad 上不再一边堆满）
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .refreshable { await load() }
    }

    @ViewBuilder private func channelRow(_ c: Channel) -> some View {
        let list = rows[c.cate] ?? []
        VStack(alignment: .leading, spacing: 12) {
            Button { app.push(.channel(c)) } label: {
                HStack(spacing: 12) {
                    Image(systemName: c.symbol)
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular, in: .rect(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).font(.title3.weight(.bold))
                        Text(c.desc).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label("全部", systemImage: "chevron.right")
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal)

            #if os(macOS)
            // macOS：按窗口宽度自适应列数，整段铺开，不再单行左右滑
            if list.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 16, alignment: .top)], spacing: 18) {
                    ForEach(0..<8, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 14).fill(.quaternary).aspectRatio(3 / 4, contentMode: .fit)
                    }
                }
                .padding(.horizontal)
            } else {
                AdaptiveGrid(items: list, minWidth: 150) { v in
                    Button { app.open(list.map(\.id), at: list.firstIndex(of: v) ?? 0, title: c.name) } label: {
                        PosterCard(video: v, progress: app.progress(v.id))
                    }
                    .pressable()
                }
                .padding(.horizontal)
            }
            #else
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    if list.isEmpty {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 14).fill(.quaternary).frame(width: 132, height: 176)
                        }
                    }
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, v in
                        Button { app.open(list.map(\.id), at: i, title: c.name) } label: {
                            PosterCard(video: v, progress: app.progress(v.id), width: 132)
                        }
                        .pressable()
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.never)
            #endif
        }
    }

    @ViewBuilder private var postsRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { app.push(.posts) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "newspaper.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular, in: .rect(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("吃瓜爆料").font(.title3.weight(.bold))
                        Text("热点事件 · 图文与视频").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label("全部", systemImage: "chevron.right").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    if posts.isEmpty {
                        Text(loaded ? "暂无内容" : "加载中…").font(.footnote).foregroundStyle(.tertiary)
                            .frame(height: 150)
                    }
                    ForEach(posts) { p in
                        Button { app.push(.post(p.id)) } label: { PostCard(post: p, width: 240) }
                            .pressable()
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.never)
        }
    }

    private func load() async {
        async let posts = try? API.posts(page: 1, size: 8).items
        let result = await withTaskGroup(of: (String, [VideoCard]).self) { g in
            for c in Channel.all {
                #if os(macOS)
                let n = 18
                #else
                let n = 8
                #endif
                g.addTask { (c.cate, (try? await API.category(c.cate, page: 1, size: n).items) ?? []) }
            }
            var out: [String: [VideoCard]] = [:]
            for await (k, v) in g { out[k] = v }
            return out
        }
        rows = result
        self.posts = await posts ?? []
        loaded = true
    }
}

/* ───────────── 单频道 ───────────── */

struct ChannelView: View {
    let channel: Channel
    @Environment(AppModel.self) private var app
    @State private var items: [VideoCard] = []
    @State private var page = 0
    @State private var pages = 1
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            if let error, items.isEmpty {
                ErrorStateView(message: error) { reset() }
            } else {
                AdaptiveGrid(items: items) { v in
                    Button { app.open(items.map(\.id), at: items.firstIndex(of: v) ?? 0, title: channel.name) } label: {
                        PosterCard(video: v, progress: app.progress(v.id))
                    }
                    .pressable()
                }
                .padding(.horizontal)
                LoadMoreFooter(loading: loading, done: page >= pages, count: items.count) { Task { await load() } }
            }
        }
        .navigationTitle(channel.name)
        .navigationSubtitleCompat(channel.desc)
        .refreshable { reset() }
        .task { if items.isEmpty { await load() } }
    }

    private func reset() {
        items = []; page = 0; pages = 1; error = nil
        Task { await load() }
    }

    private func load() async {
        guard !loading, page < pages else { return }
        loading = true
        defer { loading = false }
        do {
            let res = try await API.category(channel.cate, page: page + 1, size: 24)
            let known = Set(items.map(\.id))
            items += res.items.filter { !known.contains($0.id) }
            page += 1
            pages = res.pagination.pages
            error = nil
        } catch {
            self.error = Net.describe(error)
        }
    }
}

extension View {
    @ViewBuilder func navigationSubtitleCompat(_ s: String) -> some View {
        #if os(macOS)
        self.navigationSubtitle(s)
        #else
        self.navigationSubtitle(s)
        #endif
    }
}
