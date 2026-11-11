import Foundation
import Testing
@testable import HGhub

/// 登录态联调：需要 `HGHUB_TEST_USER` / `HGHUB_TEST_PASS`（不设则跳过）。
/// 每个写操作都「开 → 关」成对执行，测试结束后账号状态不变；评论是公开且不可删的，不在这里发送。
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HGHUB_TEST_USER"] != nil))
struct AuthLiveTests {
    let user = ProcessInfo.processInfo.environment["HGHUB_TEST_USER"] ?? ""
    let pass = ProcessInfo.processInfo.environment["HGHUB_TEST_PASS"] ?? ""

    @Test func fullAuthedFlow() async throws {
        let saved = (SessionStore.shared.token, SessionStore.shared.user)
        defer {
            if let t = saved.0 { SessionStore.shared.set(token: t, user: saved.1) } else { SessionStore.shared.clear() }
        }

        // 登录（失败则注册）
        var u: User
        do {
            u = try await API.login(username: user, password: pass)
        } catch {
            u = try await API.register(username: user, password: pass, email: "")
        }
        #expect(u.id > 0)
        #expect(SessionStore.shared.token != nil)

        let me = try await API.me()
        #expect(me.username == user)

        let v = try #require(try await API.feed(page: 1, size: 1).items.first)
        let d = try await API.video(v.id)

        try await API.like(v.id, ep: 1, on: true)
        try await API.like(v.id, ep: 1, on: false)
        try await API.collect(v.id, on: true)
        let after = try await API.video(v.id)
        #expect(after.collected)
        try await API.collect(v.id, on: false)
        #expect(!(try await API.video(v.id)).collected)

        if d.author.id > 0 {
            try await API.follow(d.author.id, on: true)
            try await API.follow(d.author.id, on: false)
        }

        let post = try #require(try await API.posts(page: 1, size: 1).items.first)
        try await API.postLike(post.id, on: true)
        try await API.postLike(post.id, on: false)
        try await API.postCollect(post.id, on: true)
        try await API.postCollect(post.id, on: false)

        await API.logout()
        #expect(SessionStore.shared.token == nil)
        await #expect(throws: APIError.needLogin) { try await API.collect(v.id, on: true) }
    }
}
