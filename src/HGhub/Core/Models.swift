import Foundation

struct Author: Hashable, Sendable {
    var id: Int
    var name: String
    var avatar: String
    var followers: Int
    var following: Int
    var likeCount: Int
    var isFollowing: Bool

    init(_ j: JSON) {
        id = j["id"].intValue
        name = j["name"].str
        avatar = j["avatar"].str
        followers = j["followers"].intValue
        following = j["following"].intValue
        likeCount = j["like_count"].intValue
        isFollowing = j["is_following"].boolValue
    }
}

struct Pagination: Hashable, Sendable {
    var page: Int
    var pages: Int
    var size: Int
    var total: Int

    init(_ j: JSON) {
        page = j["page"].intValue
        pages = max(1, j["pages"].intValue)
        size = j["size"].intValue
        total = j["total"].intValue
    }
}

struct Paged<T: Sendable>: Sendable {
    var items: [T]
    var pagination: Pagination
}

/// 列表卡片（首页 / 分类 / 搜索）
struct VideoCard: Identifiable, Hashable, Sendable {
    var id: Int
    var title: String
    var cover: String
    var description: String
    var tags: [String]
    var score: Double
    var episodeCount: Int
    var totalEpisodes: Int
    var duration: Int
    var hot: Int
    var likeCount: Int
    var collectCount: Int
    var commentCount: Int
    var isFinished: Bool
    var isOriginal: Bool
    var createdAt: String
    var author: Author?

    init(_ j: JSON) {
        id = j["id"].intValue
        title = j["title"].str
        cover = j["cover"].str
        description = j["description"].str
        tags = j["tags"].strings
        score = j["score"].num
        episodeCount = j["episode_count"].intValue
        totalEpisodes = j["total_episodes"].intValue
        duration = j["duration"].intValue
        hot = j["hot"].intValue
        likeCount = j["like_count"].intValue
        collectCount = j["collect_count"].intValue
        commentCount = j["comment_count"].intValue
        isFinished = j["is_finished"].boolValue
        isOriginal = j["is_original"].boolValue
        createdAt = j["created_at"].str
        author = j["author"].isNull ? nil : Author(j["author"])
    }

    /// 排行榜条目也能直接当卡片用
    init(rank r: RankItem) {
        id = r.videoId
        title = r.title
        cover = r.cover
        description = ""
        tags = r.tags
        score = r.score
        episodeCount = r.episodeCount
        totalEpisodes = 0
        duration = 0
        hot = r.metricValue
        likeCount = r.like
        collectCount = r.collect
        commentCount = r.comment
        isFinished = r.isFinished
        isOriginal = false
        createdAt = ""
        author = nil
    }

    var episodesLabel: String {
        let n = max(episodeCount, totalEpisodes)
        if n <= 0 { return "" }
        return isFinished ? "全\(n)集" : "更新至\(n)集"
    }
}

struct Episode: Identifiable, Hashable, Sendable {
    var epNum: Int
    var title: String
    var duration: Int
    var status: Int
    var id: Int { epNum }

    init(_ j: JSON) {
        epNum = j["ep_num"].intValue
        title = j["title"].str
        duration = j["duration"].intValue
        status = j["status"].intValue
    }
}

/// 剧集详情
struct VideoDetail: Identifiable, Hashable, Sendable {
    var id: Int
    var title: String
    var description: String
    var cover: String
    var tags: [String]
    var score: Double
    var episodeCount: Int
    var totalEpisodes: Int
    var episodes: [Episode]
    var collect: Int
    var comment: Int
    var hot: Int
    var like: Int
    var author: Author
    var collected: Bool
    var liked: Bool
    var isFinished: Bool
    var createdAt: String
    var categoryName: String

    init(_ j: JSON) {
        id = j["id"].intValue
        title = j["title"].str
        description = j["description"].str
        cover = j["cover"].str
        tags = j["tags"].strings
        score = j["score"].num
        episodeCount = j["episode_count"].intValue
        totalEpisodes = j["total_episodes"].intValue
        episodes = j["episodes"].array.map(Episode.init).sorted { $0.epNum < $1.epNum }
        let c = j["counts"]
        collect = c["collect"].intValue
        comment = c["comment"].intValue
        hot = c["hot"].intValue
        like = c["like"].intValue
        author = Author(j["author"])
        collected = j["interaction"]["collected"].boolValue
        liked = j["interaction"]["liked"].boolValue
        isFinished = j["is_finished"].boolValue
        createdAt = j["created_at"].str
        categoryName = j["breadcrumb"][0]["name"].str
    }

    var epCount: Int { max(episodes.count, episodeCount, totalEpisodes, 1) }
}

/// 播放地址（新 playback 接口 → 主线 / HEVC）
struct PlayInfo: Hashable, Sendable {
    var id: Int
    var ep: Int
    var title: String
    var duration: Int
    var url: String
    var hevc: String
}

struct RankItem: Identifiable, Hashable, Sendable {
    var rank: Int
    var videoId: Int
    var title: String
    var cover: String
    var tags: [String]
    var score: Double
    var categoryName: String
    var episodeCount: Int
    var isFinished: Bool
    var metricLabel: String
    var metricValue: Int
    var collect: Int
    var comment: Int
    var like: Int
    var play: Int
    var id: Int { videoId }

    init(_ j: JSON) {
        rank = j["rank"].intValue
        videoId = j["video_id"].intValue
        title = j["title"].str
        cover = j["cover"].str
        tags = j["tags"].strings
        score = j["score"].num
        categoryName = j["cate_name"].str
        episodeCount = j["episode_count"].intValue
        isFinished = j["is_finished"].boolValue
        metricLabel = j["metric_label"].str
        metricValue = j["metric_value"].intValue
        let m = j["metrics"]
        collect = m["collect"].intValue
        comment = m["comment"].intValue
        like = m["like"].intValue
        play = m["play"].intValue
    }
}

struct Comment: Identifiable, Hashable, Sendable {
    var id: Int
    var userId: Int
    var nickname: String
    var avatar: String
    var avatarColor: String
    var text: String
    var time: String
    var likeCount: Int
    var liked: Bool
    var replyCount: Int
    var replyId: Int
    var replies: [Comment]
    var isPinned: Bool
    var ipRegion: String

    init(_ j: JSON) {
        id = j["id"].intValue
        userId = j["user_id"].intValue
        nickname = j["nickname"].str
        avatar = j["avatar"].str
        avatarColor = j["avatar_color"].str
        let t = j["text"].str
        text = t.isEmpty ? j["content"].str : t
        let tm = j["time"].str
        time = tm.isEmpty ? j["created_at"].str : tm
        likeCount = j["like_count"].intValue
        liked = j["liked"].boolValue
        replyCount = j["reply_count"].intValue
        replyId = j["reply_id"].intValue
        replies = j["reply_list"].array.map(Comment.init)
        isPinned = j["is_pinned"].boolValue
        ipRegion = j["ip_region"].str
    }
}

struct CommentPage: Sendable {
    var ep: Int
    var items: [Comment]
    var pagination: Pagination
}

/// 吃瓜帖子
struct Post: Identifiable, Hashable, Sendable {
    var id: Int
    var title: String
    var desc: String
    var content: String
    var cover: String
    var tags: [String]
    var hot: Int
    var videoURL: String
    var videos: [String]
    var author: Author?
    var like: Int
    var comment: Int
    var collect: Int
    var liked: Bool
    var collected: Bool
    var publishTime: String

    init(_ j: JSON) {
        id = j["id"].intValue
        title = j["title"].str
        desc = j["desc"].str
        content = j["content"].str
        cover = j["cover"].str
        tags = j["tags"].strings
        let c = j["counts"]
        hot = j["hot"].int ?? c["hot"].intValue
        videoURL = j["video_url"].str
        videos = j["videos"].array.compactMap { $0["url"].string ?? $0.string }.filter { !$0.isEmpty }
        author = j["author"].isNull ? nil : Author(j["author"])
        like = c["like"].intValue
        comment = c["comment"].intValue
        collect = c["collect"].intValue
        liked = j["interaction"]["liked"].boolValue
        collected = j["interaction"]["collected"].boolValue
        let p = j["publish_time"].str
        publishTime = p.isEmpty ? j["created_at"].str : p
    }

    var hasVideo: Bool { !videoURL.isEmpty }
}

struct User: Hashable, Sendable, Codable {
    var id: Int
    var username: String
    var nickname: String
    var avatar: String
    var avatarColor: String
    var sign: String
    var likeCount: Int
    var collectCount: Int
    var followingCount: Int
    var likeVideoIds: [Int]
    var favoriteVideoIds: [Int]
    var followUserIds: [Int]
    var raw: JSON

    init(_ j: JSON) {
        id = j["id"].intValue
        username = j["username"].str
        let n = j["nickname"].str
        nickname = n.isEmpty ? j["username"].str : n
        avatar = j["avatar"].str
        avatarColor = j["avatar_color"].str
        sign = j["sign"].string ?? j["desc"].str
        let c = j["counts"]
        likeCount = c["like"].intValue
        collectCount = c["collect"].int ?? c["favorite"].intValue
        followingCount = c["following"].int ?? c["follow"].intValue
        let it = j["interactions"]
        likeVideoIds = it["like_video_ids"].array.compactMap(\.int)
        favoriteVideoIds = it["favorite_video_ids"].array.compactMap(\.int)
        followUserIds = it["follow_user_ids"].array.compactMap(\.int)
        raw = j
    }
}

/* ───────────── 格式化 ───────────── */

enum Fmt {
    /// 1.2万 / 3.4亿
    static func count(_ n: Int) -> String {
        let v = Double(n)
        func trim(_ x: Double) -> String {
            let s = String(format: "%.1f", x)
            return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
        }
        if v >= 100_000_000 { return trim(v / 100_000_000) + "亿" }
        if v >= 10_000 { return trim(v / 10_000) + "万" }
        return String(n)
    }

    /// 秒 → m:ss（超过 1 小时 h:mm:ss）
    static func time(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "0:00" }
        let t = Int(s)
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func score(_ s: Double) -> String { s > 0 ? String(format: "%.1f", s) : "" }
}
