import Foundation
import Observation
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// 观看记录：看到第几集、第几秒（`dur` 用来判断是否已看完）
struct WatchProgress: Codable, Hashable, Sendable, Identifiable {
    var id: Int
    var ep: Int
    var t: Double
    var dur: Double
    var at: Double

    var finished: Bool { dur > 0 && t >= dur - 5 }
    var fraction: Double { dur > 0 ? min(1, max(0, t / dur)) : 0 }
}

struct Toast: Identifiable, Equatable {
    enum Kind { case ok, heart, star, info }
    let id = UUID()
    var message: String
    var kind: Kind

    var symbol: String {
        switch kind {
        case .ok: "checkmark.circle.fill"
        case .heart: "heart.fill"
        case .star: "star.fill"
        case .info: "info.circle.fill"
        }
    }
}

enum AppTab: String, Hashable, CaseIterable {
    /// iOS / iPadOS：首页（顶部浮动切换 推荐 / 热门 / 最新）
    case home
    /// macOS：侧栏直接列出 推荐 / 热门 / 最新 / 排行榜 / 设置
    case rec, hot, latest, ranks, settings
    case search, category, profile
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var title: String {
        switch self { case .system: "跟随系统"; case .dark: "深色"; case .light: "浅色" }
    }
    var scheme: ColorScheme? {
        switch self { case .system: nil; case .dark: .dark; case .light: .light }
    }
}

/// 播放页上下文：一组 id + 起始位置（与旧版 FeedContext 对应）
struct FeedRoute: Hashable, Identifiable {
    enum Kind: Hashable { case video, post }
    var ids: [Int]
    var index: Int
    var title: String
    var kind: Kind = .video
    var startEp: Int?
    var startTime: Double?
    var id: String { "\(title)|\(ids.first ?? 0)|\(index)|\(ids.count)" }
}

/// 单个标签页的导航路径
@MainActor
@Observable
final class TabNav {
    var path: [Route] = []
}

enum Route: Hashable {
    case feed(FeedRoute)
    case channel(Channel)
    case ranks
    case settings
    case search
    case posts
    case post(Int)
}

struct Channel: Hashable, Identifiable, Sendable {
    var cate: String
    var name: String
    var desc: String
    var symbol: String
    var id: String { cate }

    static let all: [Channel] = [
        Channel(cate: "ai-duanju", name: "AI成人短剧", desc: "高能反转 · 一口气看完", symbol: "film.stack"),
        Channel(cate: "ai-manju", name: "AI成人漫剧", desc: "国创漫剧 · 每周更新", symbol: "paintbrush.pointed"),
        Channel(cate: "ai-huanlian", name: "AI换脸", desc: "换脸演绎 · 全新剧情", symbol: "theatermasks"),
        Channel(cate: "ai-mogai", name: "AI魔改", desc: "魔改名场面 · 脑洞大开", symbol: "wand.and.stars"),
    ]
}

/// 全局状态：本地收藏 / 点赞 / 关注 / 观看记录 / 搜索历史 + 登录态 + 导航。
@MainActor
@Observable
final class AppModel {
    private struct Persist: Codable {
        var likes: [Int] = []
        var favs: [Int] = []
        var history: [WatchProgress] = []
        var follows: [Int] = []
        var muted = true
        var volume: Float = 0.7
        var searchHist: [String] = []
        var rate: Float = 1
        /// 可选型：老版本存档里没有这个键，解码成 nil 再取默认值，不会把整份状态丢掉
        var preloadNext: Bool?
        var autoLine: Bool?
        var ipv6First: Bool?
        var keepAlive: Bool?
        var fastFail4xx: Bool?
        var strictSecurity: Bool?
    }

    private static let storeURL = AppPaths.file("library.json")

    var likes: [Int] = [] { didSet { save() } }
    var favs: [Int] = [] { didSet { save() } }
    var history: [WatchProgress] = [] { didSet { save() } }
    var follows: [Int] = [] { didSet { save() } }
    var muted = true { didSet { save(); player.muted = muted } }
    var volume: Float = 0.7 { didSet { save(); player.volume = volume } }
    var searchHist: [String] = [] { didSet { save() } }
    var rate: Float = 1 { didSet { save(); player.baseRate = rate } }
    /// 播放视频流时预载下一条（开关）
    var preloadNext = true { didSet { save() } }
    /// 每成功自动切一次线路 +1，页面可以据此重新拉数据
    private(set) var lineSwitchToken = 0
    @ObservationIgnored private var switchingLine = false
    @ObservationIgnored private var lineTries = 0
    /// 上次自动切线路的时间（30 秒冷却）
    @ObservationIgnored private var lastAutoSwitch: Date?
    /// 当前线路播放失败时自动切到延迟最低的可用线路
    var autoLine = true { didSet { save() } }
    /// IPv6 优先（DNS 优先解析 AAAA，选线路时优先挑有 IPv6 的）
    var ipv6First = false { didSet { save(); pushPolicy() } }
    /// 连接池复用：30 秒内不重建会话，避免反复 TLS 握手
    var keepAlive = true { didSet { save(); pushPolicy() } }
    /// 非重试型 4xx 快速失败
    var fastFail4xx = true { didSet { save(); pushPolicy() } }
    /// 严格安全模式：SSRF 防护 + HTML 净化（默认关闭，需要时在「线路 → 网络加固」里开）
    var strictSecurity = false { didSet { save(); pushPolicy() } }

    var user: User?
    var loginPresented = false
    var tab: AppTab = .rec
    /// 每个标签页一个独立的导航栈（引用类型，`NavigationStack` 直接绑定 `$nav.path`）
    @ObservationIgnored let navs: [AppTab: TabNav] = Dictionary(uniqueKeysWithValues: AppTab.allCases.map { ($0, TabNav()) })
    var toasts: [Toast] = []
    /// 清屏：单击视频隐藏所有控件
    var clean = false
    /// 正在全屏播放（iOS 隐藏 Tab 栏 / macOS 进入窗口全屏）
    var immersive = false
    var lineBase: String = Net.shared.base

    @ObservationIgnored @AppStorage("appearance") private var appearanceRaw = Appearance.dark.rawValue
    var appearance: Appearance = .dark {
        didSet { appearanceRaw = appearance.rawValue; applyAppearance() }
    }

    /// macOS 的 TabView 侧边栏不一定响应 preferredColorScheme，直接设置应用级外观
    func applyAppearance() {
        #if os(macOS)
        switch appearance {
        case .system: NSApp?.appearance = nil
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        }
        #endif
    }

    let player: PlayerEngine
    @ObservationIgnored private var loading = true

    init() {
        var p = Persist()
        if let d = try? Data(contentsOf: Self.storeURL), let v = try? JSONDecoder().decode(Persist.self, from: d) {
            p = v
        }
        player = PlayerEngine(muted: p.muted, volume: p.volume)
        likes = p.likes
        favs = p.favs
        history = p.history.sorted { $0.at > $1.at }
        follows = p.follows
        muted = p.muted
        volume = p.volume
        searchHist = p.searchHist
        rate = p.rate
        preloadNext = p.preloadNext ?? true
        autoLine = p.autoLine ?? true
        ipv6First = p.ipv6First ?? false
        keepAlive = p.keepAlive ?? true
        fastFail4xx = p.fastFail4xx ?? true
        strictSecurity = p.strictSecurity ?? false
        player.baseRate = p.rate
        appearance = Appearance(rawValue: appearanceRaw) ?? .dark
        pushPolicy()
        let raw = SessionStore.shared.user
        if SessionStore.shared.token != nil, raw["id"].intValue > 0 { user = User(raw) }
        loading = false
    }

    /// 把设置推给网络层
    func pushPolicy() {
        Net.shared.policy = Net.Policy(ipv6First: ipv6First, keepAlive: keepAlive,
                                       fastFail4xx: fastFail4xx, strictSecurity: strictSecurity)
    }

    private func save() {
        guard !loading else { return }
        let p = Persist(likes: likes, favs: favs, history: history, follows: follows, muted: muted,
                        volume: volume, searchHist: searchHist, rate: rate, preloadNext: preloadNext, autoLine: autoLine,
                        ipv6First: ipv6First, keepAlive: keepAlive,
                        fastFail4xx: fastFail4xx, strictSecurity: strictSecurity)
        if let d = try? JSONEncoder().encode(p) { try? d.write(to: Self.storeURL, options: .atomic) }
    }

    /* ───────────── 线路自动切换 ───────────── */

    /// 网络失败时调用：测速挑一条延迟最低的可用线路换过去。
    /// 返回是否真的切了，调用方据此决定要不要重试。
    @discardableResult
    func autoSwitchLine() async -> Bool {
        // 冷却 30 秒：线路探测本身是一串请求，太频繁同样会触发 CDN 防刷
        if let t = lastAutoSwitch, Date().timeIntervalSince(t) < 30 { return false }
        guard autoLine, !switchingLine, lineTries < 3 else { return false }
        lastAutoSwitch = Date()
        switchingLine = true
        lineTries += 1
        defer { switchingLine = false }
        let current = lineBase
        guard let best = await Lines.bestLine(excluding: current) else {
            toast("线路不通，自动测速没找到能用的线路", .info)
            return false
        }
        guard let next = try? Net.shared.setBase(best.line.url) else { return false }
        lineBase = next
        Media.playlistCache.clear()
        lineSwitchToken += 1
        toast(best.ms > 0 ? "线路不通，已自动切到 \(best.line.host)（\(best.ms) ms）" : "线路不通，已自动切到 \(best.line.host)", .ok)
        return true
    }

    /// 请求成功后调用，让下次失败还能再切
    func lineOK() { lineTries = 0 }

    /* ───────────── 启动 / 登录 ───────────── */

    func boot() async {
        guard SessionStore.shared.token != nil else { return }
        do {
            let me = try await API.me()
            user = me
            mergeInteractions(me)
        } catch let e as APIError where e == .unauthorized {
            SessionStore.shared.clear()
            user = nil
        } catch {
            // 网络失败：保留本地会话，下次再刷
        }
    }

    /// 把账号里的点赞 / 收藏 / 关注并进本地（本地优先，不删除）
    func mergeInteractions(_ u: User) {
        func merge(_ a: [Int], _ b: [Int]) -> [Int] {
            var seen = Set(a)
            return a + b.filter { seen.insert($0).inserted }
        }
        if !u.likeVideoIds.isEmpty { likes = merge(likes, u.likeVideoIds) }
        if !u.favoriteVideoIds.isEmpty { favs = merge(favs, u.favoriteVideoIds) }
        if !u.followUserIds.isEmpty { follows = merge(follows, u.followUserIds) }
    }

    func didLogin(_ u: User) {
        user = u
        loginPresented = false
        mergeInteractions(u)
        toast("欢迎回来，\(u.nickname)", .ok)
        Task { if let me = try? await API.me() { user = me; mergeInteractions(me) } }
    }

    func logout() async {
        await API.logout()
        user = nil
        toast("已退出登录", .info)
    }

    /// 需要登录的操作：未登录时弹出登录面板并返回 false
    func requireLogin() -> Bool {
        if user != nil { return true }
        loginPresented = true
        return false
    }

    /* ───────────── 本地互动 ───────────── */

    func isLiked(_ id: Int) -> Bool { likes.contains(id) }
    func isFav(_ id: Int) -> Bool { favs.contains(id) }
    func isFollowing(_ uid: Int) -> Bool { follows.contains(uid) }

    @discardableResult
    func toggleLike(_ id: Int) -> Bool {
        if let i = likes.firstIndex(of: id) { likes.remove(at: i); return false }
        likes.insert(id, at: 0); return true
    }

    @discardableResult
    func toggleFav(_ id: Int) -> Bool {
        if let i = favs.firstIndex(of: id) { favs.remove(at: i); return false }
        favs.insert(id, at: 0); return true
    }

    @discardableResult
    func toggleFollow(_ uid: Int) -> Bool {
        if let i = follows.firstIndex(of: uid) { follows.remove(at: i); return false }
        follows.insert(uid, at: 0); return true
    }

    /// 记一条观看记录；`ep` 变了就把进度归零。最多保留 80 条（与旧版一致）。
    func addHistory(_ id: Int, ep: Int? = nil, t: Double? = nil, dur: Double? = nil) {
        let now = Date().timeIntervalSince1970 * 1000
        var entry = history.first { $0.id == id } ?? WatchProgress(id: id, ep: ep ?? 1, t: 0, dur: 0, at: now)
        if let ep, ep != entry.ep { entry.ep = ep; entry.t = 0; entry.dur = 0 }
        if let t { entry.t = t }
        if let dur, dur > 0 { entry.dur = dur }
        entry.at = now
        var next = history.filter { $0.id != id }
        next.insert(entry, at: 0)
        history = Array(next.prefix(80))
    }

    func progress(_ id: Int) -> WatchProgress? { history.first { $0.id == id } }

    func clearHistory() { history = [] }

    func addSearch(_ q: String) {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        searchHist = Array(([t] + searchHist.filter { $0 != t }).prefix(12))
    }

    func clearSearchHist() { searchHist = [] }

    /* ───────────── 导航 ───────────── */

    func nav(_ tab: AppTab) -> TabNav { navs[tab]! }

    func push(_ r: Route) {
        nav(tab).path.append(r)
    }

    func open(_ ids: [Int], at index: Int, title: String, kind: FeedRoute.Kind = .video,
              startEp: Int? = nil, startTime: Double? = nil) {
        guard !ids.isEmpty else { return }
        push(.feed(FeedRoute(ids: ids, index: max(0, min(index, ids.count - 1)), title: title, kind: kind,
                             startEp: startEp, startTime: startTime)))
    }

    /* ───────────── 提示 ───────────── */

    func toast(_ message: String, _ kind: Toast.Kind = .info) {
        let t = Toast(message: message, kind: kind)
        withAnimation(.snappy) { toasts = Array((toasts + [t]).suffix(3)) }
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation(.smooth) { toasts.removeAll { $0.id == t.id } }
        }
    }

    func copy(_ text: String, note: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        toast(note, .ok)
    }
}
