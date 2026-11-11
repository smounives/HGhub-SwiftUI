import SwiftUI

/* ───────────── 卡片 ───────────── */

/// 竖版海报卡（瀑布 / 横滑行）
struct PosterCard: View {
    let video: VideoCard
    var progress: WatchProgress?
    var width: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Cover(url: video.cover)
                .aspectRatio(3 / 4, contentMode: .fit)
                .frame(width: width)
                .clipShape(.rect(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if video.score > 0 {
                        Text(Fmt.score(video.score))
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.black.opacity(0.5), in: .capsule)
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottom) { meta }
                .contentShape(.rect(cornerRadius: 14))

            Text(video.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2, reservesSpace: true)
                .foregroundStyle(.primary)
                .frame(width: width, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(video.title)，\(video.episodesLabel)")
    }

    @ViewBuilder private var meta: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                Image(systemName: "flame.fill").font(.caption2)
                Text(Fmt.count(video.hot)).font(.caption2.weight(.semibold).monospacedDigit())
                Spacer(minLength: 4)
                Text(video.episodesLabel).font(.caption2)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
            if let p = progress, p.dur > 0 {
                GeometryReader { g in
                    Capsule().fill(.tint).frame(width: g.size.width * p.fraction)
                }
                .frame(height: 3)
            }
        }
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14, style: .continuous))
    }
}

/// 横排行（排行榜 / 历史 / 搜索结果的紧凑模式）
struct RowCard: View {
    let cover: String
    let title: String
    var subtitle: String = ""
    var caption: String = ""
    var badge: String?
    var progress: Double?

    var body: some View {
        HStack(spacing: 14) {
            Cover(url: cover)
                .frame(width: 78, height: 104)
                .clipShape(.rect(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if let badge {
                        Text(badge)
                            .font(.caption.weight(.heavy).monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(minWidth: 26, minHeight: 22)
                            .background(.black.opacity(0.6), in: .rect(cornerRadius: 8))
                            .padding(5)
                    }
                }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline).lineLimit(2)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if !caption.isEmpty {
                    Text(caption).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
                if let progress {
                    ProgressView(value: progress).tint(.accentColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .frame(height: 104)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// 自适应网格列：iPhone 2 列，iPad / Mac 按宽度自动排
struct AdaptiveGrid<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    var minWidth: CGFloat = 150
    @ViewBuilder var cell: (Item) -> Cell

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth, maximum: 260), spacing: 14, alignment: .top)],
                  alignment: .leading, spacing: 18) {
            ForEach(items) { cell($0) }
        }
    }
}

/// 排行榜用的海报卡：封面 + 名次角标 + 标题 + 副标题，适合自适应多列网格
struct RankPoster: View {
    let rank: Int
    let cover: String
    let title: String
    var subtitle: String = ""
    var progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Cover(url: cover)
                .aspectRatio(3 / 4, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .topLeading) {
                    Text("\(rank)")
                        .font(.caption.weight(.heavy).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(minWidth: 26, minHeight: 22)
                        .background(.black.opacity(0.6), in: .rect(cornerRadius: 8))
                        .padding(6)
                }
                .overlay(alignment: .bottom) {
                    if let p = progress, p > 0 {
                        GeometryReader { g in
                            Capsule().fill(.tint).frame(width: g.size.width * p)
                        }
                        .frame(height: 3)
                    }
                }
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(2, reservesSpace: true)
            if !subtitle.isEmpty {
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，第 \(rank) 名")
    }
}

/* ───────────── 状态 ───────────── */

struct LoadingView: View {
    var label = "加载中"
    var body: some View {
        ProgressView { Text(label).font(.footnote).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity, minHeight: 160)
    }
}

struct ErrorStateView: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label("加载失败", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            if let retry {
                Button("重试", systemImage: "arrow.clockwise", action: retry)
                    .buttonStyle(.glassProminent)
            }
        }
    }
}

/// 列表底部的「加载更多」哨兵
struct LoadMoreFooter: View {
    let loading: Bool
    let done: Bool
    /// 已加载条数：每加载一页就变化，让页脚重新出现，从而再次触发 onAppear。
    /// 不传的话只会触发一次，滚动到底后就不再加载下一页。
    var count: Int = -1
    let onAppear: () -> Void

    var body: some View {
        Group {
            if done {
                Text("没有更多了").font(.footnote).foregroundStyle(.tertiary)
            } else {
                ProgressView().opacity(loading ? 1 : 0.4)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .onAppear { if !done { onAppear() } }
        // id 放在最外层：条数变化时整块重建，onAppear 才会再次触发
        .id(count)
    }
}

/* ───────────── 提示 ───────────── */

struct ToastHost: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                ForEach(app.toasts) { t in
                    Label(t.message, systemImage: t.symbol)
                        .font(.subheadline.weight(.semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(t.kind == .heart ? Theme.heart : Color.primary)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .glassEffect(.regular, in: .capsule)
                        .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
                        .accessibilityAddTraits(.isStaticText)
                }
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }
}

/* ───────────── 标签 ───────────── */

struct TagChips: View {
    let tags: [String]
    var onTap: ((String) -> Void)?

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(tags, id: \.self) { t in
                Button(t) { onTap?(t) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
    }
}

/// 自动换行布局
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: min(maxX, width), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

extension View {
    /// 打开播放页的按钮样式：无系统高亮，保留按压缩放
    func pressable() -> some View { buttonStyle(PressableStyle()) }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

/* ───────────── 配色 ───────────── */

/// 配色：跟随系统明暗；强调色为系统蓝（AccentColor），
/// 视频层之上使用白色前景，「喜欢」使用系统红。
/* ───────────── 右上角圆形按钮 ───────────── */

/// 页面右上角的圆形玻璃按钮：搜索 / 设置 / 取消静音都复用它，
/// 各页面的位置与尺寸由此统一（40pt 圆、距上 8、距右 16）。
struct CircleGlassButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = ChromeMetric.button
    var glyph: CGFloat = 16
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: glyph, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.clear.interactive(), in: .circle)
        // 浅色页面上 clear 玻璃几乎看不见：补一圈极淡的描边，形状还在
        .overlay {
            Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .accessibilityLabel(label)
    }
}

/// 页面顶部的大标题行。右上角的圆按钮由 overlay 画在同一条中线上，
/// 因此「首页 / 分类 / 我的」的标题与按钮位置完全一致。
struct PageHeader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.largeTitle.bold())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, ChromeMetric.top)
            .padding(.horizontal, ChromeMetric.trailing)
            .padding(.bottom, 4)
    }
}

/// iPad / 大屏上的页面标题行：标题在左，操作在右，整行跟内容列同宽并居中，
/// 不会像手机那样贴在屏幕最边缘。
struct PageHeaderRow<Actions: View>: View {
    let title: String
    var maxWidth: CGFloat = 760
    let actions: () -> Actions

    init(_ title: String, maxWidth: CGFloat = 760, @ViewBuilder actions: @escaping () -> Actions) {
        self.title = title
        self.maxWidth = maxWidth
        self.actions = actions
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.largeTitle.bold())
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            actions()
        }
        .padding(.horizontal, 20)
        .padding(.top, ChromeMetric.top + 10)
        .padding(.bottom, 2)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

extension PageHeaderRow where Actions == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

/// 和 macOS 窗口左上角红绿灯同款的关闭点：平时只画红圆，悬停时浮现 ×
struct MacCloseDot: View {
    @State private var hovering = false

    var body: some View {
        ZStack {
            Circle().fill(Color(red: 0.99, green: 0.37, blue: 0.34))
            Image(systemName: "xmark")
                .font(.system(size: 7.5, weight: .heavy))
                .foregroundStyle(.black.opacity(hovering ? 0.62 : 0))
        }
        .frame(width: 13, height: 13)
        .onHover { hovering = $0 }
        .contentShape(.circle)
    }
}

enum ChromeMetric {
    /// 圆形按钮直径
    static let button: CGFloat = 40
    /// 距屏幕右边
    static let trailing: CGFloat = 16
    /// 距安全区顶部
    static let top: CGFloat = 8
    /// 两个圆按钮之间的间距
    static let gap: CGFloat = 8
}

extension View {
    /// 统一右上角按钮的位置；extra 用于把按钮让到别的按钮左侧
    func chromeCorner(extra trailing: CGFloat = 0) -> some View {
        self.padding(.top, ChromeMetric.top)
            .padding(.trailing, ChromeMetric.trailing + trailing)
    }
}

enum Theme {
    /// 深色底色：不是纯黑，而是深炭灰（约 #1C1C1E），浅色下为系统背景
    private static let tvDark = (r: 0.110, g: 0.110, b: 0.118)
    static var background: Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) {
            $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: tvDark.r, green: tvDark.g, blue: tvDark.b, alpha: 1)
                : NSColor.windowBackgroundColor
        })
        #else
        Color(uiColor: UIColor {
            $0.userInterfaceStyle == .dark
                ? UIColor(red: tvDark.r, green: tvDark.g, blue: tvDark.b, alpha: 1)
                : .systemBackground
        })
        #endif
    }
    /// 选中胶囊 / 播放按钮的玻璃着色
    static let selection = Color.accentColor.opacity(0.9)
    /// 点赞 / 心形 —— Apple 系统红
    static let heart = Color(red: 1.0, green: 0.27, blue: 0.23)
    /// 评分文字：不使用黄色，用半透明白
    static let rating = Color.white.opacity(0.88)
    /// 视频上方控制层的次级前景
    static let overlaySecondary = Color.white.opacity(0.7)
}
