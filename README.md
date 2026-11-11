# HGhub-SwiftUI

用 Swift + SwiftUI 从零重写的黄果短剧客户端,同时支持 **macOS 26+** 与 **iOS / iPadOS 26+**。
界面遵循 Apple Liquid Glass 设计规范。

![platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20iOS%20%7C%20iPadOS-blue)

> 本仓库是独立重写版本:全部前端界面重新实现,后端能力(edge 信封请求、线路、登录、收藏、播放等)以 Swift 重新实现并保持功能对齐。

## 功能

- **上游接口**:`POST /api/edge/request` 信封请求,统一错误描述与超时处理
- **线路**:固定线路 + 镜像线路自动解析、测速、手动切换
- **账号**:登录 / 注册、会话持久化、退出登录
- **首页**:首页(客户端加权随机,含兴趣画像)/ 热门 / 最新
- **分类**:4 个频道横滑或网格、吃瓜帖子、单频道全部列表(自动翻页)
- **搜索**:关键词搜索、热门标签、搜索历史、HG 热榜
- **排行榜**:热播榜 / 推荐榜 / 潜力榜,自适应多列
- **详情与播放**:剧集信息、选集、播放地址解析
- **评论**:列表、点赞、回复、发评论
- **互动**:点赞、收藏、关注(未登录时引导登录)
- **观看历史**:记录集数与进度,支持续播
- **HLS 播放**:AVPlayer + 自定义 `AVAssetResourceLoaderDelegate`,代理 m3u8 / AES key / 分片,带站点 Referer
- **预载下一条**:设置里可开关;开启时提前取好下一条的播放地址与 m3u8 播放列表,翻页少两跳网络
- **线路**:固定线路 + 发布页镜像,可测速(按延迟升序排);「自动切换线路」开启后播放失败会自动切到延迟最低的可用线路
- **本地设置**:外观、默认静音、默认倍速、预载下一个视频、缓存清理、网络诊断、检查更新

## 平台差异

| | macOS | iOS / iPadOS |
|---|---|---|
| 导航 | 侧边栏:首页 / 热门 / 最新 / 排行榜 / 我的 / 设置,下方「发现」分组含分类、搜索 | 底部五个标签:首页 / 热门 / 最新 / 分类 / 我的;首页 / 热门 / 最新 / 分类 右上角是同一颗搜索按钮(同一尺寸、同一位置),「我的」右上角放设置,位置与大小跟搜索一致 |
| 播放页返回 | 窗口工具栏系统返回 | 视频层上的玻璃返回按钮 |
| 播放页右侧操作 | 关注 / 喜欢 / 评论 / 收藏 / 选集 / 分享,纯图标 + 计数,无玻璃底 | 同上;横屏时自动收紧尺寸并隐藏数字计数 |
| 播放交互 | 单击暂停/继续、双击点赞、长按 2x;鼠标按住上下拖动翻页、左右拖动调进度;空格、⌘←/⌘→、↑/↓ 均可用 | 单击隐藏 / 显示全部界面(只剩画面,控件滑到屏幕边缘),再点一下恢复;双击暂停/继续;长按 2x;竖滑翻页,左右滑动调进度(拖动时显示目标时间) |
| 静音 | 控制条静音键;设置里可改默认静音 | 竖屏视频页右上角「取消静音」,静音时出现、点一下即有声;全屏只在底部控制条里有一个静音键,不会出现两个 |
| 全屏 | 右下角全屏按钮循环三态:按比例 → 裁切铺满 → 退出;窗口铺满并带缩放过渡 | 右下角全屏按钮(唯一入口)循环三态:按比例 → 裁切铺满 → 退出;横版视频自动转横屏;标签栏、状态栏一并隐藏,切换是连续缩放动画 |
| 横屏播放 | — | iPhone 横屏不显示标签栏(整屏看片)、iPad 横屏保留顶部标签栏,因为屏幕够大 |
| 键盘 | 空格播放/暂停,⌘←/⌘→ 快退快进,⌘1–⌘7 切换页面 | — |

## 环境要求

- Xcode 27(项目使用 iOS 26 / macOS 26 SDK 与 Liquid Glass API)
- 部署目标:macOS 26.0、iOS 26.0
- 无第三方依赖,不需要 CocoaPods / SwiftPM 拉包

## 构建

```bash
# macOS
xcodebuild -project HGhub.xcodeproj -scheme HGhub \
  -configuration Release -destination 'platform=macOS' build

# iOS
xcodebuild -project HGhub.xcodeproj -scheme HGhub \
  -configuration Release -destination 'generic/platform=iOS' \
  DEVELOPMENT_TEAM=<你的 Team ID> build
```

也可以直接用 Xcode 打开 `HGhub.xcodeproj`,选 `HGhub` scheme 运行。

## 安装包

`dist/` 里是打好的两个包,随时可以重新生成:

```bash
./scripts/package.sh        # 两个都打
./scripts/package.sh mac    # macOS → dist/HGhub-<版本>.dmg
./scripts/package.sh ios    # iOS   → dist/HGhub-<版本>-unsigned.ipa
```

- **macOS**:ad-hoc 签名(不需要开发者账号),打开 DMG 把 HGhub 拖进「应用程序」即可。
  首次启动若被 Gatekeeper 拦下,右键 →「打开」,或执行
  `xattr -dr com.apple.quarantine /Applications/HGhub.app`。
- **iOS**:完全未签名,用 AltStore / Sideloadly / Xcode 自己的证书重签后安装。

`project.yml` 是 XcodeGen 的描述文件,装了 XcodeGen 的话可以用 `xcodegen generate` 重新生成工程;
不装也能直接构建,仓库内已包含可用的 `HGhub.xcodeproj`。

## 测试

```bash
xcodebuild -project HGhub.xcodeproj -scheme HGhub \
  -destination 'platform=macOS' test
```

`HGhubTests` 共 25 项:JSON、线路解析、版本比较、HLS 重写、封面解密、格式化的纯逻辑测试,
以及请求真实接口的在线测试(推荐池、分类、榜单、搜索、详情与播放地址、评论、吃瓜、登录失败、镜像探测、诊断、检查更新)。

## 目录结构

```
HGhub/
  App/        入口、根导航、全局状态(AppModel)
  Core/       接口、网络、模型、JSON、线路、媒体缓存、推荐算法
  Feed/       竖向翻页播放流、控件层、面板(选集 / 评论 / 简介)
  Pages/      首页、分类、搜索、榜单、我的、设置、登录、帖子
  Player/     AVPlayer 封装、HLS 资源代理
  UI/         卡片、封面、通用组件与配色
  Resources/  Info.plist、权限、图标
HGhubTests/   单元测试与在线接口测试
```

## 说明

- Release 页的 iOS 包是**未签名 IPA**,需要用 AltStore / Sideloadly 等工具用自己的证书重签后安装。
- macOS 包为 ad-hoc 签名、未公证,首次打开请右键「打开」,或执行 `xattr -cr HGhub.app`。
- 应用内「检查更新」指向本仓库的 Releases。

## 版本

当前版本 **1.0.0**。

## 致谢

本项目在功能范围与交互设计上参考了以下上游项目,感谢原作者的工作:

- [LNPANDY/HGhub-MacOS-iOS-Version](https://github.com/LNPANDY/HGhub-MacOS-iOS-Version) — HGhub 跨平台客户端(macOS & iOS 增强版),本项目的功能对齐基准
- [Minireel/HGhub](https://github.com/Minireel/HGhub) — HGhub 项目源头

本项目为独立重写的代码,不包含上述仓库的源代码。

## 许可证

本项目以 [PolyForm Noncommercial License 1.0.0](LICENSE) 发布:
可以自由查看、修改、用于个人学习、研究、兴趣项目,以及非商业组织的内部使用;
**不允许商业使用**。分发时需一并保留许可证条款与 `Required Notice` 声明。
