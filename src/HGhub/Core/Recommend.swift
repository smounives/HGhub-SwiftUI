import Foundation

/// 首页「推荐」流：抖音式加权随机（与 1.2.0 的 recommend.ts 同一套算法）。
///
/// 上游 `/api/videos` 只有 hot / new 两种固定排序，没有 seed / random / 个性化接口，所以在客户端做：
/// 1. 候选池 = 热门 Top 100 + 若干随机深页（覆盖全站）
/// 2. 打分 = 热度 + 新鲜度 + 本地兴趣（历史/点赞/收藏/关注 + 本次会话看过的标签）
///          - 最近重复标签惩罚 + 随机噪声（探索）
/// 3. 在 Top-K 里按 softmax 概率抽
enum Recommend {
    struct Taste: Sendable {
        var history: [Int] = []
        var likes: [Int] = []
        var favs: [Int] = []
        var follows: [Int] = []
        var watchedTags: [String: Double] = [:]
    }

    typealias Fetch = @Sendable (_ page: Int, _ size: Int) async throws -> Paged<VideoCard>

    static func pool(size: Int = 100, samples: Int = 2, fetch: @escaping Fetch) async throws -> [VideoCard] {
        let size = max(1, min(100, size))
        let top = try await fetch(1, size)
        let pages = max(1, top.pagination.pages)

        var picks = Set<Int>()
        if pages > 1 {
            let wanted = min(samples, pages - 1)
            while picks.count < wanted { picks.insert(2 + Int.random(in: 0..<(pages - 1))) }
        }
        let rest = await withTaskGroup(of: [VideoCard].self) { g in
            for p in picks { g.addTask { (try? await fetch(p, size).items) ?? [] } }
            var all: [[VideoCard]] = []
            for await x in g { all.append(x) }
            return all
        }
        var seen = Set<Int>()
        var out: [VideoCard] = []
        for v in top.items + rest.flatMap({ $0 }) where seen.insert(v.id).inserted { out.append(v) }
        return out
    }

    private static func ageDays(_ created: String) -> Double {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let d = f.date(from: created) else { return 999 }
        return max(0, Date().timeIntervalSince(d) / 86_400)
    }

    private struct Profile { var tag: [String: Double]; var author: [Int: Double] }

    private static func normalize<K>(_ m: [K: Double]) -> [K: Double] {
        let mx = max(1, m.values.max() ?? 1)
        return m.mapValues { $0 / mx }
    }

    private static func profile(_ pool: [VideoCard], _ t: Taste) -> Profile {
        var tag: [String: Double] = [:]
        var author: [Int: Double] = [:]
        let hist = Set(t.history), likes = Set(t.likes), favs = Set(t.favs), follows = Set(t.follows)
        for v in pool {
            var w = 0.0
            if hist.contains(v.id) { w += 1.2 }
            if likes.contains(v.id) { w += 2 }
            if favs.contains(v.id) { w += 3 }
            if let a = v.author?.id, a > 0, follows.contains(a) { w += 1.5 }
            if w == 0 { continue }
            for x in v.tags { tag[x, default: 0] += w }
            if let a = v.author?.id, a > 0 { author[a, default: 0] += w }
        }
        for (x, w) in t.watchedTags { tag[x, default: 0] += w * 0.6 }
        return Profile(tag: normalize(tag), author: normalize(author))
    }

    private static func score(_ v: VideoCard, _ p: Profile, _ recent: [String], ages: [Int: Double]) -> Double {
        var s = log10(1 + Double(max(0, v.hot))) * 0.5
        s += max(0, 1 - (ages[v.id] ?? 999) / 150) * 0.9
        let affinity = v.tags.reduce(0) { $0 + (p.tag[$1] ?? 0) }
        s += min(1.6, affinity) * 1.15
        if let a = v.author?.id { s += (p.author[a] ?? 0) * 0.7 }
        let dup = v.tags.filter { recent.contains($0) }.count
        s -= Double(min(3, dup)) * 0.7
        s += Double.random(in: 0..<1.35)
        return s
    }

    /// 从候选池里挑一批：Top-K 内按 softmax 权重随机，带标签多样性约束。
    static func pick(_ pool: [VideoCard], seen: Set<Int>, taste: Taste, count: Int = 12) -> [VideoCard] {
        var seen = seen
        let prof = profile(pool, taste)
        var ages: [Int: Double] = [:]
        for v in pool { ages[v.id] = ageDays(v.createdAt) }
        var recent: [String] = []
        var out: [VideoCard] = []

        for _ in 0..<max(1, count) {
            let available = pool.filter { !seen.contains($0.id) }
            if available.isEmpty { break }
            let scored = available.map { ($0, score($0, prof, recent, ages: ages)) }.sorted { $0.1 > $1.1 }
            let top = Array(scored.prefix(12))
            let weights = top.map { exp(($0.1 - top[0].1) / 0.9) }
            var r = Double.random(in: 0..<weights.reduce(0, +))
            var chosen = top[0].0
            for (i, w) in weights.enumerated() {
                r -= w
                if r <= 0 { chosen = top[i].0; break }
            }
            out.append(chosen)
            seen.insert(chosen.id)
            recent.append(contentsOf: chosen.tags)
            if recent.count > 14 { recent.removeFirst(recent.count - 14) }
        }
        return out
    }
}
