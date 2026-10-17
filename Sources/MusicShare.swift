import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/* ============================================================
   音乐（App 里的「听一听」）

   · 曲库在服务器上（后台「音乐（听一听）」页传的歌），App 只读
   · 「听一听」页：列表 + 底下一根播放条（微信听一听就长这样）
   · 聊天「＋ → 音乐」：选一首 → 发出去是一张**音乐卡片**（封面 + 歌名 + 歌手）
   · 点卡片 → 进播放页（大封面 + 进度 + 播放/暂停）
   ⚠ 音频一定要**先下到本机再播**：AVPlayer 走自己的网络栈，
     我们服务器的地址带签名/可能不是 https，直接播会一直转圈（视频那边踩过）。
   ============================================================ */

struct MusicTrack: Decodable, Identifiable, Hashable {
    var id: String
    var title: String
    var artist: String?
    var cover: String?
    var url: String
    /// 歌词（后台「音乐（听一听）」里贴的）：LRC 或一行一句都行，空 = 没有
    var lyrics: String? = nil
    /// 分类（2026-10-15 对齐 QQ音乐搜索的「歌名 / 歌手 / 分类」）：
    /// 后台曲库哪天填了这个字段就用它；**没填就按「有没有歌词」自动分「人声 / 纯音乐」**，
    /// 这样搜索和分类筛选现在就能用（曲库里现在 33 首有人声、5 首纯音乐）。
    var category: String? = nil
    /// 谁赞过（判断我赞过没有）/ 赞了几个 / 被转发几次
    var likes: [String]? = nil
    var likeCount: Int? = nil
    var shareCount: Int? = nil
    var at: Double?

    var artistText: String { (artist ?? "").isEmpty ? "未知歌手" : (artist ?? "") }
    /// 这首歌的分类（后台给了就用后台的，没给就按有没有歌词自动分）
    var categoryText: String {
        let c = (category ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !c.isEmpty { return c }
        return (lyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "纯音乐" : "人声"
    }
}

/* ---------------------------------------------------------- 歌词 */

/* ---------------------------------------------------------- 好友在听什么 */

/// 好友"正在听"的一条（服务器 /api/music/friends 回的）
struct FriendNowPlaying: Decodable, Identifiable {
    var id: String
    var name: String
    var avatar: String?
    var trackId: String
    var title: String
    var artist: String?
    var cover: String?
    var url: String
    var at: Double?

    var asTrack: MusicTrack {
        MusicTrack(id: trackId.isEmpty ? id : trackId, title: title,
                   artist: artist, cover: cover, url: url, at: nil)
    }

    /// 「在听《歌名》 · 歌手」那一行
    var line: String {
        let a = (artist ?? "").trimmingCharacters(in: .whitespaces)
        return "在听《" + title + "》" + (a.isEmpty ? "" : " · " + a)
    }
}

struct NowPlayingPayload: Decodable { var list: [FriendNowPlaying]? }

struct MusicLyricLine: Identifiable, Equatable {
    var id: Int
    var time: Double
    var text: String
}

enum MusicLyrics {
    /// 解析歌词：带 [00:12.34] 时间戳的按 LRC 走；纯文字就按总时长均分。
    static func parse(_ raw: String, duration: Double) -> [MusicLyricLine] {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        guard !rows.isEmpty else { return [] }

        if let re = try? NSRegularExpression(pattern: "\\[(\\d{1,2}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]") {
            var out: [MusicLyricLine] = []
            for r in rows {
                let ns = r as NSString
                let ms = re.matches(in: r, options: [], range: NSRange(location: 0, length: ns.length))
                var stamp: Double? = nil
                for m in ms {
                    let mm = Double(ns.substring(with: m.range(at: 1))) ?? 0
                    let ss = Double(ns.substring(with: m.range(at: 2))) ?? 0
                    var frac = 0.0
                    if m.range(at: 3).location != NSNotFound {
                        let raw3 = ns.substring(with: m.range(at: 3))
                        frac = (Double(raw3) ?? 0) / pow(10, Double(max(1, raw3.count)))
                    }
                    if stamp == nil { stamp = mm * 60 + ss + frac }
                }
                guard let t0 = stamp else { continue }
                let last = ms.last
                let body = (last == nil ? ns as String
                            : ns.substring(from: (last!.range.location + last!.range.length)))
                    .trimmingCharacters(in: .whitespaces)
                if body.isEmpty { continue }
                out.append(MusicLyricLine(id: out.count, time: t0, text: body))
            }
            if !out.isEmpty { return out.sorted { $0.time < $1.time } }
        }

        /* 没时间戳：一行一句，按总时长均分（前 8% 留给前奏） */
        let plain = rows.filter { !$0.isEmpty && !$0.hasPrefix("[") }
        guard !plain.isEmpty else { return [] }
        let span = duration > 1 ? duration : Double(plain.count) * 4
        let lead = span * 0.08
        let step = (span - lead) / Double(plain.count)
        return plain.enumerated().map { i, s in
            MusicLyricLine(id: i, time: lead + step * Double(i), text: s)
        }
    }

    /// 现在唱到第几行（-1 = 还没开始）
    static func current(_ lines: [MusicLyricLine], at t: Double) -> Int {
        guard !lines.isEmpty else { return -1 }
        var idx = 0
        for (i, l) in lines.enumerated() {
            if l.time <= t + 0.2 { idx = i } else { break }
        }
        return idx
    }
}

/* ---------------------------------------------------------- 歌词页 */

/// 播放页右上角那个「词」：整页歌词，当前那句高亮 + 自动滚到中间
struct MusicLyricsView: View {
    let track: MusicTrack?
    /// 关掉（由播放页那边把 showLyrics 置回 false —— 这一页现在是**整屏覆盖**，
    /// 不是 sheet，所以不用 dismiss）
    var onClose: () -> Void = { }
    @ObservedObject private var player = MusicPlayer.shared
    /// 上一个高亮行（用来判断"是一句一句往下走"还是"一下跳很多行"）
    @State private var lastLyricLine = -1

    private var lines: [MusicLyricLine] { MusicLyrics.parse(track?.lyrics ?? "", duration: player.total) }
    private var cur: Int { MusicLyrics.current(lines, at: player.seconds) }
    /// 点某一句 → 按总时长换算成比例跳过去（总时长还没探到就什么都不做）
    private func seekTo(_ t: Double) {
        guard player.total > 1 else { return }
        player.seek(min(max(0, t / player.total), 1))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button { onClose() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(C.label)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                VStack(spacing: 2) {
                    Text(track?.title ?? "").font(pf(15, .semibold)).foregroundColor(C.label).lineLimit(1)
                    Text(track?.artistText ?? "").font(pf(12)).foregroundColor(C.subLabel).lineLimit(1)
                }
                Spacer(minLength: 0)
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.top, 6)

            if lines.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 30)).foregroundColor(C.subLabel)
                    Text(Tr("这首歌还没有歌词")).font(pf(15)).foregroundColor(C.label)
                    Text(Tr("后台「音乐（听一听）」里，每首歌后面点「歌词」就能贴上去"))
                        .font(pf(12.5)).foregroundColor(C.subLabel)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 30)
                .padding(.top, 60)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { sp in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 18) {
                            Color.clear.frame(height: 130)
                            ForEach(lines) { l in
                                Text(l.text)
                                    .font(pf(l.id == cur ? 17.5 : 15, l.id == cur ? .semibold : .regular))
                                    .foregroundColor(l.id == cur ? C.green : C.label.opacity(0.72))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .id(l.id)
                                    /* 点某一句 → 跳到那一句（QQ音乐也是点歌词跳转） */
                                    .contentShape(Rectangle())
                                    .onTapGesture { seekTo(l.time) }
                            }
                            Color.clear.frame(height: 180)
                        }
                        .padding(.horizontal, 26)
                    }
                    .onChange(of: cur) { i in
                        guard i >= 0 else { return }
                        /* 同上：滚顺一点，跳很多行才直接到位 */
                        let jump = lastLyricLine < 0 || abs(i - lastLyricLine) > 3
                        lastLyricLine = i
                        if jump { sp.scrollTo(i, anchor: .center) }
                        else { withAnimation(.easeInOut(duration: 0.55)) { sp.scrollTo(i, anchor: .center) } }
                    }
                }
            }
        }
        .background(C.cardBg.ignoresSafeArea())
    }
}

/// 音乐卡片里的内容（和 chat 里那条消息的 JSON 对应）
struct MusicCardInfo {
    var id = ""
    var title = ""
    var artist = ""
    var cover = ""
    var url = ""

    init?(json: String) {
        guard let d = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        id = (o["id"] as? String) ?? ""
        title = (o["title"] as? String) ?? ""
        artist = (o["artist"] as? String) ?? ""
        cover = (o["cover"] as? String) ?? ""
        url = (o["url"] as? String) ?? ""
        guard !title.isEmpty, !url.isEmpty else { return nil }
    }

    var asTrack: MusicTrack { MusicTrack(id: id, title: title, artist: artist, cover: cover, url: url, at: nil) }
}

/* ---------------------------------------------------------- 播放器 */

@MainActor
final class MusicPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = MusicPlayer()

    /// 正在放哪一首 / 在不在放 / 进度（0~1）/ 已播秒数 / 总时长 / 正在下载哪一首
    @Published private(set) var current: MusicTrack?
    /* ⚠ playing 的 setter 得是 internal：锁屏那颗"播放/暂停"（MiniPlayerBall.swift）
       在**别的文件**里要改它。改回 private(set) 会编不过。 */
    @Published var playing = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var seconds: Double = 0
    @Published private(set) var total: Double = 0
    @Published private(set) var loadingId = ""

    /* ⚠ 这三个以前是 private。迷你播放球 / 锁屏那部分（MiniPlayerBall.swift）
       要在**别的文件**里读到它们，同一个 module 必须留成 internal ——
       别再改回 private，不然那边编不过。 */
    var player: AVAudioPlayer?
    /* 2026-10-14 用户：「听一听要加载/之前秒开」—— 没缓存的歌原来要**整首下完**才出声。
       现在没本地文件时用 **StreamPlay 那套边下边播**（AVAssetResourceLoader 转请求 →
       App 自己的会话，认自签证书 + 带登录令牌，服务器支持 206）→ 立刻出声；
       同时后台把整首落盘留底，下次真·秒开。见 startStream。 */
    var stream: AVPlayer?
    /// 流播放的这一首"放完了"的监听（AVPlayer 不走 AVAudioPlayerDelegate，得自己挂通知）
    private var endObserver: NSObjectProtocol?
    var timer: Timer?
    private var cache: [String: Data] = [:]
    /// 锁屏/控制中心那几个按键挂过没有（挂一次就够）
    private var remoteReady = false
    /// 上一次报给锁屏的秒数（别每 0.3 秒都报一遍）
    private var syncedSecond: Int = -1
    /// 上一次报给服务器的"我在听这首"（同一首 60 秒内只报一次）
    private var nowId = ""
    private var nowAt = Date.distantPast

    /* 播放列表（QQ音乐那排「上一首 / 下一首」要有东西可切）：
       从「听一听」点歌时把那一页的列表塞进来，切歌就在这份里找上下首 */
    var queue: [MusicTrack] = []

    /// 点赞结果写回「正在放的这一首」和播放列表 —— 播放页 / 小球读的就是它们，
    /// 不写回去的话关掉再打开又是「没赞过」（用户报的「点赞没存上」）。
    func applyLike(id: String, myId: String, liked: Bool, count: Int) {
        func patch(_ t: MusicTrack) -> MusicTrack {
            var x = t
            var list = x.likes ?? []
            if liked {
                if !list.contains(myId) { list.append(myId) }
            } else {
                list = list.filter { $0 != myId }
            }
            x.likes = list
            x.likeCount = count
            return x
        }
        if var c = current, c.id == id {
            c = patch(c)
            current = c
        }
        queue = queue.map { $0.id == id ? patch($0) : $0 }
    }
    func setQueue(_ list: [MusicTrack]) { queue = list }
    /// 单曲循环（播放页那颗「播放模式」）：开着就一直放这一首
    var loopOne = false
    /* 2026-10-15 对齐 QQ音乐：播放模式 + 定时关闭
       mode: 0 = 顺序播放（默认，列表放完停），1 = 单曲循环，2 = 随机播放 */
    var playMode = 0
    /// 定时关闭：设置完之后还剩多少秒（0 = 没开）。
    /// ⚠ 用「剩余秒数」而不是「到点的时间」：**只在正在放的时候才吃时间**，
    ///    暂停那一段不吃 —— 不然定时 30 分钟、暂停半小时再放，会立刻被停掉。
    private var sleepLeftSec: Double = 0
    /// 上一次给定时关闭倒数是什么时候
    private var sleepTickAt: Date? = nil
    /// 定时关闭刚把歌放停：这一首放完时不再自动往下放（用一次就清）
    private var sleepStopped = false
    /// 定时关闭还剩多少秒（0 = 没开）——界面显示用
    var sleepLeft: Int { max(0, Int(sleepLeftSec.rounded())) }
    /// 设定时关闭：minutes 分钟后停（0 = 取消）
    func setSleep(minutes: Int) {
        sleepLeftSec = minutes > 0 ? Double(minutes) * 60 : 0
        sleepTickAt = minutes > 0 ? Date() : nil
    }
    /// 定时关闭的倒数（tick() 每 0.3 秒叫一次）：true = 到点了，该停
    private func sleepElapsed() -> Bool {
        guard sleepLeftSec > 0 else { return false }
        let now = Date()
        if playing, let last = sleepTickAt {
            sleepLeftSec = max(0, sleepLeftSec - now.timeIntervalSince(last))
        }
        sleepTickAt = now
        if sleepLeftSec <= 0 { sleepLeftSec = 0; sleepTickAt = nil; return true }
        return false
    }
    /* 2026-10-15 对齐 QQ音乐：倍速（0.75x ~ 2.0x）。
       ⚠ AVAudioPlayer 必须先 `enableRate = true`，不然 rate 设了没反应；
         AVPlayer（边下边播那一首）的 rate = 0 就等于暂停，
         所以它只在**正在放**的时候才写 rate。 */
    @Published private(set) var rate: Float = 1
    /// 调倍速（0.5~2.0 之间夹一下；换歌 / 暂停继续之后都会自动带上这个倍速）
    func setRate(_ r: Float) {
        let v = min(max(0.5, r), 2.0)
        rate = v
        if let p = player { p.enableRate = true; p.rate = v }
        if let st = stream, playing { st.rate = v }
    }

    /// 下一首（没有列表就什么都不做）
    func next() {
        guard let cur = current, let i = queue.firstIndex(where: { $0.id == cur.id }) else { return }
        let n = queue[(i + 1) % queue.count]
        play(n)
    }
    /// 上一首
    func prev() {
        guard let cur = current, let i = queue.firstIndex(where: { $0.id == cur.id }) else { return }
        let n = queue[(i - 1 + queue.count) % queue.count]
        play(n)
    }

    /// 报一句"我在听这首"：好友在「听一听 → 朋友推荐」里就能看到
    private func reportNow(_ t: MusicTrack) {
        if nowId == t.id, Date().timeIntervalSince(nowAt) < 60 { return }
        nowId = t.id
        nowAt = Date()
        Task { await API.shared.musicNow(t) }
    }

    /// 只在用到播放器的时候挂一次锁屏控制（省得在 init 里碰 MediaPlayer）
    func ensureRemote() {
        guard !remoteReady else { return }
        remoteReady = true
        setupRemoteControls()
    }

    func isPlaying(_ id: String) -> Bool { playing && current?.id == id }

    /// 点一下：同一首就暂停/继续，别的就换歌
    func toggle(_ t: MusicTrack) {
        if current?.id == t.id, let p = player {
            if p.isPlaying {
                p.pause(); playing = false; stopTimer()
            } else {
                /* 接着放：先把音频会话重新激活 —— 别的页面 / 语音播完可能把它关了，
                   会话没激活时 play() 是**没声音**的（用户说的「暂停之后放不出」多半是这个） */
                try? AVAudioSession.sharedInstance().setActive(true)
                sleepStopped = false
                p.play(); p.rate = rate; playing = true; startTimer()
            }
            syncNowPlaying()
            return
        }
        /* 边下边播的那一首（AVPlayer，不是 AVAudioPlayer）：暂停/继续走它自己 */
        if current?.id == t.id, let st = stream {
            if playing {
                st.pause(); playing = false; stopTimer()
            } else {
                try? AVAudioSession.sharedInstance().setActive(true)
                sleepStopped = false
                st.play(); st.rate = rate; playing = true; startTimer()
            }
            syncNowPlaying()
            return
        }
        play(t)
    }

    /// 封面存一份到本机（锁屏/控制中心那张小图用；没有也没关系，只是不显示图）
    private func cacheCover(_ t: MusicTrack) {
        guard let cover = t.cover, !cover.isEmpty else { return }
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let dir = caches.appendingPathComponent("musiccover", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let to = dir.appendingPathComponent(t.id)
        if FileManager.default.fileExists(atPath: to.path) { return }
        guard let url = API.shared.assetURL(cover) else { return }
        Task {
            if let d = try? await API.shared.assetData(url) {
                try? d.write(to: to, options: .atomic)
                await MainActor.run { self.syncNowPlaying() }
            }
        }
    }

    /// 本机缓存路径：一首歌一个文件（下载过就直接从本地放）
    /* 不是 private：播放页那个「AI 识别歌词」要拿这个本地文件去喂语音识别 */
    func localURL(_ t: MusicTrack) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("music", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let raw = (t.url as NSString).pathExtension
        let ext = (raw.isEmpty || raw.count > 5) ? "mp3" : raw
        return dir.appendingPathComponent("\(t.id).\(ext)")
    }

    func play(_ t: MusicTrack) {
        /* ⚠ 曲库里存的是**相对地址**（/uploads/xxx.mp3），必须用 assetURL 补上服务器前缀，
           不然 URLSession 拿一个没有域名的地址去请求，必然失败 —— 用户看到的「上传了不播放」就是这个。 */
        guard let url = API.shared.assetURL(t.url) else { return }
        ensureRemote()
        cacheCover(t)
        current = t
        reportNow(t)
        /* 记一条「最近播放」（本机 dd_music.json；听一听顶上那个入口就是它） */
        MusicLibrary.shared.markPlayed(t)
        /* 用户自己点开了新歌：定时关闭刚把歌放停那个标记就作废（别误伤下一首） */
        sleepStopped = false
        /* 换歌：先把上一个停干净 —— 本地播放器和流播放器都要停，
           不停的话两首会一起响（流那一首尤其明显，它是另一个 AVPlayer） */
        player?.stop()
        player = nil
        stopStream()
        /* ① 本机已经存过一份：直接放（秒开、离线也能放） */
        if let local = localURL(t), FileManager.default.fileExists(atPath: local.path),
           let p = try? AVAudioPlayer(contentsOf: local) {
            stopTimer()
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
            player = p
            p.delegate = self
            p.enableRate = true          // 倍速：不开这个 rate 不生效
            p.prepareToPlay()
            p.play()
            p.rate = rate
            playing = true
            seconds = 0
            progress = 0
            total = p.duration
            startTimer()
            syncNowPlaying()
            return
        }
        if let d = cache[t.id] {
            start(data: d, track: t)
            return
        }
        /* ③ 本机没有、内存也没有：**边下边播**（2026-10-14 改）—— 不再等整首下完。
           见 startStream：走的还是我们自己的会话（认自签证书 + 带登录令牌）。 */
        startStream(t, httpsURL: url)
    }

    /// 没缓存的歌：**边下边播**，不等整首下完。
    ///
    /// 走视频那套现成的 StreamPlay：地址换成 chrisplay://，AVPlayer 的每个请求回到我们手里，
    /// 再用 **App 自己的会话**去取（认自签证书、带登录令牌，服务器支持 206）→ "够一小段就出声"。
    /// （整首下完再播的话：一首 3.3 MB、手机到服务器只有 ~0.3 MB/s，要干等 11 秒 ——
    ///  这就是用户说的「听一听要加载」。）
    private func startStream(_ t: MusicTrack, httpsURL: URL) {
        guard let p = StreamPlay.player(httpsURL) else {
            /* 连"边下边播"都建不起来（地址不合法之类）→ 退回老路 */
            startDownloadFallback(t, url: httpsURL)
            return
        }
        stopTimer()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        stream = p
        watchEnd(p)
        playing = true
        loadingId = ""
        seconds = 0
        progress = 0
        total = 0            // 真时长要等 AVPlayer 探到，tick() 里补上
        p.play()
        p.rate = rate        // 倍速（换歌后也带着当前的倍速）
        startTimer()
        syncNowPlaying()
        /* 兜底：6 秒还没出声（网络不通 / 地址被拒）就退回"整首下完再播"。
           判据用"播放头有没有动"，别用 rate —— 我们关了 automaticallyWaitsToMinimizeStalling，
           rate 一调 play() 就是 1，看不出到底出没出声。 */
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard self.stream === p else { return }
            let advanced = CMTimeGetSeconds(p.currentTime()) > 0.15   // 时间无效(NaN)时算"没动"
            if !advanced, p.currentItem?.status != .readyToPlay {
                self.stopStream()
                self.startDownloadFallback(t, url: httpsURL)
            }
        }
        /* 后台补一份整首到本机：下次真·秒开。流式落盘（不吃内存），失败也不影响正在播的流 */
        Task {
            var req = URLRequest(url: httpsURL)
            req.timeoutInterval = 120
            if !API.shared.token.isEmpty {
                req.setValue("Bearer \(API.shared.token)", forHTTPHeaderField: "Authorization")
            }
            guard let (tmp, resp) = try? await API.shared.session.download(for: req),
                  !((resp as? HTTPURLResponse).map { $0.statusCode >= 400 } ?? false),
                  let local = self.localURL(t) else { return }
            try? FileManager.default.removeItem(at: local)
            try? FileManager.default.moveItem(at: tmp, to: local)
        }
    }

    /// 流播放的那一首放完：AVPlayer 不会走 AVAudioPlayerDelegate，得自己挂通知
    private func watchEnd(_ p: AVPlayer) {
        dropEndObserver()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.finished() }
        }
    }

    private func dropEndObserver() {
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
    }

    /// 把流播放器停干净（换歌 / 停止 / 开始放本地文件时都要）
    private func stopStream() {
        stream?.pause()
        StreamPlay.cancel(stream?.currentItem)   // 没下完的长请求一起掐掉，别占着连接
        dropEndObserver()
        stream = nil
    }

    /// 老路（很稳）：整首下完再喂给 AVAudioPlayer
    private func startDownloadFallback(_ t: MusicTrack, url: URL) {
        loadingId = t.id
        Task {
            do {
                let data = try await API.shared.assetData(url)
                await MainActor.run {
                    self.loadingId = ""
                    self.cache[t.id] = data
                    if let local = self.localURL(t) { try? data.write(to: local, options: .atomic) }
                    self.start(data: data, track: t)
                }
            } catch {
                await MainActor.run {
                    self.loadingId = ""
                    self.current = nil
                    self.playing = false
                }
            }
        }
    }

    private func start(data: Data, track: MusicTrack) {
        stopTimer()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(data: data)
        player?.delegate = self
        player?.enableRate = true        // 倍速：不开这个 rate 不生效
        player?.prepareToPlay()
        player?.play()
        player?.rate = rate
        playing = true
        seconds = 0
        progress = 0
        total = player?.duration ?? 0
        startTimer()
        syncNowPlaying()
    }

    func pause() {
        player?.pause()
        stream?.pause()
        playing = false
        stopTimer()
        syncNowPlaying()
    }

    func stop() {
        player?.stop()
        player = nil
        stopStream()
        playing = false
        current = nil
        progress = 0
        seconds = 0
        total = 0
        stopTimer()
        syncNowPlaying()
    }

    /// 拖进度：ratio 0~1
    func seek(_ ratio: Double) {
        let r = min(max(0, ratio), 1)
        if let p = player, p.duration > 0 {
            let v = r * p.duration
            p.currentTime = v
            seconds = v
            progress = r
            syncNowPlaying()
            return
        }
        /* 边下边播的那一首：AVPlayer 只认识 CMTime */
        if let st = stream, total > 0 {
            let v = r * total
            st.seek(to: CMTime(seconds: v, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
            seconds = v
            progress = r
            syncNowPlaying()
        }
    }

    /* 迷你球/锁屏那边要手动起停这个计时器，所以这两个不再是 private */
    func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            Task { @MainActor in self.tick() }
        }
    }
    func stopTimer() { timer?.invalidate(); timer = nil }
    func tick() {
        /* 定时关闭到点：停掉这一首（对齐 QQ音乐的「定时关闭」） */
        if sleepElapsed() {
            sleepStopped = true
            pause()
            return
        }
        if let p = player {
            seconds = p.currentTime
            total = p.duration
            progress = p.duration > 0 ? min(1, p.currentTime / p.duration) : 0
        } else if let st = stream {
            /* 流播放：进度从 AVPlayer 读；时长要等它探到才是有限值 */
            let cur = CMTimeGetSeconds(st.currentTime())
            let dur = CMTimeGetSeconds(st.currentItem?.duration ?? .invalid)
            seconds = cur.isFinite ? max(0, cur) : 0
            if dur.isFinite, dur > 0 { total = dur }
            progress = (dur.isFinite && dur > 0) ? min(1, max(0, seconds / dur)) : 0
        } else {
            return
        }
        /* 锁屏上的进度每秒刷一次就够（别每 0.3 秒都报一次） */
        let s = Int(seconds)
        if s != syncedSecond { syncedSecond = s; syncNowPlaying() }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.finished()
        }
    }

    /// 一首放完（本地播放器和流播放器都走这里）
    private func finished() {
        playing = false
        progress = 0
        seconds = 0
        stopTimer()
        syncNowPlaying()
        /* 放完一首（照 QQ音乐）：
           · 定时关闭到点了 → 就停在这儿，不再往下放
           · 单曲循环（或老开关 loopOne）→ 再来一遍
           · 随机 → 列表里随便挑一首（尽量不挑到刚放的这首）
           · 顺序 → 放下一首；到列表末尾就停（不回头，和 QQ音乐「顺序播放」一致） */
        /* 定时关闭刚把歌放停：就停在这儿，不往下放 */
        if sleepStopped { sleepStopped = false; return }
        if loopOne || playMode == 1, let t = current { play(t); return }
        guard let t = current else { return }
        if playMode == 2, queue.count > 1 {
            let others = queue.filter { $0.id != t.id }
            if let n = others.randomElement() { play(n) }
            return
        }
        if let i = queue.firstIndex(where: { $0.id == t.id }), i + 1 < queue.count {
            play(queue[i + 1])
        }
    }
}

/* ---------------------------------------------------------- 小零件 */

/// mm:ss
func musicTime(_ s: Double) -> String {
    guard s.isFinite, s > 0 else { return "00:00" }
    let t = Int(s.rounded())
    return String(format: "%02d:%02d", t / 60, t % 60)
}

/// 封面（没有就用一个音符占位）
struct MusicCover: View {
    var path: String
    var size: CGFloat
    var radius: CGFloat = 8

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0xB98CFF), Color(hex: 0x7A45D6)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "music.note")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
            if !path.isEmpty {
                RemoteImage(path: path, icon: "music.note")
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            }
        }
        .frame(width: size, height: size)
    }
}

/// 一颗播放/暂停圆钮
struct MusicPlayButton: View {
    var playing: Bool
    var loading: Bool
    var size: CGFloat = 30
    var tint: Color = .white
    var bg: Color = Color.black.opacity(0.35)

    var body: some View {
        ZStack {
            Circle().fill(bg)
            if loading {
                ProgressView().tint(tint).scaleEffect(0.7)
            } else {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 0.36, weight: .bold))
                    .foregroundColor(tint)
                    .offset(x: playing ? 0 : size * 0.03)
            }
        }
        .frame(width: size, height: size)
    }
}

/* ---------------------------------------------------------- 聊天里的音乐卡片 */

struct MusicBubble: View {
    let info: MusicCardInfo
    /// 点整张卡：进播放页（微信就是点开进播放器）
    var onOpen: () -> Void
    @ObservedObject private var player = MusicPlayer.shared

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                MusicCover(path: info.cover, size: 52, radius: 8)
                MusicPlayButton(playing: player.isPlaying(info.id),
                                loading: player.loadingId == info.id, size: 22)
                    .offset(x: 3, y: 3)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(info.title)
                    .font(pf(15))
                    .foregroundColor(C.label)
                    .lineLimit(1)
                Text(info.artist.isEmpty ? "未知歌手" : info.artist)
                    .font(pf(12))
                    .foregroundColor(C.subLabel)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(width: 232, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(C.cardBg))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(C.hairline, lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
    }
}

/* ---------------------------------------------------------- 听一听（曲库页） */

struct ListenView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    /// 有值 = 从聊天里进来的：点一首 = 发给这个会话（音乐卡片）
    var sendTo: Chat? = nil
    var onSend: ((MusicTrack) -> Void)? = nil

    @State private var tracks: [MusicTrack] = []
    @State private var loading = true
    @State private var query = ""
    @State private var showSearch = false
    /// 0 = 推荐 / 1 = 歌曲 / 2 = 朋友推荐（照微信「听一听」那三个 tab）
    @State private var tab = 0
    /// 顶上那三个入口（我喜欢 / 我的歌单 / 最近播放）点开了哪一页
    @State private var mine: MusicMineKind? = nil
    /// 搜索的「分类」筛选（"" = 全部）
    @State private var cat = ""
    /// 「换一批」每点一次 +1，推荐列表跟着重排
    @State private var batch = 0
    /// 朋友推荐（好友最近 2 小时在听的）
    @State private var friends: [FriendNowPlaying] = []
    @State private var friendsLoaded = false
    /// 换图标（只有 ops 账号看得到那个小按钮）
    @State private var iconPickFor = ""
    @State private var showIconPick = false
    /// ops 账号在听一听里**直接管理**：多选删除 / 批量导入（用户要求做在这一页）
    @State private var manageMode = false
    @State private var pickedTracks: Set<String> = []
    @State private var showBatchPick = false
    @State private var showFolderPick = false
    @State private var busyText = ""
    @ObservedObject private var player = MusicPlayer.shared

    private var sendMode: Bool { sendTo != nil }

    private var matched: [MusicTrack] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var list = tracks
        if !cat.isEmpty { list = list.filter { $0.categoryText == cat } }
        guard !q.isEmpty else { return list }
        /* 搜索对齐 QQ音乐：歌名 / 歌手 / 分类（分类没填就按有没有歌词自动分） */
        return list.filter { $0.title.localizedCaseInsensitiveContains(q)
            || ($0.artist ?? "").localizedCaseInsensitiveContains(q)
            || $0.categoryText.localizedCaseInsensitiveContains(q) }
    }

    /// 曲库里的分类（去重排序；后台没给分类就按有没有歌词分「人声 / 纯音乐」）
    private var cats: [String] {
        Array(Set(tracks.map { $0.categoryText })).sorted()
    }

    /// 今日推荐：打乱一批（点「换一批」就换一份）
    private var recommend: [MusicTrack] {
        var list = tracks
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return matched }
        /* ⚠ 以前这里每次算都现 shuffle()：这一页盯着播放器（进度 0.3 秒跳一次），
           等于每 0.3 秒重排一遍 —— 用户看到的「音乐卡片怎么在乱跳」就是这个。
           现在按「批次号」做**确定性**打乱：同一批永远同一个顺序，
           只有点「换一批」（batch + 1）才换一份新的。 */
        list.sort { recRank($0.id) < recRank($1.id) }
        return Array(list.prefix(12))
    }

    /// 按 id + 批次号算一个稳定的分数（同一批里顺序固定，换一批才变）
    private func recRank(_ id: String) -> UInt64 {
        var h = UInt64(truncatingIfNeeded: batch &* 2654435761) &+ 1469598103934665603
        for b in id.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return h
    }

    /// 推荐音乐人 = 曲库里出现过的歌手
    private var artists: [(String, String)] {
        var seen: [String: String] = [:]
        tracks.forEach { t in
            let a = (t.artist ?? "").isEmpty ? "未知歌手" : t.artist!
            if seen[a] == nil { seen[a] = t.cover ?? "" }
        }
        return seen.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr(sendMode ? "选择音乐" : "听一听"), back: { dismiss() }) {
                if !sendMode {
                    HStack(spacing: 0) {
                        /* ops 账号：右上角一个「管理」——多选删除、批量导入都在这页直接做 */
                        if app.me?.ops == true {
                            Button {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    manageMode.toggle()
                                    pickedTracks = []
                                }
                            } label: {
                                Text(manageMode ? Tr("完成") : Tr("管理"))
                                    .font(pf(15, .medium))
                                    .foregroundColor(C.green)
                                    .frame(height: 44)
                                    .padding(.horizontal, 8)
                            }
                            .buttonStyle(.plain)
                        }
                        Button { showSearch.toggle() } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(C.label)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if showSearch {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 14.5)).foregroundColor(C.searchIcon)
                    TextField(Tr("搜索歌名 / 歌手 / 分类"), text: $query).font(pf(15))
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15)).foregroundColor(C.searchIcon2)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12).frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(C.searchBg))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(C.hairline, lineWidth: 0.6))
                .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 4)
            }

            if !sendMode {
                /* 2026-10-15 对齐 QQ音乐：顶上三个入口（我喜欢 / 我的歌单 / 最近播放） */
                MusicMineBar { k in mine = k }
                tabRow
                if showSearch || tab == 1, cats.count > 1 { catRow }
                HairLine()
            }

            content

            if !sendMode, let cur = player.current { miniBar(cur) }
            /* 管理模式底下那条：批量导入 + 删除选中（都在这一页里做完） */
            if manageMode {
                HStack(spacing: 8) {
                    Button { showBatchPick = true } label: {
                        Text(Tr("导入文件")).font(pf(13.5, .medium)).foregroundColor(C.label)
                            .padding(.horizontal, 12).frame(height: 34)
                            .background(Capsule().fill(C.pageBg))
                    }
                    .buttonStyle(.plain)
                    Button { showFolderPick = true } label: {
                        Text(Tr("导入文件夹")).font(pf(13.5, .medium)).foregroundColor(C.label)
                            .padding(.horizontal, 12).frame(height: 34)
                            .background(Capsule().fill(C.pageBg))
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                    Button { Task { await deletePicked() } } label: {
                        Text(Tr("删除选中") + " \(pickedTracks.count)")
                            .font(pf(13.5, .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14).frame(height: 34)
                            .background(Capsule().fill(pickedTracks.isEmpty ? C.subLabel : C.red))
                    }
                    .buttonStyle(.plain)
                    .disabled(pickedTracks.isEmpty)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(C.cardBg)
            }
            if !busyText.isEmpty {
                Text(busyText).font(pf(12)).foregroundColor(C.subLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 6)
                    .background(C.cardBg)
            }
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task {
            tracks = await API.shared.musicTracks()
            loading = false
        }
        /* 我喜欢 / 我的歌单 / 最近播放：整页打开（自己带一层 NavigationStack，
           歌单点进去那种二级页才能在栈里推） */
        .fullScreenCover(item: $mine) { k in
            NavigationStack {
                MusicMinePage(kind: k).environmentObject(app)
            }
        }
    }

    /// 顶上那三个 tab（推荐 / 歌曲 / 朋友推荐）—— 微信「听一听」就是这样
    private var tabRow: some View {
        HStack(spacing: 22) {
            ForEach([Tr("推荐"), Tr("歌曲"), Tr("朋友推荐")].indices, id: \.self) { i in
                Button { tab = i } label: {
                    VStack(spacing: 6) {
                        Text([Tr("推荐"), Tr("歌曲"), Tr("朋友推荐")][i])
                            .font(pf(16, tab == i ? .semibold : .regular))
                            .foregroundColor(tab == i ? C.label : C.subLabel)
                        Rectangle()
                            .fill(tab == i ? C.green : Color.clear)
                            .frame(width: 22, height: 2.5)
                            .clipShape(Capsule())
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// 搜索 / 歌曲那一栏底下的分类筛选（QQ音乐搜索页顶上那一排）
    private var catRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                catChip(Tr("全部"), on: cat.isEmpty) { cat = "" }
                ForEach(cats, id: \.self) { c in
                    catChip(c, on: cat == c) { cat = (cat == c ? "" : c) }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 6)
    }

    private func catChip(_ title: String, on: Bool, tap: @escaping () -> Void) -> some View {
        Button { tap() } label: {
            Text(title)
                .font(pf(13, on ? .semibold : .regular))
                .foregroundColor(on ? .white : C.label)
                .padding(.horizontal, 13)
                .frame(height: 28)
                .background(Capsule().fill(on ? C.green : C.pageBg))
                .overlay(Capsule().stroke(C.hairline, lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        /* ⚠ 包一层 Group：.task/.onChange 得挂在**一个视图**上，
           直接跟在 if/else 后面是编不过的（instance member 'task' cannot be used on type 'View'） */
        Group {
        if loading {
            HStack(spacing: 10) { ProgressView(); Text(Tr("正在加载…")).font(pf(15)).foregroundColor(C.subLabel) }
                .frame(maxWidth: .infinity).frame(height: 100)
            Spacer(minLength: 0)
        } else if tracks.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 30, weight: .light)).foregroundColor(C.subLabel)
                Text(Tr("曲库还没有歌（后台「音乐（听一听）」里传一首）"))
                    .font(pf(14)).foregroundColor(C.subLabel)
                    .multilineTextAlignment(.center).padding(.horizontal, 30)
            }
            .frame(maxWidth: .infinity).padding(.top, 60)
            Spacer(minLength: 0)
        } else {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    if tab == 0 {
                        /* 今日推荐 + 换一批（微信顶上就是这一行） */
                        HStack(spacing: 8) {
                            Text(Tr("今日推荐")).font(pf(17, .semibold)).foregroundColor(C.label)
                            Spacer(minLength: 0)
                            Button { batch += 1 } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 12))
                                    Text(Tr("换一批")).font(pf(13))
                                }
                                .foregroundColor(C.subLabel)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)

                        /* 2026-10-15 用户：「听一听我要大图的那种」「一排 2 个大图」——
                           推荐区就是**一排两个大图**（封面铺满半屏、1:1），
                           下面「歌曲」那一栏同样是两列大图。 */
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                            GridItem(.flexible(), spacing: 12)], spacing: 14) {
                            ForEach(Array(recommend.enumerated()), id: \.element.id) { i, t in
                                bigCard(t, rank: i + 1, wide: true)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)

                        if artists.count > 1 {
                            HStack {
                                Text(Tr("推荐音乐人")).font(pf(17, .semibold)).foregroundColor(C.label)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 10)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 16) {
                                    ForEach(Array(artists.enumerated()), id: \.offset) { _, a in
                                        VStack(spacing: 6) {
                                            MusicCover(path: a.1, size: 58, radius: 29)
                                            Text(a.0).font(pf(12.5)).foregroundColor(C.label).lineLimit(1)
                                                .frame(width: 68)
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                            .padding(.bottom, 10)
                        }
                    } else if tab == 1 {
                        /* 歌曲栏：**两列大图**（专辑墙那种），不再是小小一行 */
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                            GridItem(.flexible(), spacing: 12)], spacing: 14) {
                            ForEach(Array(matched.enumerated()), id: \.offset) { _, t in
                                bigCard(t, rank: nil, wide: true)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                    } else {
                        /* 朋友推荐 = 好友最近 2 小时在听的歌（用户要的「让好友看到我在听啥」）。
                           进来的时候拉一次，切到这一栏也会再拉一次。 */
                        if !friends.isEmpty {
                            ForEach(Array(friends.enumerated()), id: \.element.id) { _, f in
                                friendRow(f)
                            }
                            Text(Tr("好友最近 2 小时在听的歌"))
                                .font(pf(12)).foregroundColor(C.subLabel.opacity(0.8))
                                .frame(maxWidth: .infinity)
                                .padding(.top, 14)
                        } else {
                            VStack(spacing: 8) {
                                Text(Tr("朋友推荐还没有内容")).font(pf(14)).foregroundColor(C.subLabel)
                                Text(Tr("你在这一页放一首歌，好友的「朋友推荐」里就会看到你在听什么；\n反过来，好友在听的时候这里也会出现。"))
                                    .font(pf(12.5)).foregroundColor(C.subLabel.opacity(0.8))
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity).padding(.top, 50)
                        }
                    }
                    Spacer().frame(height: 24)
                }
            }
            .background(C.pageBg)
        }
        }
        /* 进来先拉一次好友在听什么；点到「朋友推荐」那一栏再拉一次（要最新的） */
        .task { await loadFriends() }
        .onChange(of: tab) { t in if t == 2 { Task { await loadFriends() } } }
        /* 换个封面：选一张图 → 上传 → 存到这首的 cover 上 */
        .sheet(isPresented: $showIconPick) {
            PhotoPicker { img in
                let id = iconPickFor
                Task {
                    if let url = try? await API.shared.upload(image: img) {
                        try? await API.shared.manageSetIcon(kind: "music", id: id, cover: url)
                        tracks = await API.shared.musicTracks()
                    }
                }
            }
        }
        /* 批量导入：文件（可多选）/ 整个文件夹 —— 就在听一听这一页做 */
        .fileImporter(isPresented: $showBatchPick, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
        .fileImporter(isPresented: $showFolderPick, allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let dir = urls.first { importFolder(dir) }
        }
    }

    /* ---------------- 听一听页里的管理（ops 账号） ---------------- */

    private let audioExts: Set<String> = ["mp3", "m4a", "flac", "wav", "aac", "ogg", "oga",
                                          "opus", "ape", "wma", "aiff", "aif", "amr", "mka", "mp4"]

    private func deletePicked() async {
        let ids = Array(pickedTracks)
        guard !ids.isEmpty else { return }
        do {
            try await API.shared.manageRemoveMusic(ids: ids)
            pickedTracks = []
            busyText = Tr("已删除 ") + "\(ids.count)" + Tr(" 首")
            tracks = await API.shared.musicTracks()
        } catch {
            busyText = (error as? APIError)?.errorDescription ?? "删除失败"
        }
    }

    private func importFolder(_ dir: URL) {
        let ok = dir.startAccessingSecurityScopedResource()
        if !ok { busyText = Tr("读不到这个文件夹"); return }
        var files: [URL] = []
        if let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) {
            for case let u as URL in e where audioExts.contains(u.pathExtension.lowercased()) {
                files.append(u)
            }
        }
        guard !files.isEmpty else {
            dir.stopAccessingSecurityScopedResource()
            busyText = Tr("这个文件夹里没找到音频文件")
            return
        }
        importFiles(files, holding: dir)
    }

    /// 一首一首来：上传 → 入库（歌名用文件名；服务器会把非 mp3 转码）
    private func importFiles(_ urls: [URL], holding: URL? = nil) {
        let list = urls.filter { audioExts.contains($0.pathExtension.lowercased()) }
        guard !list.isEmpty else {
            holding?.stopAccessingSecurityScopedResource()
            busyText = Tr("没找到能导入的音频文件")
            return
        }
        Task {
            defer { holding?.stopAccessingSecurityScopedResource() }
            var done = 0
            for u in list {
                let scoped = u.startAccessingSecurityScopedResource()
                defer { if scoped { u.stopAccessingSecurityScopedResource() } }
                do {
                    let raw = try Data(contentsOf: u)
                    if raw.count > 60 * 1024 * 1024 { done += 1; continue }
                    let payload: [String: Any] = [
                        "dataUrl": "data:" + musicMimeFor(u.lastPathComponent) + ";base64," + raw.base64EncodedString(),
                        "filename": u.lastPathComponent
                    ]
                    let r = try await API.shared.rawUpload(payload)
                    try await API.shared.manageSaveMusic(id: "",
                                                         title: u.deletingPathExtension().lastPathComponent,
                                                         artist: "", cover: "", url: r.url, lyrics: "")
                } catch { }
                done += 1
                busyText = Tr("正在导入 ") + "\(done)/\(list.count)"
            }
            busyText = Tr("导入完成 ") + "\(done)/\(list.count)"
            tracks = await API.shared.musicTracks()
        }
    }

    private func musicMimeFor(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4a", "m4r", "mp4", "aac": return "audio/mp4"
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        case "ogg", "oga", "opus": return "audio/ogg"
        case "aiff", "aif": return "audio/aiff"
        default: return "application/octet-stream"
        }
    }

    /* 好友在听的一行：头像 + 名字 + 在听什么 + 一起听（点了直接播这首）
       2026-10-12 跟歌曲列表一样改成 QQ 音乐那种独立卡片。 */
    private func friendRow(_ f: FriendNowPlaying) -> some View {
        let t = f.asTrack
        return Button { MusicPlayer.shared.toggle(t) } label: {
            HStack(spacing: 12) {
                Avatar(path: f.avatar ?? "", size: 52, radius: 12)
                VStack(alignment: .leading, spacing: 4) {
                    Text(f.name).font(pf(16, .medium)).foregroundColor(C.label).lineLimit(1)
                    Text(f.line)
                        .font(pf(12.5)).foregroundColor(C.subLabel).lineLimit(1)
                }
                Spacer(minLength: 6)
                playDot(playing: player.isPlaying(t.id), loading: player.loadingId == t.id)
            }
            .padding(.horizontal, 12).frame(height: 78)
            .background(cardFace)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16).padding(.vertical, 5)
    }

    /* ---------------- 卡片外壳 / 零件（照 QQ 音乐列表那一套） ---------------- */

    /// 一张独立卡片的底：圆角 14 + 一条极淡的描边 + 浅色模式下一点点投影
    private var cardFace: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(C.cardBg)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(C.hairline.opacity(scheme == .dark ? 1 : 0.65), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.06), radius: 7, x: 0, y: 2)
    }

    /// 右边那颗播放钮：在播 = 实心绿 + 白图标，没在播 = 淡绿底 + 绿图标（QQ 音乐就是这个）
    private func playDot(playing: Bool, loading: Bool) -> some View {
        MusicPlayButton(playing: playing, loading: loading, size: 34,
                        tint: playing ? .white : C.green,
                        bg: playing ? C.green : C.green.opacity(0.12))
    }

    /// 「推荐」那一栏的排名徽章（1 红 / 2 橙 / 3 金，其余灰），贴在封面左上角
    private func rankBadge(_ n: Int) -> some View {
        let c: Color = n == 1 ? Color(hex: 0xFA3B4B)
            : (n == 2 ? Color(hex: 0xFF8A00) : (n == 3 ? Color(hex: 0xF7B500) : Color.black.opacity(0.45)))
        return Text("\(n)")
            .font(pf(11, .bold))
            .foregroundColor(.white)
            .frame(width: 19, height: 19)
            .background(Circle().fill(c))
            .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.2))
            .offset(x: -5, y: -5)
    }

    /// 管理模式的勾选圈
    private func checkDot(_ t: MusicTrack) -> some View {
        Image(systemName: pickedTracks.contains(t.id) ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 21))
            .foregroundColor(pickedTracks.contains(t.id) ? C.green : C.subLabel)
    }

    /// ops 账号在列表里直接换封面那颗小按钮
    private func iconPickDot(_ t: MusicTrack) -> some View {
        Button {
            iconPickFor = t.id
            showIconPick = true
        } label: {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 17))
                .foregroundColor(C.green)
                .frame(width: 34, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func loadFriends() async {
        friends = await API.shared.friendsNowPlaying()
        friendsLoaded = true
    }

    /* 一首歌 = 一张独立卡片（2026-10-12 用户要求「听一听对齐 QQ 音乐那种卡片」）：
       大封面 58 圆角 12 + 标题 16 + 歌手 12.5 + 右边一颗圆形播放钮，
       卡与卡之间留缝、圆角 14、浅色下带一点点投影；「推荐」栏前 3 名封面左上角带排名。
       点整张卡的行为没变：管理模式 = 勾选，发歌模式 = 发给这个会话，平时 = 播放/暂停。 */
    private func row(_ t: MusicTrack, rank: Int? = nil) -> some View {
        rowBody(t, rank: rank)
    }

    /// 大图卡（听一听的「大图那种」）：封面尽量大 + 歌名 + 歌手 + 右下角播/暂停
    /// - wide = true 时宽度自适应（两列网格里用）；否则固定 186（横滑推荐用）
    private func bigCard(_ t: MusicTrack, rank: Int? = nil, wide: Bool = false) -> some View {
        /* 2026-10-15 用户：「图太大了都没适配屏幕了」——
           以前用 `.aspectRatio(.fill)`，盒子会被内容固有尺寸（320）撑大 → 溢出屏幕。
           现在**按屏宽算死的正方形**：一排两个 =（屏宽 − 左右各 16 − 中间缝 12）/ 2，
           图就是这个边长，绝不会超屏。 */
        let gridSide: CGFloat = max(120, (L.width - 16 * 2 - 12) / 2)
        let side: CGFloat = wide ? gridSide : 186
        return Button {
            if manageMode {
                if pickedTracks.contains(t.id) { pickedTracks.remove(t.id) }
                else { pickedTracks.insert(t.id) }
            } else if let onSend, sendMode {
                onSend(t)
                dismiss()
            } else {
                MusicPlayer.shared.setQueue(tracks)
                MusicPlayer.shared.toggle(t)
            }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                ZStack(alignment: .topLeading) {
                    MusicCover(path: t.cover ?? "", size: side, radius: 14)
                    if let rank { rankBadge(rank) }
                    /* 右下角那颗播放钮（压在图上，像大图音轨卡） */
                    MusicPlayButton(playing: player.isPlaying(t.id), loading: player.loadingId == t.id,
                                    size: 38, tint: .white, bg: Color.black.opacity(0.42))
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
                Text(t.title).font(pf(15, .medium)).foregroundColor(C.label).lineLimit(1)
                Text(t.artistText).font(pf(12.5)).foregroundColor(C.subLabel).lineLimit(1)
            }
            .frame(width: side, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func rowBody(_ t: MusicTrack, rank: Int? = nil) -> some View {
        Button {
            if manageMode {
                if pickedTracks.contains(t.id) { pickedTracks.remove(t.id) }
                else { pickedTracks.insert(t.id) }
            } else if let onSend, sendMode {
                onSend(t)
                dismiss()
            } else {
                /* 点一下**只播放/暂停** —— 以前还会顺手弹出播放页，
                   手一抖就"播放 + 弹页"两件事一起发生（用户说的误触）。 */
                MusicPlayer.shared.setQueue(tracks)    // 记住这一页的列表：播放页能切上下首
                MusicPlayer.shared.toggle(t)
            }
        } label: {
            HStack(spacing: 12) {
                if manageMode { checkDot(t) }
                ZStack(alignment: .topLeading) {
                    MusicCover(path: t.cover ?? "", size: 58, radius: 12)
                    /* 排名只在「推荐」那一栏显示（搜索出来的列表不显示） */
                    if let rank, !manageMode { rankBadge(rank) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(t.title).font(pf(16, .medium)).foregroundColor(C.label).lineLimit(1)
                    Text(t.artistText).font(pf(12.5)).foregroundColor(C.subLabel).lineLimit(1)
                }
                Spacer(minLength: 8)
                playDot(playing: player.isPlaying(t.id), loading: player.loadingId == t.id)
                /* 有管理权限的账号：在听一听列表里直接点一下就能给这首歌换图标
                   （后台、App 管理页里也都能换，这里最顺手） */
                if app.me?.ops == true && !manageMode { iconPickDot(t) }
            }
            .padding(.horizontal, 12).frame(height: 78)
            .background(cardFace)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16).padding(.vertical, 5)
    }

    /// 底下一根播放条（微信听一听就这样）
    private func miniBar(_ t: MusicTrack) -> some View {
        VStack(spacing: 0) {
            HairLine()
            HStack(spacing: 10) {
                MusicCover(path: t.cover ?? "", size: 38, radius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(pf(14)).foregroundColor(C.label).lineLimit(1)
                    Text(t.artistText).font(pf(11.5)).foregroundColor(C.subLabel).lineLimit(1)
                }
                Spacer(minLength: 6)
                Button { MusicPlayer.shared.toggle(t) } label: {
                    MusicPlayButton(playing: player.isPlaying(t.id), loading: player.loadingId == t.id,
                                    size: 32, tint: .white, bg: C.green)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(C.cardBg)
            /* 点这条空白处 = 进播放页（大封面那页）；点右边的按钮才是 播放/暂停 */
            .contentShape(Rectangle())
            .onTapGesture { MusicSheet.shared.open(t) }
        }
    }
}

/* ---------------------------------------------------------- 播放页（大封面） */

/// 谁都能叫出播放页（聊天里点卡片、听一听里点一首）
@MainActor
final class MusicSheet: ObservableObject {
    static let shared = MusicSheet()
    @Published var open = false
    @Published var track: MusicTrack?
    func open(_ t: MusicTrack) { track = t; open = true }
    func close() { open = false }

    /// 点赞结果写回「正在看的那一首」（见 MusicPlayer.applyLike 的说明）
    func applyLike(id: String, myId: String, liked: Bool, count: Int) {
        guard var t = track, t.id == id else { return }
        var list = t.likes ?? []
        if liked {
            if !list.contains(myId) { list.append(myId) }
        } else {
            list = list.filter { $0 != myId }
        }
        t.likes = list
        t.likeCount = count
        track = t
    }
}

struct MusicPlayingView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var sheet = MusicSheet.shared
    @Environment(\.dismiss) private var dismiss
    @State private var dragging = false
    @State private var dragValue: Double = 0
    /// 歌词页（右上角那个「词」）
    @State private var showLyrics = false
    /// 大图翻转成玻璃卡（正面封面 / 背面歌词）
    @State private var flipped = false
    /// AI 识别歌词：识别中的文字 / 是不是在识别
    @State private var aiText = ""
    @State private var aiBusy = false
    /// 歌词滚动的上一个高亮行（跳很多行就"直接跳过去"，只差一两行才做动画）
    @State private var lastLyricLine = -1
    /// 播放器下面那排：点赞 / 转发 / 分享（微信听一听那一排）
    @State private var likedNow: Bool? = nil
    @State private var likeCountNow: Int? = nil
    @State private var shareTo = false
    @State private var shareSystem = false
    /// 播放列表（QQ音乐那颗「列表」按钮）
    @State private var showQueue = false
    /// 切「单曲循环」时用它触发一次重绘（loopOne 在播放器上，不是 @Published）
    @State private var loopTick = false

    private var t: MusicTrack? { sheet.track ?? player.current }

    /// 关掉这一页：**先把这个开关归位再 dismiss** —— 只 dismiss 不归位的话
    /// 标记还立着，下一次界面刷新又会把它弹回来（用户说的"关不掉"）。
    private func closeMe() {
        MusicSheet.shared.close()
    }

    /* ---------------------------------------------------------- 赞 / 转发 / 分享 */

    private var liked: Bool {
        if let v = likedNow { return v }
        return (t?.likes ?? []).contains(app.me?.id ?? "")
    }
    private var likeCount: Int {
        if let n = likeCountNow { return n }
        return t?.likeCount ?? (t?.likes ?? []).count
    }

    /// 一排里的一个：图标 + 数字 + 名字（微信就是"图标在上面、数字/文字在下面"）
    private func playerAction(icon: String, name: String, count: Int?,
                              tint: Color, tap: @escaping () -> Void) -> some View {
        Button { tap() } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 21)).foregroundColor(tint)
                if let c = count, c > 0 {
                    Text("\(c)").font(pf(11.5)).foregroundColor(C.subLabel)
                }
                Text(name).font(pf(12)).foregroundColor(C.subLabel)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func likeIt() {
        guard let track = t else { return }
        let now = !liked
        likedNow = now
        likeCountNow = max(0, likeCount + (now ? 1 : -1))
        Task {
            if let r = await API.shared.musicLike(track.id) {
                likedNow = r.liked
                likeCountNow = r.count
                /* 把结果写回共享的那份（播放页 / 播放列表 / 小球都读它），
                   不然关掉再打开又变回"没赞过" */
                let mine = app.me?.id ?? ""
                MusicSheet.shared.applyLike(id: track.id, myId: mine, liked: r.liked, count: r.count)
                MusicPlayer.shared.applyLike(id: track.id, myId: mine, liked: r.liked, count: r.count)
            }
        }
    }

    /// 把这首歌在服务器上的最新点赞状态拉回来（进播放页时调一次）
    private func refreshLike() async {
        guard let id = t?.id else { return }
        guard let fresh = await API.shared.musicTracks().first(where: { $0.id == id }) else { return }
        let mine = app.me?.id ?? ""
        likedNow = (fresh.likes ?? []).contains(mine)
        likeCountNow = fresh.likeCount ?? (fresh.likes ?? []).count
    }

    /// 转发出去的那张音乐卡片（和聊天里「＋ → 音乐」发的是同一种）
    /// 分享面板里那段文字：「歌名 — 歌手」
    private var shareText: String {
        let title = t?.title ?? ""
        let artist = t?.artistText ?? ""
        return artist.isEmpty ? title : title + " — " + artist
    }

    /* ---------------------------------------------------------- 播放模式 · 倍速 · 定时 */

    /// 播放模式：0 顺序（列表放完停）/ 1 单曲循环 / 2 随机
    private var modeIcon: String {
        let m = MusicPlayer.shared.playMode
        return m == 1 ? "repeat.1" : (m == 2 ? "shuffle" : "repeat")
    }
    private var modeName: String {
        let m = MusicPlayer.shared.playMode
        return m == 1 ? "单曲循环" : (m == 2 ? "随机播放" : "顺序播放")
    }
    private func toggleMode() {
        MusicPlayer.shared.playMode = (MusicPlayer.shared.playMode + 1) % 3
        loopTick.toggle()          // playMode 不是 @Published：动一下 @State 逼这一页重画
    }

    /// 倍速文案：1.0x / 0.75x / 1.25x / 1.5x / 2.0x
    private func rateText(_ v: Double) -> String {
        let s = v == floor(v) ? String(format: "%.1f", v) : String(format: "%.2f", v)
        return s + "x"
    }

    /// 定时关闭那顆按钮上的字：没开 = 「定时」，开着 = 剩余时间
    private var sleepText: String {
        let left = player.sleepLeft
        guard left > 0 else { return Tr("定时") }
        return String(format: "%02d:%02d", left / 60, left % 60)
    }

    /// 下面那排小胶囊的样子（播放模式 / 倍速 / 定时）
    private func pillLabel(_ icon: String, _ text: String, on: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 12.5))
            Text(text).font(pf(12.5, .medium)).lineLimit(1)
        }
        .foregroundColor(on ? C.green : C.label)
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background(Capsule().fill(on ? C.green.opacity(0.12) : C.pageBg))
        .overlay(Capsule().stroke(C.hairline, lineWidth: 0.5))
        .contentShape(Capsule())
    }

    private func pill(_ icon: String, _ text: String, on: Bool, tap: @escaping () -> Void) -> some View {
        Button { tap() } label: { pillLabel(icon, text, on: on) }
            .buttonStyle(.plain)
    }

    /// 播放模式 · 倍速 · 定时（QQ音乐进度条下面那三颗）
    private var toolsRow: some View {
        HStack(spacing: 9) {
            pill(modeIcon, Tr(modeName), on: MusicPlayer.shared.playMode != 0) { toggleMode() }

            Menu {
                ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { v in
                    Button(rateText(v)) {
                        MusicPlayer.shared.setRate(Float(v))
                        loopTick.toggle()
                    }
                }
            } label: {
                pillLabel("gauge.with.needle", rateText(Double(player.rate)), on: abs(player.rate - 1) > 0.01)
            }

            Menu {
                ForEach([10, 20, 30, 60], id: \.self) { m in
                    Button("\(m) " + Tr("分钟")) {
                        MusicPlayer.shared.setSleep(minutes: m)
                        loopTick.toggle()
                    }
                }
                if player.sleepLeft > 0 {
                    Button(Tr("关闭定时"), role: .destructive) {
                        MusicPlayer.shared.setSleep(minutes: 0)
                        loopTick.toggle()
                    }
                }
            } label: {
                pillLabel("timer", sleepText, on: player.sleepLeft > 0)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
    }

    /// 点歌词里的某一句 → 跳过去（歌词给的是秒数，seek 要 0~1 的比例）
    private func seekTo(_ sec: Double) {
        let total = player.total
        guard total > 1 else { return }
        MusicPlayer.shared.seek(min(max(0, sec / total), 1))
    }

    /// 「封面 / 歌词」切换（点大卡也能翻，这里是明面上的那一颗）
    private var coverLyricSwitch: some View {
        HStack(spacing: 0) {
            segButton(Tr("封面"), on: !flipped) { flipped = false }
            segButton(Tr("歌词"), on: flipped) { flipped = true }
        }
        .padding(3)
        .background(Capsule().fill(C.pageBg))
        .overlay(Capsule().stroke(C.hairline, lineWidth: 0.5))
        .padding(.top, 12)
    }

    private func segButton(_ title: String, on: Bool, tap: @escaping () -> Void) -> some View {
        Button { tap() } label: {
            Text(title)
                .font(pf(13.5, on ? .semibold : .regular))
                .foregroundColor(on ? .white : C.subLabel)
                .frame(width: 76, height: 28)
                .background(Capsule().fill(on ? C.green : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// 播放列表：从下往上滑出来的半屏（QQ音乐那颗「列表」）
    private var queueSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text(Tr("播放列表") + "（\(player.queue.count)）")
                    .font(pf(16, .semibold)).foregroundColor(C.label)
                Spacer(minLength: 0)
                Button { showQueue = false } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                        .foregroundColor(C.subLabel).frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.top, 10)

            if player.queue.isEmpty {
                VStack(spacing: 8) {
                    Text(Tr("还没有播放列表")).font(pf(14)).foregroundColor(C.label)
                    Text(Tr("去「听一听」里点一首歌，就能在这里切上一首/下一首"))
                        .font(pf(12)).foregroundColor(C.subLabel)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 40)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(player.queue.enumerated()), id: \.element.id) { i, t in
                            if i > 0 { HairLine(inset: 66) }
                            Button {
                                MusicPlayer.shared.play(t)
                            } label: {
                                HStack(spacing: 10) {
                                    MusicCover(path: t.cover ?? "", size: 40, radius: 6)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(t.title).font(pf(15)).foregroundColor(C.label).lineLimit(1)
                                        Text(t.artistText).font(pf(12)).foregroundColor(C.subLabel).lineLimit(1)
                                    }
                                    Spacer(minLength: 6)
                                    if player.current?.id == t.id {
                                        Image(systemName: "waveform").font(.system(size: 14)).foregroundColor(C.green)
                                    }
                                }
                                .padding(.horizontal, 14).frame(height: 58)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: 380)
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(C.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .zIndex(70)
    }

    private var musicCardJSON: String {
        guard let track = t else { return "" }
        var d: [String: Any] = ["id": track.id, "title": track.title, "url": track.url]
        if let v = track.artist, !v.isEmpty { d["artist"] = v }
        if let v = track.cover, !v.isEmpty { d["cover"] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: d),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    /* ---------------------------------------------------------- 可翻转的玻璃大卡 */

    private var cardSide: CGFloat { min(288, L.width - 72) }

    private var flipCard: some View {
        ZStack {
            /* 正面：封面 */
            VStack(spacing: 0) {
                MusicCover(path: t?.cover ?? "", size: cardSide - 18, radius: 14)
                HStack(spacing: 5) {
                    Image(systemName: "text.alignleft").font(.system(size: 11))
                    Text(Tr("点一下看歌词")).font(pf(11.5))
                }
                .foregroundColor(C.subLabel)
                .padding(.top, 8)
            }
            .padding(9)
            .frame(width: cardSide, height: cardSide)
            .background {
                GlassBackground(shape: RoundedRectangle(cornerRadius: 20, style: .continuous),
                                opacity: UIConfig.num("musicCardGlass", 0.9),
                                edgeAlpha: 0.55, shadow: true, seed: 0.42)
            }
            .opacity(flipped ? 0 : 1)

            /* 背面：歌词（还带一个「AI 识别歌词」） */
            backFace
                .padding(10)
                .frame(width: cardSide, height: cardSide)
                .background {
                    GlassBackground(shape: RoundedRectangle(cornerRadius: 20, style: .continuous),
                                    opacity: UIConfig.num("musicCardGlass", 0.9),
                                    edgeAlpha: 0.55, shadow: true, seed: 0.42)
                }
                .opacity(flipped ? 1 : 0)
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
        }
        .rotation3DEffect(.degrees(flipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))
        .animation(.spring(response: 0.55, dampingFraction: 0.85), value: flipped)
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .onTapGesture { flipped.toggle() }
    }

    private var backFace: some View {
        let raw = (t?.lyrics ?? "").isEmpty ? aiText : (t?.lyrics ?? "")
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "text.alignleft").font(.system(size: 11)).foregroundColor(C.subLabel)
                Text(t?.title ?? "").font(pf(12.5, .medium)).foregroundColor(C.label).lineLimit(1)
                Spacer(minLength: 0)
                if aiBusy {
                    ProgressView().scaleEffect(0.6)
                } else {
                    Button { aiRecognize() } label: {
                        Text(aiText.isEmpty ? Tr("AI 识别歌词") : Tr("重新识别"))
                            .font(pf(11.5)).foregroundColor(C.green)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 6)

            /* 2026-10-15：换成共享的 LyricsView —— 逐行高亮 + 自动居中 +
               **点某一句跳过去**（onSeek）；没有歌词时它自己给占位（不会是白板）。 */
            LyricsView(raw: raw, seconds: player.seconds, duration: player.total) { sec in
                seekTo(sec)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 「AI 识别歌词」：拿本机那份音频喂系统语音识别（本地跑），
    /// 识别出来直接当歌词显示；管理账号顺手存到曲库（别人也能看到）。
    private func aiRecognize() {
        guard let track = t, !aiBusy else { return }
        aiBusy = true
        Task {
            guard await FileSpeech.authorize() else {
                aiText = Tr("需要先允许「语音识别」权限")
                aiBusy = false
                return
            }
            guard let url = MusicPlayer.shared.localURL(track) ?? API.shared.assetURL(track.url) else {
                aiText = Tr("拿不到这首歌的音频")
                aiBusy = false
                return
            }
            if !FileManager.default.fileExists(atPath: url.path), let remote = API.shared.assetURL(track.url),
               let data = try? await API.shared.assetData(remote), let local = MusicPlayer.shared.localURL(track) {
                try? data.write(to: local, options: .atomic)
            }
            let file = MusicPlayer.shared.localURL(track) ?? url
            let text = await FileSpeech.recognize(url: file, timeout: 90)
            aiText = text.isEmpty ? Tr("没识别出来（歌曲背景音太吵时识别会比较难）") : text
            if !text.isEmpty, app.me?.ops == true {
                try? await API.shared.manageSaveMusic(id: track.id, title: track.title,
                                                      artist: track.artist ?? "", cover: track.cover ?? "",
                                                      url: track.url, lyrics: text)
            }
            aiBusy = false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { closeMe() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(C.label)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                Spacer()
                Text(Tr("正在播放")).font(pf(14)).foregroundColor(C.subLabel)
                Spacer()
                /* 歌词（后台「音乐（听一听）」里贴的；没有歌词时这一页会提示去哪儿加） */
                Button { showLyrics = true } label: {
                    Text(Tr("词"))
                        .font(pf(15, .medium))
                        .foregroundColor(C.label)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
            }
            /* 顶栏往下拖一截 = 关掉这一页（有些系统手势在这页上不好使，
               这里自己接一手，保证一定关得掉） */
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 10).onEnded { v in
                if v.translation.height > 70 && abs(v.translation.height) > abs(v.translation.width) {
                    closeMe()
                }
            })

            Spacer(minLength: 10)

            /* 大图 = 一张**可以翻转的玻璃卡**：正面封面，背面歌词（用户要求） */
            flipCard

            /* 封面 / 歌词：明面上的那一颗（点大卡也能翻） */
            coverLyricSwitch

            VStack(spacing: 6) {
                Text(t?.title ?? "").font(pf(19, .semibold)).foregroundColor(C.label).lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(t?.artistText ?? "").font(pf(13.5)).foregroundColor(C.subLabel).lineLimit(1)
            }
            .padding(.horizontal, 30)
            .padding(.top, 14)

            Spacer(minLength: 8)

            /* 进度条：拖的时候实时跟手 */
            VStack(spacing: 6) {
                Slider(value: Binding(
                    get: { dragging ? dragValue : player.progress },
                    set: { dragValue = $0 }
                ), in: 0...1, onEditingChanged: { on in
                    dragging = on
                    if !on { MusicPlayer.shared.seek(dragValue) }
                })
                .tint(C.green)
                .padding(.horizontal, 24)
                HStack {
                    Text(musicTime(dragging ? dragValue * player.total : player.seconds))
                        .font(pf(11.5)).foregroundColor(C.subLabel)
                    Spacer()
                    Text(musicTime(player.total)).font(pf(11.5)).foregroundColor(C.subLabel)
                }
                .padding(.horizontal, 28)
            }

            /* 2026-10-15 对齐 QQ音乐：播放模式 · 倍速 · 定时（三颗小胶囊） */
            toolsRow

            /* QQ音乐那一排：播放模式 · 上一首 · 大播放钮 · 下一首 · 播放列表 */
            HStack(spacing: 0) {
                /* 左边这颗 = 播放模式：点一下 顺序 → 单曲 → 随机（图标跟着变） */
                Button { toggleMode() } label: {
                    Image(systemName: modeIcon)
                        .font(.system(size: 19))
                        .foregroundColor(MusicPlayer.shared.playMode == 0 ? C.subLabel : C.green)
                        .frame(width: 54, height: 46)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button { MusicPlayer.shared.prev() } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 25))
                        .foregroundColor(player.queue.count > 1 ? C.label : C.subLabel.opacity(0.5))
                        .frame(width: 54, height: 46)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    if let t { MusicPlayer.shared.toggle(t) }
                } label: {
                    ZStack {
                        Circle().fill(C.green).frame(width: 64, height: 64)
                        if player.loadingId == (t?.id ?? "") {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: player.playing ? "pause.fill" : "play.fill")
                                .font(.system(size: 25, weight: .bold))
                                .foregroundColor(.white)
                                .offset(x: player.playing ? 0 : 2)
                        }
                    }
                    .frame(width: 84, height: 46)
                }
                .buttonStyle(.plain)

                Button { MusicPlayer.shared.next() } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 25))
                        .foregroundColor(player.queue.count > 1 ? C.label : C.subLabel.opacity(0.5))
                        .frame(width: 54, height: 46)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button { showQueue = true } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 20))
                        .foregroundColor(C.label)
                        .frame(width: 54, height: 46)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 14)

            /* 微信听一听那一排：赞（带数字）· 转发 · 分享 */
            HStack(spacing: 0) {
                playerAction(icon: liked ? "heart.fill" : "heart",
                             name: Tr("赞"),
                             count: likeCount,
                             tint: liked ? Color(hex: 0xFF5A5A) : C.label) { likeIt() }
                playerAction(icon: "arrowshape.turn.up.right",
                             name: Tr("转发"),
                             count: t?.shareCount ?? 0,
                             tint: C.label) { shareTo = true }
                playerAction(icon: "square.and.arrow.up",
                             name: Tr("分享"),
                             count: nil,
                             tint: C.label) { shareSystem = true }
            }
            .padding(.top, 10)

            Spacer(minLength: 8)
        }
        .background(C.cardBg.ignoresSafeArea())
        /* 整页往下拖也能关（拖得够远、方向是往下才关，横着拖进度条不受影响） */
        .contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 12).onEnded { v in
            if v.translation.height > 90 && abs(v.translation.height) > abs(v.translation.width) * 1.2 {
                closeMe()
            }
        })
        /* 歌词页也当整屏覆盖（和播放页一套逻辑，不再走 sheet） */
        .overlay {
            if showLyrics {
                MusicLyricsView(track: t) { showLyrics = false }
                    .transition(.opacity)
            }
        }
        /* 转发：选一个好友 → 发一张音乐卡片（转发次数 +1） */
        .sheet(isPresented: $shareTo) {
            ForwardPickerView(items: [ForwardItem(kind: "music", content: musicCardJSON)]) {
                if let track = t { Task { await API.shared.musicShareCount(track.id) } }
            }
            .environmentObject(app)
        }
        /* 分享：系统分享面板（把歌名歌手分享出去） */
        .sheet(isPresented: $shareSystem) {
            ShareSheet(items: [shareText])
        }
        /* 播放列表（QQ音乐那颗「列表」）：点一首就切过去 */
        .overlay {
            if showQueue {
                queueSheet
            }
        }
        .onAppear {
            /* 只有「换了一首」才从头播；同一首进进出出别打断（以前每次进这页都重播一遍） */
            if let t, player.current?.id != t.id { MusicPlayer.shared.play(t) }
            /* 顺手把这首歌**服务器上最新的点赞状态**拉回来：
               以前这儿用的是打开时那份快照，赞过之后重开播放器又显示"没赞过"
               （用户报的「音乐点赞还是没存上」——其实服务器存上了，是这一页读的旧值）。 */
            Task { await refreshLike() }
        }
        /* 这一页被往下划掉 / 点左上角关掉之后，把"要弹播放页"这个标记也清掉 ——
           不然标记还立着，下一次任何一次打开都会又弹一遍（"关不掉"的一种情况） */
        .onDisappear { MusicSheet.shared.close() }
    }
}

/* ⚠ 取曲库的接口写在 API.swift 里（那边的 get 是 private，扩展里调不到） */
