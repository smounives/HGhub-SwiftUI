import CommonCrypto
import Foundation
import Synchronization

/// 有上限的内存缓存（满了丢最早插入的，与旧版 HashMap 淘汰策略等价但更可预期）。
final class BoundedCache<V: Sendable>: Sendable {
    private struct Box: Sendable { var order: [String] = []; var map: [String: V] = [:]; var bytes = 0 }
    private let box = Mutex(Box())
    private let maxCount: Int
    private let maxBytes: Int
    private let cost: @Sendable (V) -> Int

    init(maxCount: Int, maxBytes: Int = .max, cost: @escaping @Sendable (V) -> Int = { _ in 0 }) {
        self.maxCount = maxCount
        self.maxBytes = maxBytes
        self.cost = cost
    }

    func get(_ k: String) -> V? { box.withLock { $0.map[k] } }

    func put(_ k: String, _ v: V) {
        let c = cost(v)
        if c > maxBytes { return }
        box.withLock { b in
            if let old = b.map[k] { b.bytes -= cost(old); b.order.removeAll { $0 == k } }
            while !b.order.isEmpty, b.order.count >= maxCount || b.bytes + c > maxBytes {
                let first = b.order.removeFirst()
                if let o = b.map.removeValue(forKey: first) { b.bytes -= cost(o) }
            }
            b.map[k] = v
            b.order.append(k)
            b.bytes += c
        }
    }

    func clear() { box.withLock { $0 = Box() } }
    var count: Int { box.withLock { $0.map.count } }
}

/// 媒体层：封面解密 + HLS 播放列表改写。
enum Media {
    /* ───────────── 封面（AES-128-CBC 密文） ───────────── */

    static let imgKey = Array("f5d965df75336270".utf8)
    static let imgIV = Array("97b60394abc2fbe1".utf8)

    static let imageCache = BoundedCache<Data>(maxCount: 240, maxBytes: 96 * 1024 * 1024, cost: { $0.count })
    static let playlistCache = BoundedCache<String>(maxCount: 60)
    static let keyCache = BoundedCache<Data>(maxCount: 120)

    static var diskDir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.hghub.native/covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func diskName(_ url: String) -> String {
        var h = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let d = Data(url.utf8)
        d.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(d.count), &h) }
        return h.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func imageKind(_ b: Data) -> String? {
        guard b.count >= 12 else { return nil }
        let p = [UInt8](b.prefix(12))
        if p[0] == 0xFF, p[1] == 0xD8 { return "image/jpeg" }
        if p[0] == 0x89, p[1] == 0x50, p[2] == 0x4E, p[3] == 0x47 { return "image/png" }
        if p[0] == 0x47, p[1] == 0x49, p[2] == 0x46, p[3] == 0x38 { return "image/gif" }
        if p[0] == 0x52, p[1] == 0x49, p[2] == 0x46, p[3] == 0x46,
           p[8] == 0x57, p[9] == 0x45, p[10] == 0x42, p[11] == 0x50 { return "image/webp" }
        return nil
    }

    /// AES-128-CBC 解密（无填充模式解，再手动去 PKCS7，和旧版一致：填充不合法时原样保留）。
    static func aesDecrypt(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count % 16 == 0 else { return nil }
        var out = Data(count: data.count)
        var moved = 0
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { i in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), 0,
                        imgKey, kCCKeySizeAES128, imgIV,
                        i.baseAddress, data.count, o.baseAddress, data.count, &moved)
            }
        }
        guard status == kCCSuccess else { return nil }
        out.count = moved
        return stripPadding(out)
    }

    static func stripPadding(_ buf: Data) -> Data {
        guard let last = buf.last else { return buf }
        let pad = Int(last)
        guard pad > 0, pad <= 16, buf.count >= pad else { return buf }
        if buf.suffix(pad).allSatisfy({ Int($0) == pad }) { return buf.prefix(buf.count - pad) }
        return buf
    }

    /// 取封面：内存 → 磁盘 → 网络（按需解密）。
    static func image(_ url: String) async throws -> Data {
        if let hit = imageCache.get(url) { return hit }
        let disk = diskDir.appendingPathComponent(diskName(url))
        if let d = try? Data(contentsOf: disk), imageKind(d) != nil {
            imageCache.put(url, d)
            return d
        }
        let (_, bytes) = try await Net.shared.fetch(url)
        let plain: Data
        if imageKind(bytes) != nil {
            plain = bytes
        } else if let dec = aesDecrypt(bytes), imageKind(dec) != nil {
            plain = dec
        } else {
            throw APIError.message("封面解密失败")
        }
        imageCache.put(url, plain)
        try? plain.write(to: disk, options: .atomic)
        return plain
    }

    /// 只清除封面与播放列表缓存（收藏、记录、搜索历史、登录态保留）。
    static func clearCaches() {
        imageCache.clear()
        playlistCache.clear()
        keyCache.clear()
        try? FileManager.default.removeItem(at: diskDir)
        URLCache.shared.removeAllCachedResponses()
    }

    static func diskCacheBytes() -> Int {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: diskDir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /* ───────────── HLS ───────────── */

    static func isM3U8(_ u: String) -> Bool {
        let path = (u.split(separator: "?", maxSplits: 1).first.map(String.init) ?? u).lowercased()
        return path.hasSuffix(".m3u8")
    }

    static func absolutize(_ base: String, _ target: String) -> String {
        if target.hasPrefix("http://") || target.hasPrefix("https://") { return target }
        if let b = URL(string: base), let j = URL(string: target, relativeTo: b) { return j.absoluteString }
        return target
    }

    /// 改写 m3u8：
    /// - 子播放列表 / key 走 `scheme`（由 ResourceLoader 代拉，带 Referer + 缓存）
    /// - 分片保持绝对 https 地址（AVFoundation 要求 HLS 分片走真实网络，且 CDN 分片不校验 Referer）
    static func rewrite(playlist text: String, base url: String, scheme: String) -> String {
        var out = ""
        out.reserveCapacity(text.count + 512)
        var expectSub = false
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { out += "\n"; continue }
            if line.hasPrefix("#") {
                if line.hasPrefix("#EXT-X-STREAM-INF") { expectSub = true }
                if line.hasPrefix("#EXT-X-KEY") || line.hasPrefix("#EXT-X-MAP") || line.hasPrefix("#EXT-X-MEDIA") {
                    out += rewriteURIAttr(line, base: url, scheme: scheme)
                } else {
                    out += line
                }
            } else {
                let abs = absolutize(url, line)
                if expectSub || isM3U8(abs) {
                    out += proxied(abs, scheme: scheme)
                } else {
                    out += abs
                }
                expectSub = false
            }
            out += "\n"
        }
        return out
    }

    private static func rewriteURIAttr(_ line: String, base: String, scheme: String) -> String {
        guard let start = line.range(of: "URI=\"") else { return line }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return line }
        let uri = absolutize(base, String(rest[..<end]))
        // EXT-X-MAP 的 init 分片也是媒体数据，必须走真实网络
        let replaced = line.hasPrefix("#EXT-X-MAP") ? uri : proxied(uri, scheme: scheme)
        return String(line[..<start.upperBound]) + replaced + String(rest[end...])
    }

    /// `hgkey://…` / `hghls://…`：把原 https 地址整体塞进自定义 scheme
    static func proxied(_ abs: String, scheme: String) -> String {
        let route = isM3U8(abs) ? "\(scheme)hls" : "\(scheme)key"
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return "\(route)://p/?u=\(abs.addingPercentEncoding(withAllowedCharacters: allowed) ?? abs)"
    }

    static func unproxied(_ url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "u" }?.value
    }

    static func playlist(_ url: String, scheme: String) async throws -> String {
        let k = "\(scheme)|\(url)"
        if let hit = playlistCache.get(k) { return hit }
        let (_, bytes) = try await Net.shared.fetch(url)
        let text = String(decoding: bytes, as: UTF8.self)
        guard text.contains("#EXTM3U") else { throw APIError.message("播放列表格式错误") }
        let out = rewrite(playlist: text, base: url, scheme: scheme)
        playlistCache.put(k, out)
        return out
    }

    static func key(_ url: String) async throws -> Data {
        if let hit = keyCache.get(url) { return hit }
        let (_, bytes) = try await Net.shared.fetch(url)
        keyCache.put(url, bytes)
        return bytes
    }
}
