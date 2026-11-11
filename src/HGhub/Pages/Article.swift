import SwiftUI

/// 帖子正文块：段落 / 小标题 / 图片 / 引用 / 列表项
enum ArticleBlock: Hashable, Identifiable {
    case paragraph(AttributedString)
    case heading(String)
    case image(String)
    case quote(AttributedString)
    case bullet(AttributedString)

    var id: Int { hashValue }
}

/// 极简 HTML → 原生块解析（替代旧版 DOMParser + 白名单清洗）。
/// 脚本 / 样式 / 表单直接丢弃，`javascript:` 链接不保留，懒加载图取 `data-src`。
enum ArticleParser {
    static let site = "https://huangguoai.com"

    static func absolute(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s.lowercased().hasPrefix("data:") { return "" }
        if s.hasPrefix("//") { return "https:\(s)" }
        if s.lowercased().hasPrefix("http://") || s.lowercased().hasPrefix("https://") { return s }
        if s.hasPrefix("/") { return site + s }
        return "\(site)/\(s.hasPrefix("./") ? String(s.dropFirst(2)) : s)"
    }

    static func attr(_ tag: String, _ name: String) -> String? {
        guard let r = tag.range(of: "\(name)=", options: .caseInsensitive) else { return nil }
        let rest = tag[r.upperBound...]
        guard let q = rest.first, q == "\"" || q == "'" else {
            return rest.split(whereSeparator: { $0 == " " || $0 == ">" }).first.map(String.init)
        }
        let body = rest.dropFirst()
        guard let end = body.firstIndex(of: q) else { return nil }
        return String(body[..<end])
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        let map = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                   "&ldquo;": "“", "&rdquo;": "”", "&hellip;": "…", "&mdash;": "—"]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        // &#123; / &#x1F600;
        while let r = out.range(of: "&#[xX]?[0-9a-fA-F]+;", options: .regularExpression) {
            let ent = out[r].dropFirst(2).dropLast()
            let code = ent.first == "x" || ent.first == "X" ? UInt32(ent.dropFirst(), radix: 16) : UInt32(ent)
            out.replaceSubrange(r, with: code.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? "")
        }
        return out
    }

    /// 行内：保留 <b>/<strong> 粗体、<a> 链接（仅 http/https），其余标签去掉
    static func inline(_ html: String) -> AttributedString {
        var result = AttributedString()
        var bold = 0
        var link: URL?
        var rest = Substring(html)
        func emit(_ text: Substring) {
            let t = decodeEntities(String(text))
            guard !t.isEmpty else { return }
            var a = AttributedString(t)
            if bold > 0 { a.inlinePresentationIntent = .stronglyEmphasized }
            if let link { a.link = link }
            result += a
        }
        while let lt = rest.firstIndex(of: "<") {
            emit(rest[..<lt])
            guard let gt = rest[lt...].firstIndex(of: ">") else { rest = rest[lt...]; break }
            let tag = rest[rest.index(after: lt)..<gt].lowercased()
            let name = tag.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).split(separator: " ").first.map(String.init) ?? ""
            let closing = tag.hasPrefix("/")
            switch name {
            case "b", "strong": bold += closing ? -1 : 1; bold = max(0, bold)
            case "a":
                if closing { link = nil } else if let h = attr(String(rest[lt...gt]), "href") {
                    // 严格安全模式：正文里一律不生成可点链接
                    let full = absolute(h)
                    link = (!Net.shared.policy.strictSecurity && full.hasPrefix("http")) ? URL(string: full) : nil
                }
            case "br": result += AttributedString("\n")
            default: break
            }
            rest = rest[rest.index(after: gt)...]
        }
        emit(rest)
        return result
    }

    static func parse(_ html: String) -> [ArticleBlock] {
        guard !html.isEmpty else { return [] }
        var s = html
        // 丢弃不安全 / 无意义内容
        for t in ["script", "style", "iframe", "object", "embed", "form", "noscript"] {
            s = s.replacingOccurrences(of: "<\(t)[^>]*>[\\s\\S]*?</\(t)>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        var blocks: [ArticleBlock] = []
        var buffer = ""
        var mode: String = "p"

        func flush() {
            let text = inline(buffer)
            let plain = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = ""
            guard !plain.isEmpty else { return }
            switch mode {
            case "h": blocks.append(.heading(plain))
            case "q": blocks.append(.quote(text))
            case "li": blocks.append(.bullet(text))
            default: blocks.append(.paragraph(text))
            }
        }

        var rest = Substring(s)
        while let lt = rest.firstIndex(of: "<") {
            buffer += rest[..<lt]
            guard let gt = rest[lt...].firstIndex(of: ">") else { buffer += rest[lt...]; rest = ""; break }
            let raw = String(rest[lt...gt])
            let tag = raw.dropFirst().dropLast().lowercased()
            let closing = tag.hasPrefix("/")
            let name = tag.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).split(separator: " ").first.map(String.init) ?? ""
            switch name {
            case "p", "div", "section", "article":
                flush(); mode = "p"
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flush(); mode = closing ? "p" : "h"
            case "blockquote":
                flush(); mode = closing ? "p" : "q"
            case "li":
                flush(); mode = closing ? "p" : "li"
            case "ul", "ol":
                flush(); mode = "p"
            case "img":
                flush()
                let src = attr(raw, "data-src") ?? attr(raw, "data-original") ?? attr(raw, "data-lazy-src") ?? attr(raw, "src") ?? ""
                let full = absolute(src)
                if !full.isEmpty, !full.contains("cover-placeholder") { blocks.append(.image(full)) }
            default:
                buffer += raw  // 行内标签交给 inline()
            }
            rest = rest[rest.index(after: gt)...]
        }
        buffer += rest
        flush()
        return blocks
    }
}

struct ArticleView: View {
    let blocks: [ArticleBlock]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(blocks) { b in
                switch b {
                case .paragraph(let t):
                    Text(t).font(.body).lineSpacing(6).textSelection(.enabled)
                case .heading(let t):
                    Text(t).font(.title3.weight(.bold)).padding(.top, 6)
                case .image(let u):
                    ArticleImage(url: u)
                case .quote(let t):
                    Text(t).font(.callout).foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.fill.quaternary, in: .rect(cornerRadius: 12))
                        .overlay(alignment: .leading) { Capsule().fill(.tint).frame(width: 3).padding(.vertical, 6) }
                case .bullet(let t):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.tint)
                        Text(t)
                    }
                }
            }
        }
    }
}

/// 正文图：按原始宽高比显示
private struct ArticleImage: View {
    let url: String
    @State private var image: PlatformImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(platform: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(.quaternary).aspectRatio(4 / 3, contentMode: .fit)
                    .overlay { failed ? AnyView(Image(systemName: "photo").foregroundStyle(.tertiary)) : AnyView(ProgressView()) }
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(.rect(cornerRadius: 14, style: .continuous))
        .task(id: url) {
            if let hit = DecodedImages.cache.object(forKey: url as NSString) { image = hit; return }
            do {
                let d = try await Media.image(url)
                let img = await Task.detached { PlatformImage(data: d) }.value
                if let img { DecodedImages.cache.setObject(img, forKey: url as NSString); image = img } else { failed = true }
            } catch { failed = true }
        }
    }
}
