import SwiftUI

/* ───────────── 选集 ───────────── */

struct EpisodesPanel: View {
    let detail: VideoDetail?
    let current: Int
    var onPick: (Int) -> Void

    @Environment(AppModel.self) private var app
    @State private var ascending = true

    private var numbers: [Int] {
        guard let d = detail else { return [] }
        let list = d.episodes.isEmpty ? Array(1...d.epCount) : d.episodes.map(\.epNum)
        return ascending ? list : list.reversed()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if numbers.isEmpty {
                    ContentUnavailableView("暂无剧集", systemImage: "film")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 10)], spacing: 10) {
                        ForEach(numbers, id: \.self) { n in
                            Button { onPick(n) } label: {
                                Text("\(n)")
                                    .font(.body.weight(.semibold).monospacedDigit())
                                    .frame(maxWidth: .infinity, minHeight: 46)
                            }
                            .buttonStyle(n == current ? AnyButtonStyle(.glassProminent) : AnyButtonStyle(.glass))
                            .accessibilityLabel("第 \(n) 集\(n == current ? "，正在播放" : "")")
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("选集")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(ascending ? "倒序" : "正序", systemImage: "arrow.up.arrow.down") { ascending.toggle() }
                }
                ToolbarItem(placement: .status) {
                    Text("共 \(detail?.epCount ?? 0) 集").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// 让 `.glass` / `.glassProminent` 可以按条件切换
struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: PrimitiveButtonStyle>(_ s: S) { make = { AnyView(s.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/* ───────────── 评论 ───────────── */

struct CommentsPanel: View {
    enum Target { case video, post }

    let videoId: Int
    var ep: Int = 1
    var total: Int = 0
    var target: Target = .video

    @Environment(AppModel.self) private var app
    @State private var items: [Comment] = []
    @State private var page = 0
    @State private var pages = 1
    @State private var totalCount = 0
    @State private var loading = false
    @State private var error: String?
    @State private var text = ""
    @State private var sending = false
    @State private var replyTo: Comment?
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                if let error, items.isEmpty {
                    ErrorStateView(message: error) { Task { await load(reset: true) } }
                        .listRowBackground(Color.clear)
                } else if items.isEmpty, !loading {
                    ContentUnavailableView("还没有评论", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("来抢沙发吧"))
                        .listRowBackground(Color.clear)
                }
                ForEach(items) { c in
                    CommentRow(comment: c) { replyTo = c; inputFocused = true }
                        .listRowSeparator(.hidden)
                }
                if !items.isEmpty || loading {
                    LoadMoreFooter(loading: loading, done: page >= pages, count: items.count) { Task { await load() } }
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .navigationTitle(totalCount > 0 ? "\(Fmt.count(totalCount)) 条评论" : "评论")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .safeAreaInset(edge: .bottom) { if target == .video { composer } }
            .task { await load(reset: true) }
        }
    }

    @ViewBuilder private var composer: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                if let r = replyTo {
                    HStack {
                        Text("回复 @\(r.nickname)").font(.caption).foregroundStyle(.secondary)
                        Button("取消", systemImage: "xmark.circle.fill") { replyTo = nil }
                            .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                }
                HStack(spacing: 10) {
                    TextField(app.user == nil ? "登录后参与评论" : "说点什么…", text: $text, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.plain)
                        .focused($inputFocused)
                        .submitLabel(.send)
                        .onSubmit(send)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .glassEffect(.regular, in: .capsule)
                        .disabled(app.user == nil)
                        .onTapGesture { _ = app.requireLogin() }
                    Button(action: send) {
                        Image(systemName: sending ? "ellipsis" : "paperplane.fill")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .symbolEffect(.pulse, isActive: sending)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("发送")
                }
            }
        }
        .padding(.horizontal).padding(.vertical, 10)
    }

    private func load(reset: Bool = false) async {
        if loading { return }
        if !reset, page >= pages { return }
        loading = true
        defer { loading = false }
        let next = reset ? 1 : page + 1
        do {
            let res = target == .video
                ? try await API.comments(videoId, ep: ep, page: next, size: 20)
                : try await API.postComments(videoId, page: next, size: 20)
            if reset { items = res.items } else {
                let known = Set(items.map(\.id))
                items += res.items.filter { !known.contains($0.id) }
            }
            page = next
            pages = res.pagination.pages
            totalCount = res.pagination.total
            error = nil
        } catch {
            self.error = Net.describe(error)
        }
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, app.requireLogin(), !sending else { return }
        sending = true
        let reply = replyTo?.id
        Task {
            defer { sending = false }
            do {
                try await API.sendComment(videoId, ep: ep, text: t, replyId: reply)
                text = ""
                replyTo = nil
                inputFocused = false
                app.toast("评论已发送", .ok)
                await load(reset: true)
            } catch {
                app.toast(Net.describe(error), .info)
            }
        }
    }
}

private struct CommentRow: View {
    let comment: Comment
    var onReply: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(url: comment.avatar, name: comment.nickname, color: comment.avatarColor, size: 36)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(comment.nickname).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    if comment.isPinned {
                        Text("置顶").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: .capsule)
                    }
                }
                Text(comment.text).font(.body).textSelection(.enabled)
                HStack(spacing: 14) {
                    Text([comment.time, comment.ipRegion].filter { !$0.isEmpty }.joined(separator: " · "))
                    Button("回复", action: onReply).buttonStyle(.plain).fontWeight(.semibold)
                    Spacer()
                    Label(Fmt.count(comment.likeCount), systemImage: comment.liked ? "heart.fill" : "heart")
                        .foregroundStyle(comment.liked ? Theme.heart : .secondary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if !comment.replies.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(comment.replies) { r in
                            Text("\(Text(r.nickname).fontWeight(.semibold))：\(r.text)")
                                .font(.subheadline)
                        }
                        if comment.replyCount > comment.replies.count {
                            Text("共 \(comment.replyCount) 条回复").font(.caption).foregroundStyle(.tint)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.fill.quaternary, in: .rect(cornerRadius: 12))
                } else if comment.replyCount > 0 {
                    Text("\(comment.replyCount) 条回复").font(.caption).foregroundStyle(.tint)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/* ───────────── 简介 ───────────── */

struct InfoPanel: View {
    let detail: VideoDetail
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 16) {
                        Cover(url: detail.cover)
                            .frame(width: 110, height: 146)
                            .clipShape(.rect(cornerRadius: 16, style: .continuous))
                        VStack(alignment: .leading, spacing: 8) {
                            Text(detail.title).font(.title2.weight(.bold))
                            if detail.score > 0 {
                                Label("\(Fmt.score(detail.score)) 分", systemImage: "star.fill")
                                    .foregroundStyle(Theme.rating).font(.subheadline.weight(.semibold))
                            }
                            Text([detail.categoryName, detail.isFinished ? "已完结 · \(detail.epCount) 集" : "更新至 \(detail.epCount) 集"]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                        GridRow {
                            stat("热度", detail.hot, "flame.fill")
                            stat("点赞", detail.like, "heart.fill")
                            stat("收藏", detail.collect, "star.fill")
                            stat("评论", detail.comment, "bubble.right.fill")
                        }
                    }
                    if !detail.tags.isEmpty { TagChips(tags: detail.tags) }
                    Text(detail.description.isEmpty ? "暂无简介" : detail.description)
                        .font(.body).foregroundStyle(.secondary).textSelection(.enabled)
                    if detail.author.id > 0 {
                        HStack(spacing: 12) {
                            Avatar(name: detail.author.name, size: 44)
                            VStack(alignment: .leading) {
                                Text(detail.author.name).font(.headline)
                                Text("\(Fmt.count(detail.author.followers)) 粉丝").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(app.isFollowing(detail.author.id) ? "已关注" : "关注") {
                                let on = app.toggleFollow(detail.author.id)
                                app.toast(on ? "已关注 \(detail.author.name)" : "已取消关注", on ? .ok : .info)
                                let uid = detail.author.id
                                if app.requireLogin() { Task { try? await API.follow(uid, on: on) } }
                            }
                            .buttonStyle(.glassProminent)
                        }
                        .padding(14)
                        .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    }
                }
                .padding()
            }
            .navigationTitle("简介")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }

    private func stat(_ title: String, _ v: Int, _ symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(.tint)
            Text(Fmt.count(v)).font(.headline.monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

/* ───────────── 屏幕方向（iOS） ───────────── */

#if os(iOS)
enum Orientation {
    @MainActor static func request(landscape: Bool) {
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
                ?? UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let mask: UIInterfaceOrientationMask = landscape ? .landscape : .portrait
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: scene.traitCollection.userInterfaceIdiom == .pad ? .all : mask)) { _ in }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
#endif
