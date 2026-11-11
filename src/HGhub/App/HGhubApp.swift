import SwiftUI

@main
struct HGhubApp: App {
    @State private var app = AppModel()
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .preferredColorScheme(app.appearance.scheme)
                .task { app.applyAppearance(); await app.boot() }
                #if os(macOS)
                .frame(minWidth: 900, minHeight: 600)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)
        .commands { AppCommands(app: app) }
        #endif

        #if os(macOS)
        Settings {
            NavigationStack { SettingsView() }
                .environment(app)
                .preferredColorScheme(app.appearance.scheme)
                .frame(width: 520, height: 640)
        }
        #endif
    }
}

#if os(iOS)
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        .allButUpsideDown
    }
}
#endif

#if os(macOS)
struct AppCommands: Commands {
    let app: AppModel

    var body: some Commands {
        CommandMenu("播放") {
            Button(app.player.isPlaying ? "暂停" : "播放") { app.player.toggle() }
                .keyboardShortcut(.space, modifiers: [])
            Button("快退 10 秒") { app.player.skip(-10) }.keyboardShortcut(.leftArrow, modifiers: .command)
            Button("快进 10 秒") { app.player.skip(10) }.keyboardShortcut(.rightArrow, modifiers: .command)
            Divider()
            Button(app.muted ? "取消静音" : "静音") { app.muted.toggle() }.keyboardShortcut("m", modifiers: [])
            Menu("倍速") {
                ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { r in
                    Button("\(String(format: "%g", r))x") { app.rate = r }
                }
            }
        }
        CommandGroup(after: .sidebar) {
            Button("首页") { app.tab = .rec }.keyboardShortcut("1")
            Button("热门") { app.tab = .hot }.keyboardShortcut("2")
            Button("最新") { app.tab = .latest }.keyboardShortcut("3")
            Button("排行榜") { app.tab = .ranks }.keyboardShortcut("4")
            Button("分类") { app.tab = .category }.keyboardShortcut("5")
            Button("搜索") { app.tab = .search }.keyboardShortcut("6")
            Button("我的") { app.tab = .profile }.keyboardShortcut("7")
            Button("设置") { app.tab = .settings }.keyboardShortcut(",", modifiers: [.command, .shift])
        }
        CommandGroup(after: .appInfo) {
            Button(app.user == nil ? "登录…" : "退出登录") {
                if app.user == nil { app.loginPresented = true } else { Task { await app.logout() } }
            }
        }
    }
}
#endif

/// 根视图：系统 TabView（iPhone 底部悬浮玻璃 Tab 栏 / iPad & Mac 自适应侧边栏）
struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.tab) {
            #if os(macOS)
            // macOS 侧栏：推荐、热门、最新、排行榜、我的、设置；分类 / 搜索放在下方「发现」分组
            Tab("首页", systemImage: "house.fill", value: AppTab.rec) {
                TabStack(.rec) { HomeView(feed: .rec) }
            }
            Tab("热门", systemImage: "flame.fill", value: AppTab.hot) {
                TabStack(.hot) { HomeView(feed: .hot) }
            }
            Tab("最新", systemImage: "clock.fill", value: AppTab.latest) {
                TabStack(.latest) { HomeView(feed: .new) }
            }
            Tab("排行榜", systemImage: "trophy.fill", value: AppTab.ranks) {
                TabStack(.ranks) { RanksView() }
            }
            Tab("我的", systemImage: "person.crop.circle.fill", value: AppTab.profile) {
                TabStack(.profile) { ProfileView() }
            }
            Tab("设置", systemImage: "gearshape.fill", value: AppTab.settings) {
                TabStack(.settings) { SettingsView() }
            }
            TabSection("发现") {
                Tab("分类", systemImage: "square.grid.2x2.fill", value: AppTab.category) {
                    TabStack(.category) { CategoryView() }
                }
                Tab("搜索", systemImage: "magnifyingglass", value: AppTab.search) {
                    TabStack(.search) { SearchView() }
                }
            }
            #else
            // iOS / iPadOS：底部五个标签，首个标签与 macOS 一致叫「首页」
            Tab("首页", systemImage: "house.fill", value: AppTab.rec) {
                TabStack(.rec) { HomeView(feed: .rec) }
            }
            Tab("热门", systemImage: "flame.fill", value: AppTab.hot) {
                TabStack(.hot) { HomeView(feed: .hot) }
            }
            Tab("最新", systemImage: "clock.fill", value: AppTab.latest) {
                TabStack(.latest) { HomeView(feed: .new) }
            }
            Tab("分类", systemImage: "square.grid.2x2.fill", value: AppTab.category) {
                TabStack(.category) { CategoryView() }
            }
            Tab("我的", systemImage: "person.crop.circle.fill", value: AppTab.profile) {
                TabStack(.profile) { ProfileView() }
            }
            #endif
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewSidebarBottomBar { SidebarFooter() }
        #if os(iOS)
        // 关掉标签栏自带的那层底色，否则视频上会出现一条横贯的浅色遮罩
        .toolbarBackgroundVisibility(.hidden, for: .tabBar)
        // 不用「滚动收起」：竖向翻页视频会让标签栏被反复收起/展开，表现为上下闪动。
        .tabBarMinimizeBehavior(.never)
        #endif
        .overlay { ToastHost() }
        .sheet(isPresented: $app.loginPresented) { LoginView() }
        .onChange(of: app.tab) { _, _ in app.clean = false }
        .task { await applyDebugRoute() }
    }

    /// 当前标签页栈顶是否是播放页，或正处于全屏
    private var inPlayer: Bool {
        if app.immersive { return true }
        if case .feed = app.nav(app.tab).path.last { return true }
        return false
    }

    private func applyDebugRoute() async {
        guard let r = DebugRoute.value else { return }
        // 等 NavigationStack 就绪后再 push，否则 path 会被忽略
        if r != "login" { try? await Task.sleep(for: .seconds(1)) }
        func go(_ tab: AppTab, _ route: Route? = nil) async {
            app.tab = tab
            guard let route else { return }
            // 先让目标 Tab 的 NavigationStack 建好，再 push，避免 path 被初始化覆盖
            try? await Task.sleep(for: .seconds(1))
            app.push(route)
        }
        switch r {
        case "category": await go(.category)
        case "channel": await go(.category, .channel(Channel.all[0]))
        case "ranks":
            #if os(macOS)
            await go(.ranks)
            #else
            await go(.category, .ranks)
            #endif
        case "posts": await go(.category, .posts)
        case "profile", "history": await go(.profile)
        case "settings", "lines":
            #if os(macOS)
            await go(.settings)
            #else
            await go(.profile, .settings)
            #endif
        case "hot":
            #if os(macOS)
            await go(.hot)
            #endif
        case "new":
            #if os(macOS)
            await go(.latest)
            #endif
        case "login": app.loginPresented = true
        case _ where r.hasPrefix("script:"):
            // 调试脚本：script:tab=category,open,wait=6,tab=profile,pop,immersive=1 …
            for step in r.dropFirst(7).split(separator: ",") {
                let kv = step.split(separator: "=", maxSplits: 1).map(String.init)
                switch kv[0] {
                case "wait": try? await Task.sleep(for: .seconds(Double(kv[1]) ?? 1))
                case "tab": if let t = AppTab(rawValue: kv[1]) { app.tab = t }
                case "open":
                    if let res = try? await API.feed(page: 1, size: 5, sort: .hot) {
                        app.open(res.items.map(\.id), at: 0, title: "调试")
                    }
                case "pop": if !app.nav(app.tab).path.isEmpty { app.nav(app.tab).path.removeLast() }
                case "immersive": app.immersive = kv[1] == "1"
                default: break
                }
            }
        case "home-switch", "home-switch-profile":
            // 调试：首页播放 8 秒后切到别的标签页，复现标签栏状态
            try? await Task.sleep(for: .seconds(8))
            app.tab = r == "home-switch" ? .category : .profile
        case "open-ranks", "open-category", "open-search", "open-profile":
            // 调试：在对应标签页里直接 push 一个播放页，验证列表点开的导航链路
            let t: AppTab = r == "open-ranks" ? .ranks : r == "open-category" ? .category : r == "open-search" ? .search : .profile
            await go(t)
            try? await Task.sleep(for: .seconds(2))
            if let res = try? await API.feed(page: 1, size: 5, sort: .hot) {
                app.open(res.items.map(\.id), at: 0, title: "调试")
            }
        default:
            if r.hasPrefix("search") {
                #if os(macOS)
                await go(.search)
                #else
                await go(.category, .search)
                #endif
            }
            if r.hasPrefix("post:"), let id = Int(DebugRoute.argument ?? "") { await go(.category, .post(id)) }
        }
    }
}

/// 侧边栏底部（iPad / Mac）：账号 + 版本号，与旧版桌面端一致
private struct SidebarFooter: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                if app.user == nil { app.loginPresented = true } else { app.tab = .profile }
            } label: {
                HStack(spacing: 10) {
                    if let u = app.user {
                        Avatar(url: u.avatar, name: u.nickname, color: u.avatarColor, size: 30)
                        Text(u.nickname).font(.subheadline.weight(.semibold)).lineLimit(1)
                    } else {
                        Image(systemName: "person.crop.circle").font(.title2).foregroundStyle(.secondary)
                        Text("登录 / 注册").font(.subheadline.weight(.semibold))
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            #if os(iOS)
            Button("设置", systemImage: "gearshape") { app.tab = .profile; app.push(.settings) }
                .font(.subheadline).buttonStyle(.plain).foregroundStyle(.secondary)
            #endif
            Text("HGhub for \(Self.platform) \(API.appVersion)")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    static var platform: String {
        #if os(macOS)
        "macOS"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #endif
    }
}

extension View {
    func routes() -> some View {
        navigationDestination(for: Route.self) { r in
            switch r {
            case .feed(let f):
                FeedView(ids: f.ids, mode: .context, title: f.title, startIndex: f.index,
                         startEp: f.startEp, startTime: f.startTime)
            case .channel(let c): ChannelView(channel: c)
            case .ranks: RanksView()
            case .settings: SettingsView()
            case .search: SearchView()
            case .posts: PostsView()
            case .post(let id): PostDetailView(id: id)
            }
        }
    }
}

/// 每个标签页一个独立导航栈：路径放在该标签页专属的 `@Observable` 对象里，`NavigationStack` 直接绑定它。
struct TabStack<Root: View>: View {
    @Environment(AppModel.self) private var app
    let tab: AppTab
    private let root: Root

    init(_ tab: AppTab, @ViewBuilder root: () -> Root) {
        self.tab = tab
        self.root = root()
    }

    var body: some View {
        StackHost(nav: app.nav(tab)) { root }
    }

    private struct StackHost<Content: View>: View {
        @Bindable var nav: TabNav
        @ViewBuilder let content: Content

        var body: some View {
            NavigationStack(path: $nav.path) {
                content.routes()
            }
        }
    }
}
