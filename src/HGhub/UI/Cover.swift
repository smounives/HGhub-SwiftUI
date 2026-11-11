import SwiftUI

#if os(iOS)
typealias PlatformImage = UIImage
extension Image {
    init(platform img: PlatformImage) { self.init(uiImage: img) }
}
#else
typealias PlatformImage = NSImage
extension Image {
    init(platform img: PlatformImage) { self.init(nsImage: img) }
}
#endif

/// 解码后的图片缓存（避免滑动时重复解码）
@MainActor
enum DecodedImages {
    static let cache: NSCache<NSString, PlatformImage> = {
        let c = NSCache<NSString, PlatformImage>()
        c.countLimit = 300
        return c
    }()
}

/// 站点封面：经 `Media.image` 下载 + AES 解密后显示。
struct Cover: View {
    let url: String
    var contentMode: ContentMode = .fill

    @State private var image: PlatformImage?
    @State private var failed = false

    var body: some View {
        // Color.clear 承接父视图给的尺寸，图片作为 overlay 填充并裁切，不会把布局撑大
        Color.clear.overlay {
            if let image {
                Image(platform: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        if failed {
                            Image(systemName: "photo")
                                .font(.title2)
                                .foregroundStyle(.tertiary)
                        }
                    }
            }
        }
        .clipped()
        .task(id: url) { await load() }
        .accessibilityHidden(true)
    }

    private func load() async {
        guard !url.isEmpty else { failed = true; return }
        if let hit = DecodedImages.cache.object(forKey: url as NSString) {
            image = hit
            return
        }
        image = nil
        failed = false
        do {
            let data = try await Media.image(url)
            guard !Task.isCancelled else { return }
            let decoded = await Task.detached(priority: .utility) { () -> PlatformImage? in
                PlatformImage(data: data)
            }.value
            guard let decoded else { failed = true; return }
            DecodedImages.cache.setObject(decoded, forKey: url as NSString)
            withAnimation(.easeOut(duration: 0.2)) { image = decoded }
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}

/// 头像：有图走封面解密链路，没有就用昵称首字 + 色块
struct Avatar: View {
    var url: String = ""
    var name: String
    var color: String = ""
    var size: CGFloat = 40

    var body: some View {
        Group {
            if !url.isEmpty {
                Cover(url: url)
            } else {
                ZStack {
                    Circle().fill(Color(hex: color) ?? .accentColor.opacity(0.85))
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
