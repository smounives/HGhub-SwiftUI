import Foundation
import Synchronization

/// 会话持久化：token + 用户资料存到应用数据目录 session.json（格式与旧版一致，可直接迁移）。
final class SessionStore: Sendable {
    static let shared = SessionStore()

    private struct State: Sendable { var token = ""; var user: JSON = .null }
    private let state: Mutex<State>
    private let file = AppPaths.file("session.json")

    private init() {
        AppPaths.migrate("session.json")
        var s = State()
        if let data = try? Data(contentsOf: file), let j = try? JSON.parse(data) {
            s.token = j["token"].str
            s.user = j["user"]
        }
        state = Mutex(s)
    }

    var token: String? {
        let t = state.withLock { $0.token }
        return t.isEmpty ? nil : t
    }

    var user: JSON { state.withLock { $0.user } }

    func set(token: String, user: JSON) {
        state.withLock { $0 = State(token: token, user: user) }
        persist()
    }

    func updateUser(_ user: JSON) {
        state.withLock { $0.user = user }
        persist()
    }

    func clear() {
        state.withLock { $0 = State() }
        persist()
    }

    private func persist() {
        let snap = state.withLock { $0 }
        let j: JSON = ["token": .string(snap.token), "user": snap.user]
        try? j.data(pretty: true).write(to: file, options: .atomic)
    }
}

/// 业务接口：登录 / 列表 / 详情 / 播放 / 互动。路径与旧版 Rust `api.rs` 一一对应。
enum API {
    private static var net: Net { .shared }
    private static var session: SessionStore { .shared }

    private static func get(_ path: String) async throws -> JSON {
        try await net.edge("GET", path, token: session.token)
    }

    private static func authed(_ method: String, _ path: String, body: JSON? = nil) async throws -> JSON {
        guard let t = session.token else { throw APIError.needLogin }
        return try await net.edge(method, path, body: body, token: t)
    }

    private static func q(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /* ───────────── 会话 ───────────── */

    static func login(username: String, password: String) async throws -> User {
        let data = try await net.edge("POST", "/api/account/loginByPassword",
                                      body: ["username": .string(username), "password": .string(password)])
        guard let token = data["token"].string, !token.isEmpty else { throw APIError.message("登录返回缺少 token") }
        session.set(token: token, user: data["user"])
        return User(data["user"])
    }

    static func register(username: String, password: String, email: String) async throws -> User {
        var body: [String: JSON] = [
            "username": .string(username), "password": .string(password), "confirm_password": .string(password),
        ]
        if !email.trimmingCharacters(in: .whitespaces).isEmpty { body["email"] = .string(email) }
        let data = try await net.edge("POST", "/api/account/registerByPassword", body: .object(body))
        guard let token = data["token"].string, !token.isEmpty else { throw APIError.message("注册返回缺少 token") }
        session.set(token: token, user: data["user"])
        return User(data["user"])
    }

    static func logout() async {
        let t = session.token
        _ = try? await net.edge("POST", "/api/account/logout", token: t)
        session.clear()
    }

    static func me() async throws -> User {
        let me = try await get("/api/account/me")
        if session.token != nil { session.updateUser(me) }
        return User(me)
    }

    /* ───────────── 列表 ───────────── */

    enum FeedSort: String, Sendable { case hot, new }

    static func feed(page: Int, size: Int, sort: FeedSort = .hot) async throws -> Paged<VideoCard> {
        let d = try await get("/api/videos?page=\(page)&size=\(size)&sort=\(sort.rawValue)")
        return Paged(items: d["items"].array.map(VideoCard.init), pagination: Pagination(d["pagination"]))
    }

    static func category(_ cate: String, page: Int, size: Int) async throws -> Paged<VideoCard> {
        let d = try await get("/api/videos/category/\(cate)?page=\(page)&size=\(size)")
        return Paged(items: d["items"].array.map(VideoCard.init), pagination: Pagination(d["pagination"]))
    }

    enum RankKind: String, CaseIterable, Sendable, Identifiable {
        case hot, recommend, potential
        var id: String { rawValue }
        var title: String {
            switch self { case .hot: "热播榜"; case .recommend: "推荐榜"; case .potential: "潜力榜" }
        }
        var symbol: String {
            switch self { case .hot: "flame.fill"; case .recommend: "hand.thumbsup.fill"; case .potential: "chart.line.uptrend.xyaxis" }
        }
    }

    static func rank(_ kind: RankKind) async throws -> [RankItem] {
        let d = try await get("/api/ranks/\(kind.rawValue)")
        return d["items"].array.map(RankItem.init)
    }

    static func search(_ keyword: String, page: Int, size: Int) async throws -> Paged<VideoCard> {
        let d = try await get("/api/search?q=\(q(keyword))&page=\(page)&size=\(size)")
        return Paged(items: d["items"].array.map(VideoCard.init), pagination: Pagination(d["pagination"]))
    }

    static func posts(page: Int, size: Int) async throws -> Paged<Post> {
        let d = try await get("/api/posts?page=\(page)&size=\(size)")
        return Paged(items: d["items"].array.map(Post.init), pagination: Pagination(d["pagination"]))
    }

    /// 帖子详情：详情与 playback 并发拉取。详情里的 `video_url` 自 2026-11 起恒为空，
    /// 视频地址改由 `POST /api/posts/{id}/playback` 的 `videos[].url` 下发，这里合并回去。
    static func post(_ id: Int) async throws -> Post {
        let tok = session.token
        async let detail = get("/api/posts/\(id)")
        async let play = try? net.edge("POST", "/api/posts/\(id)/playback", token: tok)
        var post = Post(try await detail)
        if let p = await play {
            let urls = p["videos"].array.compactMap { $0["url"].string }.filter { !$0.isEmpty }
            if !urls.isEmpty {
                post.videos = urls
                if post.videoURL.isEmpty { post.videoURL = urls[0] }
            }
        }
        return post
    }

    static func video(_ id: Int) async throws -> VideoDetail {
        VideoDetail(try await get("/api/videos/\(id)"))
    }

    /// 播放地址：先走新 POST playback 接口，失败或为空时回退旧 `/play`。
    static func play(_ id: Int, ep: Int) async throws -> PlayInfo {
        var lastError: Error?
        do {
            let d = try await net.edge("POST", "/api/videos/\(id)/episodes/\(ep)/playback", token: session.token)
            let main = d["streams"]["main"].str
            if !main.isEmpty {
                return PlayInfo(id: id, ep: d["ep"].int ?? ep, title: d["title"].str,
                                duration: d["duration"].intValue, url: main, hevc: d["streams"]["hevc"].str)
            }
        } catch {
            lastError = error
        }
        do {
            let d = try await get("/api/videos/\(id)/play?ep=\(ep)&page_texts=0")
            let url = d["video_url"].str
            if !url.isEmpty {
                return PlayInfo(id: id, ep: d["ep_num"].int ?? ep, title: d["title"].str,
                                duration: d["duration"].intValue, url: url, hevc: d["video_url_hevc"].str)
            }
        } catch {
            lastError = lastError ?? error
        }
        if let e = lastError as? APIError, case .needLogin = e { throw e }
        throw APIError.message("暂无播放地址（上游接口未返回 video_url）")
    }

    /* ───────────── 评论 ───────────── */

    static func comments(_ id: Int, ep: Int, page: Int, size: Int) async throws -> CommentPage {
        let d = try await get("/api/videos/\(id)/comments?ep=\(ep)&page=\(page)&size=\(size)")
        return CommentPage(ep: d["ep"].int ?? ep, items: d["items"].array.map(Comment.init),
                           pagination: Pagination(d["pagination"]))
    }

    static func sendComment(_ id: Int, ep: Int, text: String, replyId: Int? = nil) async throws {
        var body: [String: JSON] = ["text": .string(text)]
        let path: String
        if let r = replyId, r > 0 {
            body["reply_id"] = .number(Double(r))
            path = "/api/videos/\(id)/comments"
        } else {
            path = "/api/videos/\(id)/comments?ep=\(ep)"
        }
        _ = try await authed("POST", path, body: .object(body))
    }

    static func postComments(_ id: Int, page: Int, size: Int) async throws -> CommentPage {
        let d = try await get("/api/posts/\(id)/comments?page=\(page)&size=\(size)")
        return CommentPage(ep: 0, items: d["items"].array.map(Comment.init), pagination: Pagination(d["pagination"]))
    }

    /* ───────────── 互动 ───────────── */

    static func like(_ id: Int, ep: Int, on: Bool) async throws {
        _ = try await authed(on ? "POST" : "DELETE", "/api/videos/\(id)/like?ep=\(ep)")
    }

    static func collect(_ id: Int, on: Bool) async throws {
        _ = try await authed(on ? "POST" : "DELETE", "/api/videos/\(id)/collect")
    }

    static func follow(_ uid: Int, on: Bool) async throws {
        _ = try await authed(on ? "POST" : "DELETE", "/api/users/\(uid)/follow")
    }

    static func postLike(_ id: Int, on: Bool) async throws {
        _ = try await authed(on ? "POST" : "DELETE", "/api/posts/\(id)/like")
    }

    static func postCollect(_ id: Int, on: Bool) async throws {
        _ = try await authed(on ? "POST" : "DELETE", "/api/posts/\(id)/collect")
    }

    /* ───────────── 更新检查 ───────────── */

    static let repo = "smounives/HGhub-SwiftUI"

    struct UpdateInfo: Sendable {
        var current: String
        var latest: String
        var hasUpdate: Bool
        var url: String
        var name: String
        var publishedAt: String
        var notes: String
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func checkUpdate() async throws -> UpdateInfo {
        let current = appVersion
        let fallback = "https://github.com/\(repo)/releases"
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw APIError.message("bad url")
        }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await net.session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 {
            return UpdateInfo(current: current, latest: "", hasUpdate: false, url: fallback, name: "", publishedAt: "", notes: "")
        }
        guard (200..<300).contains(status) else { throw APIError.message("GitHub 返回 HTTP \(status)") }
        let v = try JSON.parse(data)
        let tag = v["tag_name"].str
        let latest = String(tag.drop { $0 == "v" || $0 == "V" })
        return UpdateInfo(
            current: current, latest: latest,
            hasUpdate: !tag.isEmpty && isNewer(tag, than: current),
            url: v["html_url"].string ?? fallback, name: v["name"].str,
            publishedAt: v["published_at"].str, notes: String(v["body"].str.prefix(800)))
    }

    /// 只比较数字段：`v1.2.0` > `1.1.9`；`1.2.0-ios` 的 `-ios` 段按 0 处理。
    static func versionParts(_ v: String) -> [Int] {
        v.trimmingCharacters(in: .whitespaces)
            .drop { $0 == "v" || $0 == "V" }
            .split(whereSeparator: { ".-+".contains($0) })
            .map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
    }

    static func isNewer(_ latest: String, than current: String) -> Bool {
        let a = versionParts(latest), b = versionParts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
