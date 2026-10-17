import SwiftUI
import AVKit
import PhotosUI

/* ============================================================
   视频号（发现 → 视频号）—— 抖音式上下刷
     · 一次一屏，手指上滑看下一条（松手吸附，跟手）
     · 右侧动作栏：头像+关注 / ❤️ / 💬 / ↗️
     · 底部：作者 + 文案 + 🎵 音乐名
     · 右上角 ＋ 可以发表自己的视频（从相册选，传到服务器）
   视频列表在服务器的 data/feed.json（后台可改），用户发的会追加进去。
   ============================================================ */

struct FeedAuthor: Decodable, Hashable {
    var id: String?
    var name: String?
    var avatar: String?
}

struct FeedItem: Decodable, Identifiable, Hashable {
    var id: String
    var video: String?
    /// 分片地址（服务器切好的 HLS）：有就用它 —— 拿到第一段就出画面，后面边看边下
    var hls: String?
    var cover: String?

    /// 播放地址：优先 HLS（先播放后加载），没有就退回整包 MP4
    var playPath: String {
        if let h = hls, !h.isEmpty { return h }
        return video ?? ""
    }
    var desc: String?
    var music: String?
    var tag: String?
    /* 短剧：集数标签（第3集）/ 总集数 / 剧集 id / 剧名 */
    var ep: String?
    var epTotal: Int?
    var series: String?
    var seriesName: String?
    var favorited: Bool?
    var favorites: Int?
    var author: FeedAuthor?
    var likes: Int?
    var liked: Bool?
    /// 我有没有关注这个作者（视频号的关注是单独的，和好友关系无关）
    var followed: Bool?
    var comments: Int?
    var shares: Int?
    var mine: Bool?
}

struct ChannelsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var items: [FeedItem] = []
    /// 全屏「抖音版」播放页（一屏一条、上下滑切换）
    @State private var showBigPlayer = false
    @State private var index = 0
    /// 视频号顶部 tab：0=关注 1=朋友 2=推荐（默认推荐）
    @State private var tab = 2
    @State private var drag: CGFloat = 0
    @State private var loading = true
    @State private var commentFor: FeedItem?
    /// 转发面板 / 转发给朋友
    @State private var shareItem: FeedItem?
    @State private var forwardItem: FeedItem?
    @State private var commentText = ""
    @State private var comments: [FeedCommentItem] = []      // 评论列表
    @State private var pickOpen = false
    @State private var picked: PhotosPickerItem?
    @State private var uploading = false
    /// 上传进度（0…1）和当前阶段文案：压缩中 / 上传中（抖音也是这么给的）
    @State private var uploadProgress: Double = 0
    @State private var uploadStage = ""
    /// 发布页左边那张封面（本地抽第一帧，发布时立刻有画面）
    @State private var pendingCover: UIImage?
    @State private var showPublish = false
    @State private var publishDesc = ""
    @State private var publishMusic = ""
    @State private var pendingVideoPath = ""
    @State private var uploadMB: Double = 0
    @State private var trim = 0          // 0=不处理 1=剪底部10% 2=剪底部14% 3=剪右侧12% 4=剪右下角
    @State private var style = FeedStyle()
    @State private var flags = FeedFlags()
    @State private var loadingMore = false          // 正在拉下一批（无限刷）
    @State private var episodeFor: FeedItem?         // 短剧「选集」面板
    @State private var seriesEpisodes: [FeedItem] = []
    /// 精彩视频里的「B站热门」（点开用新闻那套卡片，看原视频去 B 站）
    @State private var showBili = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                if loading && items.isEmpty {
                    ProgressView().tint(.white)
                } else if items.isEmpty {
                    Text("视频号还没有内容\n去后台 data/feed.json 加，或者点右上角 ＋ 发一条")
                        .font(pf(14)).foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                } else {
                    /* 三条一组：上一条、当前、下一条，跟着手指上下移动 */
                    ForEach(visible, id: \.item.id) { row in
                        FeedCell(item: row.item,
                                 active: row.offset == 0,
                                 style: style,
                                 flags: flags,
                                 onLike: { toggleLike(row.item) },
                    onComment: { commentFor = row.item; commentText = ""; comments = [] },
                                 onShare: { share(row.item) },
                                 onFollow: { follow(row.item) },
                                 onDelete: { remove(row.item) },
                                 onPickEpisode: { episodeFor = row.item; seriesEpisodes = [] },
                                 onFavorite: { toggleFavorite(row.item) })
                            .frame(width: geo.size.width, height: geo.size.height)
                            .offset(y: CGFloat(row.offset) * geo.size.height + drag)
                    }
                }
                topBar
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { v in
                        guard !items.isEmpty else { return }
                        drag = v.translation.height
                    }
                    .onEnded { v in
                        guard !items.isEmpty else { return }
                        let h = geo.size.height
                        let far = abs(v.translation.height) > h * 0.22
                        let fast = abs(v.predictedEndTranslation.height) > h * 0.45
                        if (far || fast), v.translation.height < 0, index < items.count - 1 {
                            withAnimation(.easeOut(duration: 0.22)) { drag = -h }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { index += 1; drag = 0 }
                        } else if (far || fast), v.translation.height > 0, index > 0 {
                            withAnimation(.easeOut(duration: 0.22)) { drag = h }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { index -= 1; drag = 0 }
                        } else if (far || fast), v.translation.height < 0, index >= items.count - 1 {
                            /* 已经滑到当前这批的最后一条，还往上滑 —— 去拿下一批（无限刷） */
                            withAnimation(.easeOut(duration: 0.22)) { drag = -h }
                            Task {
                                await loadMore()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    if index < items.count - 1 { index += 1 }
                                    drag = 0
                                }
                            }
                        } else {
                            withAnimation(.easeOut(duration: 0.22)) { drag = 0 }
                        }
                    }
            )
        }
        .toolbar(.hidden, for: .navigationBar)
        .hidesTabBar()
        .swipeBack { dismiss() }
        /* 精彩视频 → B站热门：全屏打开我们那套新闻排版（只显示这一栏） */
        .fullScreenCover(isPresented: $showBili) {
            NavigationStack {
                VStack(spacing: 0) {
                    ZStack {
                        Text(Tr("B站热门")).font(pf(17, .semibold)).foregroundColor(C.label)
                        HStack(spacing: 0) {
                            Button { showBili = false } label: {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 19, weight: .medium))
                                    .foregroundColor(C.label)
                                    .frame(width: 44, height: L.navH)
                            }
                            .buttonStyle(.plain)
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(height: L.navH)
                    .background(C.navBg)
                    .overlay(alignment: .bottom) { HairLine() }
                    NewsFeedView(compact: false,
                                 initialSource: "bili",
                                 onlyTabs: [NewsChannel(id: "bili", label: "B站热门", desc: "哔哩哔哩热门榜")])
                }
                .background(C.cardBg.ignoresSafeArea())
            }
        }
        /* 全屏「抖音版」播放页：一屏一条、上下滑切换、滑到哪条自动播 */
        .fullScreenCover(isPresented: $showBigPlayer) {
            FeedPlayerView(items: items, start: 0).environmentObject(app)
        }
        .sheet(item: $commentFor) { item in
            commentSheet(item)
        }
        /* 抖音那种转发面板 */
        .sheet(item: $shareItem) { item in
            VideoShareSheet(
                item: item,
                onForward: { forwardItem = item },
                onToMoments: {
                    UIPasteboard.general.string = item.video ?? ""
                    app.show(Tr("链接已复制，去「发现 → 朋友圈」粘贴就能发"))
                },
                onFavorite: {
                    Task {
                        if let r = try? await API.shared.feedFavorite(item.id) {
                            app.show((r.favorited ? Tr("已收藏") : Tr("已取消收藏")))
                            await load()
                        }
                    }
                },
                onSaveLocal: {
                    UIPasteboard.general.string = item.video ?? ""
                    app.show(Tr("视频链接已复制；保存到相册会占内存，先在聊天里发给自己也能存"))
                },
                onHide: {
                    app.show(Tr("已经减少这类视频的推荐"))
                }
            )
            .environmentObject(app)
        }
        .sheet(item: $forwardItem) { item in
            VideoForwardPicker(link: item.video ?? "")
                .environmentObject(app)
        }
        .sheet(item: $episodeFor) { item in
            episodeSheet(item)
        }
        .sheet(isPresented: $showPublish) {
            publishSheet
        }
        .photosPicker(isPresented: $pickOpen, selection: $picked, matching: .videos)
        .onChange(of: picked) { v in Task { await uploadPicked(v) } }
        .overlay(alignment: .center) {
            if uploading {
                ZStack {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    VStack(spacing: 10) {
                        ZStack {
                            Circle().stroke(Color.white.opacity(0.25), lineWidth: 4)
                                .frame(width: 54, height: 54)
                            Circle()
                                .trim(from: 0, to: max(0.03, min(1, uploadProgress)))
                                .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .frame(width: 54, height: 54)
                            Text(uploadProgress > 0.01 ? "\(Int(min(1, uploadProgress) * 100))%" : "…")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        Text(uploadStage.isEmpty ? Tr("正在处理视频…") : uploadStage)
                            .font(pf(13))
                            .foregroundColor(.white)
                    }
                    .padding(18)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.72)))
                }
            }
        }
        .task { await load() }
        /* 快滑到最后几条就提前把下一批拉回来，滑到底也不会卡住 */
        .onChange(of: index) { i in
            if i >= items.count - 2 { Task { await loadMore() } }
        }
        /* 进视频号就把音频通道设成「播放」：这样手机的静音键拨下去也有声音
           （抖音就是这个行为），离开时再交还，别影响别人听歌。 */
        .onAppear {
            let s = AVAudioSession.sharedInstance()
            try? s.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try? s.setActive(true)
        }
        .onDisappear {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /* ---------------------------------------------------------- 顶部 */

    private var topBar: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 44, height: L.navH)
                }
                .buttonStyle(.plain)

                /* 全屏播放（抖音那种一屏一条）：点这里进去，上下滑切换 */
                Button { showBigPlayer = true } label: {
                    Image(systemName: "rectangle.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 40, height: L.navH)
                }
                .buttonStyle(.plain)

                /* 精彩视频里直接能看 B 站热门（我们自己不放它的视频，点开去 B 站看） */
                Button { showBili = true } label: {
                    Text(Tr("B站热门"))
                        .font(pf(14, .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Capsule().fill(Color.white.opacity(0.16)))
                        .frame(height: L.navH)
                }
                .buttonStyle(.plain)

                /* 顶部三个 tab（和微信视频号一致）：关注 / 朋友 / 推荐
                   推荐 = 抖音那套（热度+新鲜度，每次刷新顺序会变） */
                HStack(spacing: 22) {
                    /* 三个 tab 的文字后台能改：ui.json 里写 feedTab0 / feedTab1 / feedTab2 */
                    ForEach(Array([UIConfig.text("feedTab0", "关注"),
                                   UIConfig.text("feedTab1", "朋友"),
                                   UIConfig.text("feedTab2", "推荐")].enumerated()), id: \.offset) { i, name in
                        Button {
                            guard tab != i else { return }
                            tab = i
                            index = 0
                            items = []
                            loading = true
                            Task { await load() }
                        } label: {
                            VStack(spacing: 5) {
                                Text(Tr(name))
                                    .font(pf(tab == i ? 17.5 : 16.5, tab == i ? .semibold : .regular))
                                    .foregroundColor(tab == i ? .white : Color.white.opacity(0.62))
                                Capsule()
                                    .fill(tab == i ? Color.white : Color.clear)
                                    .frame(width: 18, height: 2.5)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)

                Spacer()
                /* 后台把关了「允许前台发视频」就不显示这个 ＋ */
                if flags.allowPublish != false {
                    Button { pickOpen = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: L.navH)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            Spacer()
        }
    }

    private struct Row { let item: FeedItem; let offset: Int }
    private var visible: [Row] {
        var out: [Row] = []
        for o in -1...1 {
            let i = index + o
            if i >= 0 && i < items.count { out.append(Row(item: items[i], offset: o)) }
        }
        return out
    }

    /* ---------------------------------------------------------- 数据 */

    private func load() async {
        if let r = try? await API.shared.feed(tab: ["follow", "friends", "recommend"][tab]) {
            items = r.items
            style = r.style
            flags = r.flags
        }
        loading = false
    }

    /* 无限刷：滑到快到底部时，再拉一批接在后面。
       服务端每次会给「下一批」（它自己记着播放进度），所以这里只管往后接。
       如果服务端这一轮给回来的都是已经有的（说明一轮刷完了、它重新排了一轮），
       也照样接上 —— 宁可重复，也不能滑到底。 */
    private func loadMore() async {
        if loadingMore { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let r = try? await API.shared.feed(tab: ["follow", "friends", "recommend"][tab]) else { return }
        style = r.style
        flags = r.flags
        let known = Set(items.map { $0.id })
        let add = r.items.filter { !known.contains($0.id) }
        if add.isEmpty {
            items.append(contentsOf: r.items)
        } else {
            items.append(contentsOf: add)
        }
    }

    /* 收藏 / 取消收藏 */
    private func toggleFavorite(_ item: FeedItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        Task {
            if let r = try? await API.shared.feedFavorite(item.id) {
                items[i].favorited = r.favorited
                items[i].favorites = r.favorites
            }
        }
    }

    private func toggleLike(_ item: FeedItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        Task {
            if let r = try? await API.shared.feedLike(item.id) {
                items[i].liked = r.liked
                items[i].likes = r.likes
            }
        }
    }

    /* 转发：打开抖音那种转发面板（转发给朋友 / 朋友圈 / 收藏 / 复制链接 / 保存本地 / 举报 / 不感兴趣） */
    private func share(_ item: FeedItem) {
        shareItem = item
    }

    private func follow(_ item: FeedItem) {
        guard let uid = item.author?.id, !uid.isEmpty else { return }
        Task {
            /* 以前这里是拿用户 id 当用户名去发好友申请 → 服务器查不到 → 永远失败。
               现在走真的关注接口（和好友关系分开，微信视频号也是这个逻辑）。 */
            let now = !(item.followed == true)
            let ok = await API.shared.feedFollow(userId: uid, follow: now)
            if ok {
                app.show(now ? Tr("已关注") : Tr("已取消关注"))
                await load()
            } else {
                app.show(Tr("关注失败，稍后再试"))
            }
        }
    }

    private func remove(_ item: FeedItem) {
        Task {
            await API.shared.feedDelete(item.id)
            await load()
            if index >= items.count { index = max(0, items.count - 1) }
        }
    }

    private func sendComment(_ item: FeedItem) {
        let text = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        commentText = ""
        Task {
            if let n = try? await API.shared.feedComment(item.id, text: text),
               let i = items.firstIndex(where: { $0.id == item.id }) {
                items[i].comments = n
            }
            await loadComments(item)          // 发完立刻能在列表里看到
            app.show(Tr("评论成功"))
        }
    }

    /// 拉某条视频的评论列表
    private func loadComments(_ item: FeedItem) async {
        comments = (try? await API.shared.feedComments(item.id)) ?? []
    }

    /* 短剧「选集」：列出这套剧的全部集数，点哪集跳哪集 */
    private func episodeSheet(_ item: FeedItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.seriesName?.isEmpty == false ? (item.seriesName ?? "") : Tr("选集"))
                .font(pf(16, .semibold))
                .padding(.top, 16)
                .padding(.horizontal, 18)
            Text(Tr("共\(item.epTotal ?? seriesEpisodes.count)集"))
                .font(pf(12.5))
                .foregroundColor(.secondary)
                .padding(.horizontal, 18)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(seriesEpisodes) { ep in
                        Button {
                            jumpToEpisode(ep)
                            episodeFor = nil
                        } label: {
                            HStack(spacing: 10) {
                                Text(ep.ep ?? "")
                                    .font(pf(15, .medium))
                                    .foregroundColor(ep.id == item.id ? C.green : .primary)
                                Text(String((ep.desc ?? "").prefix(18)))
                                    .font(pf(13))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                if ep.id == item.id {
                                    Text(Tr("正在播放")).font(pf(12)).foregroundColor(C.green)
                                }
                            }
                            .padding(.vertical, 11)
                            .padding(.horizontal, 14)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }
                    if seriesEpisodes.isEmpty {
                        ProgressView().padding(.top, 20)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            guard let sid = item.series, !sid.isEmpty else { return }
            if let r = try? await API.shared.feedSeries(sid) { seriesEpisodes = r.items }
        }
    }

    /* 跳到某一集：已经在列表里就直接跳，否则插到当前这条后面再跳 */
    private func jumpToEpisode(_ ep: FeedItem) {
        if let i = items.firstIndex(where: { $0.id == ep.id }) {
            index = i
        } else {
            let at = min(items.count, index + 1)
            items.insert(ep, at: at)
            index = at
        }
    }

    private func commentSheet(_ item: FeedItem) -> some View {
        VStack(spacing: 14) {
            Text(Tr("评论")).font(pf(16, .medium)).padding(.top, 16)
            Text(item.desc ?? "").font(pf(13)).foregroundColor(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 20)
            /* 评论列表（以前只显示视频文案，看不到别人说了什么） */
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if comments.isEmpty {
                        Text(Tr("还没有评论，来说第一句")).font(pf(13)).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                    }
                    ForEach(comments) { c in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(c.name ?? Tr("用户")).font(pf(13, .medium))
                            Text(c.text ?? "").font(pf(14))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 20)
            }
            .frame(maxHeight: 220)
            TextField("说点什么…", text: $commentText)
                .textFieldStyle(.roundedBorder).padding(.horizontal, 20)
            Button { sendComment(item) } label: {
                Text(Tr("发送")).font(pf(16, .medium)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 23).fill(C.green))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            Spacer()
        }
        .presentationDetents([.height(430)])
        .task { await loadComments(item) }
    }

    /* ---------------------------------------------------------- 发表 */

    /* 发表页（照着抖音那版做的）：
       顶栏「取消 · 发布视频 · 发布胶囊」+ 左边封面缩略图 + 右边多行文案 +
       下面一张设置卡（音乐 / 剪水印 / 清晰度说明）+ 底部大按钮。
       目标是"高级"：留白大、圆角统一、分隔线细、主按钮只有一个视觉重点。 */
    private var publishSheet: some View {
        VStack(spacing: 0) {
            /* ---------- 顶栏 ---------- */
            HStack {
                Button { showPublish = false } label: {
                    Text(Tr("取消"))
                        .font(pf(16))
                        .foregroundColor(C.label)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)

                Spacer()

                Text(Tr("发布视频"))
                    .font(pf(16.5, .semibold))
                    .foregroundColor(C.label)

                Spacer()

                Button { publish() } label: {
                    Text(Tr("发布"))
                        .font(pf(15, .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 34)
                        .background(Capsule().fill(pendingVideoPath.isEmpty ? C.subLabel : C.green))
                }
                .buttonStyle(.plain)
                .disabled(pendingVideoPath.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)

            HairLine(inset: 0)
                .padding(.top, 6)

            ScrollView {
                VStack(spacing: 14) {
                    /* ---------- 封面 + 文案 ---------- */
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            if let c = pendingCover {
                                Image(uiImage: c).resizable().scaledToFill()
                            } else {
                                C.searchBg
                                Image(systemName: "video.fill")
                                    .font(.system(size: 20))
                                    .foregroundColor(C.subLabel)
                            }
                            VStack { Spacer()
                                HStack { Spacer()
                                    if uploadMB > 0 {
                                        Text(String(format: "%.1f MB", uploadMB))
                                            .font(.system(size: 10.5, weight: .medium))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Capsule().fill(Color.black.opacity(0.5)))
                                    }
                                }
                            }
                            .padding(6)
                        }
                        .frame(width: 92, height: 122)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                        ZStack(alignment: .topLeading) {
                            if publishDesc.isEmpty {
                                Text(Tr("添加作品描述…"))
                                    .font(pf(15.5))
                                    .foregroundColor(C.subLabel)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                            }
                            TextEditor(text: $publishDesc)
                                .font(pf(15.5))
                                .foregroundColor(C.label)
                                .scrollContentBackground(.hidden)
                                .background(Color.clear)
                        }
                        .frame(height: 122)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)

                    /* ---------- 设置卡 ---------- */
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Image(systemName: "music.note")
                                .font(.system(size: 15))
                                .foregroundColor(C.label)
                                .frame(width: 22)
                            Text(Tr("音乐")).font(pf(15.5)).foregroundColor(C.label)
                            TextField(Tr("选填，例如：原声"), text: $publishMusic)
                                .font(pf(15))
                                .multilineTextAlignment(.trailing)
                                .foregroundColor(C.subLabel)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 52)

                        if flags.allowTrim != false {
                            HairLine(inset: 16)
                            VStack(spacing: 10) {
                                HStack(spacing: 12) {
                                    Image(systemName: "wand.and.stars")
                                        .font(.system(size: 15))
                                        .foregroundColor(C.label)
                                        .frame(width: 22)
                                    Text(Tr("剪掉水印")).font(pf(15.5)).foregroundColor(C.label)
                                    Spacer()
                                    Text(trimTitle)
                                        .font(pf(14.5))
                                        .foregroundColor(C.subLabel)
                                }
                                Picker("剪掉水印", selection: $trim) {
                                    Text(Tr("不处理")).tag(0)
                                    Text(Tr("底部 10%")).tag(1)
                                    Text(Tr("底部 14%")).tag(2)
                                    Text(Tr("右侧 12%")).tag(3)
                                    Text(Tr("右下角")).tag(4)
                                }
                                .pickerStyle(.segmented)
                                Text(Tr("剪完会把画面放大回原尺寸，只是把带水印的那一条切掉。"))
                                    .font(pf(11.5))
                                    .foregroundColor(C.subLabel)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }

                        HairLine(inset: 16)
                        HStack(spacing: 12) {
                            Image(systemName: "bolt.hd.fill")
                                .font(.system(size: 15))
                                .foregroundColor(C.label)
                                .frame(width: 22)
                            Text(Tr("清晰度")).font(pf(15.5)).foregroundColor(C.label)
                            Spacer()
                            Text(Tr("自动转 720p · 秒开")).font(pf(14.5)).foregroundColor(C.subLabel)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 52)
                    }
                    .background(C.cardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 16)

                    Text(Tr("发布后会先在后台转码，视频马上就能看，不用等。"))
                        .font(pf(12))
                        .foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 2)
                }
                .padding(.bottom, 20)
            }

            /* ---------- 底部主按钮 ---------- */
            Button { publish() } label: {
                Text(Tr("发布"))
                    .font(pf(16.5, .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: 25, style: .continuous)
                        .fill(pendingVideoPath.isEmpty ? C.subLabel : C.green))
            }
            .buttonStyle(.plain)
            .disabled(pendingVideoPath.isEmpty)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .background(.ultraThinMaterial)
        }
        .background(C.pageBg)
        .presentationDetents([.height(560), .large])
    }

    /// 设置卡右上角那句「剪掉水印」当前选了什么
    private var trimTitle: String {
        switch trim {
        case 1: return Tr("底部 10%")
        case 2: return Tr("底部 14%")
        case 3: return Tr("右侧 12%")
        case 4: return Tr("右下角")
        default: return Tr("不处理")
        }
    }

    private func uploadPicked(_ v: PhotosPickerItem?) async {
        guard let v = v else { return }
        uploading = true
        uploadProgress = 0
        uploadStage = Tr("准备中…")
        defer { uploading = false; uploadStage = "" }
        do {
            guard let data = try await v.loadTransferable(type: Data.self), !data.isEmpty else {
                app.show(Tr("读不到这个视频")); return
            }
            /* 提速策略（和抖音一个思路：先压再传，别把 4K 原片硬塞上去）：
               ① ≤6MB：原样传（已经很小，重编码反而慢）
               ② 6～18MB：压到 1080p
               ③ >18MB：压到 720p（体积砍得最狠，上传快一大截） */
            let raw = FileManager.default.temporaryDirectory.appendingPathComponent("feed-raw-\(UUID().uuidString).mov")
            try data.write(to: raw)
            /* 封面：本地先抽一帧，发布页立刻有画面（服务器那边也会再抽一张正式的） */
            if pendingCover == nil, let img = await MediaTool.firstFrame(raw) {
                pendingCover = img
            }
            let uploadData: Data
            let mb = Double(data.count) / 1024 / 1024
            if mb <= 6 {
                uploadData = data
            } else {
                uploadStage = Tr("压缩中…")
                let preset: String = mb > 18 ? "720p" : "1080p"
                let small = await Self.compress(raw, preset: preset)
                if let small = small, !small.isEmpty, small.count < data.count {
                    uploadData = small
                } else {
                    uploadData = data
                }
            }
            try? FileManager.default.removeItem(at: raw)
            /* 走文件流上传 + 真实进度（以前是把整段 data 塞进 httpBody，没进度、还吃内存） */
            uploadStage = Tr("上传中…")
            let upFile = FileManager.default.temporaryDirectory.appendingPathComponent("feed-up-\(UUID().uuidString).mp4")
            try uploadData.write(to: upFile)
            uploadProgress = 0
            let url = try await API.shared.uploadBinaryFile(upFile, mime: "video/mp4", skipTranscode: true) { p in
                DispatchQueue.main.async { uploadProgress = p }
            }
            try? FileManager.default.removeItem(at: upFile)
            pendingVideoPath = url
            uploadMB = Double(uploadData.count) / 1024 / 1024
            showPublish = true
        } catch {
            app.show((error as? APIError)?.errorDescription ?? "上传失败（视频别超过 20MB）")
        }
    }

    /// 把视频压成 1080p / 720p（H.264），返回压缩后的数据；失败返回 nil
    nonisolated static func compress(_ url: URL, preset: String = "1080p") async -> Data? {
        let asset = AVURLAsset(url: url)
        /* 1080p 起步；大文件（>18MB）降到 720p，体积砍得更狠、传得更快 */
        let exportName = (preset == "720p") ? AVAssetExportPreset1280x720 : AVAssetExportPreset1920x1080
        guard let export = AVAssetExportSession(asset: asset, presetName: exportName) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("feed-out-\(UUID().uuidString).mp4")
        export.outputURL = out
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { c.resume() }
        }
        guard export.status == .completed else { return nil }
        let d = try? Data(contentsOf: out)
        try? FileManager.default.removeItem(at: out)
        return d
    }

    private func publish() {
        let desc = publishDesc.trimmingCharacters(in: .whitespacesAndNewlines)
        let music = publishMusic.trimmingCharacters(in: .whitespacesAndNewlines)
        publishDesc = ""
        publishMusic = ""
        pendingCover = nil            // 下一轮发布重新抽封面，别残留上一条的
        let crop = trim
        showPublish = false
        Task {
            do {
                var video = pendingVideoPath
                if crop > 0 {
                    let area: (top: Double, bottom: Double, left: Double, right: Double)
                    switch crop {
                    case 1: area = (0, 0.10, 0, 0)
                    case 2: area = (0, 0.14, 0, 0)
                    case 3: area = (0, 0, 0, 0.12)
                    default: area = (0, 0.12, 0, 0.10)
                    }
                    if let trimmed = try? await API.shared.feedTrim(video, top: area.top, bottom: area.bottom,
                                                                     left: area.left, right: area.right) {
                        video = trimmed
                    } else {
                        app.show(Tr("剪水印失败，就用原视频发了"))
                    }
                }
                _ = try await API.shared.feedPublish(video: video, desc: desc, music: music)
                app.show(Tr("发表成功"))
                index = 0
                await load()
            } catch {
                app.show((error as? APIError)?.errorDescription ?? "发表失败")
            }
        }
        trim = 0
    }
}

/* ---------------------------------------------------------- 单条视频 */

struct FeedCell: View {
    let item: FeedItem
    let active: Bool
    var style = FeedStyle()
    var flags = FeedFlags()
    var onLike: () -> Void
    var onComment: () -> Void
    var onShare: () -> Void
    var onFollow: () -> Void
    var onDelete: () -> Void
    var onPickEpisode: () -> Void = {}     // 短剧：点「选集」
    var onFavorite: () -> Void = {}        // 收藏

    @State private var player: AVPlayer?
    @State private var loadingVideo = true
    @State private var liked = false
    @State private var likes = 0
    @State private var favorited = false
    @State private var favorites = 0
    @State private var bounced = false
    @State private var progress: Double = 0        // 播放进度 0~1（抖音式底部进度条）
    @State private var durationSec: Double = 0
    @State private var timeObserver: Any?

    var body: some View {
        ZStack {
            Color.black
            if !(item.cover ?? "").isEmpty {
                RemoteImage(path: item.cover ?? "").opacity(player == nil ? 1 : 0.001)
            }
            if let p = player {
                PlayerSurface(player: p)
            }
            if loadingVideo {
                ProgressView().tint(.white)
            }
            LinearGradient(colors: [.black.opacity(0.35), .clear, .black.opacity(0.65)],
                           startPoint: .top, endPoint: .bottom)

            /* 抖音式底部细进度条：能看进度，按住还能拖 */
            VStack {
                Spacer()
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.22))
                        Rectangle().fill(Color.white)
                            .frame(width: max(0, min(1, progress)) * g.size.width)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        let r = max(0, min(1, v.location.x / max(1, g.size.width)))
                        progress = r
                        if durationSec > 0 {
                            player?.seek(to: CMTime(seconds: r * durationSec, preferredTimescale: 600),
                                         toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                    })
                }
                .frame(height: 3)
            }

            /* 短剧：左上角显示当前集数，旁边一个「选集」入口 */
            if !(item.ep ?? "").isEmpty {
                VStack {
                    HStack(spacing: 8) {
                        Text(item.ep ?? "")
                            .font(pf(13, .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.black.opacity(0.45)))
                        if (item.epTotal ?? 0) > 1 {
                            Button { onPickEpisode() } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "list.bullet").font(.system(size: 11, weight: .semibold))
                                    Text(Tr("选集")).font(pf(13, .semibold))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color.black.opacity(0.45)))
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
            }

            if flags.showRail != false {
                HStack(alignment: .bottom, spacing: 0) {
                    Spacer()
                    rightRail
                }
                .padding(.trailing, 12)
                .padding(.bottom, 110)
            }

            VStack(alignment: .leading, spacing: 8) {
                Spacer()
                Text("@\(item.author?.name ?? "用户")")
                    .font(pf(style.nameSize ?? 16, .semibold)).foregroundColor(.white)
                Text(item.desc ?? "")
                    .font(pf(style.descSize ?? 14)).foregroundColor(.white.opacity(0.95))
                    .lineLimit(3)
                HStack(spacing: 5) {
                    Image(systemName: "music.note").font(.system(size: 12))
                    Text(item.music?.isEmpty == false ? (item.music ?? "") : "原创声音")
                        .font(pf(style.musicSize ?? 12.5))
                }
                .foregroundColor(.white.opacity(0.9))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, max(style.padBottom ?? 28, L.safeBottom + 10))
        }
        /* 只有「当前这一条」才建播放器并下载：
           视频号一次显示上一条/当前/下一条三个格子，以前三条一起建 AVPlayer、
           一起下整条视频，同一条带宽被三份分掉，手机上就是「一直在加载」。
           现在滑到哪条才下哪条，滑走立刻停掉（抖音也是这么干的）。 */
        .onAppear { if active { setup() } }
        .onDisappear { teardown() }
        .onChange(of: active) { on in
            if on { setup(); player?.play() } else { teardown() }
        }
    }

    /// 滑走/离开：停掉播放和下载，把内存里的播放器放掉
    private func teardown() {
        if let obs = timeObserver, let p = player { p.removeTimeObserver(obs) }
        timeObserver = nil
        player?.pause()
        player = nil
        loadingVideo = true
        progress = 0
    }

    private var rightRail: some View {
        VStack(spacing: max(style.railGap ?? 22, 22)) {
            ZStack(alignment: .bottom) {
                Avatar(path: item.author?.avatar ?? "", size: style.avatar ?? 46,
                       radius: (style.avatar ?? 46) / 2, circle: true)
                    .overlay(Circle().stroke(Color.white.opacity(0.92), lineWidth: 1.6))
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                Button { onFollow() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundColor(.white)
                        .frame(width: 21, height: 21)
                        .background(Circle().fill(LinearGradient(colors: [Color(hex: 0xFF6B6B), Color(hex: 0xFA5151)],
                                                                 startPoint: .top, endPoint: .bottom)))
                        .overlay(Circle().stroke(Color.white, lineWidth: 1.2))
                        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                        .offset(y: 10)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 12)

            railAction(icon: "heart.fill", tint: liked ? Color(hex: 0xFF4D6D) : .white,
                       count: "\(likes)", active: liked, bounce: bounced) {
                liked.toggle()
                likes += liked ? 1 : -1
                bounced = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { bounced = false }
                onLike()
            }
            railAction(icon: "bubble.right.fill", tint: .white, count: "\(item.comments ?? 0)", action: onComment)
            /* 收藏（抖音那排的星标） */
            railAction(icon: "star.fill", tint: favorited ? Color(hex: 0xFFC542) : .white,
                       count: "\(favorites)", active: favorited) {
                favorited.toggle()
                favorites += favorited ? 1 : -1
                onFavorite()
            }
            railAction(icon: "arrowshape.turn.up.right.fill", tint: .white, count: "\(item.shares ?? 0)", action: onShare)
            if item.mine == true {
                railAction(icon: "trash.fill", tint: .white, count: Tr("删除"), action: onDelete)
            }
        }
    }

    /* 右侧按钮：毛玻璃圆底 + 图标 + 数字。
       比原来光秃秃的图标更精致：白色描边、柔和投影、激活时整体轻微放大。 */
    private func railAction(icon: String, tint: Color, count: String, active: Bool = false,
                            bounce: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 44, height: 44)
                        .overlay(Circle().fill(Color.black.opacity(active ? 0.26 : 0.14)))
                        .overlay(Circle().stroke(Color.white.opacity(active ? 0.36 : 0.18), lineWidth: 0.9))
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                    Image(systemName: icon)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundColor(tint)
                        .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                }
                .scaleEffect(bounce ? 1.18 : 1)
                if !count.isEmpty {
                    Text(count)
                        .font(pf(12.5, .semibold))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                }
            }
            .frame(width: 54)
        }
        .buttonStyle(.plain)
    }

    private func setup() {
        liked = item.liked ?? false
        likes = item.likes ?? 0
        favorited = item.favorited ?? false
        favorites = item.favorites ?? 0
        guard player == nil else { return }
        /* 播放地址：**优先整包 MP4**（和聊天里的视频一条路：先下到本地再播，最稳），
           没有整包的才用服务器切好的分片 */
        let hls = item.playPath
        let mp4 = item.video ?? ""
        let path = mp4.isEmpty ? hls : mp4
        guard let url = API.shared.assetURL(path) else { return }
        loadingVideo = true
        CrashCatcher.note("视频号", "开始加载 id=\(item.id) 源=\(path)")
        startPlayer(path: path, url: url, canFallback: !mp4.isEmpty && mp4 != hls, viaDownload: true)
    }

    /// 起播放器。**要「画面真的动起来」才算成功**；而且**边下边播**：
    /// 分片（m3u8）够一小段就出画面，不等整段；**3 秒还没画面**就换整包 MP4 再试
    /// （整包慢一点，给它 12 秒）。以前是死等 20+10 秒 —— 用户看到的就是一直转圈。
    private func startPlayer(path: String, url: URL, canFallback: Bool, viaDownload: Bool = false) {
        Task { @MainActor in
            /* 边下边播：走 App 自己的会话（认自签证书），取到一段喂一段；
               viaDownload = 兜底那一趟：整段先下到本地再播（最稳）。 */
            var playURL = url
            if viaDownload {
                guard let local = await StreamPlay.download(url) else {
                    /* 整段下不下来（极少数）：退回服务器切好的分片再试一次 */
                    if canFallback, let h = item.hls, !h.isEmpty,
                       let u2 = API.shared.assetURL(h), u2 != url {
                        CrashCatcher.note("视频号", "整段下载失败，改用分片 id=\(item.id)")
                        startPlayer(path: h, url: u2, canFallback: false, viaDownload: false)
                    } else {
                        loadingVideo = false
                    }
                    return
                }
                playURL = local
            }
            let p = viaDownload ? AVPlayer(url: playURL) : (StreamPlay.player(playURL) ?? AVPlayer(url: playURL))
            p.isMuted = false
            p.actionAtItemEnd = .none
            /* 先缓冲再播：以前设成 false（几乎不缓冲就开播），网速一般时视频会一顿一顿。
               缓存压到 1.5 秒 + 让系统自己判断：先出画面，后面的边看边下。 */
            /* 抖音那套：**有数据就播**（不攒够一大段才开播），后面边播边下。
               以前是 true + 1.5 秒缓冲：弱网下播放器会一直等"安全缓冲"，
               用户看到的就是一直转圈（实测第二条 40 秒都没出画面）。 */
            p.automaticallyWaitsToMinimizeStalling = false
            p.currentItem?.preferredForwardBufferDuration = 2
            /* 每 0.1 秒回一次播放位置，驱动底部进度条 */
            if let old = timeObserver, let oldP = player { oldP.removeTimeObserver(old) }
            timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { t in
                let d = p.currentItem?.duration.seconds ?? 0
                if d.isFinite, d > 0 {
                    durationSec = d
                    progress = min(1, max(0, t.seconds / d))
                }
            }
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                   object: p.currentItem, queue: .main) { _ in
                p.seek(to: .zero)
                p.play()
            }
            if let old = player, old !== p {
                old.pause()
                StreamPlay.cancel(old.currentItem)     // 旧的那条不播了：把它没下完的请求掐掉
            }
            player = p
            if active { p.play() }
            /* 画面真的动起来才算成功：**分片只等 3 秒**（够一小段就该出画面了），
               有整包 MP4 兜底时超时就直接换它；整包本身慢一点，给它 12 秒。 */
            let ticks = canFallback ? 15 : 60          // × 0.2 秒 = 3 秒 / 12 秒
            var moved = false
            for _ in 0..<ticks {
                if let it = p.currentItem {
                    if it.status == .failed { break }
                    if it.status == .readyToPlay, CMTimeGetSeconds(p.currentTime()) > 0.05 {
                        moved = true
                        break
                    }
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
                if player !== p || !active { return }
            }
            if player !== p { return }
            if moved {
                loadingVideo = false
                CrashCatcher.note("视频号", "出画面 id=\(item.id) 源=\(path)")
                return
            }
            let why = p.currentItem?.error?.localizedDescription ?? "没等到画面"
            CrashCatcher.note("视频号", "加载失败 id=\(item.id) 源=\(path) 原因=\(why)")
            p.pause()
            player = nil
            if canFallback, let fb = item.video, !fb.isEmpty, let u2 = API.shared.assetURL(fb) {
                CrashCatcher.note("视频号", "改用整包 MP4（先下后播）id=\(item.id) 源=\(fb)")
                loadingVideo = true
                startPlayer(path: fb, url: u2, canFallback: false, viaDownload: true)
            } else {
                loadingVideo = false
            }
        }
    }
}

/// AVPlayer 的显示层（通话页那个 VideoSurface 是给 WebRTC 用的，这里是本地播放器）
/// 「作品」页点开一个方块后播这条视频（和视频号一样：先下载到本地再播）
struct FeedPlayerSheet: View {
    let item: FeedItem
    var all: [FeedItem] = []

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var loading = true
    @State private var liked = false
    @State private var likes = 0
    @State private var index = 0

    private var list: [FeedItem] { all.isEmpty ? [item] : all }
    private var cur: FeedItem { list[min(index, list.count - 1)] }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let p = player { PlayerSurface(player: p) }
            if loading { ProgressView().tint(.white) }
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 8)
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("@\(cur.author?.name ?? "用户")")
                            .font(pf(15, .semibold)).foregroundColor(.white)
                        Text(cur.desc ?? "").font(pf(13.5)).foregroundColor(.white.opacity(0.95))
                            .lineLimit(3)
                        if !(cur.music ?? "").isEmpty {
                            Text("♪ \(cur.music ?? "")").font(pf(12)).foregroundColor(.white.opacity(0.8))
                        }
                    }
                    Spacer(minLength: 12)
                    Button {
                        liked.toggle(); likes += liked ? 1 : -1
                        Task { _ = try? await API.shared.feedLike(cur.id) }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 26))
                                .foregroundColor(liked ? Color(hex: 0xFF4D6D) : .white)
                            Text("\(likes)").font(pf(12.5)).foregroundColor(.white)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, max(20, L.safeBottom + 8))
            }
            /* 左右切换（作品页点开的那个列表） */
            if list.count > 1 {
                HStack {
                    Button { step(-1) } label: { chevron("chevron.left") }
                    Spacer()
                    Button { step(1) } label: { chevron("chevron.right") }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
            }
        }
        .onAppear {
            index = list.firstIndex(where: { $0.id == item.id }) ?? 0
            liked = cur.liked ?? false
            likes = cur.likes ?? 0
            load(cur)
        }
        /* 从作品页/视频号点开的大图播放器：关掉这一页也要停声音 */
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private func chevron(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 22, weight: .semibold))
            .foregroundColor(.white.opacity(0.75))
            .frame(width: 44, height: 60)
    }

    private func step(_ d: Int) {
        let n = index + d
        guard n >= 0, n < list.count else { return }
        index = n
        liked = cur.liked ?? false
        likes = cur.likes ?? 0
        player?.pause()
        player = nil
        load(cur)
    }

    private func load(_ w: FeedItem) {
        /* 有分片就走分片，先出画面再慢慢加载（边下边播）；分片 3 秒没画面就换整包 MP4 */
        let path = w.playPath
        guard let url = API.shared.assetURL(path) else { loading = false; return }
        loading = true
        let canFallback = !(w.video ?? "").isEmpty && (w.video ?? "") != path
        Task { @MainActor in
            func mount(_ playURL: URL, allowFallback: Bool, viaDownload: Bool = false) async {
                var realURL = playURL
                if viaDownload {
                    /* 兜底那一趟：整段下到本地再播（自签证书也不怕） */
                    guard let local = await StreamPlay.download(playURL) else { loading = false; return }
                    realURL = local
                }
                let p = viaDownload ? AVPlayer(url: realURL) : (StreamPlay.player(realURL) ?? AVPlayer(url: realURL))
                p.actionAtItemEnd = .none
                /* 有数据就播（不攒够一大段），弱网下才不会一直转圈 */
                p.automaticallyWaitsToMinimizeStalling = false
                p.currentItem?.preferredForwardBufferDuration = 1.5
                NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                       object: p.currentItem, queue: .main) { _ in
                    p.seek(to: .zero); p.play()
                }
                if let old = player, old !== p {
                    old.pause()
                    StreamPlay.cancel(old.currentItem)
                }
                player = p
                p.play()
                var moved = false
                for _ in 0..<(allowFallback ? 15 : 60) {      // × 0.2 秒 = 3 秒 / 12 秒
                    if let it = p.currentItem {
                        if it.status == .failed { break }
                        if it.status == .readyToPlay, CMTimeGetSeconds(p.currentTime()) > 0.05 {
                            moved = true
                            break
                        }
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    if player !== p { return }
                }
                if player !== p { return }
                if moved { loading = false; return }
                if allowFallback, let v = w.video, !v.isEmpty, let u2 = API.shared.assetURL(v) {
                    CrashCatcher.note("视频号", "分片 3 秒没画面，改用整包 MP4（先下后播）id=\(w.id)")
                    await mount(u2, allowFallback: false, viaDownload: true)
                } else {
                    loading = false
                }
            }
            await mount(url, allowFallback: canFallback)
        }
    }
}

struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView()
        v.backgroundColor = .black
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ v: PlayerView, context: Context) {
        v.playerLayer.player = player
    }

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
