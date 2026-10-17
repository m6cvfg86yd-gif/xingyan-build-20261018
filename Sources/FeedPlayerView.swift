import SwiftUI
import AVFoundation
import UIKit

/* ============================================================
   视频号「抖音版」全屏播放页
   · 一屏一条、上下滑切换（用系统分页容器，iOS 16 也能用）
   · 滑到哪条自动播、其它自动停；播完循环；点一下暂停/继续
   · **播放器池**：只给「当前 / 上一条 / 下一条」建播放器，滑过去立刻有画面 ——
     每滑一次新建播放器正是卡的根源，这里复用它
   · 素材仍然是服务端切好的 HLS（800kbps），所以起播快、流量小
   ============================================================ */

struct FeedPlayerView: View {
    let items: [FeedItem]
    var start: Int = 0

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var paused = false
    @State private var progress: Double = 0
    @State private var showHeart = false
    /// 每条视频的互动状态（点赞/评论/收藏/关注）——本地先变，服务器回来再校准
    @State private var ui: [String: FeedItemUI] = [:]
    /// 正在看评论的那条
    @State private var commentItem: FeedItem?
    /// 分享面板
    @State private var shareItems: [Any] = []
    @State private var showShare = false

    init(items: [FeedItem], start: Int = 0) {
        self.items = items
        self.start = start
        _index = State(initialValue: max(0, min(start, max(0, items.count - 1))))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if items.isEmpty {
                Text(Tr("还没有视频")).foregroundColor(.white)
            } else {
                VerticalPager(index: $index, count: items.count) { i in
                    PlayerPage(item: items[i],
                               active: (i == index),
                               paused: paused,
                               ui: ui[items[i].id] ?? FeedItemUI(items[i]),
                               onTap: { paused.toggle() },
                               onDoubleTap: { like(items[i], fromDoubleTap: true) },
                               onLike: { like(items[i], fromDoubleTap: false) },
                               onComment: { commentItem = items[i] },
                               onFavorite: { favorite(items[i]) },
                               onShare: { share(items[i]) },
                               onFollow: { follow(items[i]) },
                               onAvatar: { openAuthor(items[i]) },
                               progress: (i == index) ? progress : 0)
                }
                .ignoresSafeArea()
            }

            if showHeart {
                Image(systemName: "heart.fill")
                    .font(.system(size: 120))
                    .foregroundColor(Color(hex: 0xFF2D55))
                    .shadow(color: .black.opacity(0.3), radius: 12)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                    .allowsHitTesting(false)
            }

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color.black.opacity(0.28)))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                Spacer()
            }
        }
        .statusBarHidden(true)
        .onAppear { seed() }
        .sheet(item: $commentItem) { it in
            FeedCommentSheet(item: it) { n in
                if var s = ui[it.id] { s.comments = n; ui[it.id] = s }
            }
            .environmentObject(app)
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showShare) { ShareSheet(items: shareItems) }
        .task(id: index) {
            /* 只保留「当前 / 上一条 / 下一条」的播放器：滑得再多也不会越积越卡（内存和缓冲都省） */
            let lo = max(0, index - 1), hi = min(items.count - 1, index + 1)
            if lo <= hi { PlayerPool.shared.keepOnly(Array(items[lo...hi]).map { $0.id }) }
            /* ⚠ 关键：告诉所有页面「现在轮到哪一条」。
               以前每页的 active 是在「页面被创建那一刻」算的 —— 分页器是 UIKit 包一层，
               滑到第 2 条时新建的页面拿到的还是旧 index（active=false），播放器永远不启动，
               表现就是「只有第一条能播，后面的全在转圈」。 */
            PlayerPool.shared.currentId = items[safe: index]?.id ?? ""
            await trackProgress()
        }
    }

    /// 第一次进来把每条的状态从服务器给的数据里初始化一份
    private func seed() {
        for it in items where ui[it.id] == nil { ui[it.id] = FeedItemUI(it) }
    }

    private func like(_ item: FeedItem, fromDoubleTap: Bool) {
        var s = ui[item.id] ?? FeedItemUI(item)
        /* 已经赞过再双击：只播动画，不再发请求（抖音也是这样） */
        if fromDoubleTap, s.liked { flashHeart(); return }
        let next = !s.liked
        s.liked = next
        s.likes = max(0, s.likes + (next ? 1 : -1))
        ui[item.id] = s
        if fromDoubleTap { flashHeart() }
        Task {
            if let r = try? await API.shared.feedLike(item.id), var cur = ui[item.id] {
                cur.liked = r.liked
                cur.likes = r.likes
                ui[item.id] = cur
            }
        }
    }

    private func flashHeart() {
        withAnimation(.spring(response: 0.26, dampingFraction: 0.55)) { showHeart = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            withAnimation(.easeOut(duration: 0.25)) { showHeart = false }
        }
    }

    private func favorite(_ item: FeedItem) {
        var s = ui[item.id] ?? FeedItemUI(item)
        s.favorited.toggle()
        s.favorites = max(0, s.favorites + (s.favorited ? 1 : -1))
        ui[item.id] = s
        Task {
            if let r = try? await API.shared.feedFavorite(item.id), var cur = ui[item.id] {
                cur.favorited = r.favorited
                cur.favorites = r.favorites
                ui[item.id] = cur
            }
        }
    }

    private func follow(_ item: FeedItem) {
        guard let uid = item.author?.id, !uid.isEmpty else { return }
        var s = ui[item.id] ?? FeedItemUI(item)
        s.followed.toggle()
        ui[item.id] = s
        Task {
            let ok = await API.shared.feedFollow(userId: uid, follow: s.followed)
            if !ok, var cur = ui[item.id] { cur.followed = !s.followed; ui[item.id] = cur }
        }
    }

    private func share(_ item: FeedItem) {
        var arr: [Any] = []
        if let d = item.desc, !d.isEmpty { arr.append(d) }
        if let u = URL(string: API.shared.base) { arr.append(u) }
        shareItems = arr.isEmpty ? ["视频号"] : arr
        showShare = true
    }

    /// 点头像/昵称：打开作者的名片（和微信一样先看是谁）
    private func openAuthor(_ item: FeedItem) {
        guard let uid = item.author?.id, !uid.isEmpty else { return }
        Task { @MainActor in
            if let u = try? await API.shared.user(id: uid) {
                app.scanCardUser = u
            } else if let n = item.author?.name, !n.isEmpty {
                app.show("@" + n)
            }
        }
    }

    /// 底部进度条：每 0.25 秒读一次当前页的播放进度
    private func trackProgress() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            progress = PlayerPool.shared.progress(of: items[safe: index]?.id ?? "")
        }
    }
}

/* ---------------------------------------------------------- 抖音式：互动状态 */

/// 一条视频在本地的互动状态（服务器给的初始值 + 本地的即时变化）
struct FeedItemUI {
    var liked = false
    var likes = 0
    var comments = 0
    var favorites = 0
    var favorited = false
    var followed = false
    var authorName = ""
    var authorAvatar = ""
    var desc = ""
    var music = ""
    var seriesName = ""
    var ep = ""

    init(_ it: FeedItem) {
        liked = it.liked ?? false
        likes = it.likes ?? 0
        comments = it.comments ?? 0
        favorites = it.favorites ?? 0
        favorited = it.favorited ?? false
        followed = it.followed ?? false
        authorName = it.author?.name ?? ""
        authorAvatar = it.author?.avatar ?? ""
        desc = it.desc ?? ""
        music = it.music ?? ""
        seriesName = it.seriesName ?? ""
        ep = it.ep ?? ""
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { (i >= 0 && i < count) ? self[i] : nil }
}

/* ---------------------------------------------------------- 播放器池 */

/// 全局播放器池：只保留「当前 / 上一条 / 下一条」三个，多余的销毁。
/// 这样上下滑都是「复用已经在缓冲的播放器」，不会每滑一次重新建、重新缓冲（那就是卡）。
final class PlayerPool: ObservableObject {
    static let shared = PlayerPool()
    /// 当前正在播的那一条（每个页面都盯着它决定自己播不播 —— 见 FeedPlayerView.task）
    @Published var currentId: String = ""
    /// 正在等画面的（页面转圈用）
    @Published private(set) var loading: Set<String> = []
    /// HLS 和整包 MP4 都播不出来的（页面给个「重新加载」）
    @Published private(set) var failed: Set<String> = []
    private var players: [String: AVPlayer] = [:]      // itemId -> player
    private var urls: [String: URL] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    /// 最近碰过的几条（最多 8 个）：滑回来立刻有画面，别每次都重建播放器
    private var recent: [String] = []
    /// 已经真的出过画面的（滑回来不用再判定一遍）
    private var played: Set<String> = []

    func player(for item: FeedItem) -> AVPlayer? {
        let key = item.id
        touch(key)
        if let p = players[key] { return p }
        guard let u = startURL(item) else { return nil }
        return makePlayer(item: item, url: u, triedMP4: u == mp4URL(item))
    }

    private func touch(_ key: String) {
        recent.removeAll { $0 == key }
        recent.insert(key, at: 0)
        if recent.count > 8 { recent.removeLast(recent.count - 8) }
    }

    /// 已经是「出过画面」的条目
    func hasPlayed(_ id: String) -> Bool { played.contains(id) }

    /// 起播地址：**优先整包 MP4**（和聊天里的视频一条路：先下到本地再播，最稳），没有才用分片
    private func startURL(_ item: FeedItem) -> URL? {
        if let v = item.video, !v.isEmpty, let u = API.shared.assetURL(v) { return u }
        if let h = item.hls, !h.isEmpty, let u = API.shared.assetURL(h) { return u }
        return API.shared.assetURL(item.playPath)
    }

    private func mp4URL(_ item: FeedItem) -> URL? {
        guard let v = item.video, !v.isEmpty else { return nil }
        return API.shared.assetURL(v)
    }

    @discardableResult
    private func makePlayer(item: FeedItem, url: URL, triedMP4: Bool, fromDownload: Bool = false) -> AVPlayer {
        let key = item.id
        /* ★★ 真因修复：**AVPlayer 不认我们的自签证书**（聊天里的视频就是这么黑屏的，
           精彩视频"完全不播放"是同一个坑）—— 所以不能直接 `AVPlayer(url: 远程地址)`。
           这里先建一个空播放器占住位置，媒体走 loadInto：
             ① 本地有留底（自己发过 / 以前播过）→ 直接播本地文件；
             ② 没有 → 用 **App 自己的会话**（认证书）把文件下下来，写进留底，再播本地文件。
           下好用 `replaceCurrentItem` 装进**同一个**播放器 —— 页面那边的引用不用换。 */
        let p = AVPlayer()
        p.actionAtItemEnd = .none
        /* 抖音那套：有数据就播，不攒够一大段才开播（弱网下「等安全缓冲」就是一直转圈） */
        p.automaticallyWaitsToMinimizeStalling = false
        players[key] = p
        urls[key] = url
        if currentId == key { p.play() }
        CrashCatcher.note("视频号", "开始加载 id=\(key) 源=\(url.absoluteString)")
        loadInto(item: item, player: p, url: url, triedMP4: triedMP4, fromDownload: fromDownload)
        return p
    }

    /// 媒体怎么进播放器：**和聊天里的视频完全一样 —— 先整段下到本地，再播本地文件**。
    /// （以前这里是「边下边播」：第二条经常一直转圈不播。本地文件不挑证书、也不用等
    ///  AVPlayer 自己缓冲，下过一次还留底，第二次秒开。）
    private func loadInto(item: FeedItem, player p: AVPlayer, url: URL, triedMP4: Bool, fromDownload: Bool = false) {
        let key = item.id
        /* 本来就是本地文件：直接装上 */
        if url.scheme != "http" && url.scheme != "https" {
            attach(item: item, player: p, file: url, remote: url, triedMP4: true)
            return
        }
        /* ① 本地留底：自己发过 / 以前播过 → 直接播本地，秒出画面 */
        if let local = LocalStore.localURL(url.path), FileManager.default.fileExists(atPath: local.path) {
            attach(item: item, player: p, file: local, remote: url, triedMP4: true)
            return
        }
        /* ② 分片（没有整包 MP4 的那些）：分片本来就是一小段一小段拉的，走边下边播 */
        if url.pathExtension == "m3u8", let pi = StreamPlay.item(url) {
            pi.preferredForwardBufferDuration = 1.5
            p.replaceCurrentItem(with: pi)
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                  object: pi, queue: .main) { [weak p] _ in
                p?.seek(to: .zero)
                p?.play()
            }
            urls[key] = url
            if currentId == key { p.play() }
            verify(item: item, player: p, url: url, triedMP4: false)
            return
        }
        /* ③ 远程整包：**整段下到本地再播**（和聊天视频一条路） */
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let local = await StreamPlay.download(url)
            guard self.players[key] === p else { return }
            guard let file = local else {
                self.loading.remove(key)
                self.failed.insert(key)
                CrashCatcher.note("视频号", "整段下载失败 id=\(key) 源=\(url.absoluteString)")
                return
            }
            self.attach(item: item, player: p, file: file, remote: url, triedMP4: true)
        }
    }

    /// 把这一份真正装进播放器：循环播放 + 起播校验（校验仍用**远程地址**判断要不要退回整包 MP4）
    private func attach(item: FeedItem, player p: AVPlayer, file: URL, remote: URL, triedMP4: Bool) {
        let key = item.id
        let pi = AVPlayerItem(url: file)
        pi.preferredForwardBufferDuration = 2
        p.replaceCurrentItem(with: pi)
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                              object: pi, queue: .main) { [weak p] _ in
            p?.seek(to: .zero)
            p?.play()
        }
        urls[key] = file
        if currentId == key { p.play() }
        verify(item: item, player: p, url: remote, triedMP4: triedMP4)
    }

    /// 盯着刚建的播放器：**画面真的往前走才算成功**。
    /// 分片只等 3 秒（超时就换整包 MP4），整包给它 12 秒；再不行才告诉页面「播不出来」。
    /// （全屏这个播放器以前没有这段，所以线上表现就是「一直转圈，没有尽头」。）
    private func verify(item: FeedItem, player: AVPlayer, url: URL, triedMP4: Bool) {
        let key = item.id
        tasks[key]?.cancel()
        tasks[key] = Task { @MainActor [weak self] in
            guard let self = self else { return }
            if !self.played.contains(key) { self.loading.insert(key) }
            self.failed.remove(key)
            /* ⚠ 这里以前对**预加载**的那几条也按 3 秒/12 秒判失败 ——
               可预加载的播放器我们并不会去 play()，它当然不会「出画面」，
               于是旁边的几条动不动就被判「播不出来」、切去整段下载（更慢），
               用户看到的就是「只有第一条能播，后面全在转圈」。
               现在**只有正在看的那一条才计时超时**，预加载的那些只要等它 ready 就行。 */
            var moved = false
            var activeWait = 0.0
            for tick in 0..<250 {                            // 最多 50 秒
                if self.players[key] !== player { return }
                let active = (self.currentId == key)
                if active { player.play() }                  // 这一页正显示就催一下
                if let it = player.currentItem {
                    if it.status == .failed { break }
                    if it.status == .readyToPlay, CMTimeGetSeconds(player.currentTime()) > 0.05 {
                        moved = true
                        break
                    }
                }
                /* 每 5 秒记一条诊断：下次「转圈不播」时，看日志就知道卡在哪一步 */
                if tick % 25 == 0 {
                    let st = player.currentItem?.status.rawValue ?? -1
                    let t = CMTimeGetSeconds(player.currentTime())
                    let buf = player.currentItem?.loadedTimeRanges.first?.timeRangeValue.duration.seconds ?? 0
                    CrashCatcher.note("视频号",
                        "诊断 id=\(key) active=\(active) status=\(st) t=\(String(format: "%.2f", t.isFinite ? t : 0))"
                        + " rate=\(player.rate) 缓冲=\(String(format: "%.1f", buf.isFinite ? buf : 0))"
                        + " likely=\(player.currentItem?.isPlaybackLikelyToKeepUp ?? false)")
                }
                if active { activeWait += 0.2 }
                /* 正在看、而且等够了还没画面 → 才算真失败（分片 3 秒、整包 12 秒） */
                if active, activeWait >= (triedMP4 ? 12 : 3), !(player.currentItem?.isPlaybackLikelyToKeepUp ?? false) {
                    break
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard self.players[key] === player else { return }
            if moved {
                self.played.insert(key)
                self.loading.remove(key)
                self.failed.remove(key)
                CrashCatcher.note("视频号", "出画面 id=\(key)")
                return
            }
            /* 还没轮到播的那几条：别急着判「播不出来」—— 它只是还没被 play()。
               先记一条日志，等用户真的滑到它，那时候再看要不要兜底。 */
            if self.currentId != key, player.currentItem?.status != .failed {
                self.loading.remove(key)
                self.tasks[key] = nil      // 真的轮到它的时候要能再校验一次
                CrashCatcher.note("视频号", "预加载等画面超时（先不判失败）id=\(key) 源=\(url.absoluteString)")
                return
            }
            let why = player.currentItem?.error?.localizedDescription ?? "没等到画面"
            CrashCatcher.note("视频号", "加载失败 id=\(key) 源=\(url.absoluteString) 原因=\(why)")
            player.pause()
            StreamPlay.cancel(player.currentItem)     // 把没下完的长请求掐掉，别占着连接
            player.replaceCurrentItem(with: nil)
            if self.players[key] === player { self.players.removeValue(forKey: key) }
            self.urls.removeValue(forKey: key)
            if !triedMP4, let u2 = self.mp4URL(item), u2 != url {
                CrashCatcher.note("视频号", "改用整包 MP4（先下后播）id=\(key)")
                self.makePlayer(item: item, url: u2, triedMP4: true, fromDownload: true)
            } else {
                self.loading.remove(key)
                self.failed.insert(key)
            }
        }
    }

    /// 用户点「重新加载」：从头再来一次（网络可能就是刚才那一会儿不好）
    func retry(_ item: FeedItem) {
        let key = item.id
        tasks[key]?.cancel()
        players[key]?.pause()
        StreamPlay.cancel(players[key]?.currentItem)
        players[key]?.replaceCurrentItem(with: nil)
        players.removeValue(forKey: key)
        urls.removeValue(forKey: key)
        played.remove(key)
        failed.remove(key)
        loading.remove(key)
        guard let u = startURL(item) else { failed.insert(key); return }
        CrashCatcher.note("视频号", "手动重试 id=\(key) 源=\(u.absoluteString)")
        makePlayer(item: item, url: u, triedMP4: u == mp4URL(item))
    }

    func play(_ item: FeedItem) {
        guard let p = player(for: item) else { return }
        if p.timeControlStatus != .playing { p.play() }
        /* 之前只做过「预加载」校验（那会儿不判失败）：现在真的轮到它了，
           补一次真正的起播校验 —— 分片 3 秒 / 整包 12 秒还没画面就自动换整包。 */
        if !played.contains(item.id), tasks[item.id] == nil, let u = urls[item.id] {
            verify(item: item, player: p, url: u, triedMP4: (u == mp4URL(item)))
        }
    }

    func pause(_ item: FeedItem) {
        players[item.id]?.pause()
    }

    func progress(of id: String) -> Double {
        guard let p = players[id], let it = p.currentItem else { return 0 }
        let total = CMTimeGetSeconds(it.duration)
        guard total.isFinite, total > 0 else { return 0 }
        return max(0, min(1, CMTimeGetSeconds(p.currentTime()) / total))
    }

    /// 只留这些（当前 ± 1），其余释放 —— 避免越刷越占内存
    func keepOnly(_ ids: [String]) {
        /* ⚠ 这里必须把「当前这条」和「最近碰过的几条」一起留下。
           只留「当前 ±1」的时候，推荐流一刷新（列表会重排 / 重新拉一页），
           正在看的那条会和它的播放器一起被丢掉 → 页面又去重新建播放器 →
           表现就是用户说的「第二条一直在转圈、就是不出画面」。 */
        var keep = Set(ids)
        keep.formUnion(recent)
        if !currentId.isEmpty { keep.insert(currentId) }
        for (k, p) in players where !keep.contains(k) {
            p.pause()
            StreamPlay.cancel(p.currentItem)     // 同上：丢掉播放器就把它的请求一起掐掉
            p.replaceCurrentItem(with: nil)
            tasks[k]?.cancel()
            tasks.removeValue(forKey: k)
            players.removeValue(forKey: k)
            urls.removeValue(forKey: k)
            loading.remove(k)
        }
    }
}

/* ---------------------------------------------------------- 单页 */

private struct PlayerPage: View {
    let item: FeedItem
    let active: Bool
    let paused: Bool
    var ui: FeedItemUI
    var onTap: () -> Void = { }
    var onDoubleTap: () -> Void = { }
    var onLike: () -> Void = { }
    var onComment: () -> Void = { }
    var onFavorite: () -> Void = { }
    var onShare: () -> Void = { }
    var onFollow: () -> Void = { }
    var onAvatar: () -> Void = { }
    var progress: Double = 0

    /// 当前是不是轮到我播：盯播放器池广播的 currentId（分页器包了一层 UIKit，
    /// 传进来的 active 是创建那一刻算的，滑到这一页时可能已经是旧值）
    @ObservedObject private var pool = PlayerPool.shared
    private var isActive: Bool { pool.currentId == item.id }

    var body: some View {
        ZStack {
            /* 封面先铺上（已经在缓存里），再盖播放画面 —— 所以滑过去不会白屏 */
            if let c = item.cover, !c.isEmpty {
                RemoteImage(path: c, mode: .fill, maxSide: 1600)
                    .ignoresSafeArea()
            }
            PlayerLayerView(player: PlayerPool.shared.player(for: item))
                .ignoresSafeArea()

            /* 弱网那两种情况：还在等画面 → 转个圈；分片和整包都试过还是不行 → 给个「重新加载」。
               以前这一页什么都不显示，用户看到的就是「一直转圈，也不知道能不能好」。 */
            if isActive {
                if pool.failed.contains(item.id) {
                    failedBadge
                } else if pool.loading.contains(item.id), !pool.hasPlayed(item.id) {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.15)
                        .allowsHitTesting(false)
                }
            }

            /* 底部左边：作者 / 文案 / 音乐（抖音那一列） */
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 7) {
                        Button { onAvatar() } label: {
                            Text("@" + (ui.authorName.isEmpty ? Tr("视频号") : ui.authorName))
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)

                        if !ui.desc.isEmpty {
                            Text(ui.desc)
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.94))
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                        }
                        if !ui.ep.isEmpty || !ui.seriesName.isEmpty {
                            Text((ui.seriesName.isEmpty ? "" : ui.seriesName) + (ui.ep.isEmpty ? "" : " · " + ui.ep))
                                .font(.system(size: 12.5))
                                .foregroundColor(.white.opacity(0.9))
                        }
                        if !ui.music.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "music.note")
                                    .font(.system(size: 12))
                                Text(ui.music)
                                    .font(.system(size: 12.5))
                                    .lineLimit(1)
                            }
                            .foregroundColor(.white.opacity(0.92))
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
                .padding(.trailing, 76)          // 给右边那排按钮让位
            }

            /* 右侧竖排操作栏（抖音那种：头像 / 赞 / 评论 / 收藏 / 分享 / 唱片） */
            VStack {
                Spacer()
                VStack(spacing: 18) {
                    ZStack(alignment: .bottom) {
                        Button { onAvatar() } label: {
                            Avatar(path: ui.authorAvatar, size: 46, radius: 23, circle: true)
                                .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        if !ui.followed {
                            Button { onFollow() } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 20, height: 20)
                                    .background(Circle().fill(Color(hex: 0xFE2C55)))
                            }
                            .buttonStyle(.plain)
                            .offset(y: 9)
                        }
                    }
                    .padding(.bottom, ui.followed ? 0 : 8)

                    FeedRailButton(icon: "heart.fill",
                                   color: ui.liked ? Color(hex: 0xFE2C55) : .white,
                                   count: ui.likes, action: onLike)
                    FeedRailButton(icon: "ellipsis.bubble.fill", color: .white,
                                   count: ui.comments, action: onComment)
                    FeedRailButton(icon: "star.fill",
                                   color: ui.favorited ? Color(hex: 0xFFD60A) : .white,
                                   count: ui.favorites, action: onFavorite)
                    FeedRailButton(icon: "arrowshape.turn.up.right.fill", color: .white,
                                   count: 0, action: onShare)
                    MusicDisc()
                }
                .padding(.bottom, 34)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 12)

            /* 底部进度条（抖音那种：细细一条贴着底） */
            VStack {
                Spacer()
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.25)).frame(height: 2)
                        Rectangle().fill(Color.white).frame(width: max(0, geo.size.width * progress), height: 2)
                    }
                }
                .frame(height: 2)
                .padding(.bottom, 3)
            }

            if paused {
                Image(systemName: "play.fill")
                    .font(.system(size: 54))
                    .foregroundColor(.white.opacity(0.85))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onDoubleTap() }
        .onTapGesture { onTap() }
        .onAppear { if isActive { PlayerPool.shared.play(item) } }
        .onChange(of: pool.currentId) { _ in
            if isActive { PlayerPool.shared.play(item) } else { PlayerPool.shared.pause(item) }
        }
        .onChange(of: paused) { p in
            if p { PlayerPool.shared.pause(item) } else if isActive { PlayerPool.shared.play(item) }
        }
    }

    /// 这条视频起不来时页面中间那块：说清楚 + 一个「重新加载」的按钮
    private var failedBadge: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 26, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
            Text(Tr("这条没加载出来"))
                .font(.system(size: 14.5))
                .foregroundColor(.white.opacity(0.92))
            Button {
                PlayerPool.shared.retry(item)
            } label: {
                Text(Tr("重新加载"))
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .frame(height: 34)
                    .background(Capsule().fill(Color.white.opacity(0.2)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.38))
        )
    }
}

/// 一层 AVPlayerLayer（SwiftUI 里用它显示画面）
final class PlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer?

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let v = PlayerLayerUIView()
        v.backgroundColor = .black
        let l = v.layer as? AVPlayerLayer
        l?.player = player
        l?.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ v: PlayerLayerUIView, context: Context) {
        let l = v.layer as? AVPlayerLayer
        if l?.player !== player { l?.player = player }
    }
}

/* ---------------------------------------------------------- 竖向分页容器（iOS 16 可用） */

struct VerticalPager<Content: View>: UIViewControllerRepresentable {
    @Binding var index: Int
    let count: Int
    let content: (Int) -> Content

    func makeUIViewController(context: Context) -> UIPageViewController {
        let vc = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .vertical, options: nil)
        vc.dataSource = context.coordinator
        vc.delegate = context.coordinator
        vc.setViewControllers([context.coordinator.host(index)], direction: .forward, animated: false)
        return vc
    }

    func updateUIViewController(_ vc: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.current != index, let target = context.coordinator.host(index) as UIViewController? {
            let dir: UIPageViewController.NavigationDirection = index > context.coordinator.current ? .forward : .reverse
            vc.setViewControllers([target], direction: dir, animated: true)
            context.coordinator.current = index
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: VerticalPager
        var current: Int = 0
        /// 每个托管页面对应的下标（滑完靠它认出当前是哪一条）
        private var map: [ObjectIdentifier: Int] = [:]
        init(_ p: VerticalPager) { parent = p; current = p.index }

        func host(_ i: Int) -> UIHostingController<AnyView> {
            let vc = UIHostingController(rootView: AnyView(parent.content(i)))
            map[ObjectIdentifier(vc)] = i
            return vc
        }

        func pageViewController(_ vc: UIPageViewController, viewControllerBefore v: UIViewController) -> UIViewController? {
            guard let i = map[ObjectIdentifier(v)], i > 0 else { return nil }
            return host(i - 1)
        }
        func pageViewController(_ vc: UIPageViewController, viewControllerAfter v: UIViewController) -> UIViewController? {
            guard let i = map[ObjectIdentifier(v)], i + 1 < parent.count else { return nil }
            return host(i + 1)
        }
        func pageViewController(_ vc: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let v = vc.viewControllers?.first,
                  let i = map[ObjectIdentifier(v)] else { return }
            current = i
            parent.index = i
        }
    }
}

/* ============================================================
   抖音式：右侧操作栏 / 转动的唱片 / 评论区（半屏）
   ============================================================ */

/// 右侧操作栏上的一个按钮：图标 + 数字（带描边阴影，深色画面上也看得清）
private struct FeedRailButton: View {
    let icon: String
    var color: Color = .white
    var count: Int = 0
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 27))
                    .foregroundColor(color)
                    .shadow(color: .black.opacity(0.35), radius: 4)
                if count > 0 {
                    Text(FeedCount.text(count))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.35), radius: 3)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

enum FeedCount {
    /// 数字显示：10000 → 1.0万，抖音也是这么写的
    static func text(_ n: Int) -> String {
        if n >= 10000 { return String(format: "%.1f万", Double(n) / 10000.0) }
        return String(n)
    }
}

/// 右下角那个转动的唱片
private struct MusicDisc: View {
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.06)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().stroke(Color.white.opacity(0.18), lineWidth: 1)
            Image(systemName: "music.note")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
        }
        .frame(width: 42, height: 42)
        .rotationEffect(.degrees(spin ? 360 : 0))
        .animation(.linear(duration: 6).repeatForever(autoreverses: false), value: spin)
        .onAppear { spin = true }
    }
}

/// 评论区（抖音那种半屏）：列表 + 底部输入框，发出去后刷新并回报条数
struct FeedCommentSheet: View {
    let item: FeedItem
    var onCount: (Int) -> Void

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var list: [FeedCommentItem] = []
    @State private var draft = ""
    @State private var sending = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(list.isEmpty ? Tr("还没有评论") : "\(list.count) " + Tr("条评论"))
                    .font(pf(15, .semibold))
                    .foregroundColor(C.label)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(C.subLabel)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(list) { c in
                        HStack(alignment: .top, spacing: 10) {
                            Avatar(path: c.avatar ?? "", size: 34, radius: 17, circle: true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(c.name ?? "").font(pf(13)).foregroundColor(C.subLabel)
                                Text(c.text ?? "").font(pf(15)).foregroundColor(C.label)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 14)
            }

            Divider()

            HStack(spacing: 10) {
                TextField(Tr("说点什么…"), text: $draft)
                    .focused($focused)
                    .font(pf(15))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 18).fill(C.searchBg))
                Button { send() } label: {
                    Text(Tr("发送"))
                        .font(pf(15, .semibold))
                        .foregroundColor(draft.trimmingCharacters(in: .whitespaces).isEmpty ? C.subLabel : C.green)
                }
                .buttonStyle(.plain)
                .disabled(sending || draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(C.cardBg)
        .task { await load() }
    }

    private func load() async {
        list = (try? await API.shared.feedComments(item.id)) ?? []
        onCount(list.count)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        Task {
            if let n = try? await API.shared.feedComment(item.id, text: text) {
                draft = ""
                focused = false
                onCount(n)
                await load()
            } else {
                app.show(Tr("评论失败"))
            }
            sending = false
        }
    }
}
