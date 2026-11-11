import Foundation
import Synchronization

/// 应用数据目录：`Application Support/com.hghub.native/`
enum AppPaths {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("com.hghub.native", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// 旧版 Tauri 客户端的数据目录（macOS 上首次启动时迁移会话与线路）
    static let legacyDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("com.hghub.huangguo", isDirectory: true)
    }()

    static func file(_ name: String) -> URL { dir.appendingPathComponent(name) }

    /// 新目录缺这个文件、旧目录有，就复制一份过来
    static func migrate(_ name: String) {
        let dst = file(name)
        let src = legacyDir.appendingPathComponent(name)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dst.path), fm.fileExists(atPath: src.path) {
            try? fm.copyItem(at: src, to: dst)
        }
    }
}

enum APIError: LocalizedError, Equatable {
    case message(String)
    case unauthorized
    case needLogin

    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        case .unauthorized: return "登录已失效，请重新登录"
        case .needLogin: return "请先登录"
        }
    }
}

/// 网络层：与上游站点对话。
///
/// 站点把全部 `/api/**` 调用收敛成 `POST /api/edge/request` 的信封，这里只实现这一个入口，
/// 其余接口都是「填 path」。URLSession 天然读取系统代理（含 PAC），不需要旧版的代理探测补丁。
/// DNS 解析辅助：IPv6 优先 + 提前解析（暖 DNS，减少首包等待）
enum Resolver {
    static func hasIPv6(_ host: String) async -> Bool {
        guard !host.isEmpty else { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .utility).async {
                guard let h = host.cString(using: .utf8) else { cont.resume(returning: false); return }
                var hints = addrinfo(ai_flags: 0, ai_family: AF_INET6, ai_socktype: SOCK_STREAM,
                                     ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
                var res: UnsafeMutablePointer<addrinfo>?
                let rc = getaddrinfo(h, nil, &hints, &res)
                if let res { freeaddrinfo(res) }
                cont.resume(returning: rc == 0)
            }
        }
    }

    static func warm(_ host: String) async {
        guard !host.isEmpty else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                guard let h = host.cString(using: .utf8) else { cont.resume(); return }
                var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                                     ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
                var res: UnsafeMutablePointer<addrinfo>?
                getaddrinfo(h, nil, &hints, &res)
                if let res { freeaddrinfo(res) }
                cont.resume()
            }
        }
    }
}

/// 重定向守卫：URLSession 默认会自动跟随跳转，跳转目标是内网就绕过了 SSRF 检查。
/// 严格模式下逐跳校验，非公网目标直接不跟随。
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = RedirectGuard()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard Net.shared.policy.strictSecurity else { completionHandler(request); return }
        guard let host = request.url?.host, Net.isPublicHost(host) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

final class Net: Sendable {
    static let shared = Net()

    static let defaultBase = "https://huangguoai.com"
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    /// 网络加固开关（设置里可调）
    struct Policy: Sendable {
        var ipv6First = false
        var keepAlive = true
        var fastFail4xx = true
        /// 默认关闭：开了会拒绝内网/回环目标，自建局域网镜像这类场景会被误伤
        var strictSecurity = false
    }

    private let policyState = Mutex(Policy())
    private let rebuiltAt = Mutex(Date.distantPast)

    private let baseState: Mutex<String>
    private let sessionState: Mutex<URLSession>

    private init() {
        AppPaths.migrate("line.json")
        var initial = Net.defaultBase
        if let data = try? Data(contentsOf: AppPaths.file("line.json")),
           let v = try? JSON.parse(data), let b = v["base"].string, let n = Net.normalize(b) {
            // 老版本把 huangguoai.ai 当固定线路存过：它是地址入口页，没有 edge 接口（404），
            // 启动时直接迁回官网，免得用户一直卡在 404。
            initial = (n == "https://huangguoai.ai") ? Net.defaultBase : n
        }
        baseState = Mutex(initial)
        sessionState = Mutex(Net.makeSession())
    }

    private static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        cfg.httpAdditionalHeaders = ["User-Agent": userAgent]
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.httpMaximumConnectionsPerHost = 8
        if let p = ProcessInfo.processInfo.environment["HGHUB_PROXY"], let u = URL(string: p), let host = u.host {
            let port = u.port ?? 80
            cfg.connectionProxyDictionary = [
                "HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port,
                "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port,
            ]
        }
        return URLSession(configuration: cfg, delegate: RedirectGuard.shared, delegateQueue: nil)
    }

    var session: URLSession { sessionState.withLock { $0 } }

    var policy: Policy {
        get { policyState.withLock { $0 } }
        set { policyState.withLock { $0 = newValue } }
    }

    /// 代理软件开关过之后重建会话。
    /// 开了「连接复用」时 30 秒内不重建——重建会丢掉已建立的连接（TLS 握手要重做）。
    func refreshSession(force: Bool = false) {
        let p = policy
        if !force, p.keepAlive, Date().timeIntervalSince(rebuiltAt.withLock { $0 }) < 30 { return }
        let fresh = Net.makeSession()
        sessionState.withLock { $0 = fresh }
        rebuiltAt.withLock { $0 = Date() }
    }

    var base: String { baseState.withLock { $0 } }

    /// 规整线路地址：必须是 http(s) 且带 host，去掉结尾斜杠。
    static func normalize(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: t), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = u.host, !host.isEmpty else { return nil }
        var s = t
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// 严格安全模式下的 SSRF 防护：只允许公网地址。
    /// 与参考实现（Rust/JS 两端各有一份）保持同一张白名单：
    /// 内网、回环、链路本地、组播、ULA、6to4、Teredo、NAT64、文档地址全部拒绝；
    /// 198.18.0.0/15 明确放行——那是 Clash/Surge 的 FakeIP 段，不是真的内网。
    static func isPublicHost(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h.isEmpty { return false }
        if ["tauri.localhost", "hg.localhost", "ipc.localhost"].contains(h) { return false }
        if ["localhost", "local", "internal", "home.arpa"].contains(where: { h == $0 || h.hasSuffix(".\($0)") }) {
            return false
        }
        if h.contains(":") {
            return isPublicIPv6(h)
        }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return true }  // 域名放行
        let (a, b, c) = (parts[0], parts[1], parts[2])
        if a == 198 && (b == 18 || b == 19) { return true }   // FakeIP
        if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
        if a == 100 && (64...127).contains(b) { return false }
        if a == 169 && b == 254 { return false }
        if a == 172 && (16...31).contains(b) { return false }
        if a == 192 && b == 168 { return false }
        if a == 192 && b == 0 && (c == 0 || c == 2) { return false }
        if a == 192 && b == 88 && c == 99 { return false }
        if a == 198 && b == 51 && c == 100 { return false }
        if a == 203 && b == 0 && c == 113 { return false }
        return true
    }

    /// IPv6 只允许全球单播（2000::/3），并排除 6to4 / Teredo / 文档段 / NAT64
    private static func isPublicIPv6(_ raw: String) -> Bool {
        var s = raw
        if s.hasPrefix("::ffff:"), let v4 = IPv4Style(s.dropFirst(7)) { return isPublicHost(v4) }
        let groups = s.split(separator: ":", omittingEmptySubsequences: false)
        guard let head = groups.first, let g0 = UInt16(head, radix: 16) else { return false }
        if g0 & 0xe000 != 0x2000 { return false }          // 非全球单播
        if g0 == 0x2002 { return false }                    // 6to4
        if g0 == 0x2001, groups.count > 1 {
            guard let g1 = UInt16(groups[1], radix: 16) else { return false }
            if g1 < 0x0200 { return false }                 // Teredo 2001:0::/32
            if g1 == 0x0db8 { return false }                // 文档段
        }
        if g0 == 0x0064 { return false }                    // NAT64 64:ff9b::/96（不是全球单播，已被上面拦）
        _ = s
        return true
    }

    private static func IPv4Style(_ s: Substring) -> String? {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return parts.joined(separator: ".")
    }

    /// 请求前检查目标（严格模式）：任何非公网目标直接拒绝
    func checkTarget(_ url: URL) throws {
        guard policy.strictSecurity else { return }
        guard let host = url.host, Net.isPublicHost(host) else {
            throw APIError.message("严格安全模式：目标地址不在允许范围")
        }
    }

    /// 切换线路并落盘，返回规整后的地址。
    @discardableResult
    func setBase(_ raw: String) throws -> String {
        guard let next = Net.normalize(raw) else { throw APIError.message("线路地址无效（需要 http(s)://域名）") }
        if policy.strictSecurity {
            guard let host = URL(string: next)?.host, Net.isPublicHost(host) else {
                throw APIError.message("严格安全模式：不允许内网 / 回环地址")
            }
        }
        Task.detached(priority: .utility) { await Resolver.warm(URL(string: next)?.host ?? "") }
        baseState.withLock { $0 = next }
        let v: JSON = ["base": .string(next)]
        try? v.data().write(to: AppPaths.file("line.json"), options: .atomic)
        return next
    }

    /* ───────────── 重试 ───────────── */

    /// 站点偶发 TLS 抖动，统一重试 3 次；连接类错误先重建会话再试。
    private func withRetry<T: Sendable>(_ op: @Sendable (URLSession) async throws -> T) async throws -> T {
        var last: Error = APIError.message("network error")
        for attempt in 0..<3 {
            do {
                return try await op(session)
            } catch let e as APIError {
                if e == .unauthorized { throw e }
                // 只有 HTTP 状态码错误才可能值得重试
                guard let code = httpStatus(e) else { throw e }
                let retryable = code == 408 || code == 425 || code == 429 || (500...599).contains(code)
                // 非重试型 4xx：开关打开时立刻失败；关掉则照常重试
                if !retryable && policy.fastFail4xx { throw e }
                last = e
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(350 * (attempt + 1))) }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                last = error
                if let u = error as? URLError,
                   [.cannotConnectToHost, .timedOut, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed,
                    .secureConnectionFailed].contains(u.code) {
                    refreshSession()
                }
                if attempt < 2 {
                    try? await Task.sleep(for: .milliseconds(350 * (attempt + 1)))
                }
            }
        }
        throw APIError.message(Net.describe(last))
    }

    /// 从 "HTTP 404: ..." 里取出状态码
    private func httpStatus(_ e: APIError) -> Int? {
        guard let msg = e.errorDescription, msg.hasPrefix("HTTP ") else { return nil }
        return Int(msg.dropFirst(5).prefix(3))
    }

    static func describe(_ e: Error) -> String {
        if let a = e as? APIError { return a.errorDescription ?? "请求失败" }
        if let u = e as? URLError {
            switch u.code {
            case .notConnectedToInternet: return "网络未连接"
            case .timedOut: return "请求超时，请检查网络或切换线路"
            case .cannotFindHost, .dnsLookupFailed: return "域名解析失败（\(u.failingURL?.host ?? "")），请切换线路"
            case .cannotConnectToHost: return "无法连接服务器，请切换线路"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
                return "TLS 握手失败：\(u.localizedDescription)"
            default: return u.localizedDescription
            }
        }
        return e.localizedDescription
    }

    /* ───────────── 边缘信封 ───────────── */

    /// 业务请求：`POST {base}/api/edge/request`，信封里写真实的 method/path/body(base64)。
    /// 返回信封里的 `data`；`status != 1` 时抛出 `msg`。
    func edge(_ method: String, _ path: String, body: JSON? = nil, token: String? = nil) async throws -> JSON {
        var encoded = ""
        var ctype = ""
        if let body {
            encoded = body.data().base64EncodedString()
            ctype = "application/json"
        }
        let envelope: JSON = [
            "method": .string(method), "path": .string(path),
            "body": .string(encoded), "content_type": .string(ctype),
        ]
        let cur = base
        guard let url = URL(string: "\(cur)/api/edge/request") else { throw APIError.message("线路地址无效") }
        try checkTarget(url)
        let payload = envelope.data()
        let referer = "\(cur)/"
        let tok = token

        let value: JSON = try await withRetry { session in
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.httpBody = payload
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue(referer, forHTTPHeaderField: "Referer")
            if let t = tok, !t.isEmpty { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 { throw APIError.unauthorized }
            guard (200..<300).contains(status) else {
                let text = String(decoding: data.prefix(160), as: UTF8.self)
                throw APIError.message("HTTP \(status): \(text)")
            }
            if data.isEmpty || String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .null
            }
            do { return try JSON.parse(data) } catch {
                throw APIError.message("返回格式错误：\(String(decoding: data.prefix(120), as: UTF8.self))")
            }
        }

        if value.isNull { return .null }
        if value["status"].int == 1 { return value["data"] }
        let msg = value["msg"].str
        throw APIError.message(msg.isEmpty ? "接口返回失败" : msg)
    }

    /// 拉原始字节（图片 / m3u8 / 分片 / key），带站点 Referer。
    func fetch(_ urlString: String, timeout: TimeInterval = 20) async throws -> (String?, Data) {
        guard let url = URL(string: urlString) else { throw APIError.message("地址无效") }
        try checkTarget(url)
        let referer = "\(base)/"
        return try await withRetry { session in
            var req = URLRequest(url: url, timeoutInterval: timeout)
            req.setValue(referer, forHTTPHeaderField: "Referer")
            let (data, resp) = try await session.data(for: req)
            let http = resp as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw APIError.message("HTTP \(status)") }
            return (http?.value(forHTTPHeaderField: "Content-Type"), data)
        }
    }

    /// 网络自检：DNS / HTTP / 代理快照，用于定位「打不开」。
    func diagnose() async -> JSON {
        let cur = base
        let host = URL(string: cur)?.host ?? ""
        let dns = await Task.detached { () -> JSON in
            var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                                 ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var res: UnsafeMutablePointer<addrinfo>?
            let rc = getaddrinfo(host, "443", &hints, &res)
            guard rc == 0, let first = res else {
                return .string("解析失败: \(String(validatingCString: gai_strerror(rc)) ?? "\(rc)")")
            }
            defer { freeaddrinfo(first) }
            var out: [JSON] = []
            var p: UnsafeMutablePointer<addrinfo>? = first
            while let ai = p {
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let s = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    if !out.contains(.string(s)) { out.append(.string(s)) }
                }
                p = ai.pointee.ai_next
            }
            return .array(out)
        }.value

        let started = ContinuousClock.now
        var http: JSON
        do {
            guard let u = URL(string: "\(cur)/") else { throw APIError.message("bad url") }
            let (_, resp) = try await session.data(from: u)
            http = ["status": .number(Double((resp as? HTTPURLResponse)?.statusCode ?? 0)),
                    "ms": .number(Double(Net.ms(since: started)))]
        } catch {
            http = ["error": .string(Net.describe(error)), "ms": .number(Double(Net.ms(since: started)))]
        }

        var proxy: JSON = .null
        if let dict = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] {
            var o: [String: JSON] = [:]
            for k in ["HTTPEnable", "HTTPProxy", "HTTPPort", "HTTPSEnable", "HTTPSProxy", "HTTPSPort",
                      "ProxyAutoConfigEnable", "ProxyAutoConfigURLString", "SOCKSEnable", "SOCKSProxy", "SOCKSPort"] {
                if let v = dict[k] { o[k] = .string("\(v)") }
            }
            proxy = .object(o)
        }
        let env = ProcessInfo.processInfo.environment
        return [
            "base": .string(cur), "host": .string(host), "dns": dns, "http": http,
            "system_proxy": proxy,
            "env": [
                "HTTP_PROXY": env["HTTP_PROXY"].map(JSON.string) ?? .null,
                "HTTPS_PROXY": env["HTTPS_PROXY"].map(JSON.string) ?? .null,
                "ALL_PROXY": env["ALL_PROXY"].map(JSON.string) ?? .null,
                "HGHUB_PROXY": env["HGHUB_PROXY"].map(JSON.string) ?? .null,
            ],
        ]
    }

    static func ms(since start: ContinuousClock.Instant) -> Int {
        let d = start.duration(to: .now)
        return Int(d.components.seconds) * 1000 + Int(d.components.attoseconds / 1_000_000_000_000_000)
    }
}
