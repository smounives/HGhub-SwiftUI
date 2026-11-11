import Foundation

/// 线路（数据源）：固定线路 + 地址发布页上的镜像线路。
///
/// 上游只是域名在变，请求链路与数据模型完全一致，所以「切线路」等价于换 `Net.base`。
/// 镜像地址来自 <https://huangguoai.pages.dev/>：页面本身是空壳，真正的清单在 `publish.js`
/// 里（`var urls` 域名数组 + `var subdomains` 子域数组，页面自己随机拼）。
enum Lines {
    struct Line: Identifiable, Hashable, Sendable {
        var name: String
        var url: String
        var id: String { url }
        var host: String { URL(string: url)?.host ?? url }
    }

    struct Probe: Hashable, Sendable {
        var url: String
        var ok: Bool
        var status: Int?
        var ms: Int
        var error: String?
    }

    struct MirrorList: Sendable {
        var source: String
        var script: String
        var items: [Line]
    }

    static let fixed: [Line] = [
        Line(name: "固定线路 1", url: "https://huangguoai.com"),
        Line(name: "固定线路 2", url: "https://huangguoai.ai"),
    ]

    static let publishPage = "https://huangguoai.pages.dev/"
    static let mirrorMax = 60

    /// 拉地址发布页 → 解析 publish.js → 拼出镜像地址。
    static func mirrors() async throws -> MirrorList {
        Net.shared.refreshSession()
        let html = try await text(publishPage)
        let rel = scriptSrc(html) ?? "publish.js"
        let jsURL = absolute(publishPage, rel)
        let js = try await text(jsURL)

        let domains = jsArray(js, "var urls")
        let subs = jsArray(js, "var subdomains")
        guard !domains.isEmpty else { throw APIError.message("地址发布页格式有变化：没找到镜像域名") }

        var items: [Line] = []
        var seen = Set<String>()
        outer: for raw in domains {
            var domain = raw
            while domain.hasSuffix("/") { domain.removeLast() }
            if domain.isEmpty { continue }
            let hosts = subs.isEmpty ? [domain] : subs.map { "\($0).\(domain)" }
            for host in hosts where seen.insert(host).inserted {
                items.append(Line(name: host, url: "https://\(host)"))
                if items.count >= mirrorMax { break outer }
            }
        }
        guard !items.isEmpty else { throw APIError.message("地址发布页里没有可用的镜像地址") }
        return MirrorList(source: publishPage, script: jsURL, items: items)
    }

    /// 可达性探测：每组 6 条并发，只报结果，不做自动切换。
    static func probe(_ urls: [String]) async -> [Probe] {
        Net.shared.refreshSession()
        var out: [Probe] = []
        var i = 0
        while i < urls.count {
            let chunk = Array(urls[i..<min(i + 6, urls.count)])
            let results = await withTaskGroup(of: (Int, Probe).self) { group in
                for (k, u) in chunk.enumerated() {
                    group.addTask { (k, await probeOne(u)) }
                }
                var r: [(Int, Probe)] = []
                for await x in group { r.append(x) }
                return r.sorted { $0.0 < $1.0 }.map(\.1)
            }
            out.append(contentsOf: results)
            i += 6
        }
        return out
    }

    /// 自动切换用：挑一条能用的线路（排除当前这条）。
    /// 先只测固定线路——两条、够快；固定线路都不行才去拉发布页测镜像。
    static func bestLine(excluding current: String, limit: Int = 12) async -> (line: Line, ms: Int)? {
        Net.shared.refreshSession()
        var fixedOthers = fixed.filter { $0.url != current }
        // IPv6 优先：先把有 AAAA 记录的线路挑出来（没有就退回全部）
        if Net.shared.policy.ipv6First {
            let v6 = await withTaskGroup(of: (Line, Bool).self) { group -> [Line] in
                for l in fixedOthers { group.addTask { (l, await Resolver.hasIPv6(l.host)) } }
                var out: [Line] = []
                for await (l, ok) in group where ok { out.append(l) }
                return out
            }
            if !v6.isEmpty { fixedOthers = v6 }
        }
        if let hit = await fastest(fixedOthers, timeout: 5) { return hit }
        // 探测本身也可能被墙/超时：固定线路是同一站点的镜像，盲换一条也比干等着强
        if let fallback = fixedOthers.first { return (fallback, 0) }
        if let m = try? await mirrors() {
            let extra = Array(m.items.filter { $0.url != current }.prefix(limit))
            return await fastest(extra, timeout: 4)
        }
        return nil
    }

    /// 每 6 条并发测一轮，出现可用线路就收手（目标是最快恢复，不是全网最优）
    private static func fastest(_ candidates: [Line], timeout: TimeInterval = 5) async -> (line: Line, ms: Int)? {
        guard !candidates.isEmpty else { return nil }
        var best: (line: Line, ms: Int)?
        var i = 0
        while i < candidates.count {
            let chunk = Array(candidates[i..<min(i + 6, candidates.count)])
            let results = await withTaskGroup(of: (Line, Probe).self) { group in
                for l in chunk { group.addTask { (l, await probeOne(l.url, timeout: timeout)) } }
                var out: [(Line, Probe)] = []
                for await r in group { out.append(r) }
                return out
            }
            for (l, p) in results where p.ok {
                if best == nil || p.ms < best!.ms { best = (l, p.ms) }
            }
            if best != nil { break }
            i += 6
        }
        return best
    }

    static func probeOne(_ url: String, timeout: TimeInterval = 8) async -> Probe {
        var trimmed = url
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        let started = ContinuousClock.now
        guard let target = URL(string: trimmed + "/") else {
            return Probe(url: url, ok: false, status: nil, ms: 0, error: "地址无效")
        }
        var req = URLRequest(url: target, timeoutInterval: timeout)
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        do {
            let (_, resp) = try await Net.shared.session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return Probe(url: url, ok: status < 400, status: status, ms: Net.ms(since: started), error: nil)
        } catch {
            return Probe(url: url, ok: false, status: nil, ms: Net.ms(since: started), error: Net.describe(error))
        }
    }

    private static func text(_ url: String) async throws -> String {
        guard let u = URL(string: url) else { throw APIError.message("地址无效") }
        let (data, resp) = try await Net.shared.session.data(for: URLRequest(url: u, timeoutInterval: 12))
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw APIError.message("HTTP \(status)") }
        return String(decoding: data, as: UTF8.self)
    }

    /* ───────────── 解析（与旧版 Rust 实现逐行对应，有单元测试） ───────────── */

    /// 从 HTML 里挑出脚本地址（发布页只有一个 `publish.js?<版本>`）。
    static func scriptSrc(_ html: String) -> String? {
        var rest = Substring(html)
        while let r = rest.range(of: "src=\"") {
            let after = rest[r.upperBound...]
            guard let end = after.firstIndex(of: "\"") else { return nil }
            let candidate = after[..<end]
            if candidate.contains(".js") { return String(candidate) }
            rest = after[end...]
        }
        return nil
    }

    static func absolute(_ base: String, _ rel: String) -> String {
        if rel.hasPrefix("http://") || rel.hasPrefix("https://") { return rel }
        guard let u = URL(string: base), let scheme = u.scheme, let host = u.host else { return rel }
        let origin = "\(scheme)://\(host)"
        return rel.hasPrefix("/") ? origin + rel : "\(origin)/\(rel)"
    }

    /// 取 JS 里 `var <name> = [ ... ]` 的字符串数组（去掉行尾 `//` 注释，保留字符串里的 `//`）。
    static func jsArray(_ src: String, _ decl: String) -> [String] {
        guard let at = src.range(of: decl) else { return [] }
        let rest = src[at.lowerBound...]
        guard let open = rest.firstIndex(of: "["),
              let close = rest[open...].firstIndex(of: "]") else { return [] }
        let body = String(rest[rest.index(after: open)..<close])
        return stripLineComments(body)
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                .trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func stripLineComments(_ body: String) -> String {
        var out = ""
        var quote: Character?
        var it = Array(body)
        var i = 0
        while i < it.count {
            let c = it[i]
            if let q = quote {
                out.append(c)
                if c == q { quote = nil }
            } else if c == "'" || c == "\"" {
                quote = c
                out.append(c)
            } else if c == "/", i + 1 < it.count, it[i + 1] == "/" {
                while i < it.count, it[i] != "\n" { i += 1 }
                if i < it.count { out.append("\n") }
            } else {
                out.append(c)
            }
            i += 1
        }
        it.removeAll()
        return out
    }
}
