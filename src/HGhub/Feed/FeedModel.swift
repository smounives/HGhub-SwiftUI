import Foundation
import Observation

/// 播放页数据：按 id 懒加载详情、按 (id, ep) 取播放地址。
@MainActor
@Observable
final class FeedModel {
    private(set) var details: [Int: VideoDetail] = [:]
    private(set) var detailErrors: [Int: String] = [:]
    /// 每部剧当前在看第几集
    var episode: [Int: Int] = [:]

    @ObservationIgnored private var playCache: [String: PlayInfo] = [:]
    @ObservationIgnored private var inflight: Set<Int> = []

    func detail(_ id: Int) -> VideoDetail? { details[id] }

    func ep(_ id: Int) -> Int { episode[id] ?? 1 }

    /// 预取详情（当前条 + 前后各 2 条）
    func prefetch(_ ids: [Int], around index: Int) {
        guard !ids.isEmpty else { return }
        let lo = max(0, index - 1), hi = min(ids.count - 1, index + 2)
        guard lo <= hi else { return }
        for i in lo...hi { loadDetail(ids[i]) }
    }

    func loadDetail(_ id: Int, force: Bool = false) {
        guard id > 0, force || (details[id] == nil && !inflight.contains(id)) else { return }
        inflight.insert(id)
        detailErrors[id] = nil
        Task {
            defer { inflight.remove(id) }
            do {
                details[id] = try await API.video(id)
            } catch {
                detailErrors[id] = Net.describe(error)
            }
        }
    }

    func play(_ id: Int, ep: Int) async throws -> PlayInfo {
        let key = "\(id)-\(ep)"
        if let hit = playCache[key] { return hit }
        let info = try await API.play(id, ep: ep)
        playCache[key] = info
        return info
    }

    /// 地址过期 / 加载失败时清掉缓存重新取
    func invalidate(_ id: Int, ep: Int) {
        playCache["\(id)-\(ep)"] = nil
    }

    func updateDetail(_ id: Int, _ f: (inout VideoDetail) -> Void) {
        guard var d = details[id] else { return }
        f(&d)
        details[id] = d
    }
}
