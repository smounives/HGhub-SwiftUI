import AVFoundation
import Foundation
import Testing
@testable import HGhub

/// 真实上游联调：逐个接口走一遍 Swift 实现（需要网络；`HGHUB_LIVE=0` 时跳过）。
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HGHUB_LIVE"] != "0"))
struct LiveAPITests {
    @Test func feedHotAndNew() async throws {
        let hot = try await API.feed(page: 1, size: 5, sort: .hot)
        let new = try await API.feed(page: 1, size: 5, sort: .new)
        #expect(hot.items.count == 5)
        #expect(new.items.count == 5)
        #expect(hot.pagination.total > 1000)
        #expect(hot.items.map(\.id) != new.items.map(\.id))
        #expect(!hot.items[0].title.isEmpty && !hot.items[0].cover.isEmpty)
    }

    @Test func recommendPoolAndPick() async throws {
        let pool = try await Recommend.pool(size: 100, samples: 2) { p, s in try await API.feed(page: p, size: s) }
        #expect(pool.count >= 200)
        #expect(Set(pool.map(\.id)).count == pool.count)
        let a = Recommend.pick(pool, seen: [], taste: .init(), count: 12)
        let b = Recommend.pick(pool, seen: Set(a.map(\.id)), taste: .init(), count: 12)
        #expect(a.count == 12 && b.count == 12)
        #expect(Set(a.map(\.id)).isDisjoint(with: b.map(\.id)))
    }

    @Test(arguments: Channel.all.map(\.cate))
    func category(_ cate: String) async throws {
        let r = try await API.category(cate, page: 1, size: 4)
        #expect(!r.items.isEmpty)
    }

    @Test(arguments: API.RankKind.allCases)
    func ranks(_ kind: API.RankKind) async throws {
        let r = try await API.rank(kind)
        #expect(!r.isEmpty)
        #expect(r[0].rank == 1 && r[0].videoId > 0)
    }

    @Test func search() async throws {
        let r = try await API.search("都市", page: 1, size: 5)
        #expect(!r.items.isEmpty)
    }

    @Test func detailPlayAndHLS() async throws {
        let feed = try await API.feed(page: 1, size: 1)
        let id = try #require(feed.items.first?.id)
        let d = try await API.video(id)
        #expect(d.id == id && !d.episodes.isEmpty)

        let p = try await API.play(id, ep: 1)
        #expect(p.url.contains(".m3u8"))

        // 播放列表改写 + key 代理
        let pl = try await Media.playlist(p.url, scheme: HLSLoader.scheme)
        #expect(pl.contains("#EXTM3U"))
        let lines = pl.split(separator: "\n")
        if let keyLine = lines.first(where: { $0.hasPrefix("#EXT-X-KEY") }) {
            #expect(keyLine.contains("hgkey://"))
            let start = try #require(keyLine.range(of: "URI=\""))
            let rest = keyLine[start.upperBound...]
            let proxied = String(rest[..<rest.firstIndex(of: "\"")!])
            let real = try #require(Media.unproxied(URL(string: proxied)!))
            let key = try await Media.key(real)
            #expect(key.count == 16)
        }
        let seg = try #require(lines.first { !$0.hasPrefix("#") && !$0.isEmpty })
        #expect(seg.hasPrefix("https://"))
        let (_, bytes) = try await Net.shared.fetch(String(seg))
        #expect(bytes.count > 10_000)
        #expect(bytes.first == 0x47 || bytes.count % 16 == 0) // TS 同步字节或 AES 块
    }

    /// 真机解码前的最后一环：AVFoundation 能经 ResourceLoader 打开改写后的播放列表并就绪
    @MainActor @Test func avPlayerBecomesReady() async throws {
        let feed = try await API.feed(page: 1, size: 1)
        let id = try #require(feed.items.first?.id)
        let p = try await API.play(id, ep: 1)
        let engine = PlayerEngine(muted: true, volume: 0)
        engine.load(p.url, autoplay: true)
        var ready = false
        for _ in 0..<80 {
            if engine.isReady, engine.duration > 0 { ready = true; break }
            if engine.error != nil { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        #expect(engine.error == nil, "\(engine.error ?? "")")
        #expect(ready)
        #expect(engine.duration > 30)
        // 等到真正开始走时间
        for _ in 0..<40 where engine.time < 0.5 { try await Task.sleep(for: .milliseconds(250)) }
        #expect(engine.time > 0.3)
        engine.seek(to: 60)
        try await Task.sleep(for: .seconds(2))
        #expect(engine.time >= 59)
        engine.teardown()
    }

    @Test func comments() async throws {
        let feed = try await API.feed(page: 1, size: 1)
        let id = try #require(feed.items.first?.id)
        let c = try await API.comments(id, ep: 1, page: 1, size: 5)
        #expect(c.pagination.total >= 0)
        if let first = c.items.first { #expect(!first.text.isEmpty) }
    }

    @Test func postsAndPostDetail() async throws {
        let list = try await API.posts(page: 1, size: 5)
        #expect(!list.items.isEmpty)
        let post = try await API.post(list.items[0].id)
        #expect(!post.title.isEmpty)
        #expect(!post.content.isEmpty || post.hasVideo)
        let blocks = ArticleParser.parse(post.content)
        #expect(!blocks.isEmpty)
        let pc = try await API.postComments(post.id, page: 1, size: 5)
        #expect(pc.pagination.page >= 0)
    }

    @Test func coverDecrypt() async throws {
        let feed = try await API.feed(page: 1, size: 3)
        for v in feed.items {
            let data = try await Media.image(v.cover)
            #expect(Media.imageKind(data) != nil)
        }
    }

    @Test func interactionsRequireLogin() async throws {
        // 未登录（或 token 失效）时，写操作要么报「请先登录」，要么上游 401 —— 不能静默成功
        if SessionStore.shared.token == nil {
            await #expect(throws: APIError.needLogin) { try await API.collect(1, on: true) }
        }
    }

    @Test func loginWrongPasswordFails() async throws {
        await #expect(throws: (any Error).self) {
            _ = try await Net.shared.edge("POST", "/api/account/loginByPassword",
                                          body: ["username": "hghub_nonexistent_user_x", "password": "wrong-password"])
        }
    }

    @Test func mirrorsAndProbe() async throws {
        let m = try await Lines.mirrors()
        #expect(!m.items.isEmpty)
        let probes = await Lines.probe(Lines.fixed.map(\.url))
        #expect(probes.count == 2)
        #expect(probes.contains { $0.ok })
    }

    @Test func diagnose() async throws {
        let d = await Net.shared.diagnose()
        #expect(d["base"].string == Net.shared.base)
        #expect(d["http"]["status"].int == 200)
    }

    @Test func checkUpdate() async throws {
        let u = try await API.checkUpdate()
        #expect(!u.url.isEmpty)
    }
}
