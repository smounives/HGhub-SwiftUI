import AVKit
import SwiftUI

struct PostCard: View {
    let post: Post
    var width: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Cover(url: post.cover)
                .aspectRatio(16 / 10, contentMode: .fit)
                .frame(width: width)
                .clipShape(.rect(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    Label(Fmt.count(post.hot), systemImage: "flame.fill")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .glassEffect(.clear, in: .capsule)
                        .foregroundStyle(.white)
                        .padding(8)
                }
            Text(post.title).font(.subheadline.weight(.semibold)).lineLimit(2, reservesSpace: true)
                .frame(width: width, alignment: .leading)
            if !post.publishTime.isEmpty {
                Text(String(post.publishTime.prefix(10))).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 吃瓜列表
struct PostsView: View {
    @Environment(AppModel.self) private var app
    @State private var items: [Post] = []
    @State private var page = 0
    @State private var pages = 1
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            if let error, items.isEmpty {
                ErrorStateView(message: error) { reset() }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 420), spacing: 16, alignment: .top)], spacing: 20) {
                    ForEach(items) { p in
                        Button { app.push(.post(p.id)) } label: { PostCard(post: p) }.pressable()
                    }
                }
                .padding(.horizontal)
                LoadMoreFooter(loading: loading, done: page >= pages, count: items.count) { Task { await load() } }
            }
        }
        .navigationTitle("吃瓜爆料")
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
            let res = try await API.posts(page: page + 1, size: 20)
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

/// 吃瓜详情：视频（如有）+ 正文 + 点赞 / 收藏 / 评论
struct PostDetailView: View {
    let id: Int
    @Environment(AppModel.self) private var app
    @State private var post: Post?
    @State private var error: String?
    @State private var playing = false
    @State private var liked = false
    @State private var collected = false
    @State private var showComments = false
    @State private var blocks: [ArticleBlock] = []

    var body: some View {
        ScrollView {
            if let post {
                VStack(alignment: .leading, spacing: 18) {
                    media(post)
                    Text(post.title).font(.title2.weight(.bold)).textSelection(.enabled)
                    HStack(spacing: 12) {
                        if let a = post.author { Label(a.name, systemImage: "person.crop.circle") }
                        if !post.publishTime.isEmpty { Text(post.publishTime) }
                        Label(Fmt.count(post.hot), systemImage: "flame")
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                    if !post.tags.isEmpty { TagChips(tags: post.tags) }
                    actions(post)
                    if !post.desc.isEmpty {
                        Text(post.desc).font(.body).foregroundStyle(.secondary)
                    }
                    ArticleView(blocks: blocks)
                }
                .padding()
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            } else if let error {
                ErrorStateView(message: error) { Task { await load() } }
            } else {
                LoadingView()
            }
        }
        .navigationTitle(post?.title ?? "吃瓜")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if let post {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: post.videoURL.isEmpty ? "\(post.title) https://huangguoai.com/post/\(post.id)/" : post.videoURL) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .sheet(isPresented: $showComments) {
            CommentsPanel(videoId: id, total: post?.comment ?? 0, target: .post)
                .presentationDetents([.medium, .large])
                #if os(macOS)
                .frame(minWidth: 460, minHeight: 560)
                #endif
        }
        .onDisappear { app.player.pause() }
        .task { if post == nil { await load() } }
    }

    @ViewBuilder private func media(_ p: Post) -> some View {
        ZStack {
            if playing, p.hasVideo {
                InlinePlayer(url: p.videoURL)
            } else {
                Cover(url: p.cover)
                Button {
                    if p.hasVideo { playing = true } else { app.toast("该帖子没有视频", .info) }
                } label: {
                    Image(systemName: p.hasVideo ? "play.fill" : "doc.richtext")
                        .font(.system(size: 30)).foregroundStyle(.white)
                        .frame(width: 76, height: 76)
                }
                .buttonStyle(.plain)
                .glassEffect(.clear.interactive(), in: .circle)
                .accessibilityLabel(p.hasVideo ? "播放视频" : "图文帖")
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .background(.black)
        .clipShape(.rect(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder private func actions(_ p: Post) -> some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    liked.toggle()
                    let on = liked
                    app.toast(on ? "已点赞" : "已取消点赞", on ? .heart : .info)
                    if app.requireLogin() { Task { try? await API.postLike(id, on: on) } }
                } label: {
                    Label(Fmt.count(p.like + (liked && !p.liked ? 1 : 0)), systemImage: liked ? "heart.fill" : "heart")
                        .foregroundStyle(liked ? Theme.heart : .primary)
                        .contentTransition(.symbolEffect(.replace))
                }
                Button {
                    collected.toggle()
                    let on = collected
                    app.toast(on ? "已收藏" : "已取消收藏", on ? .star : .info)
                    if app.requireLogin() { Task { try? await API.postCollect(id, on: on) } }
                } label: {
                    Label(Fmt.count(p.collect + (collected && !p.collected ? 1 : 0)), systemImage: collected ? "star.fill" : "star")
                        .foregroundStyle(.primary)
                        .contentTransition(.symbolEffect(.replace))
                }
                Button { showComments = true } label: {
                    Label(Fmt.count(p.comment), systemImage: "bubble.right")
                }
            }
            .buttonStyle(.glass)
        }
    }

    private func load() async {
        error = nil
        do {
            let p = try await API.post(id)
            post = p
            liked = p.liked
            collected = p.collected
            blocks = ArticleParser.parse(p.content)
        } catch {
            self.error = Net.describe(error)
        }
    }
}

/// 非信息流场景的内嵌播放器（吃瓜帖子），复用全局引擎与 HLS 代理
struct InlinePlayer: View {
    let url: String
    @Environment(AppModel.self) private var app

    var body: some View {
        let engine = app.player
        ZStack(alignment: .bottom) {
            VideoSurface(player: engine.player)
            if !engine.isReady || engine.isBuffering {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let e = engine.error {
                Text(e).font(.footnote).foregroundStyle(.white).padding()
                    .glassEffect(.regular, in: .rect(cornerRadius: 14))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ControlBar(engine: engine, compact: false, tight: false, pip: PiPController(), epLabel: "",
                       onImmersive: {}, onNextEp: {}, immersive: false)
                .padding(10)
                .environment(\.colorScheme, .dark)
                .foregroundStyle(.white)
        }
        .onAppear {
            engine.onEnded = nil
            engine.load(url)
        }
    }
}
