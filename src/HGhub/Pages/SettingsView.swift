import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var showLines = false
    @State private var confirmClear = false
    @State private var checking = false
    @State private var update: API.UpdateInfo?
    @State private var diagnosing = false
    @State private var cacheBytes = 0

    var body: some View {
        @Bindable var app = app
        Form {
            Section("外观") {
                Picker("外观", selection: $app.appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle("默认静音", systemImage: "speaker.slash", isOn: $app.muted)
                Picker("默认倍速", systemImage: "gauge.with.dots.needle.67percent", selection: $app.rate) {
                    ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { r in
                        Text(r == r.rounded() ? String(format: "%.1fx", r) : "\(String(format: "%g", r))x").tag(r)
                    }
                }
                Toggle("预载下一个视频", systemImage: "square.stack.3d.down.right", isOn: $app.preloadNext)
            } header: {
                Text("播放")
            }

            Section {
                row("heart.text.square", "本地数据",
                    value: "\(app.favs.count) 收藏 · \(app.likes.count) 喜欢 · \(app.history.count) 记录")
                buttonRow("trash", "清理缓存", value: ByteCountFormatter.string(fromByteCount: Int64(cacheBytes), countStyle: .file)) {
                    confirmClear = true
                }
            } header: {
                Text("本地数据")
            }

            Section("网络") {
                buttonRow("bolt.horizontal", "线路", value: lineLabel) { showLines = true }
                buttonRow("stethoscope", "网络诊断", busy: diagnosing) { diagnose() }
                    .disabled(diagnosing)
            }

            Section("其他") {
                buttonRow("arrow.triangle.2.circlepath", "检查更新", busy: checking) { check() }
                    .disabled(checking)
                buttonRow("link", "复制仓库地址") { app.copy("https://github.com/\(API.repo)", note: "仓库地址已复制") }
                row("info.circle", "版本", value: API.appVersion)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("设置")
        .sheet(isPresented: $showLines) {
            LinesView()
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 620)
                #endif
        }
        .confirmationDialog("清理缓存", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("确定清理", role: .destructive) {
                Media.clearCaches()
                DecodedImages.cache.removeAllObjects()
                cacheBytes = Media.diskCacheBytes()
                app.toast("缓存已清理", .ok)
            }
        } message: {
            Text("只清除封面与播放列表缓存（解密图 / m3u8）")
        }
        .alert("发现新版本", isPresented: Binding(get: { update?.hasUpdate == true }, set: { if !$0 { update = nil } }), presenting: update) { u in
            Button("前往下载") { if let url = URL(string: u.url) { openURL(url) } }
            Button("稍后", role: .cancel) {}
        } message: { u in
            Text("v\(u.current) → v\(u.latest)\(u.publishedAt.isEmpty ? "" : " · \(u.publishedAt.prefix(10))")\n\n\(u.notes)")
        }
        .onAppear {
            cacheBytes = Media.diskCacheBytes()
            app.lineBase = Net.shared.base
            if DebugRoute.is("lines") { showLines = true }
        }
    }

    private var lineLabel: String {
        if let f = Lines.fixed.first(where: { $0.url == app.lineBase }) {
            return f.url == Net.defaultBase ? "\(f.name)（默认）" : f.name
        }
        return URL(string: app.lineBase)?.host ?? app.lineBase
    }

    private func check() {
        checking = true
        Task {
            defer { checking = false }
            do {
                let u = try await API.checkUpdate()
                if u.hasUpdate { update = u } else {
                    app.toast(u.latest.isEmpty ? "还没有发布版本" : "已是最新版本（v\(u.current)）", .ok)
                }
            } catch {
                app.toast(Net.describe(error))
            }
        }
    }

    private func diagnose() {
        diagnosing = true
        Task {
            defer { diagnosing = false }
            let d = await Net.shared.diagnose()
            let text = String(decoding: d.data(pretty: true), as: UTF8.self)
            let line = "[\(Date().formatted(.iso8601))] [net_diag] \(text)\n"
            let log = AppPaths.file("debug.log")
            if let h = try? FileHandle(forWritingTo: log) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: log)
            }
            app.copy(text, note: "网络诊断结果已复制")
        }
    }
}

/* ───────────── 线路 ───────────── */

struct LinesView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var mirrors: [Lines.Line] = []
    @State private var probes: [String: Lines.Probe] = [:]
    @State private var loadingMirrors = false
    @State private var probing = false
    @State private var mirrorError: String?
    @State private var custom = ""

    var body: some View {
        NavigationStack {
            List {
                // 当前实际在用的线路（自动切换后会跟着变）
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Lines.fixed.first(where: { $0.url == app.lineBase })?.name
                                 ?? URL(string: app.lineBase)?.host ?? app.lineBase)
                                .font(.headline)
                            Text(app.lineBase).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if let p = probes[app.lineBase] {
                            Text(p.ok ? "\(p.ms) ms" : "不可用")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(p.ok ? .green : .red)
                        }
                    }
                } header: {
                    Text("当前线路")
                }

                Section {
                    Toggle("自动切换线路", isOn: Binding(get: { app.autoLine }, set: { app.autoLine = $0 }))
                }

                Section {
                    Toggle("IPv6 优先", isOn: Binding(get: { app.ipv6First }, set: { app.ipv6First = $0 }))
                    Toggle("连接复用（30 秒）", isOn: Binding(get: { app.keepAlive }, set: { app.keepAlive = $0 }))
                    Toggle("4xx 快速失败", isOn: Binding(get: { app.fastFail4xx }, set: { app.fastFail4xx = $0 }))
                    Toggle("严格安全模式", isOn: Binding(get: { app.strictSecurity }, set: { app.strictSecurity = $0 }))
                } header: {
                    Text("网络加固")
                }
                Section("官方线路") {
                    ForEach(sorted(Lines.fixed)) { row($0) }
                }
                Section {
                    if loadingMirrors {
                        HStack { ProgressView(); Text("正在读取地址发布页…").foregroundStyle(.secondary) }
                    } else if let mirrorError {
                        Label(mirrorError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Button("重试", systemImage: "arrow.clockwise") { Task { await loadMirrors() } }
                    } else if mirrors.isEmpty {
                        Text("暂无镜像").foregroundStyle(.secondary)
                    }
                    ForEach(sorted(mirrors)) { row($0) }
                } header: {
                    HStack {
                        Text("镜像线路")
                        Spacer()
                        if !mirrors.isEmpty { Text("\(mirrors.count) 条").foregroundStyle(.secondary) }
                    }
                }
                Section("自定义") {
                    HStack {
                        TextField("https://example.com", text: $custom)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif
                            .autocorrectionDisabled()
                            .onSubmit { choose(custom) }
                        Button("使用") { choose(custom) }
                            .buttonStyle(.glassProminent)
                            .disabled(Net.normalize(custom) == nil)
                    }
                }
            }
            .navigationTitle("线路")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成", systemImage: "checkmark") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await probeAll() } } label: {
                        if probing { ProgressView() } else { Label("测速", systemImage: "speedometer") }
                    }
                    .disabled(probing)
                }
            }
            .refreshable { await loadMirrors() }
            .task { if mirrors.isEmpty { await loadMirrors() } }
        }
    }

    /// 测速之后按延迟从小到大排：可用的在前（ms 升序），没测到 / 不可用的保持原顺序垫后
    private func sorted(_ list: [Lines.Line]) -> [Lines.Line] {
        guard !probes.isEmpty else { return list }
        return list.enumerated().sorted { a, b in
            let pa = probes[a.element.url], pb = probes[b.element.url]
            switch (pa?.ok == true, pb?.ok == true) {
            case (true, true): return (pa?.ms ?? 0, a.offset) < (pb?.ms ?? 0, b.offset)
            case (true, false): return true
            case (false, true): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    @ViewBuilder private func row(_ l: Lines.Line) -> some View {
        let current = app.lineBase == l.url
        Button { choose(l.url) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(l.name).foregroundStyle(.primary)
                    if l.name != l.host { Text(l.host).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if let p = probes[l.url] {
                    Text(p.ok ? "\(p.ms) ms" : (p.status.map { "HTTP \($0)" } ?? "不可用"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(p.ok ? (p.ms < 800 ? .green : .orange) : .red)
                        .help(p.error ?? "")
                }
                if current {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    private func choose(_ url: String) {
        do {
            let next = try Net.shared.setBase(url)
            app.lineBase = next
            Media.playlistCache.clear()
            app.toast("已切换到 \(URL(string: next)?.host ?? next)", .ok)
        } catch {
            app.toast(Net.describe(error))
        }
    }

    private func loadMirrors() async {
        loadingMirrors = true
        mirrorError = nil
        defer { loadingMirrors = false }
        do { mirrors = try await Lines.mirrors().items } catch { mirrorError = Net.describe(error) }
    }

    private func probeAll() async {
        probing = true
        defer { probing = false }
        let urls = (Lines.fixed + mirrors).map(\.url)
        for p in await Lines.probe(urls) { probes[p.url] = p }
    }
}

// MARK: - 设置行

private extension SettingsView {
    /// 只读信息行
    func row(_ symbol: String, _ title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
            Text(title)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }

    /// 可点击行：整行可点，右侧显示值 / 进度 / 箭头
    @ViewBuilder
    func buttonRow(_ symbol: String, _ title: String, value: String? = nil, busy: Bool = false,
                   action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
                Text(title)
                Spacer(minLength: 8)
                if busy {
                    ProgressView().controlSize(.small)
                } else if let value {
                    Text(value).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
