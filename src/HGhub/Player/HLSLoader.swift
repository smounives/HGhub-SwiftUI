import AVFoundation
import Foundation

/// AVAssetResourceLoader 代理：替代旧版 `hg://localhost/hls` 自定义协议。
///
/// - `hghls://p/?u=<m3u8>`：拉播放列表（带站点 Referer + 内存缓存），把子列表 / key 改写回自定义 scheme
/// - `hgkey://p/?u=<key>`：拉 AES-128 key（缓存，拖动进度时不重复请求）
///
/// 分片保持原 https 地址，由 AVFoundation 直接走网络（HLS 规范要求分片不能经由 resource loader）。
final class HLSLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "hg"
    static let hlsScheme = "\(scheme)hls"
    static let keyScheme = "\(scheme)key"

    static let queue = DispatchQueue(label: "hghub.hls.loader", qos: .userInitiated, attributes: .concurrent)

    /// 播放源：m3u8 走代理 scheme，其它（mp4 等）直接返回原地址
    static func assetURL(for source: String) -> URL? {
        if Media.isM3U8(source) {
            return URL(string: Media.proxied(source, scheme: scheme))
        }
        return URL(string: source)
    }

    private let tasks = TaskBag()

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, let s = url.scheme,
              s == HLSLoader.hlsScheme || s == HLSLoader.keyScheme,
              let target = Media.unproxied(url) else { return false }

        let isPlaylist = s == HLSLoader.hlsScheme
        let req = UncheckedRequest(value: loadingRequest)
        let id = ObjectIdentifier(loadingRequest)
        let task = Task.detached(priority: .userInitiated) {
            do {
                let data: Data
                let type: String
                if isPlaylist {
                    data = Data(try await Media.playlist(target, scheme: HLSLoader.scheme).utf8)
                    type = "public.m3u-playlist"
                } else {
                    data = try await Media.key(target)
                    type = "public.data"
                }
                if Task.isCancelled { return }
                req.finish(data: data, contentType: type)
            } catch {
                req.fail(error)
            }
        }
        tasks.add(id, task)
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        tasks.cancel(ObjectIdentifier(loadingRequest))
    }

    deinit { tasks.cancelAll() }
}

/// AVAssetResourceLoadingRequest 不是 Sendable，但它本身就是被设计成跨线程完成的。
private struct UncheckedRequest: @unchecked Sendable {
    let value: AVAssetResourceLoadingRequest

    func finish(data: Data, contentType: String) {
        if let info = value.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = false
        }
        // 声明了不支持字节区间，AVFoundation 期待一次拿到完整资源：
        // 它首个请求只要 2 字节，若按 requestedLength 截断，会报 -12847「不支持的媒体格式」。
        if let dr = value.dataRequest {
            let start = Int(dr.requestedOffset)
            if start < data.count { dr.respond(with: data.subdata(in: start..<data.count)) }
        }
        value.finishLoading()
    }

    func fail(_ error: Error) {
        value.finishLoading(with: NSError(domain: "HGhub", code: -1,
                                          userInfo: [NSLocalizedDescriptionKey: Net.describe(error)]))
    }
}

private final class TaskBag: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [ObjectIdentifier: Task<Void, Never>] = [:]

    func add(_ id: ObjectIdentifier, _ t: Task<Void, Never>) {
        lock.withLock { map[id] = t }
    }

    func cancel(_ id: ObjectIdentifier) {
        lock.withLock { map.removeValue(forKey: id) }?.cancel()
    }

    func cancelAll() {
        let all = lock.withLock { () -> [Task<Void, Never>] in
            let v = Array(map.values); map.removeAll(); return v
        }
        all.forEach { $0.cancel() }
    }
}
