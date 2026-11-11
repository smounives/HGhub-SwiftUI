import Foundation

/// 调试用：`-HGRoute <page>` 启动参数直接打开某个页面，便于逐页截图验收。Release 构建恒为 nil。
enum DebugRoute {
    static var value: String? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "HGRoute")
        #else
        return nil
        #endif
    }

    static func `is`(_ name: String) -> Bool { value == name }

    static var argument: String? {
        guard let v = value, let i = v.firstIndex(of: ":") else { return nil }
        return String(v[v.index(after: i)...])
    }

    static func has(prefix: String) -> Bool { value?.hasPrefix(prefix) == true }
}
