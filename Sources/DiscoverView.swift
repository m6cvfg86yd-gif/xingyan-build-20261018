import SwiftUI
import UniformTypeIdentifiers
import CoreLocation

struct DiscoverView: View {
    /// 列表滚了多少：顶栏那层玻璃靠它淡入（和会话页同一个组件）
    @State private var navScrolled: CGFloat = 0
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @State private var path = NavigationPath()
    /// 后台配的发现页（加一行、改个名，重开 App 或切回本页就变）
    @State private var items: [DiscoverItem] = []
    @State private var loaded = false
    /// 扫一扫（发现页 → 扫一扫）
    @State private var showScan = false
    @ObservedObject private var realtime = Realtime.shared

    private var latestThumb: String {
        for m in app.moments {
            if let img = m.images?.first, !img.isEmpty { return img }
            if let c = m.videoCover, !c.isEmpty { return c }      // 视频动态用封面
        }
        return ""
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                /* 苹果那套：发现页标题（星联）也套一块玻璃胶囊 */
                NavBar(title: C.tabText2, floating: true)
                    .measure("discover.nav")
                    /* 和会话页同一套顶栏玻璃（视界互联这一页的底色是 discoverBg） */
                    /* 视界互联顶栏**常显**那条遮罩（微信就是这样） */
                    /* 用户要求发现页关闭顶部遮罩，避免任何系统材质高光。 */
                    .background(C.discoverBg.ignoresSafeArea(edges: .top))
                    .zIndex(1)      /* 顶栏压在列表上面：列表从它后面穿过去才"透" */
                ScrollView {
                    VStack(spacing: 0) {
                        TopScrollProbe(space: "discoverScroll")
                            .frame(height: 0)
                        /* 顶上给顶栏留位：第一条还是从顶栏下面开始 */
                        Color.clear.frame(height: L.navH)
                        // 行数、名字、图标、颜色、分组全部来自后台配置
                        ForEach(grouped.indices, id: \.self) { gi in
                            let cardInset = UIConfig.num("discoverCardInset", 12)
                            let cardRadius = UIConfig.num("discoverCardRadius", 12)
                            /* 视界页的卡片和底色都能单独调（后台 discoverCardBg / discoverBg），
                               默认和其它页一样；用户想让它比别处淡一点就改这两个键。 */
                            GroupCard(bg: C.discoverCardBg) {
                                ForEach(grouped[gi].indices, id: \.self) { ri in
                                    let item = grouped[gi][ri]
                                    if ri > 0 { rowLine }
                                    MenuRow(icon: (item.svg?.isEmpty == false) ? item.svg! : I.moments,
                                            iconColor: Color(hexString: item.color ?? "#4A90D9", fallback: 0x4A90D9),
                title: Tr(item.label),
                                            badge: item.action == "moments" && app.showDot("momentsRow", auto: !latestThumb.isEmpty),
                                            thumb: item.action == "moments" ? latestThumb : "",
                                            onTap: { open(item) },
                                            /* 行**不铺自己的底色**：直接透出这张卡的底色（discoverCardBg）。
                                               以前没传这个，行被铺成通用 cardBg（深色 #141419），
                                               比卡片（#191919）暗一档 —— 用户看到的"一条条的卡片颜色不对"
                                               就是这个。现在行色 = 卡片色 = 会话页那个底色。 */
                                            clearBg: true,
                                            /* 彩色圆角方块 + 白色图标（和鸿蒙端一套）
                                               注意：参数顺序必须跟 MenuRow 声明一致（onTap 在前面） */
                                            iconTile: true,
                                            /* 方块里用**苹果自带 SF Symbols**（不再用后台手画 SVG） */
                                            sf: RowIcon.sf(action: item.action, label: item.label))
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                                    .stroke(C.hairline, lineWidth: 0.6)
                            }
                            .padding(.horizontal, cardInset)
                            GroupGap(bg: C.discoverBg)
                        }

                        Spacer().frame(height: 20)
                    }
                    .topScrollTracking($navScrolled, space: "discoverScroll")
                }
                /* 列表整体上提一个顶栏的高度：内容从顶栏后面穿过去 */
                .padding(.top, -L.navH)
                .background(C.discoverBg)
            }
            .background(C.discoverBg.ignoresSafeArea(edges: .bottom))
            /* 顶部（状态栏那一条）跟页面同一个底色，深色下才不会顶出一条浅色带 */
            .background(C.discoverBg.ignoresSafeArea(edges: .top))
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { key in
                if key == "moments" {
                    MomentsView()
                } else if key == "nearby" {
                    NearbyPageView()
        } else if key == "shake" {
            /* 2026-10-13：服务端 discover.json 里那行已经改名「漂流瓶」（action=bottle），
               但 App 自己那份内置列表 / 老配置里可能还是 shake —— 这里**两个都进漂流瓶**，
               用户点「摇一摇」那个位置看到的就一定是漂流瓶（不会再落到老的摇一摇页，
               那一页没有内容，用户报的「漂流瓶里面没有内容」就是点到它了）。 */
            BottlePageView()
        } else if key == "bottle" {
            /* 2026-10-12 用户：「摇一摇改成漂流瓶」——服务端 discover.json 里 d05
               已经改名「漂流瓶」、action = bottle，点进来就是这一页（老的 shake 也走这儿） */
            BottlePageView()
                } else if key == "live" {
                    LiveListView()
                } else if key == "games" {
                    GamesPageView()
                } else if key == "channels" {
                    ChannelsView()
                } else if key == "look" {
                    LookView()
                } else if key == "search" {
                    SearchAllView()
                } else if key == "news" {
                    NewsView()
                } else if key == "music" {
                    /* 发现 → 听一听（曲库在后台「音乐（听一听）」里传） */
                    ListenView()
                } else if key == "miniapps" {
                    /* 发现 → 小程序（运行时：后台加小程序，App 不用出包） */
                    MiniAppsView()
                } else if key.hasPrefix("soon:") {
                    ComingSoonView(title: String(key.dropFirst(5)))
                } else {
                    ComingSoonView(title: key)
                }
            }
        }
        // 别人发了新朋友圈 → 发现页那个小图也跟着换
        .onChange(of: realtime.event) { ev in
            if ev.type == "moment" || ev.user != nil { Task { await app.loadMoments() } }
            if ev.type == "ui" { Task { await loadItems() } }
        }
        /* 设置里改了「朋友圈」开关（默认是开的）→ 本页立刻重算，
           不用等切后台或重开 App（见 MomentsPref.set） */
        .onReceive(NotificationCenter.default.publisher(for: .chrisUIPrefsChanged)) { _ in
            Task { await loadItems() }
        }
        .task {
            if !loaded { await loadItems() }
        }
        .fullScreenCover(isPresented: $showScan) {
            ScannerView { text in handleScanned(text, app: app) }
        }
    }

    /// 按 group 分组：同一组排在一张卡片里（和网页版一致）
    private var grouped: [[DiscoverItem]] {
        /* 朋友圈那一行受 设置 → 通用 → 朋友圈 控制（MomentsPref，默认开）。
           放在重绘里算：开关一改，返回发现页立刻对（不用重开 App）。 */
        let visible = MomentsPref.isOn ? items : items.filter { $0.action != "moments" }
        var out: [[DiscoverItem]] = []
        var last: Int? = nil
        for it in visible {
            let g = it.group ?? 1
            if last == nil || g != last! { out.append([]); last = g }
            out[out.count - 1].append(it)
        }
        return out
    }

    private func loadItems() async {
        if let list = try? await API.shared.discover(), !list.isEmpty {
            /* 这里存**原始**列表，不要在加载时就把朋友圈那行滤掉：
               开关是用户随时能改的，滤在加载时改完要重开 App 才生效。
               真正滤的地方在 grouped（每次重绘都按当前开关算一遍）。 */
            items = list
            loaded = true
        } else if items.isEmpty {
            // 拉不到就先用内置那套，别让页面空着
            items = DiscoverItem.builtin
        }
    }

    private func open(_ item: DiscoverItem) {
        switch item.action ?? "soon" {
        case "moments": path.append("moments")
        case "news": path.append("news")
        case "nearby": path.append("nearby")
        case "shake": path.append("shake")
        case "bottle": path.append("bottle")          // 漂流瓶（摇一摇改成漂流瓶）
        case "live": path.append("live")
        case "games": path.append("games")
    case "channels": path.append("channels")
    case "look": path.append("look")
    case "search": path.append("search")
    /* ⚠ 下面这两个以前漏了：后台 discover.json 里配了「听一听 / 小程序」，
       但这里没有对应的 case，点下去会走 default 跑到「敬请期待」页 ——
       用户反馈的「发现页那个听一听进不去」就是这个。 */
    case "music": path.append("music")
    case "miniapps": path.append("miniapps")
    case "scan": showScan = true
    default: path.append("soon:" + item.label)
        }
    }

    private var gap: some View {
        Rectangle().fill(C.pageBg).frame(height: L.groupGap)
    }

    private var rowLine: some View {
        HairLine(inset: L.menuLineInset)
    }
}

/* App 拉不到后台配置时用的兜底（和微信发现页一样的那几行） */
extension DiscoverItem {
    static var builtin: [DiscoverItem] {
        [
            DiscoverItem(id: "d01", label: "朋友圈", icon: "i.moments", svg: I.moments,
                         color: "#4A90D9", action: "moments", group: 1, enabled: true),
            DiscoverItem(id: "d02", label: "视频号", icon: "i.channels", svg: I.channels,
                         color: "#F2943B", action: "soon", group: 2, enabled: true),
            DiscoverItem(id: "d03", label: "直播", icon: "i.live", svg: I.live,
                         color: "#F4525B", action: "soon", group: 2, enabled: true),
            DiscoverItem(id: "d04", label: "扫一扫", icon: "i.scan", svg: I.scan,
                         color: "#3D83E7", action: "soon", group: 3, enabled: true),
            /* 2026-10-12 用户：「摇一摇改成漂流瓶」（服务端 discover.json 同步改过） */
            DiscoverItem(id: "d05", label: "漂流瓶", icon: "i.shake", svg: I.shake,
                         color: "#2E7BD6", action: "bottle", group: 3, enabled: true),
            DiscoverItem(id: "d06", label: "看一看", icon: "i.look", svg: I.look,
                         color: "#7275E9", action: "look", group: 4, enabled: true),
            DiscoverItem(id: "d07", label: "搜一搜", icon: "i.searchRow", svg: I.searchRow,
                         color: "#59C47E", action: "search", group: 4, enabled: true),
            DiscoverItem(id: "d08", label: "附近", icon: "i.nearby", svg: I.nearby,
                         color: "#3D83E7", action: "soon", group: 5, enabled: true),
            DiscoverItem(id: "d10", label: "游戏", icon: "i.game", svg: I.game,
                         color: "#9A6AE8", action: "soon", group: 7, enabled: true)
        ]
    }

    /// 我页的兜底（和默认配置一致）
    static var builtinMe: [DiscoverItem] {
        [
            DiscoverItem(id: "m01", label: "服务", icon: "i.wallet", svg: I.wallet,
                         color: "#59C47E", action: "service", group: 1, enabled: true),
            DiscoverItem(id: "m02", label: "收藏", icon: "i.star", svg: I.star,
                         color: "#4489EA", action: "favorites", group: 2, enabled: true),
            /* 小店与卡包（2026-10-12 照微信加）。
               2026-10-12 用户要求「去掉卡包」——原来这里有一行单独叫「卡包」的，
               和后台 me-page.json 里的「小店与卡包」重复了；后台那行已经删掉，
               内置兜底这份也改成同一行（label / action 都跟后台对齐），
               免得断网走兜底时又冒出一个「卡包」。 */
            DiscoverItem(id: "m07", label: "小店与卡包", icon: "i.wallet", svg: I.wallet,
                         color: "#E08A22", action: "shop", group: 2, enabled: true),
            DiscoverItem(id: "m03", label: "朋友圈", icon: "i.album", svg: I.album,
                         color: "#7275E9", action: "moments", group: 2, enabled: true),
            DiscoverItem(id: "m04", label: "作品", icon: "i.works", svg: I.works,
                         color: "#3D83E7", action: "works", group: 2, enabled: true),
            DiscoverItem(id: "m05", label: "表情", icon: "i.sticker", svg: I.sticker,
                         color: "#F5C144", action: "stickers", group: 3, enabled: true),
            DiscoverItem(id: "m06", label: "设置", icon: "i.gear", svg: I.gear,
                         color: "#3D83E7", action: "settings", group: 4, enabled: true)
        ]
    }
}

struct ComingSoonView: View {
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text(title).font(pf(17)).foregroundColor(C.label)
            Text(Tr("这一页排在下一批")).font(pf(14)).foregroundColor(C.subLabel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.pageBg)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(pf(18, .medium))
                }
            }
            ToolbarItem(placement: .principal) {
                Text(title).font(pf(UIConfig.num("navTitle", 17))).foregroundColor(C.label)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .swipeBack { dismiss() }
        .hidesTabBar()
    }
}

/* ============================================================ 朋友圈 */

private struct OffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// 第二路测量（整个内容块的屏幕坐标），和 OffsetKey 互为备份
private struct OffsetKey2: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct MomentsView: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    var target: User? = nil
    /// 「我的朋友圈」（从「我」那一页进来的）：只显示我自己的动态，封面也是我的。
    /// 微信的逻辑就是这样：发现页进去是好友动态，我→朋友圈进去只看自己的。
    var mineOnly: Bool = false

    /// 这一页要拉谁的动态：mineOnly = 只看自己；target = 看某个好友；都没有 = 好友动态时间轴
    private var feedUserId: String? { mineOnly ? app.me?.id : target?.id }
    /// 能不能换封面（自己这一页才行）
    private var coverEditable: Bool { target == nil || mineOnly }

    /// 滚动量：两路测量各存一份（1pt 条的屏幕 y、整个内容块的屏幕 y），取滚得更多的那个
    @State private var topY: CGFloat = 0
    @State private var blockY: CGFloat = 0
    @State private var baseTop: CGFloat?
    @State private var baseBlock: CGFloat?
    /// 兜底：列表顶上那个哨兵被 LazyVStack 回收了（说明封面已经滚过去）
    @State private var sentinelGone = false
    @State private var moments: [Moment] = []
    /// 发表页点「取消」时：写了东西先问一句（微信那套「不保留这次编辑？」）
    @State private var confirmDiscard = false
    @State private var showPhoto = false
    @State private var showCamera = false
    /// 长按右上角相机 = 直接拍小视频（微信那套），录完进发表页
    @State private var showVideoShoot = false
    @State private var showCoverPhoto = false
    /* 换封面（微信：点封面 → 从相册选择/拍一张 → 拖动调整 → 完成） */
    @State private var coverMenu = false
    @State private var showCoverCamera = false
    @State private var coverDraft: UIImage?
    @State private var composerPick = false
    /* 朋友圈发视频（微信：一条动态要么九张图、要么一条视频） */
    @State private var composerVideoPick = false
    @State private var pickMediaMenu = false
    /// 发表页的「＋」：相册（照片能多选，视频一条）
    @State private var showMomentAlbum = false
    @State private var pickedVideo: URL?
    @State private var videoCover: UIImage?
    @State private var videoSeconds = 0
    @State private var videoWH: (w: Int, h: Int)?
    @State private var videoProgress = 0.0
    @State private var posting = false
    @State private var draft = ""
    @State private var picked: [UIImage] = []
    @State private var uploading = false
    @State private var commenting: Moment?
    @State private var commentText = ""
    /// 回复谁（点别人的评论时填上：userId + 名字）—— 微信的「回复 A：」
    @State private var replyToId = ""
    @State private var replyToName = ""
    @State private var actionMoment: Moment?
    /// 点开朋友圈的图片：paths = 这条动态的图片，index = 点的那张
    @State private var viewerPaths: [String] = []
    @State private var viewerIndex: Int?
    /// 朋友圈里点开的视频（全屏播放）
    @State private var momentVideo: URL?
    /// 点头像 → 名片
    @State private var cardUser: User?
    /// 朋友圈往下翻页：还有没有更多 / 正在加载 / 一共多少条
    @State private var hasMoreMoments = false
    /// 看别人的朋友圈时：这个人的可见范围（all / 3d / 6m）—— 底下一句「朋友仅展示最近三天」
    @State private var feedRange = "all"
    /* 发朋友圈：谁可以看 */
    @State private var visibility = "public"
    @State private var showVisibility = false
    @State private var showPick = false
    @State private var pickMode = "partial"
    @State private var visibleTo: Set<String> = []
    @State private var hiddenFrom: Set<String> = []
    /* 发朋友圈：所在位置 / 提醒谁看（微信发表页那两行） */
    @State private var draftLocation = ""
    @State private var remindIds: Set<String> = []
    @State private var showLocation = false
    /* 九宫格拖动排序：正在拖的那一格 */
    @State private var dragIndex: Int?
    /// 「别误触」的锁：发表完 / 关掉大图后的 0.6 秒里不响应「点图看大图」
    /// （iOS 上弹层收起时手指那一下会漏到下面列表上 —— 用户反馈的「莫名其妙点到一张」就是它）
    @State private var tapLockUntil = Date(timeIntervalSince1970: 0)
    @State private var loadingMore = false
    @State private var momentTotal = 0
    /// 下拉刷新：拉出来的距离 / 正在刷新 / 彩球自转角度
    @State private var pullY: CGFloat = 0
    @State private var pulling = false
    @State private var spin: Double = 0
    @State private var spinTask: Task<Void, Never>?
    /// 最后一次拖动的时间：用来兜底收球（手指松开的手势回调有时候不会被叫到）
    @State private var lastDragAt = Date(timeIntervalSince1970: 0)
    @ObservedObject private var realtime = Realtime.shared
    /// 微信那个「余下 x 条」：哪些好友那组已经被点开（key = 那一组第一条的 id）
    @State private var expandedGroups: Set<String> = []
    /// 点「余下 x 条」进的那一页（用户要求：单独一整页看那一串）
    @State private var groupPage: MomentGroup?
    @State private var showGroupPage = false
    /// 朋友圈「消息列表」（右上角那个小信封）：有没有人在等我点开
    @State private var showNoticeList = false
    @Environment(\.colorScheme) private var momentsScheme

    /// 和网页版一致：往下滚过「封面高度 - 52」时，顶部出现「朋友圈」三个字
    /// 两路测量 + LazyVStack 哨兵兜底，哪个先到算哪个
    private var scrolled: CGFloat {
        let a = baseTop.map { $0 - topY } ?? 0
        let b = baseBlock.map { $0 - blockY } ?? 0
        return max(0, max(a, b))
    }
    private var solid: Bool { scrolled > (L.coverH - 52) || sentinelGone }
    private var owner: User? { target ?? app.me }
    private var cover: String { owner?.momentCover ?? "" }
    /// 个性签名（微信「个人相册」里昵称下面那行小字）；没写就不占位置
    private var signature: String? {
        let s = (owner?.bio ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    var body: some View {
        ZStack(alignment: .top) {
            /* 2026-10-14 用户反馈「封面底下有 2 种色差」：这一页以前铺的是**页面底色**
               （浅色 #EDEDED / 深色 #0B0B0D），而下面的列表是**纯白 / #191919** ——
               封面和列表交界的那一段就露出第二层颜色。微信朋友圈整页就是一个底色，
               这里统一成和列表一样：浅色纯白、深色 #191919。 */
            Color.dyn(0xFFFFFF, 0x191919).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    /* 量往下滚了多少：① 内容最顶端那根 1pt 条的屏幕坐标
                       ② 整个内容块的屏幕坐标 —— 两个一起量，取滚动更多的那份，
                       任何一个在真机上抽风都不会影响「滚过封面出朋友圈三个字」 */
                    Color.clear
                        .frame(height: 1)
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(key: OffsetKey.self,
                                                       value: g.frame(in: .global).minY)
                            }
                        )
                    /* 封面：下拉的时候跟着手指**拉长**（微信那种弹簧质感）。
                       GeometryReader 量出内容被拉下来多少，多出来的高度直接补在封面上，
                       同时整体上移同样的距离（底边不动）—— 看着就是封面被"揪"下来一截；
                       松手由 ScrollView 自己的弹性收回去，不用我们做动画。 */
                    GeometryReader { g in
                        let extra = max(0, g.frame(in: .named("momentsScroll")).minY - 1)
                        coverView(extra)
                            .offset(y: -extra)
                    }
                    .frame(height: L.coverH)
                    .zIndex(1)
                    momentList
                }
                .background(
                    GeometryReader { g in
                        Color.clear.preference(key: OffsetKey2.self,
                                               value: g.frame(in: .global).minY)
                    }
                )
            }
            .coordinateSpace(name: "momentsScroll")
            .onPreferenceChange(OffsetKey.self) { y in
                if baseTop == nil { baseTop = y }
                topY = y
            }
            /* 手指在朋友圈里滑动时，就别把这一下当成「点开一张图」 */
            .simultaneousGesture(
                DragGesture(minimumDistance: 6).onChanged { _ in
                    tapLockUntil = Date().addingTimeInterval(0.35)
                    /* 朋友圈也在滑：滚动的这 0.4 秒里先别开始新的图片加载（见 ScrollGate） */
                    ScrollGate.shared.touch()
                }
            )
            .onPreferenceChange(OffsetKey2.self) { y in
                if baseBlock == nil { baseBlock = y }
                blockY = y
            }
            /* 备用的下拉检测：手指往下拖 + 封面还没滚走（说明在最顶上）→ 拉出彩球。
               这套不依赖几何坐标，真机上一定有效。 */
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { v in
                        lastDragAt = Date()
                        guard !sentinelGone else { return }        // 已经滚下去了，不算下拉
                        let dy = v.translation.height
                        if dy > 0 {
                            pullY = min(140, dy)
                            if !pulling { spin = Double(pullY) * 3.2 }
                        } else if !pulling {
                            pullY = 0
                        }
                    }
                    .onEnded { _ in
                        lastDragAt = Date()
                        if pullY > 60 && !pulling { startPullRefresh() }
                        if !pulling { pullY = 0 }
                    }
            )
            .ignoresSafeArea(edges: .top)

            /* 看门狗：0.4 秒没有新的拖动就收球。手指松开的手势回调偶尔不会被叫到，
              没有这个的话球会静止留在屏幕上。 */
            .task(id: pullY > 0 || pulling) {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    if Task.isCancelled { return }
                    if pulling {
                        /* 转圈中：最多转 10 秒。网络卡住时那个刷新请求会一直不回来，
                           以前这颗球就永远留在页面上（用户反馈的"刷新完球还在"）。 */
                        if Date().timeIntervalSince(lastDragAt) > 10 {
                            CrashCatcher.note("朋友圈", "下拉刷新超过 10 秒没回来，先收球")
                            pulling = false
                            pullY = 0
                            spin = 0
                        }
                        continue
                    }
                    if pullY > 0 && Date().timeIntervalSince(lastDragAt) > 0.4 {
                        pullY = 0
                        spin = 0
                        return
                    }
                    if pullY <= 0 { return }
                }
            }

            navBar

            /* 下拉那个彩球：往下拉到一定程度就转圈刷新（和网页版那个球一样） */
            if pullY > 0 || pulling {
                ColorBall(size: 34, spin: spin)
                    .scaleEffect(0.72 + min(1, pullY / 90) * 0.28)
                    .offset(y: min(96, pullY * 0.8) + L.safeTop + 6)
                    .animation(.easeOut(duration: 0.12), value: pullY)
                    .allowsHitTesting(false)
                    .zIndex(30)
            }

            if let i = viewerIndex, !viewerPaths.isEmpty {
                /* 朋友圈看大图：底下也是微信那排「转发 / 保存」 */
                PhotoPager(paths: viewerPaths, startIndex: i, showActions: true) {
                    viewerIndex = nil
                    tapLockUntil = Date().addingTimeInterval(0.6)      // 关大图那一下别又点开一张
                }
                    .zIndex(40)
            }

        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        /* 点「余下 x 条」→ 单独一整页看那一串（用户要求） */
        .navigationDestination(isPresented: $showGroupPage) {
            if let g = groupPage {
                MomentGroupPage(title: g.title, moments: g.moments)
            }
        }
        /* 右上角那个小信封 →「消息列表」（谁赞了/评论了我），和微信一模一样 */
        .navigationDestination(isPresented: $showNoticeList) {
            MomentNoticesView(onOpen: { n in openNotice(n) })
                .environmentObject(app)
        }
        .modifier(TapAvatarCard(cardUser: $cardUser))
        .hidesTabBar()
        /* 朋友圈视频：点封面 → 全屏播（复用聊天里那个播放器；它的关闭按钮走 dismiss，
           所以必须当 sheet 弹，不能直接挂在 ZStack 里） */
        .sheet(isPresented: Binding(get: { momentVideo != nil },
                                    set: { if !$0 { momentVideo = nil } })) {
            if let u = momentVideo { VideoPlayerSheet(url: u) }
        }
        .onAppear {
            baseTop = nil
            baseBlock = nil
            sentinelGone = false
        }
        .task {
            /* 照微信：进页面**先把本机缓存铺出来**（秒开、断网也能看上次那几屏），再去刷最新的 */
            if moments.isEmpty, target == nil, !mineOnly {
                let cached = LocalStore.cachedMoments()
                if !cached.isEmpty { moments = cached }
            }
            await reload()
        }
        // 别人发朋友圈 / 换了封面，这边立刻跟着变
        .onChange(of: realtime.event) { _ in
            /* ⚠ 以前这里**任何**实时事件都会重拉一遍资料 + 动态（别人发消息、上线、输入…
               都会触发），滑朋友圈的时候一直在重绘 —— 用户说的"刷起来不够丝滑"就是这个。
               只认和朋友圈有关的事件。 */
            let t = realtime.event.type.lowercased()
            guard t.contains("moment") || t.contains("like") || t.contains("comment") else { return }
            Task {
                app.me = try? await API.shared.me()
                await pollNewMoments()          // 只把新出现的插到最前面，别把翻过的页冲掉
            }
        }
        .task {
            // 兜底：每 8 秒对一次（万一长连接断了）
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if Task.isCancelled { break }
                app.me = try? await API.shared.me()
                await pollNewMoments()
            }
        }
        /* 点封面图 → 微信那个「更换相册封面」 */
        .confirmationDialog(Tr("更换相册封面"), isPresented: $coverMenu, titleVisibility: .visible) {
            Button(Tr("从手机相册选择")) { showCoverPhoto = true }
            Button(Tr("拍一张")) { showCoverCamera = true }
            Button(Tr("取消"), role: .cancel) { }
        }
        .sheet(isPresented: $showCoverCamera) {
            CameraPicker { image in coverDraft = image }
        }
        /* 选完先「拖动调整」，点完成才真正换（微信就是这样，不会一选就换） */
        .sheet(isPresented: Binding(get: { coverDraft != nil },
                                    set: { if !$0 { coverDraft = nil } })) {
            if let img = coverDraft {
                CoverAdjustSheet(image: img,
                                 frameSize: CGSize(width: L.width, height: L.coverH)) { out in
                    changeCover(out)
                    coverDraft = nil
                }
            }
        }
        /* 「拍摄」和「从相册选择」都搬到**发表页里面**了（微信就是点一下相机 → 发表页
           直接从底下推上来，拍摄/相册在发表页里点 ＋）。外面这层不再弹系统对话框。 */
        /* 长按相机 → 拍小视频（微信的逻辑：点一下拍照片，按住拍小视频） */
        .sheet(isPresented: $showVideoShoot, onDismiss: { showVideoShoot = false }) {
            CameraVideoPicker { url in
                Task {
                    await prepareVideo(url)
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    posting = true
                }
            }
        }
        .sheet(isPresented: $showCoverPhoto) {
            PhotoPicker { image in coverDraft = image }
        }
        .sheet(isPresented: $posting) { publishSheet }
        /* 评论**不弹框**（用户要求对齐微信）：底下滑出一条输入条，浮在键盘上面 ——
           safeAreaInset 会自动把键盘算进安全区，所以输入条始终在键盘上方。 */
        .safeAreaInset(edge: .bottom) {
            if commenting != nil {
                MomentCommentBar(text: $commentText,
                                 replyTo: replyToName,
                                 onSend: { submitComment() },
                                 onCancel: { closeCommentBar() })
            }
        }
        .confirmationDialog(Tr("这条动态"), isPresented: Binding(
            get: { actionMoment != nil },
            set: { if !$0 { actionMoment = nil } }
        ), titleVisibility: .visible) {
            if let m = actionMoment {
                if m.likedByMe == true {
                    Button(Tr("取消赞")) { like(m) }
                } else {
                    Button(Tr("赞")) { like(m) }
                }
                Button(Tr("评论")) {
                    commentText = ""
                    replyToId = ""
                    replyToName = ""
                    commenting = m
                }
                if m.mine == true {
                    Button(Tr("删除"), role: .destructive) { remove(m) }
                }
            }
            Button(Tr("取消"), role: .cancel) { actionMoment = nil }
        }
    }

    /* ---------------------------------------------------------- 封面 */

    /// 封面。`extra` = 下拉被拉长出来的那一段高度（0 = 正常）：
    /// 高度直接加上 extra，里面的图和名字都还在原来的位置（对齐方式不变），
    /// 所以看着就是那张图被往下拽长了一截，松手弹回去 —— 微信那个手感。
    private func coverView(_ extra: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            if cover.isEmpty {
                /* 没设封面时显示**包内那张微信风风景照**（2026-10-14 用户要求：不要一层纯渐变）。
                   图在仓库根目录 moments-cover.jpg，CI 会拷进 App 根目录；
                   万一图没打进包，才退回原来那层蓝渐变。 */
                if UIImage(named: "moments-cover") != nil {
                    /* ⚠ 必须 clip：scaledToFill 会溢出封面区域、盖住上面的顶栏/换封面菜单
                       （2026-10-14 用户反馈「你把封面设置给改没了」就是这个） */
                    Image("moments-cover")
                        .resizable()
                        .scaledToFill()
                        .frame(width: L.width, height: L.coverH + extra)
                        .clipped()
                } else {
                    LinearGradient(colors: [Color(hex: 0x0D3B66), Color(hex: 0x1D6FB8), Color(hex: 0x0099FF)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            } else {
                RemoteImage(path: cover, icon: "photo", maxSide: 2560)
                    .id(cover)        // 换封面立刻生效
            }

            /* 顶上那一条遮罩（用户反馈「朋友圈顶上的遮罩没了」）：
               封面图顶到屏幕最上面时，返回箭头 / 相机 / 状态栏那几个白图标
               压在一张亮封面上根本看不见 —— 微信这里就压了一条由深到透的黑。
               ⚠ 2026-10-12 用户要求「遮罩要透一点」：默认浓度 0.36 → 0.20
               （高度不变），封面本身能看清一些，白图标仍然够用。
               浓度和高度都能在后台改：momentTopMask（默认 0.20）/ momentTopMaskH（默认 150）。 */
            LinearGradient(colors: [Color.black.opacity(max(0, UIConfig.num("momentTopMask", 0.20))),
                                    Color.black.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: max(L.safeTop + 56, UIConfig.num("momentTopMaskH", 150)))
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)

            /* 底下这条是给名字/签名当底衬的，同样按「透一点」调的（0.34/0.52 → 0.22/0.36） */
            LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.22), Color.black.opacity(0.36)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: L.coverH * 0.62)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)

            HStack(alignment: .bottom, spacing: 12) {
                /* 昵称 + 个性签名：微信「朋友圈」这一页的排法 ——
                   名字在头像左边，**个性签名挂在头像下面**（居中、跟着头像的宽度）。
                   （2026-10-13 用户确认：「微信不是在头像下面的吗」—— 上一版挪到名字下面了，挪回来。）
                   以前这里写的是 app.me，看好友的朋友圈也会显示自己的名字/头像，一起改掉。 */
                VStack(alignment: .trailing, spacing: 3) {
                    Text(owner?.name ?? "")
                        .font(pf(17, .semibold))
                        .foregroundColor(.white)
                        .shadow(color: Color.black.opacity(0.55), radius: 4, x: 0, y: 1)
                        .lineLimit(1)
                }
                .padding(.bottom, 24)
                VStack(spacing: 4) {
                    Avatar(path: owner?.avatarPath ?? "", size: L.coverAvatar, radius: 8)
                        .shadow(color: Color.black.opacity(0.28), radius: 5, x: 0, y: 2)
                    if let sign = signature {
                        /* 签名颜色**跟着主题走**（用户明确要求过：浅色模式黑字、深色模式白字），
                           压在封面照片上看不清的问题用**一层淡底**解决：
                           浅色模式给白底、深色模式给黑底（都是半透明小圆角），
                           文字颜色不变，但任何封面上都读得清。 */
                        Text(sign)
                            .font(pf(12.5))
                            .foregroundColor(C.label)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.dyn(0xFFFFFF, 0x000000).opacity(0.62)))
                            .frame(width: L.coverAvatar + 56, alignment: .center)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 16)
            .offset(y: 21)
        }
        .frame(height: L.coverH + extra)
        .zIndex(1)
        /* 微信：点自己朋友圈顶部这张封面图 → 弹「更换相册封面」。
           ⚠ 2026-10-14 用户反馈「怎么把设置封面弄没了」：封面换成那张默认风景图之后，
           点击区只在图片本身（名字/头像那一块点到不一定算），摸着就像没反应。
           现在给整块封面铺一层 contentShape（哪儿点都算），另外在左下角放一颗
           **看得见的「设置封面」**（只在能改的自己的朋友圈显示）——
           微信也是点封面换，但显式给一颗更不容易找不到。 */
        .contentShape(Rectangle())
        /* 微信的交互：**点封面任意位置 → 弹「更换相册封面」**（就这一下，不放额外的按钮）
           ⚠ 2026-10-14：之前一版在左下角加过一颗「设置封面」按钮，用户要求「改回原来的：点一下就能换」
           —— 按钮已去掉，`contentShape` 保证整块封面（含名字/头像那块）点到都算。 */
        .onTapGesture { if coverEditable { coverMenu = true } }
    }

    /* ---------------------------------------------------------- 列表 */

    private func momentRow(_ moment: Moment) -> some View {
        MomentRow(moment: moment,
                  onMore: { actionMoment = moment },
                  onOpenImage: { path in openPhoto(path, in: moment) },
                  onOpenVideo: { u in momentVideo = u },
                  onOpenAvatar: { u in cardUser = u },
                  onDeleteComment: { cid in deleteComment(moment.id, cid) },
                  myId: app.me?.id ?? "",
                  onLike: { like(moment) },
                  onComment: { commentText = ""; replyToId = ""; replyToName = ""; commenting = moment },
                  onDeleteMoment: { remove(moment) },
                  onReplyComment: { uid, name in
                      replyToId = uid
                      replyToName = name
                      commenting = moment
                  },
                  onTogglePin: { togglePin(moment) })
    }

    /// 星言自己的朋友圈内容流：
    /// 保留微信的阅读顺序，但每条动态有独立轻纸表面；深浅色都靠细边和低对比纹理分层。
    private func feedMomentRow(_ moment: Moment) -> some View {
        momentRow(moment)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.dyn(0xFFFFFF, 0x1B1B1D))
                    if momentsScheme == .dark {
                        LinearGradient(colors: [Color.white.opacity(0.025), Color.clear],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.dyn(0xE9E9ED, 0x303136), lineWidth: 0.55)
            }
            .padding(.vertical, 6)
    }

    /// 时间轴分组标题：今天 / 昨天 / 前天 / M月d日（往年带年份）
    private func dayLabel(_ s: String?) -> String {
        guard let d = TimeFmt.date(s) else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return Tr("今天") }
        if cal.isDateInYesterday(d) { return Tr("昨天") }
        let days = cal.dateComponents([.day],
                                      from: cal.startOfDay(for: d),
                                      to: cal.startOfDay(for: Date())).day ?? 99
        if days == 2 { return Tr("前天") }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "M月d日" : "yyyy年M月d日"
        return f.string(from: d)
    }

    private func dayHeader(_ t: String) -> some View {
        HStack {
            Text(t)
                .font(pf(13))
                .foregroundColor(C.subLabel)
            Spacer(minLength: 0)
        }
        .padding(.top, 14)
        .padding(.bottom, 2)
    }

    /* ---------------------------------------------------------- 「余下 x 条」折叠 */

    /// 一行：显示的那条 + 被折叠的那几条
    private struct FoldRow: Identifiable {
        var id: String { first.id }
        var first: Moment
        var rest: [Moment]
    }

    /// 把时间轴按「同一个好友 + 很短时间内连发」折起来。
    /// 微信就是这套：同一个人的连续几条只留最新那条，下面写「余下 x 条」。
    /// 时间窗后台可调（momentFoldWindow，单位分钟，默认 10；0 = 不折叠）。
    private var foldRows: [FoldRow] {
        let timeline = moments.filter { $0.pinned != true }
        let win = UIConfig.num("momentFoldWindow", 10) * 60_000      // 毫秒
        guard win > 0 else {
            return timeline.map { FoldRow(first: $0, rest: []) }
        }
        var out: [FoldRow] = []
        var i = 0
        while i < timeline.count {
            let head = timeline[i]
            var rest: [Moment] = []
            let headAt = TimeFmt.date(head.createdAt) ?? Date.distantPast
            var j = i + 1
            while j < timeline.count {
                let nxt = timeline[j]
                /* 只折「同一个好友」的；作者拿不到的就不折 */
                guard let aid = head.authorId, !aid.isEmpty, nxt.authorId == aid else { break }
                let nextAt = TimeFmt.date(nxt.createdAt) ?? Date.distantPast
                /* 两条之间不超过这个窗口才算"连着发的"（同一个人的旧动态不折叠） */
                if abs(headAt.timeIntervalSince(nextAt)) > win / 1000 { break }
                rest.append(nxt)
                j += 1
            }
            out.append(FoldRow(first: head, rest: rest))
            i = j
        }
        return out
    }

    /// 那一行「余下 x 条」（微信就是一行灰字，点一下展开）
    private func packedRow(_ row: FoldRow) -> some View {
        Button {
            /* 用户要求：点它是**单独一整页**（不是就地展开） */
            groupPage = MomentGroup(id: row.first.id,
                                    title: row.first.author?.name ?? Tr("朋友圈"),
                                    moments: row.rest)
            showGroupPage = true
        } label: {
            HStack(spacing: 6) {
                Text(Tr("余下") + " \(row.rest.count) " + Tr("条"))
                    .font(pf(14))
                    .foregroundColor(Color.dyn(0x5F6470, 0xC5C7CE))
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.dyn(0x5F6470, 0xC5C7CE))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var momentList: some View {
        // 必须用 LazyVStack：1500 条动态如果一次性全建出来（每行还有图），手机会直接崩
        LazyVStack(spacing: 0) {
            /* 哨兵：它被 LazyVStack 回收时说明封面已经滚过去了（滚动量测不准时的兜底） */
            Color.clear
                .frame(height: 1)
                .onAppear { sentinelGone = false }
                .onDisappear { sentinelGone = true }
            /* 没有动态时**什么都不显示**（微信就是只有封面，下面干干净净）——
               以前这里写「正在加载朋友圈…」，没动态 / 拉失败的时候一直挂着那行字，
               看着像出错。 */
            /* 置顶的那条固定在最上面（带「置顶」标），
               其余按天分组：今天 / 昨天 / 前天 / M月d日 —— 时间轴看着清楚 */
            let pinnedOnes = moments.filter { $0.pinned == true }
            /* 每条朋友圈之间那条细线（微信同款）：左边从**头像左边**起，
               右边一直顶到屏幕边。左右内缩都在后台：momentDividerInset / momentDividerTrail。 */
            ForEach(pinnedOnes) { moment in
                feedMomentRow(moment)
            }
            /* 微信那个「余下 x 条」折叠（2026-07 上的新功能）：
               同一个好友**在很短时间里连发好几条**时，时间轴只显示**最新的一条**，
               它下面写一行「余下 x 条」——点一下才把这个人这几条都展开。
               时间窗后台可调：momentFoldWindow（分钟，默认 10；写 0 = 不折叠）。 */
            ForEach(Array(foldRows.enumerated()), id: \.element.id) { i, row in
                let day = dayLabel(row.first.createdAt)
                if i == 0 || dayLabel(foldRows[i - 1].first.createdAt) != day {
                    dayHeader(day)
                }
                feedMomentRow(row.first)
                if !row.rest.isEmpty {
                    /* 微信那行「余下 x 条」：点一下进**单独一整页**看这个人这段时间发的全部 */
                    packedRow(row)
                }
                /* 微信 iOS 朋友圈是平铺时间线，动态之间靠留白分隔，不画列表线。 */
            }
            // 滑到底自动接着拉：3000 条也能一直往下翻（微信就是这样）
            if hasMoreMoments {
                Text(loadingMore ? "正在加载…" : " ")
                    .font(pf(14))
                    .foregroundColor(C.subLabel)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .onAppear {
                        Task { await loadMoreMoments() }
                    }
            } else if momentTotal > 0 {
                Text(Tr("没有更多了"))
                    .font(pf(13))
                    .foregroundColor(C.subLabel)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }

            /* 看**别人**的朋友圈时，Ta 设了「最近三天 / 最近半年」就在底下标一句
               （微信那句「朋友仅展示最近三天的朋友圈」）；自己看自己永远不显示。 */
            if !mineOnly, !(feedUserId ?? "").isEmpty, (feedUserId ?? "") != (app.me?.id ?? ""),
               feedRange == "3d" || feedRange == "6m" {
                Text(feedRange == "3d" ? Tr("朋友仅展示最近三天的朋友圈")
                                       : Tr("朋友仅展示最近半年的朋友圈"))
                    .font(pf(13))
                    .foregroundColor(C.subLabel)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
        }
        .padding(.top, 60)
        .padding(.horizontal, L.momentPadH)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity)
        .background(Color.dyn(0xF6F6F8, 0x191919))
        .offset(y: 0)
        .zIndex(0)
    }

    /* ---------------------------------------------------------- 顶部浮条 */

    private var navBar: some View {
        ZStack {
            // 滚过封面后回到中间出现「朋友圈」（网页版就是这样）
            if solid {
                Text(Tr("朋友圈"))
                    .font(pf(UIConfig.num("navTitle", 17)))
                    .foregroundColor(C.label)
            }

            HStack(spacing: 0) {
                /* 返回箭头：和全 App 用同一个（后台「UI 图标」还能换成你自己的），
                   点击区 56×48、层级拉到最上面 —— 以前是自绘 SVG + 44 宽，真机上偶尔点不到 */
                Button { dismiss() } label: {
                    FlexIcon(custom: IconOverrides.custom("nav.back"),
                             size: 20, color: solid ? C.label : .white,
                             symbol: "chevron.left", weight: .medium)
                        .frame(width: 56, height: L.navH)
                        .shadow(color: solid ? .clear : Color.black.opacity(0.55), radius: 2, x: 0, y: 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                /* 朋友圈「消息列表」（微信顶上那个小信封）：有人赞了/评论了我，上面出红点。
                   不显示具体数字，和微信一样一个小红点。 */
                ZStack(alignment: .topTrailing) {
                    Button { showNoticeList = true } label: {
                        FlexIcon(custom: IconOverrides.custom("nav.momentsBell"), size: 21,
                                 color: solid ? C.label : .white, symbol: "bell", weight: .medium)
                            .frame(width: 40, height: 44)
                            .shadow(color: solid ? .clear : Color.black.opacity(0.55), radius: 2, x: 0, y: 1)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if app.momentNoticeUnread > 0 {
                        Circle().fill(C.red)
                            .frame(width: 8, height: 8)
                            .offset(x: -7, y: 9)
                    }
                }

                /* 微信那套：**点一下** = 发表页直接从底下推上来（不再是系统对话框，
                   拍摄/相册在发表页里点 ＋）；**长按** = 直接拍小视频。
                   这里不用 Button —— Button 自带的手势会把同时挂的长按吃掉
                   （真机上就是"长按没反应"），onTapGesture + onLongPressGesture 才稳。 */
                SVGIcon(markup: I.camera, size: 26, color: solid ? C.label : .white)
                    .frame(width: 44, height: 44)
                    .shadow(color: solid ? .clear : Color.black.opacity(0.55), radius: 2, x: 0, y: 1)
                    .contentShape(Rectangle())
                    .onTapGesture { openComposer() }
                    .onLongPressGesture(minimumDuration: 0.45, maximumDistance: 26) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        showVideoShoot = true
                    }
                .padding(.trailing, 6)
                .contentShape(Rectangle())
            }
        }
        .frame(height: L.navH)
        /* 顶栏这条遮罩 = **会话页同一套薄玻璃**（用户要的「透色的感觉」）：
           系统栏材质 .bar + 很淡的一层染色，浓度跟滚动量由浅到深；
           列表是整页铺的（ZStack 里 ScrollView 在前、顶栏压在上面），
           往上滚的时候动态会从这层玻璃后面穿过去、颜色透上来。
           浓度/颜色还是那三个后台键：chatsNavGlassAlpha / chatsNavMaskAlpha / chatsNavMaskColor。 */
        /* ⚠ 这里以前只按 scrolled 淡入。朋友圈的封面有 380 高，「滚过封面」和
           「滚了 80pt」不是一回事：滚动量没量准 / 卡片滚走但滚动量还是 0 的时候，
           这层遮罩就**完全不画**（用户反馈「朋友圈顶上的遮罩没了，原本是有的」）。
           改回旧版那个条件：只要滚过封面（solid，含哨兵兜底）就整条压出来；
           没滚过封面还是按滚动量由浅到深。 */
        /* fallback 也跟着这一页的新底色（浅色纯白 / 深色 #191919），
           不然没滚过封面时顶栏后面会透出另一种灰 */
        /* 滚动前保持透明，让封面顶到安全区；滚过一定距离后浮出与动态区一致的遮罩，
           并覆盖状态栏安全区。之前这里写成 Color.clear，遮罩就彻底消失了。 */
        .background {
            TopGlassBar(scrolled: scrolled,
                        fallback: Color.dyn(0xF6F6F8, 0x191919))
        }
        .zIndex(25)          // 永远在最上层：不能被下面的滚动层吃掉点击
        .allowsHitTesting(true)
    }

    /* ---------------------------------------------------------- 发表 / 评论 / 点赞 */

    private func openPhoto(_ path: String, in moment: Moment) {
        guard Date() >= tapLockUntil else { return }      // 刚发表完 / 刚关掉大图：这一下不算
        let all = moment.images ?? []
        guard !all.isEmpty else { return }
        viewerPaths = all
        viewerIndex = all.firstIndex(of: path) ?? 0
    }

    /// 点「消息列表」里的一条：把对应的那条动态打开（微信也是点一下就回到那条动态）。
    /// 那条如果还在更下面的页里，就先把最新一页拉回来再找。
    private func openNotice(_ n: MomentNotice) {
        let mid = n.momentId ?? ""
        guard !mid.isEmpty else { return }
        if let hit = moments.first(where: { $0.id == mid }) { openMoment(hit); return }
        Task {
            await pollNewMoments()
            if let hit = moments.first(where: { $0.id == mid }) {
                openMoment(hit)
            } else {
                app.show(Tr("那条动态在更下面的记录里，往下翻就能看到"))
            }
        }
    }

    /// 打开一条动态：九宫格进大图、视频进播放器、纯文字就在顶上提示一下
    private func openMoment(_ m: Moment) {
        if let paths = m.images, !paths.isEmpty {
            viewerPaths = paths
            viewerIndex = 0
            return
        }
        if let v = m.video, !v.isEmpty {
            let full = v.hasPrefix("http") ? v : API.shared.base + v
            if let u = URL(string: full) { momentVideo = u; return }
        }
        app.show(m.content ?? "")
    }

    private var publishSheet: some View {
        VStack(spacing: 0) {
            /* 微信发表页：右上角「发表」，什么都没写的时候是灰的、点不动 */
            NavBar(title: Tr("发表"), back: { closeComposer() }) {
                Button { publish() } label: {
                    Text(uploading ? Tr("发布中…") : Tr("发表"))
                        .font(pf(17, .semibold))
                        .foregroundColor(canPublish ? C.green : C.subLabel)
                        .frame(height: L.navH)
                        .padding(.trailing, 16)
                }
                .buttonStyle(.plain)
                .disabled(!canPublish)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    /* 文字 + 「这一刻的想法…」占位 */
                    ZStack(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text(Tr("这一刻的想法…"))
                                .font(pf(17))
                                .foregroundColor(C.subLabel)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $draft)
                            .font(pf(17))
                            .frame(minHeight: 104)
                            .scrollContentBackground(.hidden)
                    }
                    .padding(.horizontal, 12)
                    .background(C.cardBg)

                    /* 九宫格：＋ 永远在第一个空位，图上有 ✕，长按拖动换顺序 */
                    composerGrid
                        .padding(.horizontal, 16)
                        .padding(.top, 14)

                    /* 微信那三行 */
                    VStack(spacing: 0) {
                        HairLine(inset: 16)
                        composerRow(icon: "location", title: Tr("所在位置"),
                                    value: draftLocation.isEmpty ? Tr("不显示位置") : draftLocation) {
                            showLocation = true
                        }
                        HairLine(inset: 16)
                        composerRow(icon: "eye", title: Tr("谁可以看"), value: visibilityName) {
                            showVisibility = true
                        }
                        HairLine(inset: 16)
                        composerRow(icon: "at", title: Tr("提醒谁看"),
                                    value: remindIds.isEmpty ? "" : "\(remindIds.count) 个人") {
                            pickMode = "at"
                            showPick = true
                        }
                    }
                    .background(C.cardBg)
                    .padding(.top, 18)
                }
                .padding(.bottom, 30)
            }
        }
        /* 发表页和微信一样：**从底下推上来的一张大卡**（sheet），上面两个圆角、后面朋友圈压暗。
           ⚠ 以前这里连顶部也 ignoresSafeArea，内容把 sheet 的圆角和外边距盖住了 ——
           看着就像"整页 push 进来"，用户反馈「发朋友圈要和微信一样底层弹出」。
           现在只让底部铺满（键盘/安全区），顶部留给系统那圈圆角。 */
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { posting = false }
        .hidesTabBar()
            /* ＋ 号：微信是直接打开相册（照片能多选，视频就一条），不再弹「照片/视频」二选一 */
            .sheet(isPresented: $showMomentAlbum, onDismiss: { showMomentAlbum = false }) {
                MomentPicker(limit: max(1, 9 - picked.count)) { r in
                    switch r {
                    case .images(let imgs):
                        let room = 9 - picked.count
                        if imgs.count > room { app.show("最多 9 张图，还能再加 \(room) 张") }
                        picked.append(contentsOf: imgs.prefix(max(0, room)))
                    case .video(let url):
                        Task { await prepareVideo(url) }
                    }
                }
            }
            .confirmationDialog(Tr("谁可以看"), isPresented: $showVisibility, titleVisibility: .visible) {
                Button(Tr("公开（所有好友可见）")) { visibility = "public" }
                Button(Tr("私密（仅自己可见）")) { visibility = "private" }
                Button(Tr("部分可见…")) { visibility = "partial"; pickMode = "partial"; showPick = true }
                Button(Tr("不给谁看…")) { visibility = "exclude"; pickMode = "exclude"; showPick = true }
                Button(Tr("取消"), role: .cancel) { }
            }
            .sheet(isPresented: $showPick) { friendPickSheet }
            .sheet(isPresented: $showLocation) {
                PlacePickerSheet(text: $draftLocation)
            }
            /* 发表页里的「拍摄」：相机自带「照片 / 视频」切换，录了视频就按一条视频发。
               挂在这一层（发表页自己身上）才不会被 sheet 压住。 */
            .sheet(isPresented: $showCamera) {
                CameraPicker(onPick: { image in
                    picked = [image]
                }, onVideo: { url in
                    Task { await prepareVideo(url) }
                })
            }
            /* 「取消」：写了东西先问一句（微信那套），空白就直接收 */
            .alert(Tr("不保留这次编辑？"), isPresented: $confirmDiscard) {
                Button(Tr("继续编辑"), role: .cancel) { }
                Button(Tr("不保留"), role: .destructive) { resetComposer() }
            }
    }

    private var canPublish: Bool {
        !uploading && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                       || !picked.isEmpty || pickedVideo != nil)
    }

    /* 九宫格（微信发表页那一块） */
    private var composerGrid: some View {
        let gap: CGFloat = 6
        let side = (L.width - 32 - gap * 2) / 3
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: gap), count: 3),
                         alignment: .leading, spacing: gap) {
            /* ① 选了视频：就一格视频封面（微信也是这样，视频和图片不能混着发） */
            if pickedVideo != nil {
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        if let c = videoCover {
                            Image(uiImage: c)
                                .resizable()
                                .scaledToFill()
                        } else {
                            C.searchBg
                        }
                        Color.black.opacity(videoProgress > 0.01 ? 0.42 : 0.22)
                        VStack(spacing: 6) {
                            if videoProgress > 0.01 {
                                /* 上传中的那一圈进度（和聊天发视频同一套观感） */
                                ZStack {
                                    Circle().stroke(Color.white.opacity(0.30), lineWidth: 4)
                                        .frame(width: 50, height: 50)
                                    Circle()
                                        .trim(from: 0, to: max(0.04, min(1, videoProgress)))
                                        .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                        .rotationEffect(.degrees(-90))
                                        .frame(width: 50, height: 50)
                                    Text("\(Int(min(1, videoProgress) * 100))%")
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundColor(.white)
                                }
                            } else {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 30))
                                    .foregroundColor(.white.opacity(0.95))
                            }
                            if videoSeconds > 0, videoProgress <= 0.01 {
                                Text(String(format: "%02d:%02d", videoSeconds / 60, videoSeconds % 60))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .frame(width: side, height: side)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    if !uploading {
                        Button {
                            pickedVideo = nil
                            videoCover = nil
                            videoSeconds = 0
                            videoWH = nil
                            videoProgress = 0
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(Color.black.opacity(0.6)))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                    }
                }
            }
            ForEach(picked.indices, id: \.self) { i in
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: picked[i])
                        .resizable()
                        .scaledToFill()
                        .frame(width: side, height: side)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .contentShape(Rectangle())
                        .onDrag {
                            dragIndex = i
                            return NSItemProvider(object: String(i) as NSString)
                        }
                        .onDrop(of: [UTType.text],
                                delegate: MomentGridDrop(index: i, items: $picked, dragIndex: $dragIndex))
                    Button {
                        picked.remove(at: i)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.black.opacity(0.6)))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                }
            }
            if picked.count < 9 && pickedVideo == nil {
                /* 微信相册第一格就是「拍摄」，系统相册（PHPicker）里没有这一格，
                   所以这里：**点一下** = 相册（照片多选 / 视频一条），**长按** = 拍摄。 */
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(C.searchBg)
                    Image(systemName: "plus")
                        .font(.system(size: 26, weight: .light))
                        .foregroundColor(C.subLabel)
                }
                .frame(width: side, height: side)
                .contentShape(Rectangle())
                .onTapGesture { showMomentAlbum = true }
                .onLongPressGesture(minimumDuration: 0.45, maximumDistance: 26) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showCamera = true
                }
            }
        }
    }

    private func composerRow(icon: String, title: String, value: String,
                             tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundColor(C.label)
                    .frame(width: 20)
                Text(title).font(pf(16)).foregroundColor(C.label)
                Spacer(minLength: 8)
                if !value.isEmpty {
                    Text(value).font(pf(15)).foregroundColor(C.subLabel).lineLimit(1)
                }
                Chevron(size: 9, line: 1.6)
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var visibilityName: String {
        switch visibility {
        case "private": return "仅自己"
        case "partial": return "部分可见"
        case "exclude": return "不给谁看"
        default: return "公开"
        }
    }

    private var friendPickSheet: some View {
        NavigationStack {
            List {
                ForEach(app.contacts) { u in
                    Button {
                        if pickMode == "at" {
                            if remindIds.contains(u.id) { remindIds.remove(u.id) } else { remindIds.insert(u.id) }
                        } else if pickMode == "partial" {
                            if visibleTo.contains(u.id) { visibleTo.remove(u.id) } else { visibleTo.insert(u.id) }
                        } else {
                            if hiddenFrom.contains(u.id) { hiddenFrom.remove(u.id) } else { hiddenFrom.insert(u.id) }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Avatar(path: u.avatarPath, size: 38, radius: 6)
                            Text(u.name).font(pf(16)).foregroundColor(C.label)
                            Spacer()
                            let on = pickMode == "at" ? remindIds.contains(u.id)
                                : (pickMode == "partial" ? visibleTo.contains(u.id) : hiddenFrom.contains(u.id))
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(on ? C.green : C.subLabel)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(pickMode == "at" ? "提醒谁看"
                             : (pickMode == "partial" ? "选择可见的好友" : "选择不看的好友"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button(Tr("好了")) { showPick = false } } }
        }
    }

    /// 松手刷新：彩球转圈，同时把封面 + 动态重新拉一遍
    private func startPullRefresh() {
        pulling = true
        spinTask?.cancel()
        spinTask = Task { @MainActor in
            var angle = spin
            let started = Date()
            while !Task.isCancelled {
                angle += 14
                spin = angle
                try? await Task.sleep(nanoseconds: 16_000_000)
                if Date().timeIntervalSince(started) > 1.0 { break }   // 至少转 1 秒
            }
            /* 网络请求最多等 6 秒：以前网络不好的时候会卡在请求里，
               那颗彩球就一直转着不走了（用户反馈的"刷新完球还在页面上"）。
               到点就先收球 —— 请求回来照样会更新数据，不影响结果。 */
            let finished = await withPullTimeout(seconds: 6) {
                if self.coverEditable { self.app.me = try? await API.shared.me() }
                await self.reload()
            }
            if !finished {
                CrashCatcher.note("朋友圈", "下拉刷新的网络请求超 6 秒，先把彩球收掉")
            }
            pullY = 0                       // 转完收回去（一定收）
            spin = 0
            pulling = false
        }
    }

    /// 给异步活儿套个超时：到点就返回 false（活儿自己继续跑完，只是不再挡着收球）
    private func withPullTimeout(seconds: Double,
                                 _ work: @escaping @MainActor () async -> Void) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await work(); return true }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func reload() async {
        if let feed = try? await API.shared.momentsFeed(limit: 30, userId: feedUserId) {
            moments = feed.moments
            hasMoreMoments = feed.hasMore
            momentTotal = feed.total
            feedRange = feed.range          // 别人的可见范围（3d / 6m / all）→ 底下一句提示
            app.momentNoticeUnread = feed.noticeUnread    // 小信封上的红点
            /* 照微信：本机留一份"你看过的那几屏"当缓存 —— 下次进来先铺缓存（秒开、断网也能看） */
            if target == nil && !mineOnly { LocalStore.saveMoments(moments) }
        } else {
            /* 拉不到（断网 / 超时）：先铺本机缓存，没有再退回启动时预取的那份 */
            let cached = LocalStore.cachedMoments()
            moments = cached.isEmpty ? app.moments : cached
            hasMoreMoments = false
        }
        // 打开朋友圈 = 看过了：把「发现」上的小红点清掉
        if target == nil {
            await API.shared.markMomentsSeen()
            app.momentsUnread = 0
        }
    }

    /// 往下翻一页（3000 条也能一条条刷到底）
    private func loadMoreMoments() async {
        guard hasMoreMoments, !loadingMore, let last = moments.last else { return }
        loadingMore = true
        if let feed = try? await API.shared.momentsFeed(limit: 30, before: last.createdAt, beforeId: last.id,
                                                        userId: feedUserId) {
            let known = Set(moments.map { $0.id })
            moments.append(contentsOf: feed.moments.filter { !known.contains($0.id) })
            hasMoreMoments = feed.hasMore && !feed.moments.isEmpty
        } else {
            hasMoreMoments = false
        }
        loadingMore = false
    }

    /// 轮询 / 收到推送时：只把「新出现的」插到最前面，已经在列表里的和翻过的页都不动
    private func pollNewMoments() async {
        guard let feed = try? await API.shared.momentsFeed(limit: 30, userId: feedUserId) else { return }
        let known = Set(moments.map { $0.id })
        let fresh = feed.moments.filter { !known.contains($0.id) }
        if !fresh.isEmpty { moments.insert(contentsOf: fresh, at: 0) }
        momentTotal = feed.total
        if moments.count <= 30 { hasMoreMoments = feed.hasMore }
    }

    private func publish() {
        uploading = true
        Task {
            /* ① 视频那条路：压缩 → 带进度上传 → 发动态（和聊天里发视频同一套，
                  不一样的地方只有：没压过的小视频直接传，服务端也不再重复压） */
            if let v = pickedVideo {
                do {
                    DispatchQueue.main.async { videoProgress = 0.02 }   // 点发表立刻出现进度圈
                    var file = v
                    var from = 0.0
                    if await MediaTool.needsCompress(v) {
                        if let small = await MediaTool.compress(v, onProgress: { p in
                            DispatchQueue.main.async { videoProgress = min(0.45, p * 0.45) }
                        }) { file = small; from = 0.45 }
                    }
                    guard let up = await MediaTool.upload(file, onProgress: { p in
                        DispatchQueue.main.async { videoProgress = from + p * (1 - from) }
                    }, skipServerTranscode: true) else {
                        throw APIError.message("视频上传失败")
                    }
                    /* 封面（发出去以后列表里显示那张图）也上传成服务器路径 */
                    var cp = ""
                    let coverImg: UIImage?
                    if let c = videoCover { coverImg = c } else { coverImg = await MediaTool.firstFrame(file) }
                    if let c = coverImg { cp = (try? await API.shared.uploadCover(image: c)) ?? "" }
                    let wh = videoWH
                    try await API.shared.postMoment(content: draft, images: [],
                                                    video: up, videoCover: cp,
                                                    videoSeconds: videoSeconds,
                                                    videoW: wh?.w ?? 0, videoH: wh?.h ?? 0,
                                                    visibility: visibility,
                                                    visibleTo: Array(visibleTo),
                                                    hiddenFrom: Array(hiddenFrom),
                                                    location: draftLocation)
                    await remindFriends()
                    app.show(Tr("已发表"))
                } catch {
                    app.show((error as? APIError)?.errorDescription ?? "视频发表失败")
                }
                resetComposer()
                await reload()
                await app.loadMoments()
                return
            }
            var urls: [String] = []
            var sizes: [String: [Int]] = [:]
            /* ⚠ 2026-10-14 用户反馈「发多图要加载一会才出来 / 变慢」：两处一起改
               ① 用 uploadImageForSend 拿到字节 → **立刻写图片缓存**（内存+磁盘+留底），发出去的图秒出
               ② **并行 3 张**（原来是串行，9 张 ≈ 9 秒；实测手机↔服务器只有几百 KB/s）
               结果按原下标回填 → 九宫格顺序不变。 */
            var mResults: [(idx: Int, url: String, w: Int, h: Int, data: Data)] = []
            await withTaskGroup(of: (Int, String, Int, Int, Data).self) { group in
                var nextIdx = 0
                func addUpload(_ i: Int) {
                    let img = picked[i]
                    let w = Int(img.size.width.rounded()), h = Int(img.size.height.rounded())
                    group.addTask {
                        let up = try? await API.shared.uploadImageForSend(img, original: false)
                        return (i, up?.url ?? "", w, h, up?.data ?? Data())
                    }
                }
                while nextIdx < min(3, picked.count) { addUpload(nextIdx); nextIdx += 1 }
                for await r in group {
                    if !r.1.isEmpty { mResults.append((idx: r.0, url: r.1, w: r.2, h: r.3, data: r.4)) }
                    if nextIdx < picked.count { addUpload(nextIdx); nextIdx += 1 }
                }
            }
            for r in mResults.sorted(by: { $0.idx < $1.idx }) {
                urls.append(r.url)
                /* 记下宽高：列表按真实比例先画框，不跳变 */
                sizes[r.url] = [r.w, r.h]
                let img = picked[r.idx]
                ImageStore.shared.put(r.url, img)
                ImageSizeCache.put(r.url, ImageBubble.thumb(img.size))
                if !r.data.isEmpty {
                    let bytes = r.data
                    Task.detached(priority: .utility) {
                        ImageStore.shared.diskWrite(r.url, bytes)
                        LocalStore.keep(r.url, data: bytes)
                    }
                }
            }
            do {
                try await API.shared.postMoment(content: draft, images: urls,
                                                imageSizes: sizes,
                                                visibility: visibility,
                                                visibleTo: Array(visibleTo),
                                                hiddenFrom: Array(hiddenFrom),
                                                location: draftLocation)
                await remindFriends()
                app.show(Tr("已发表"))
            } catch {
                app.show((error as? APIError)?.errorDescription ?? "发表失败")
            }
            resetComposer()
            await reload()
            await app.loadMoments()
        }
    }

    /// 「提醒谁看」：给选中的好友各发一条消息，让他们点进来（微信也是这么提醒的）
    private func remindFriends() async {
        guard !remindIds.isEmpty else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let tip = "我在朋友圈提到了你" + (text.isEmpty ? "" : "：" + String(text.prefix(30)))
        for fid in remindIds {
            if let chat = try? await API.shared.openDirect(userId: fid) {
                _ = try? await API.shared.send(chatId: chat.id, text: tip)
            }
        }
        await app.loadChats()
    }

    /// 发表完把这一页的状态收干净（图片和视频两路都用）
    private func resetComposer() {
        draft = ""
        picked = []
        pickedVideo = nil
        videoCover = nil
        videoSeconds = 0
        videoWH = nil
        videoProgress = 0
        visibility = "public"
        visibleTo = []
        hiddenFrom = []
        draftLocation = ""
        remindIds = []
        uploading = false
        posting = false
        tapLockUntil = Date().addingTimeInterval(0.6)          // 发表弹层收起那一下别误触到图
    }

    /// 点右上角那个相机：发表页**直接从底下推上来**（微信就是这一下，不弹系统对话框）。
    /// 上一次没发出去的草稿先清掉，免得又冒出来。
    private func openComposer() {
        resetComposer()
        posting = true
    }

    /// 发表页左上角「取消」：写了东西先问一句（微信那套「不保留这次编辑？」）
    private func closeComposer() {
        let hasStuff = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !picked.isEmpty || pickedVideo != nil
        if hasStuff { confirmDiscard = true } else { resetComposer() }
    }

    /// 相册里挑好视频：先出封面 + 时长（真正的压缩上传放到点「发表」时做，和微信一样）
    private func prepareVideo(_ url: URL) async {
        let cover = await MediaTool.firstFrame(url)
        let secs = await MediaTool.seconds(url)
        let wh = await MediaTool.aspect(url)
        await MainActor.run {
            pickedVideo = url
            videoCover = cover
            videoSeconds = secs
            videoWH = wh
            videoProgress = 0
            picked = []              // 视频和图片不混着发（微信也是这样）
        }
    }

    private func changeCover(_ image: UIImage) {
        Task {
            uploading = true
            /* 封面用高清通道（长边 2048、画质 0.95）—— 以前走的是聊天图片那条压缩通道，所以糊 */
            if let url = try? await API.shared.uploadCover(image: image) {
                await API.shared.updateMe(["momentCover": url])
                if let me = try? await API.shared.me() {
                    app.me = me
                }
                app.show(Tr("封面换好了"))
            }
            uploading = false
        }
    }

    private func like(_ moment: Moment) {
        Task {
            await API.shared.likeMoment(id: moment.id)
            await reload()
        }
    }

    /// 置顶 / 取消置顶自己那条动态：置顶的固定排最上面，只能置顶一条
    private func togglePin(_ moment: Moment) {
        let next = !(moment.pinned == true)
        Task {
            await API.shared.pinMoment(id: moment.id, pinned: next)
            await reload()
            app.show(next ? Tr("已置顶，会固定显示在最上面") : Tr("已取消置顶"))
        }
    }

    /// 删自己发的评论（微信：点一下自己的评论 → 删除）
    private func deleteComment(_ momentId: String, _ commentId: String) {
        Task {
            if let err = await API.shared.deleteMomentComment(momentId: momentId, commentId: commentId) {
                app.show(err)
            } else {
                app.show(Tr("评论已删除"))
            }
            await reload()
        }
    }

    private func submitComment() {
        guard let moment = commenting else { return }
        let text = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return }
        let to = replyToId
        closeCommentBar()
        Task {
            await API.shared.commentMoment(id: moment.id, text: text, replyTo: to)
            await reload()
        }
    }

    /// 收起底部评论条（发完 / 取消 / 点空白都走它）
    private func closeCommentBar() {
        commenting = nil
        commentText = ""
        replyToId = ""
        replyToName = ""
    }

    private func remove(_ moment: Moment) {
        Task {
            await API.shared.deleteMoment(id: moment.id)
            await reload()
            await app.loadMoments()
            app.show(Tr("已删除"))
        }
    }
}

/* ============================================================
   「余下 x 条」那一页（单独一整页，用户要求）
   ============================================================ */

/// 点「余下 x 条」要带过去的东西：标题（是谁）+ 那一串动态
struct MomentGroup: Identifiable {
    var id: String
    var title: String
    var moments: [Moment]
}

struct MomentGroupPage: View {
    let title: String
    let moments: [Moment]
    @Environment(\.dismiss) private var dismiss
    @State private var viewerPaths: [String] = []
    @State private var viewerIndex: Int?

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                NavBar(title: title, back: { dismiss() })
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(moments.enumerated()), id: \.element.id) { i, m in
                            MomentRow(moment: m,
                                      onOpenImage: { p in open(p, in: m) },
                                      compactImages: true)
                                .padding(.horizontal, L.momentPadH)
                            if i < moments.count - 1 {
                                HairLine(inset: L.momentPadH + L.momentAvatar + 9)
                            }
                        }
                        Spacer().frame(height: 30)
                    }
                }
                .background(Color.dyn(0xFFFFFF, 0x191919))
            }

            if let i = viewerIndex, !viewerPaths.isEmpty {
                PhotoPager(paths: viewerPaths, startIndex: i, showActions: true) {
                    viewerIndex = nil
                }
                .zIndex(40)
            }
        }
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
    }

    private func open(_ path: String, in m: Moment) {
        let all = m.images ?? []
        guard !all.isEmpty else { return }
        viewerPaths = all
        viewerIndex = all.firstIndex(of: path) ?? 0
    }
}

struct MomentRow: View {
    @Environment(\.colorScheme) private var scheme
    let moment: Moment
    var onMore: (() -> Void)? = nil
    /// 点图片 → 看大图
    var onOpenImage: ((String) -> Void)? = nil
    /// 点视频封面 → 全屏播放（朋友圈视频）
    var onOpenVideo: ((URL) -> Void)? = nil
    /// 点头像 → 名片
    var onOpenAvatar: ((User) -> Void)? = nil
    /// 点自己发的评论 → 删除（微信那样）
    var onDeleteComment: ((String) -> Void)? = nil
    /// 我的用户 id（判断哪条评论是我自己发的）
    var myId: String = ""
    /// 点赞 / 评论 / 删除自己的动态（微信「···」旁边那个小横条上的按钮）
    var onLike: (() -> Void)? = nil
    var onComment: (() -> Void)? = nil
    var onDeleteMoment: (() -> Void)? = nil
    /// 点别人的评论 → 回复他（微信：点一下就在底部输入条里带上「回复 A：」）
    var onReplyComment: ((String, String) -> Void)? = nil
    /// 置顶 / 取消置顶（只对自己的动态）
    var onTogglePin: (() -> Void)? = nil
    /// 「余下 x 条」单独页：只缩小图片区，正文、头像和时间保持原尺寸。
    var compactImages: Bool = false

    @State private var deletingComment: String?
    /// 爱心爆开（自己点赞 / 别人点赞进来都会放一下）
    @State private var heartBurst = false
    /// 微信：点「···」是在按钮**旁边**弹出「赞 | 评论」小横条，不是底部弹层
    @State private var showActions = false

    private var images: [String] { moment.images ?? [] }
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Avatar(path: moment.author?.avatarPath ?? "", size: L.momentAvatar, radius: 5)
                .contentShape(Rectangle())
                .onTapGesture { if let u = moment.author { onOpenAvatar?(u) } }

            VStack(alignment: .leading, spacing: 0) {
                Text(moment.author?.name ?? "")
                    /* 名字：微信朋友圈那个蓝灰（C.link = #576B95），字号照截图量（≈17）
                       —— 截图里「极氪ZEEKR / 捷豹路虎沈勉龙」那一行量出来就是这一档 */
                    .font(pf(16, .semibold))
                    .foregroundColor(C.label)

                if let content = moment.content, !content.isEmpty {
                    /* 朋友圈正文里的网址也做成可点（和微信一样） */
                    Text(RichText.linkified(content))
                        /* 正文：#191919（C.label），行距照微信量 —— 截图里三行正文
                           的基线间距是 63px（21pt），所以字号 17.3 + 行距 1 正好。 */
                        .font(pf(16))
                        .foregroundColor(C.label)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }

                /* 置顶的那条：和微信「置顶」一样在时间旁边标一下 */
                if moment.pinned == true {
                    HStack(spacing: 3) {
                        Image(systemName: "pin.fill").font(.system(size: 10))
                        Text(Tr("置顶")).font(pf(12.5))
                    }
                    .foregroundColor(C.subLabel)
                    .padding(.top, 6)
                }

                /* 视频动态没有 images（一条动态要么九张图、要么一条视频）——
                   以前这里只看 images，视频那条整块都不画，发出去看着就是"空的"。 */
                if !images.isEmpty || !(moment.video ?? "").isEmpty {
                    grid
                        .padding(.top, 13)
                }

                HStack(spacing: 14) {
                    Text(TimeFmt.ago(moment.createdAt))
                        .font(pf(12.5))
                        /* 时间：微信那档浅灰（截图里量出来 #ACACAC，取微信标准的 #B2B2B2） */
                        .foregroundColor(Color.dyn(0xB2B2B2, 0x8A8A8E))

                    Spacer()

                    Button {
                        withAnimation(.easeOut(duration: 0.14)) { showActions.toggle() }
                    } label: {
                        HStack(spacing: 2.6) {
                            ForEach(0..<3, id: \.self) { _ in
                                Circle()
                                    .fill((moment.likedByMe == true) ? Color(hex: 0xFF6B6B) : Color.dyn(0x7F7F7F, 0xD8D8D8))
                                    .frame(width: 3.4, height: 3.4)
                            }
                        }
                        .frame(width: 28, height: 19)
                        /* 微信 iOS 这里就是裸的三点，没有玻璃底、描边和外光。 */
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 10)

                let likes = moment.likes ?? []
                let comments = moment.comments ?? []
                if !likes.isEmpty || !comments.isEmpty {
                    /* ============ 微信那块的排版（用户要求照微信）============
                       一整块**浅灰圆角底**，里面分两种行：
                         · 点赞：一个小心形 + 蓝色的名字们（顿号隔开）
                         · 评论：「名字：」蓝色 + 内容黑色，一条一条，之间画细分隔线
                       块的内边距、圆角、分隔线内缩都照微信量：8 / 4 / 8。 */
                    VStack(alignment: .leading, spacing: 0) {
                        if !likes.isEmpty {
                            HStack(alignment: .top, spacing: 4) {
                                Image(systemName: "heart.fill")
                                    .font(.system(size: 11.5))
                                    .foregroundColor(Color(hex: 0x9A9A9A))
                                    .padding(.top, 3)
                                    .overlay {
                                        if heartBurst { HeartBurst() }
                                    }
                                Text(likes.compactMap { $0.nickname }.joined(separator: "，"))
                                    .font(pf(15))
                                    .foregroundColor(Color.dyn(0x5F6470, 0xC5C7CE))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                        }
                        if !likes.isEmpty && !comments.isEmpty {
                            HairLine(inset: 0)
                        }
                        ForEach(comments.indices, id: \.self) { i in
                            let c = comments[i]
                            if i > 0 { HairLine(inset: 0) }
                            /* 名字用蓝色、内容用正文色（微信就是两截颜色不同） */
                            (Text(c.nickname ?? "")
                                .foregroundColor(Color.dyn(0x5F6470, 0xC5C7CE))
                             /* 微信：在别人的评论下回复显示成「A 回复 B：内容」（数据里本来就有
                                replyToName，以前没画出来） */
                             + Text((c.replyToName ?? "").isEmpty
                                    ? ("：" + (c.content ?? ""))
                                    : (" 回复 " + (c.replyToName ?? "") + "：" + (c.content ?? "")))
                                .foregroundColor(C.label))
                                .font(pf(15))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                                /* 微信：点自己发的评论 → 问你要不要删除 */
                               .onTapGesture {
                                    if !myId.isEmpty, c.userId == myId {
                                        /* 点自己发的评论 → 微信那样问要不要删 */
                                        if onDeleteComment != nil { deletingComment = c.id }
                                    } else if let reply = onReplyComment {
                                        /* 点别人的评论 → 回复他（底部输入条里带上「回复 A：」） */
                                        reply(c.userId ?? "", c.nickname ?? "")
                                    }
                               }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: scheme == .dark ? 10 : 8,
                                                  style: .continuous)
                        .fill(Color.dyn(0xF5F5F7, 0x242529)))
                    .padding(.top, 10)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 15)
        .padding(.bottom, 12)
        /* 别人给我这条点赞 → 底下那个爱心也爆一下（用户要求） */
        .onChange(of: (moment.likes ?? []).count) { n in
            if n > 0 { burstHeart() }
        }
        /* 微信那个小横条：贴着「···」左边弹出来，里面有「赞 | 评论」（自己的动态多一个删除） */
        .overlay(alignment: .bottomTrailing) {
            if showActions {
                actionBar
                    .offset(x: -34, y: -6)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        /* 手指在动态上滑动（其实就是在滚朋友圈）：把「赞 | 评论」这条收起来 ——
           用户要求"下滑后自动关闭"。用 simultaneousGesture，不影响正常滚动。 */
        .simultaneousGesture(
            DragGesture(minimumDistance: 10)
                .onChanged { _ in
                    if showActions {
                        withAnimation(.easeOut(duration: 0.12)) { showActions = false }
                    }
                }
        )
        /* 点自己发的评论 → 删除（微信就是这样） */
        .confirmationDialog(Tr("删除这条评论？"), isPresented: Binding(
            get: { deletingComment != nil },
            set: { if !$0 { deletingComment = nil } }
        ), titleVisibility: .visible) {
            Button(Tr("删除"), role: .destructive) {
                if let id = deletingComment { onDeleteComment?(id) }
                deletingComment = nil
            }
            Button(Tr("取消"), role: .cancel) { deletingComment = nil }
        }
    }

    private var grid: some View {
        Group {
            /* 视频动态：一张封面（微信就是一张封面 + 播放三角 + 时长），点开全屏播 */
            if let v = moment.video, !v.isEmpty {
                videoTile(v)
            } else {
                MomentImageGrid(images: images,
                                avail: (L.width - L.momentPadH * 2 - L.momentAvatar - 9)
                                    * (compactImages ? 0.72 : 1),
                                sizes: moment.imageSizes ?? [:],
                                onTap: { i in if i < images.count { onOpenImage?(images[i]) } })
            }
        }
    }

    /// 朋友圈里的视频封面：按视频本身的横竖比例（和聊天里的视频气泡同一套算法）
    private func videoTile(_ path: String) -> some View {
        let size = videoBubbleSize(w: moment.videoW ?? 0, h: moment.videoH ?? 0)
        let cover = moment.videoCover ?? ""
        let secs = moment.videoSeconds ?? 0
        return Button {
            let full = path.hasPrefix("http") ? path : API.shared.base + path
            if let u = URL(string: full) { onOpenVideo?(u) }
        } label: {
            ZStack {
                if !cover.isEmpty {
                    RemoteImage(path: cover, mode: .fill, maxSide: 1280)
                } else {
                    C.searchBg
                }
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 42))
                    .foregroundColor(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.32), radius: 6)
                if secs > 0 {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text(String(format: "%02d:%02d", secs / 60, secs % 60))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.black.opacity(0.45)))
                        }
                    }
                    .padding(7)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /* 微信那个「赞 | 评论」小横条：深色底、白字白图标，贴着「···」左边 */
    /// 爱心爆开一下（自己点赞 / 别人点赞进来都调它）
    private func burstHeart() {
        heartBurst = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { heartBurst = false }
    }

    private var actionBar: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { showActions = false }
                burstHeart()
                onLike?()
            } label: {
                HStack(spacing: 5) {
                    ZStack {
                        Image(systemName: moment.likedByMe == true ? "heart.fill" : "heart")
                            .font(.system(size: 13))
                        if heartBurst { HeartBurst() }
                    }
                    Text(moment.likedByMe == true ? Tr("取消赞") : Tr("赞"))
                        .font(pf(14.5))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 13)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle().fill(Color.white.opacity(0.22)).frame(width: 0.5, height: 18)

            Button {
                withAnimation(.easeOut(duration: 0.12)) { showActions = false }
                onComment?()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "bubble.right")
                        .font(.system(size: 12.5))
                    Text(Tr("评论")).font(pf(14.5))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 13)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if moment.mine == true, onDeleteMoment != nil {
                Rectangle().fill(Color.white.opacity(0.22)).frame(width: 0.5, height: 18)
                Button {
                    withAnimation(.easeOut(duration: 0.12)) { showActions = false }
                    onTogglePin?()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: moment.pinned == true ? "pin.slash" : "pin")
                            .font(.system(size: 12.5))
                        Text(moment.pinned == true ? Tr("取消置顶") : Tr("置顶")).font(pf(14.5))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 13)
                    .frame(height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Rectangle().fill(Color.white.opacity(0.22)).frame(width: 0.5, height: 18)
                Button {
                    withAnimation(.easeOut(duration: 0.12)) { showActions = false }
                    onDeleteMoment?()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                        .padding(.horizontal, 13)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        /* 微信 iOS 的「赞 / 评论」是实色深灰小浮条，不是液态玻璃。 */
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.dyn(0x48484A, 0x3A3A3C))
        )
    }
}

/* 下拉刷新那个彩色球（和网页版 .ptr-ball 一模一样：七色渐变 + 左上高光 + 投影） */
struct ColorBall: View {
    var size: CGFloat = 34
    var spin: Double = 0

    var body: some View {
        ZStack {
            Circle().fill(AngularGradient(
                gradient: Gradient(colors: [
                    Color(hex: 0xFF6B6B), Color(hex: 0xFFD166), Color(hex: 0x5FD07A),
                    Color(hex: 0x4AB6FF), Color(hex: 0xA06DE0), Color(hex: 0xFF6BD6),
                    Color(hex: 0xFF6B6B)
                ]),
                center: .center))
            Circle().fill(RadialGradient(
                gradient: Gradient(colors: [.white.opacity(0.95), .white.opacity(0)]),
                center: UnitPoint(x: 0.37, y: 0.3), startRadius: 0.5, endRadius: size * 0.36))
                .padding(size * 0.14)
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(spin))
        .shadow(color: Color.black.opacity(0.28), radius: 7, y: 4)
    }
}

/* ============================================================
  朋友圈图片排列（严格按规格）：
   1 张 → 不进九宫格，按原图比例自适应（比例限制 3:4 ~ 2:1，超出的居中裁切，最高 300）
   2 / 4 张 → 2 列；3 张 → 3 列；5~9 张 → 统一 3 列
   正方形缩略图居中裁切 · 间隙 4 · 圆角 4 · 顺序 = 发的人选图顺序
   ============================================================ */
struct MomentImageGrid: View {
    let images: [String]
    var avail: CGFloat
    /// 每张图的宽高（发表时带上的）—— 有它就能按真实比例先画好框，不跳变
    var sizes: [String: [Int]] = [:]
    var onTap: (Int) -> Void

    private let gap: CGFloat = 4
    private let radius: CGFloat = 4

    var body: some View {
        if images.count == 1 {
            let sz = sizes[images[0]]
            MomentSingleImage(path: images[0], avail: avail, radius: radius,
                              knownSize: (sz != nil && sz!.count == 2 && sz![1] > 0)
                                  ? CGSize(width: CGFloat(sz![0]), height: CGFloat(sz![1])) : nil) { onTap(0) }
        } else {
            let cols = (images.count == 2 || images.count == 4) ? 2 : 3
            /* 微信 iOS：多图九宫格铺满正文可用宽度，不再额外缩成 52%~74%。
               以前 3 列实际每格只有约 68pt，所以整块看起来像缩略图列表。 */
            let maxW = avail
            let cell = (maxW - gap * CGFloat(cols - 1)) / CGFloat(cols)
            let rows = stride(from: 0, to: images.count, by: cols).map { start in
                Array(start..<min(start + cols, images.count))
            }
            VStack(alignment: .leading, spacing: gap) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: gap) {
                        ForEach(rows[r], id: \.self) { i in
                            Button { onTap(i) } label: {
                                /* 九宫格一格才 ~120pt，解码上限 720 就够了 ——
                                   以前按默认 1600 解，一屏九张图就是几十 MB，
                                   滚动容易掉帧 / 触发内存回收（用户说"不够丝滑"）。 */
                                RemoteImage(path: images[i], icon: "photo", maxSide: 720)
                                    .frame(width: cell, height: cell)
                                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if rows[r].count < cols { Spacer(minLength: 0) }
                    }
                }
            }
        }
    }
}

/// 单张图：等原图加载出来，按它的宽高比摆（极端比例裁切，小图不放大）
/* ============================================================
   发表页的九宫格拖动排序（微信：按住一张图拖到别的位置就换顺序）
   ============================================================ */
/* ============================================================
   换封面第二步：「拖动调整」
   上下左右拖、双指缩放，框住的那一块就是新封面 —— 点「完成」才保存。
   （微信也是这个流程：选完图不会立刻换，要你拖一下位置）
   ============================================================ */
struct CoverAdjustSheet: View {
    let image: UIImage
    let frameSize: CGSize
    var onDone: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("拖动调整"), back: { dismiss() }) {
                Button {
                    render()
                } label: {
                    Text(Tr("完成"))
                        .font(pf(17, .semibold))
                        .foregroundColor(C.green)
                        .frame(height: L.navH)
                        .padding(.trailing, 16)
                }
                .buttonStyle(.plain)
            }

            ZStack {
                Color.black
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: frameSize.width, height: frameSize.height)
                    .scaleEffect(scale)
                    .offset(offset)
            }
            .frame(width: frameSize.width, height: frameSize.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { v in
                        offset = CGSize(width: baseOffset.width + v.translation.width,
                                        height: baseOffset.height + v.translation.height)
                    }
                    .onEnded { _ in baseOffset = offset }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { m in scale = max(1, min(3, baseScale * m)) }
                    .onEnded { _ in baseScale = scale }
            )

            Text(Tr("拖动挪位置，双指缩放，点「完成」保存"))
                .font(pf(12.5))
                .foregroundColor(C.subLabel)
                .padding(.top, 14)
            Spacer()
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .hidesTabBar()
    }

    /// 把「框住的那一块」画成一张图交给服务器
    @MainActor
    private func render() {
        /* 出图分辨率不看设备倍数，直接按「2048 像素宽」渲染 ——
           以前是按屏幕点数 ×3 渲染（比如 393×380 点 → 1179×1140），
           有的机型 / 有的系统版本 ImageRenderer 取到的倍数不对，出图就只有 393×380，
           传上去就是糊的（你的封面文件就是这么来的）。现在固定 2048 宽，怎么都不会糊。 */
        let targetW: CGFloat = 2048
        let targetH = (targetW * frameSize.height / max(1, frameSize.width)).rounded()
        let k = targetW / max(1, frameSize.width)          // 拖动/缩放的位移也要按同样的倍数放大
        let view = Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: targetW, height: targetH)
            .scaleEffect(scale)
            .offset(x: offset.width * k, y: offset.height * k)
            .frame(width: targetW, height: targetH)
            .clipped()
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        if let out = renderer.uiImage { onDone(out) }
        dismiss()
    }
}

struct MomentGridDrop: DropDelegate {
    let index: Int
    @Binding var items: [UIImage]
    @Binding var dragIndex: Int?

    func dropEntered(info: DropInfo) {
        guard let from = dragIndex, from != index,
              items.indices.contains(from), items.indices.contains(index) else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            items.move(fromOffsets: IndexSet(integer: from), toOffset: index > from ? index + 1 : index)
        }
        dragIndex = index
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragIndex = nil
        return true
    }
}

/* ============================================================
   发表页「所在位置」：定位一次，反查出位置名（微信就是让你选一个地点）
   ============================================================ */

final class OneShotLocation: NSObject, CLLocationManagerDelegate {
    static let shared = OneShotLocation()
    private let mgr = CLLocationManager()
    private var cont: CheckedContinuation<CLLocation?, Never>?
    private var timeout: Task<Void, Never>?

    func current() async -> CLLocation? {
        /* 一分钟内定位过的位置直接用，省得每次都等 */
        if let l = mgr.location, abs(l.timestamp.timeIntervalSinceNow) < 60 { return l }
        if cont != nil { return mgr.location }        // 已经有一次在定位了，别叠着来
        return await withCheckedContinuation { c in
            cont = c
            mgr.delegate = self
            mgr.desiredAccuracy = kCLLocationAccuracyHundredMeters
            let st = mgr.authorizationStatus
            if st == .notDetermined {
                /* 先要权限，等用户在弹窗上点了以后，授权回调里再真正请求位置。
                   以前是「要权限 + 立刻请求位置」一起发 —— 授权还没下来时那一次请求的
                   回调永远不会来，界面就一直卡在「正在定位」。 */
                mgr.requestWhenInUseAuthorization()
            } else if st == .denied || st == .restricted {
                finish(mgr.location)
            } else {
                mgr.requestLocation()
            }
            /* 8 秒还没结果就别让界面一直转：有上次的位置就用上次的，没有就给空 */
            timeout?.cancel()
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if Task.isCancelled { return }
                self?.finish(self?.mgr.location)
            }
        }
    }

    private func finish(_ loc: CLLocation?) {
        timeout?.cancel()
        timeout = nil
        cont?.resume(returning: loc)
        cont = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let st = manager.authorizationStatus
        if st == .notDetermined { return }
        if st == .denied || st == .restricted {
            finish(manager.location)
            return
        }
        if cont != nil { manager.requestLocation() }     // 授权刚下来：现在真正请求位置
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(manager.location)
    }
}

struct PlacePickerSheet: View {
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss

    @State private var places: [String] = []
    @State private var locating = true

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("所在位置"), back: { dismiss() })
            if locating {
                HStack { Spacer(); ProgressView(Tr("正在定位…")); Spacer() }
                    .frame(height: 90)
                    .background(C.cardBg)
            }
            ScrollView {
                VStack(spacing: 0) {
                    Button {
                        text = ""
                        dismiss()
                    } label: {
                        HStack {
                            Text(Tr("不显示位置")).font(pf(16)).foregroundColor(C.label)
                            Spacer()
                            if text.isEmpty { Image(systemName: "checkmark").foregroundColor(C.green) }
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    ForEach(places, id: \.self) { p in
                        HairLine(inset: 16)
                        Button {
                            text = p
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "mappin.and.ellipse")
                                    .font(.system(size: 15)).foregroundColor(C.subLabel)
                                Text(p).font(pf(16)).foregroundColor(C.label)
                                Spacer()
                                if text == p { Image(systemName: "checkmark").foregroundColor(C.green) }
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(C.cardBg)
                .padding(.top, 12)
            }
            Spacer()
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task {
            let loc = await OneShotLocation.shared.current()
            guard let loc = loc else { locating = false; return }
            if let marks = try? await CLGeocoder().reverseGeocodeLocation(loc), let m = marks.first {
                var list: [String] = []
                if let name = m.name, !name.isEmpty { list.append(name) }
                if let city = m.locality, !city.isEmpty, !list.contains(city) { list.append(city) }
                if let sub = m.subLocality, !sub.isEmpty, !list.contains(sub) { list.append(sub) }
                if let prov = m.administrativeArea, !prov.isEmpty, !list.contains(prov) { list.append(prov) }
                places = list
            }
            locating = false
        }
    }
}

/// 发表页里已经选好的图：和发出去以后一模一样的摆法（点一下删掉）
struct PickedGrid: View {
    let images: [UIImage]
    var onTap: (Int) -> Void

    private let gap: CGFloat = 6
    private let radius: CGFloat = 4

    var body: some View {
        if images.count == 1 {
            let img = images[0]
            let a = min(max(img.size.width / max(1, img.size.height), 0.75), 2.0)
            let limit = a >= 1 ? (L.width - 32) : (L.width - 32) * 0.62
            let w = min(limit, img.size.width)
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: w, height: min(w / a, 300))
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { onTap(0) }
        } else {
            let cols = (images.count == 2 || images.count == 4) ? 2 : 3
            let maxW = L.width - 32
            let cell = (maxW - gap * CGFloat(cols - 1)) / CGFloat(cols)
            let rows = stride(from: 0, to: images.count, by: cols).map { start in
                Array(start..<min(start + cols, images.count))
            }
            VStack(alignment: .leading, spacing: gap) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: gap) {
                        ForEach(rows[r], id: \.self) { i in
                            Image(uiImage: images[i])
                                .resizable()
                                .scaledToFill()
                                .frame(width: cell, height: cell)
                                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                                .contentShape(Rectangle())
                                .onTapGesture { onTap(i) }
                        }
                        if rows[r].count < cols { Spacer(minLength: 0) }
                    }
                }
            }
        }
    }
}

struct MomentSingleImage: View {
    let path: String
    var avail: CGFloat
    var radius: CGFloat = 4
    /// 发表时带上来的真实宽高：有它就**一开始就按真实比例画框**，不跳变
    var knownSize: CGSize? = nil
    var onTap: () -> Void

    @State private var aspect: CGFloat = 4.0 / 3.0
    @State private var naturalW: CGFloat = 0
    @State private var started = false

    var body: some View {
        /* 有真实尺寸就先用真实的（列表一上来就是最终大小，不跳变）；
           没有就退回缓存里量到的、再退回默认 4:3。 */
        let rawAspect = (knownSize?.height ?? 0) > 0 ? (knownSize!.width / knownSize!.height) : aspect
        let a = min(max(rawAspect, 0.75), 2.0)               // 3:4 ~ 2:1
        // 和微信一样：横图能占满内容宽，竖图只占 62%
        let limit = a >= 1 ? avail : avail * 0.62
        let rawW = (knownSize?.width ?? 0) > 0 ? knownSize!.width : naturalW
        let w = rawW > 0 ? min(limit, rawW) : limit          // 小图不放大
        let h = min(w / a, 300)                              // 超长图限高裁切
        /* 用 Button 而不是 onTapGesture：手指在图上滑动（滚动朋友圈）时按钮会自动取消，
           以前用手势，滑动经常被当成「点开这张图」，看起来就是莫名其妙弹出一张图 */
        Button { onTap() } label: {
            /* 单张大图：内容宽最多 ~400pt @3x ≈ 1200，解到 1080 足够（省内存、滚动更稳） */
            RemoteImage(path: path, icon: "photo", maxSide: 1080)
                .frame(width: w, height: h)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear { if !started { started = true; Task { await measure() } } }
    }

    private func measure() async {
        if let hit = ImageStore.shared.get(path), hit.size.height > 0 {
            aspect = hit.size.width / hit.size.height
            naturalW = hit.size.width
            return
        }
        guard let url = API.shared.assetURL(path) else { return }
        guard let data = try? await API.shared.imageData(url),
              let img = RemoteImage.downsampled(data, maxSide: 2048), img.size.height > 0 else { return }
        ImageStore.shared.put(path, img)
        aspect = img.size.width / img.size.height
        naturalW = img.size.width
    }
}
