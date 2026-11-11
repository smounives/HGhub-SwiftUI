import Foundation
import Testing
@testable import HGhub

struct LinesParsingTests {
    let sample = """
    var subdomains = [
        'thu',  // 清华
        'pku',  // 北大
    ];
    var urls=[
    \t'xxbgwypx.cc/',
    ];
    var foreverUrls = [
    \t  'https://huangguoai.com',
    \tJumpPage,
    \t'https://huangguoai.ai',
    ];
    """

    @Test func parsesPublishArrays() {
        #expect(Lines.jsArray(sample, "var urls") == ["xxbgwypx.cc/"])
        #expect(Lines.jsArray(sample, "var subdomains") == ["thu", "pku"])
        #expect(Lines.jsArray(sample, "var foreverUrls") == ["https://huangguoai.com", "JumpPage", "https://huangguoai.ai"])
    }

    @Test func resolvesScript() {
        #expect(Lines.absolute("https://huangguoai.pages.dev/", "publish.js?20261103-2") == "https://huangguoai.pages.dev/publish.js?20261103-2")
        #expect(Lines.absolute("https://huangguoai.pages.dev/", "/a/b.js") == "https://huangguoai.pages.dev/a/b.js")
        #expect(Lines.scriptSrc(#"<script type="text/javascript" src="publish.js?20261103-2"></script>"#) == "publish.js?20261103-2")
    }
}

struct VersionTests {
    @Test(arguments: [("v1.0.2", "1.0.1", true), ("v1.1", "1.0.9", true), ("1.0.10", "1.0.9", true),
                      ("v1.0.1", "1.0.1", false), ("v0.9.9", "1.0.1", false), ("", "1.0.1", false),
                      ("v2.0.0-ios", "1.2.0", true)])
    func compares(latest: String, current: String, newer: Bool) {
        #expect(API.isNewer(latest, than: current) == newer)
    }
}

struct MediaTests {
    @Test func stripsValidPaddingOnly() {
        #expect(Media.stripPadding(Data([1, 2, 3, 3, 3, 3])) == Data([1, 2, 3]))
        #expect(Media.stripPadding(Data([1, 2, 9])) == Data([1, 2, 9]))
    }

    @Test func rewritesPlaylist() {
        let m3u8 = """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="crypt.key?a=1",IV=0x00
        #EXTINF:5.2,
        seg0.ts?k=1
        #EXT-X-STREAM-INF:BANDWIDTH=1
        sub/index.m3u8
        """
        let out = Media.rewrite(playlist: m3u8, base: "https://cdn.x/v/main.m3u8", scheme: "hg")
        #expect(out.contains("URI=\"hgkey://p/?u=https%3A%2F%2Fcdn.x%2Fv%2Fcrypt.key%3Fa%3D1\""))
        #expect(out.contains("\nhttps://cdn.x/v/seg0.ts?k=1\n"))
        #expect(out.contains("hghls://p/?u=https%3A%2F%2Fcdn.x%2Fv%2Fsub%2Findex.m3u8"))
    }

    @Test func roundTripsProxyURL() throws {
        let src = "https://a.b/c.m3u8?auth_key=1-2&x=y"
        let u = try #require(URL(string: Media.proxied(src, scheme: "hg")))
        #expect(u.scheme == "hghls")
        #expect(Media.unproxied(u) == src)
    }

    @Test func decryptsCover() throws {
        let enc = try Data(contentsOf: URL(fileURLWithPath: "/tmp/hgjson/c.bin"))
        let dec = try #require(Media.aesDecrypt(enc))
        #expect(Media.imageKind(dec) != nil)
    }
}

struct ArticleTests {
    @Test func parsesLazyImagesAndHeadings() {
        let html = #"<p>你好<b>世界</b></p><img src="/static/web/images/cover-placeholder.png" data-src="https://pic/x.jpeg"><h2>标题</h2><script>alert(1)</script>"#
        let blocks = ArticleParser.parse(html)
        #expect(blocks.count == 3)
        #expect(blocks[1] == .image("https://pic/x.jpeg"))
        #expect(blocks[2] == .heading("标题"))
    }
}

struct FormatTests {
    @Test func counts() {
        #expect(Fmt.count(9999) == "9999")
        #expect(Fmt.count(12000) == "1.2万")
        #expect(Fmt.count(100_000) == "10万")
        #expect(Fmt.count(250_000_000) == "2.5亿")
        #expect(Fmt.time(65) == "1:05")
        #expect(Fmt.time(3725) == "1:02:05")
    }
}
