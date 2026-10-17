import SwiftUI
import WebKit
import AVFoundation

/// 分享出去那张小游戏卡片的 body（收端按这段 JSON 画卡片、点开直接进游戏）
/* ---------- 棋牌大厅的模型（一桌 = 4 个位） ---------- */

struct GameTableSeat: Decodable {
    var id: String?
    var name: String?
    var avatar: String?
    var mine: Bool?
}

struct GameTable: Decodable, Identifiable {
    var code: String
    var id: String { code }
    var game: String?
    var host: String?
    var started: Bool?
    var seated: Int?
    var seats: [GameTableSeat?]?

    var seatNames: [String?] { (seats ?? []).map { $0?.name } }
}

func miniAppSharePayload(_ g: MiniApp) -> String {
    var d: [String: Any] = ["id": g.id, "name": g.name, "kind": g.kind ?? "game", "url": g.url]
    if let v = g.desc, !v.isEmpty { d["desc"] = v }
    if let v = g.icon, !v.isEmpty { d["icon"] = v }
    if let v = g.cover, !v.isEmpty { d["cover"] = v }
    if let v = g.action, !v.isEmpty { d["action"] = v }
    guard let data = try? JSONSerialization.data(withJSONObject: d),
          let s = String(data: data, encoding: .utf8) else { return "" }
    return s
}

/* ============================================================
   游戏（发现 → 游戏）
   四款小游戏都是**网页小游戏**（服务器 /games/ 下面那几套，后台能改 data/games.json）：
      · 跳一跳 / 2048 / 飞机大战 / 贪吃蛇
   点一下就在 App **内置的浏览器**里全屏玩（左上角一颗关闭）。
   ⚠ 以前「掷骰子 / 石头剪刀布 / 抽签 / 大转盘」那 4 个原生小游戏已经删掉了（用户要求换成这 4 款）。
   ============================================================ */

struct GamesPageView: View {
    /// 一段字符串的稳定指纹（djb2）：用来给游戏缓存目录命名 ——
    /// Swift 自带的 hashValue 每次启动都不一样，不能用来当目录名。
    static func stableKey(_ s: String) -> String {
        var h: UInt64 = 5381
        for b in s.utf8 { h = (h &* 33) &+ UInt64(b) }
        return String(h, radix: 16)
    }

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var games: [MiniApp] = []
    @State private var playing: MiniApp?
    /// 分享给好友：选人页在最外层弹（在游戏页里弹会闪退，见 GameWebPage 里的说明）
    @State private var shareApp: MiniApp?
    /// 换图标（只有 ops 账号看得到那张小按钮）
    @State private var iconPickFor = ""
    @State private var showIconPick = false
    /// 顶部焦点图（微信游戏页最上面那块大图轮播）当前在第几张
    @State private var bannerIndex = 0
    /// 点开游戏详情（微信是「看详情 → 开始游戏」，不是一点就进去）
    @State private var detail: MiniApp?
    @State private var showDetail = false
    /// 游戏排行榜（每款游戏的好友最高分）
    @State private var showRankBoard = false
    /// 焦点图自动翻页
    private let tick = Timer.publish(every: 4, on: .main, in: .common).autoconnect()
    /// 「最近在玩」存在本机（每个账号一份）
    private let recentKey = "chris.games.recent"
    @State private var recentIds: [String] = []

    /* 用户要求：游戏页的底色**跟着系统走**——白天白的、晚上深色。
       以前写死深色，白天看着像另一个 App。 */
    private let pageBg = Color.dyn(0xEDEDED, 0x111114)
    private let cardBg = Color.dyn(0xFFFFFF, 0x1B1B1D)
    private let ink = C.label
    private let subInk = C.subLabel

    @State private var loading = true
    /// 游戏页设置（轮播顺序 + 默认壁纸）——只有 ops 账号看得到那颗设置按钮
    @State private var showAdmin = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(Tr("游戏")).font(pf(17, .semibold)).foregroundColor(ink)
                HStack(spacing: 0) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundColor(ink)
                            .frame(width: 44, height: L.navH)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                    /* 2026-10-17 用户：「游戏页面的滚动要给管理可以换，还有壁纸默认壁纸」——
                       ops 账号在右上角看到这颗设置，直接改轮播顺序 + 默认壁纸 */
                    if app.me?.ops == true {
                        Button { showAdmin = true } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundColor(ink)
                                .frame(width: 44, height: L.navH)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: L.navH)
            .background(pageBg)

            ScrollView {
                /* 照微信那个「小游戏」：一节一节的小标题 + 一张张卡片
                   （封面 / 名字 / 说明 / 立即玩），后台能加、能分组 */
                /* 微信那一页最上面是**焦点图轮播**（推荐位大图，能左右滑） */
                if !bannerGames.isEmpty { banner }

                /* 下面一条是「我的小游戏」——最近玩过的横排（微信也是这一条） */
                if !recentGames.isEmpty { recentRow }

                /* 「排行榜」入口（微信游戏页有好友榜/热门榜） */
                if !list.isEmpty { rankEntry }

                ForEach(groups, id: \.0) { g in
                    HStack(spacing: 6) {
                        Text(g.0).font(pf(15.5, .semibold)).foregroundColor(ink)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(subInk)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)

                    VStack(spacing: 10) {
                        ForEach(g.1) { g2 in
                            /* 微信里点卡片进**详情**（封面 + 简介 + 好友在玩），
                               点右边那颗「立即玩」就直接开局；这里照它分两个热区 */
                            card(g2)
                        }
                    }
                    .padding(.horizontal, 16)
                }

                if loading {
                    HStack(spacing: 10) {
                        ProgressView().tint(subInk)
                        Text(Tr("正在加载…")).font(pf(14)).foregroundColor(subInk)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 30)
                } else if list.isEmpty {
                    Text(Tr("游戏加载失败，检查一下网络"))
                        .font(pf(14)).foregroundColor(subInk)
                        .frame(maxWidth: .infinity).padding(.top, 30)
                }
            }
        }
        .background(pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .hidesTabBar()
        .swipeBack { dismiss() }
        /* 点开一款：**内置浏览器全屏**玩（网页小游戏在服务器上） */
        .fullScreenCover(item: $playing) { g in
            GameWebPage(game: g).environmentObject(app)
        }
        /* 有管理权限：在小游戏列表里直接点一下就能换图标 */
        .sheet(isPresented: $showIconPick) {
            PhotoPicker { img in
                let id = iconPickFor
                Task {
                    if let url = try? await API.shared.upload(image: img) {
                        try? await API.shared.manageSetIcon(kind: "miniapp", id: id, cover: url)
                        games = await API.shared.miniApps(kind: "game")
                    }
                }
            }
        }
        /* 分享给好友：选一个聊天 → 发一张小游戏卡片（收端在聊天里点开直接玩） */
        .sheet(item: $shareApp) { g in
            ForwardPickerView(items: [ForwardItem(kind: "miniapp", content: miniAppSharePayload(g))]) { shareApp = nil }
                .environmentObject(app)
        }
        .sheet(isPresented: $showAdmin) {
            GamesPageAdminSheet(games: list).environmentObject(app)
        }
        .task {
            /* 和「发现 → 小程序」同一个源：后台「小程序 / 小游戏」里 kind=小游戏 的那些。
               这样后台加一款游戏，App 不用出包。 */
            recentIds = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
            games = await API.shared.miniApps(kind: "game")
            loading = false
        }
        .onChange(of: games.count) { _ in bannerIndex = 0 }
        .onReceive(tick) { _ in
            let n = bannerGames.count
            guard n > 1 else { return }
            withAnimation(.easeInOut(duration: 0.4)) { bannerIndex = (bannerIndex + 1) % n }
        }
        .navigationDestination(isPresented: $showDetail) {
            if let g = detail {
                GameDetailView(game: g) { pick in
                    recordPlayed(pick)
                    playing = pick
                }
            }
        }
        .navigationDestination(isPresented: $showRankBoard) {
            GameRankBoardView(games: list)
        }
    }

    private var list: [MiniApp] { games }

    /* ---------------------------------------------------------- 焦点图（微信最上面那块） */

    /// 焦点图放哪几款：优先有封面的（后台传了封面 = 想推），最多 5 张；
    /// 一张封面都没有就退回前 3 款（用图标 + 渐变当海报），保证这一块不空着。
    private var bannerGames: [MiniApp] {
        /* 2026-10-17 用户：「游戏页面的滚动要给管理可以换」——
           后台（管理 → 小程序/小游戏 → 游戏页）配了 gamesBannerIds（逗号分隔的游戏 id，顺序就是轮播顺序），
           就严格按后台那份来；没配才走老规则（有封面的前 5 款 / 前 3 款兜底）。 */
        let picked = UIConfig.text("gamesBannerIds", "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !picked.isEmpty {
            let mapped = picked.compactMap { id in list.first { $0.id == id } }
            if !mapped.isEmpty { return Array(mapped.prefix(8)) }
        }
        let withCover = list.filter { ($0.cover?.isEmpty == false) }
        if withCover.count >= 2 { return Array(withCover.prefix(5)) }
        return Array(list.prefix(3))
    }

    /// 游戏页壁纸：后台 gamesWallpaper 配了就用图；没配就用内置的**默认壁纸**（深色渐变，不依赖图片）
    @ViewBuilder private var wallpaperBg: some View {
        let wp = UIConfig.text("gamesWallpaper", "").trimmingCharacters(in: .whitespaces)
        ZStack {
            LinearGradient(colors: [Color(hex: 0x1B1E26), Color(hex: 0x0E1015)],
                           startPoint: .top, endPoint: .bottom)
            if !wp.isEmpty {
                RemoteImage(path: wp, mode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .overlay(Color.black.opacity(0.35))
            }
        }
        .ignoresSafeArea()
    }

    private var banner: some View {
        let items = bannerGames
        return VStack(spacing: 7) {
            TabView(selection: $bannerIndex) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, g in
                    Button { openDetail(g) } label: { bannerCard(g) }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 148)

            if items.count > 1 {
                HStack(spacing: 5) {
                    ForEach(0..<items.count, id: \.self) { i in
                        Circle()
                            .fill(i == min(bannerIndex, items.count - 1)
                                  ? C.label.opacity(0.7) : C.subLabel.opacity(0.3))
                            .frame(width: 5.5, height: 5.5)
                    }
                }
            }
        }
        .padding(.top, 12)
    }

    private func bannerCard(_ g: MiniApp) -> some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Color(hex: 0x2B2F3A), Color(hex: 0x171B22)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let cv = g.cover, !cv.isEmpty {
                RemoteImage(path: cv, mode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                /* 没有封面：用后台配的**游戏页默认壁纸**（gamesWallpaper）当底，图标压在上面；
                   后台也没配就用内置深色渐变（默认壁纸）—— 这一块永远不会空着。 */
                let wp = UIConfig.text("gamesWallpaper", "").trimmingCharacters(in: .whitespaces)
                ZStack {
                    if !wp.isEmpty {
                        RemoteImage(path: wp, mode: .fill)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                            .overlay(Color.black.opacity(0.30))
                    }
                    Text(g.iconText).font(.system(size: 66))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            /* 底下压一层黑，字才看得清（微信焦点图也是这么压的） */
            LinearGradient(colors: [.clear, .black.opacity(0.55)],
                           startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 3) {
                Text(g.name).font(pf(17, .semibold)).foregroundColor(.white).lineLimit(1)
                Text(g.desc ?? "").font(pf(12)).foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 148)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /* ---------------------------------------------------------- 我的小游戏（最近在玩） */

    private var recentGames: [MiniApp] {
        recentIds.compactMap { id in list.first { $0.id == id } }
    }

    private var recentRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(Tr("最近在玩")).font(pf(15.5, .semibold)).foregroundColor(ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(recentGames) { g in
                        Button { recordPlayed(g); playing = g } label: {
                            VStack(spacing: 5) {
                                ZStack {
                                    Circle()
                                        .fill(LinearGradient(colors: [Color(hex: 0x2B2F3A), Color(hex: 0x171B22)],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                                    Text(g.iconText).font(.system(size: 26))
                                    if let cv = g.cover, !cv.isEmpty {
                                        RemoteImage(path: cv)
                                            .frame(width: 58, height: 58)
                                            .clipShape(Circle())
                                    }
                                }
                                .frame(width: 58, height: 58)
                                Text(g.name).font(pf(11.5)).foregroundColor(subInk)
                                    .lineLimit(1).frame(width: 62)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 14)
    }

    /// 玩过就记一笔（本机记，最多 8 个，最新的排最前）
    private func recordPlayed(_ g: MiniApp) {
        var ids = recentIds.filter { $0 != g.id }
        ids.insert(g.id, at: 0)
        if ids.count > 8 { ids = Array(ids.prefix(8)) }
        recentIds = ids
        UserDefaults.standard.set(ids, forKey: recentKey)
    }

    private func openDetail(_ g: MiniApp) {
        detail = g
        showDetail = true
    }

    /// 直接开局（列表里那颗「立即玩」、详情页的「开始游戏」都走这里）
    private func play(_ g: MiniApp) {
        recordPlayed(g)
        playing = g
    }

    /* ---------------------------------------------------------- 排行榜入口 */

    private var rankEntry: some View {
        Button { showRankBoard = true } label: {
            HStack(spacing: 11) {
                Text("🏆")
                    .font(.system(size: 19))
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.dyn(0xFFF3D6, 0x2A2417)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(Tr("游戏排行榜")).font(pf(15, .medium)).foregroundColor(ink)
                    Text(Tr("看看好友在每款游戏里的最高分")).font(pf(12)).foregroundColor(subInk)
                }
                Spacer(minLength: 6)
                Chevron(size: 8, line: 1.6, color: subInk)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(cardBg))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    /// 按分组合起来（后台没填分组的都归到「推荐小游戏」）
    private var groups: [(String, [MiniApp])] {
        var order: [String] = []
        var map: [String: [MiniApp]] = [:]
        for g in list {
            let k = g.groupText
            if map[k] == nil { map[k] = []; order.append(k) }
            map[k]?.append(g)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    private func card(_ g: MiniApp) -> some View {
        HStack(spacing: 12) {
            /* 点左边这一块（图标 + 名字 + 说明）进详情页 */
            Button { openDetail(g) } label: {
                HStack(spacing: 12) {
                    ZStack {
                        /* 2026-10-16 用户：「游戏的图标都改成圆形图标」——列表里的游戏图标统一做成圆 */
                        Circle()
                            .fill(LinearGradient(colors: [Color(hex: 0x2B2F3A), Color(hex: 0x171B22)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                        Text(g.iconText).font(.system(size: 30))
                        if let cv = g.cover, !cv.isEmpty {
                            RemoteImage(path: cv)
                                .frame(width: 72, height: 72)
                                .clipShape(Circle())
                        }
                    }
                    .frame(width: 72, height: 72)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(g.name).font(pf(16, .medium)).foregroundColor(ink).lineLimit(1)
                        Text(g.desc ?? "").font(pf(12.5)).foregroundColor(subInk)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 6)
            /* ops 账号：卡片右下角多一颗「换图标」 */
            if app.me?.ops == true {
                Button {
                    iconPickFor = g.id
                    showIconPick = true
                } label: {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 16))
                        .foregroundColor(C.green)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            /* 分享给好友（谁都能用） */
            Button { shareApp = g } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16))
                    .foregroundColor(subInk)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { play(g) } label: {
                Text(g.actionText)
                    .font(pf(13.5, .medium))
                    /* 2026-10-16 用户：「立即玩底色白色 / 立即玩字黑色」 */
                    .foregroundColor(Color.dyn(0x111111, 0x111111))
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(Capsule().fill(Color.white))
                    .overlay(Capsule().stroke(Color.black.opacity(0.10), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(cardBg))
    }
}
/* ---------------------------------------------------------- 内置浏览器玩小游戏 */

/// 小游戏页面：**全屏 + 内置浏览器**（WKWebView）。
/// 左上角一颗「✕」退出，页面本身就是 canvas 全屏，不做别的栏，免得挡着玩。
struct GameWebPage: View {
    let game: MiniApp
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    /// 下到本机的那份 index.html（见 prepare()）
    @State private var localIndex: URL?
    @State private var localDir: URL?
    @State private var loading = true
    @State private var errorText = ""
    /// 顶栏那颗 🏆（好友排名面板）要往里打 JS
    @StateObject private var box = WebBox()
    /// 「分享给好友」那个选人页
    @State private var share = false
    /// 右上角胶囊里的「···」菜单
    @State private var capsuleMenu = false
    /// 胶囊菜单里的「关于」
    @State private var about = false
    /* ---- 棋牌大厅（四国军棋这类要凑桌的） ---- */
    /// 是不是"要凑桌"的游戏。
    /// ⚠ 现在**关掉**了：四国军棋用的是项目里那套 11-junqi（自带「好友联机 / 快速匹配」，
    /// 走 wss://aa.x8iu.com/junqi 的房间服务器），不用我们这层原生大厅了。
    /// 以后要新加"凑桌"游戏，把 id 写进来就能用原生大厅。
    private var isRoomGame: Bool { false }
    @State private var tables: [GameTable] = []
    @State private var myRoom: String = ""
    @State private var mySeat: Int = 0
    @State private var roomNames: [String?] = []
    @State private var roomStarted = false
    @State private var lobbyMsg = ""
    @State private var moveSeq = 0
    @State private var pollTask: Task<Void, Never>? = nil

    var body: some View {
        /* ⚠ 2026-10-16 踩过：这一页东西太多（游戏本体 + 胶囊 + 🏆 + 转发/关于面板），
           全塞在一个 body 里 Swift 会「type-check 超时」直接编不过。
           所以舞台单独拎成 stage，body 里只挂修饰符（一个简单表达式）。
           微信小程序那样：**不占顶栏，整屏都是游戏**，只有右上角那个胶囊。 */
        stage
            .background(Color(hex: 0x0B0E17).ignoresSafeArea())
            .statusBarHidden(true)
            /* ⚠ 2026-10-16 用户：「游戏没声音了」——
               网页音频在 iOS 里默认走 ambient 会话，会被**侧边静音开关**直接掐掉
               （微信小游戏是特意绕过的）。这里进游戏就把音频会话切成 playback +
               mixWithOthers：静音开关拦不住，也不打断后台在放的音乐。
               退出页面再还回 ambient，别的页面行为不变。 */
            .onAppear { Self.setGameAudio(true) }
            .onDisappear { Self.setGameAudio(false) }
            .task {
                if isRoomGame { await loadTables() }
                await prepare()
            }
            .confirmationDialog(game.name, isPresented: $capsuleMenu, titleVisibility: .visible) {
                /* 微信小游戏那颗胶囊里就是这几项：转发给朋友 / 好友排名 / 关于 / 退出 */
                Button(Tr("转发给朋友")) { share = true }
                Button(Tr("好友排名")) { box.web?.evaluateJavaScript("window.chrisRank && chrisRank.show()") }
                if isRoomGame && !myRoom.isEmpty {
                    Button(Tr("复制桌号邀请")) {
                        UIPasteboard.general.string = Tr("四国军棋 桌号 ") + myRoom
                        lobbyMsg = Tr("桌号已复制")
                    }
                }
                Button(Tr("关于")) { about = true }
                Button(Tr("重新进入")) { Task { await prepare(force: true) } }
                Button(Tr("关闭"), role: .destructive) { dismiss() }
                Button(Tr("取消"), role: .cancel) { }
            }
            .sheet(isPresented: $share) {
                ForwardPickerView(items: [ForwardItem(kind: "miniapp", content: miniAppSharePayload(game))]) {
                    share = false
                }
                .environmentObject(app)
            }
            .alert(Tr("关于"), isPresented: $about) {
                Button(Tr("知道了"), role: .cancel) { }
            } message: {
                Text(aboutText)
            }
            .onDisappear {
                pollTask?.cancel()
                if !myRoom.isEmpty { Task { await API.shared.gameTableLeave(myRoom) } }
            }
    }

    /// 「关于」里那一小段字（字符串单独算，别写在 body 里 —— 同样会拖垮类型推断）
    private var aboutText: String {
        var s = game.name
        if let d = game.desc, !d.isEmpty { s += "\n" + d }
        s += "\n\n" + Tr("星言小游戏")
        if let g = game.group, !g.isEmpty { s += "\n" + g }
        return s
    }

    /// 舞台：游戏本体（整屏）+ 右上角胶囊 + 右下角那颗 🏆
    private var stage: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if isRoomGame && !roomStarted {
                    lobby
                } else if let localIndex {
                    GameWebView(index: localIndex, dir: localDir,
                                rankJs: chrisRankJs(game: game.id, token: API.shared.token, base: API.shared.base),
                                box: box,
                                onScore: { g, s in Task { await API.shared.gameScore(g, s) } },
                                onRank: { g, done in Task { done(await API.shared.gameRankJSONWithAvatars(g)) } },
                                roomJs: roomJs,
                                onMove: { mv in Task { await API.shared.gameTableMove(myRoom, mv) } })
                } else if loading {
                    VStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text(Tr("正在准备游戏…")).font(pf(13.5)).foregroundColor(.white.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 12) {
                        Text(errorText.isEmpty ? Tr("游戏打不开") : errorText)
                            .font(pf(14)).foregroundColor(.white.opacity(0.8))
                            .multilineTextAlignment(.center).padding(.horizontal, 30)
                        Button { Task { await prepare(force: true) } } label: {
                            Text(Tr("重试"))
                                .font(pf(15, .medium)).foregroundColor(.white)
                                .padding(.horizontal, 22).frame(height: 40)
                                .background(Capsule().fill(C.green))
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            /* ⚠ 游戏/小程序要**真的全屏**：以前只把背景铺满，网页本体还留在安全区里 ——
               刘海那一条和底部那条各留一条黑边（用户报的「游戏不是全屏」就是这个）。
               让内容本身忽略安全区，整块屏幕都是游戏；右上角那颗胶囊仍然按安全区排，
               不会被刘海压住。 */
            .ignoresSafeArea()
            /* 右上角那颗胶囊：左边 ···（菜单）右边 ⊙（关掉）—— 微信小程序就是这一颗 */
            miniCapsule
                /* 全屏游戏里画面是铺满的（ignoresSafeArea），但这颗胶囊要**躲开刘海/灵动岛**，
                   否则会被压住（2026-10-14 用户反馈「全屏幕排版下字被遮住」）。 */
                .padding(.top, max(8, L.safeTop + 6))
                .padding(.trailing, 10)
            /* 右下角那颗 🏆（好友排名）：独立一颗，一眼就能看到、点一下出榜
               （上一版把顶栏去掉时把它连同顶栏一起弄没了，用户说"没有好友排名/点不开"） */
            if localIndex != nil {
                VStack {
                    Spacer(minLength: 0)
                    HStack {
                        Spacer(minLength: 0)
                        Button {
                            box.web?.evaluateJavaScript("window.chrisRank && chrisRank.show()")
                        } label: {
                            Text("🏆")
                                .font(.system(size: 20))
                                .frame(width: 42, height: 42)
                                .background(Circle().fill(Color.black.opacity(0.35)))
                                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 12)
                        /* 同理：底下这颗 🏆 也要躲开home 指示条 */
                        .padding(.bottom, max(18, L.safeBottom + 14))
                    }
                }
            }
        }
    }

    /* ============================================================
       棋牌大厅：一张张桌子摆着（用户要求"进门要做摆放一张张的桌子"）
       ============================================================ */

    /// 微信小程序右上角那颗胶囊：[ ··· | ⊙ ]
    private var miniCapsule: some View {
        HStack(spacing: 0) {
            Button { capsuleMenu = true } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 48, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Rectangle()
                .fill(Color.white.opacity(0.25))
                .frame(width: 0.5, height: 18)
            Button { dismiss() } label: {
                ZStack {
                    Circle().stroke(Color.white, lineWidth: 1.6).frame(width: 15, height: 15)
                    Circle().fill(Color.white).frame(width: 5.5, height: 5.5)
                }
                .frame(width: 46, height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(Capsule().fill(Color.black.opacity(0.35)))
        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
    }

    private var lobby: some View {
        ZStack {
            Color(hex: 0x0B0E17).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 12) {
                    Text(Tr("四国军棋 · 棋牌大厅")).font(pf(17, .semibold)).foregroundColor(.white)
                    Text(myRoom.isEmpty ? Tr("点一张桌子坐下，缺的位置由电脑顶上")
                                        : (Tr("你在 ") + myRoom + Tr(" 号桌（") + "\(mySeat + 1)" + Tr(" 号位）")))
                        .font(pf(12.5)).foregroundColor(.white.opacity(0.6))

                    if !myRoom.isEmpty {
                        roomCard
                    } else {
                        Button { Task { await createTable() } } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle.fill")
                                Text(Tr("自己开一桌"))
                            }
                            .font(pf(15, .medium)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .background(Capsule().fill(C.green))
                        }
                        .buttonStyle(.plain)

                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                            GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(tables) { t in tableCard(t) }
                        }
                        if tables.isEmpty {
                            Text(Tr("还没有人开桌，你可以先开一桌等好友"))
                                .font(pf(13)).foregroundColor(.white.opacity(0.5))
                                .padding(.top, 20)
                        }
                    }
                    if !lobbyMsg.isEmpty {
                        Text(lobbyMsg).font(pf(12.5)).foregroundColor(.white.opacity(0.7))
                    }
                    Spacer().frame(height: 20)
                }
                .padding(16)
            }
        }
    }

    /// 大厅里的一张桌子：四个座位（有人显示名字 + 头像，没人显示"空"）
    private func tableCard(_ t: GameTable) -> some View {
        Button { Task { await sit(t.code) } } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(Tr("桌 ") + t.code).font(pf(14, .semibold)).foregroundColor(.white)
                    Spacer(minLength: 0)
                    Text("\(t.seated ?? 0)/4").font(pf(11.5)).foregroundColor(.white.opacity(0.55))
                }
                let names = t.seatNames
                ForEach(0..<4, id: \.self) { i in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(i < names.count && names[i] != nil ? C.green : Color.white.opacity(0.12))
                            .frame(width: 7, height: 7)
                        Text(i < names.count ? (names[i] ?? Tr("空位")) : Tr("空位"))
                            .font(pf(12))
                            .foregroundColor(i < names.count && names[i] != nil ? .white : .white.opacity(0.45))
                            .lineLimit(1)
                    }
                }
                Text((t.started == true) ? Tr("已开局") : Tr("点一下坐下"))
                    .font(pf(11.5)).foregroundColor(C.green)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: 0x1B1B1D)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var roomCard: some View {
        VStack(spacing: 10) {
            HStack {
                Text(Tr("桌号 ") + myRoom).font(pf(19, .semibold)).foregroundColor(.white)
                Spacer(minLength: 0)
                /* ⚠ 这里不能弹选人页（在游戏整页里弹 sheet 会闪退，之前踩过），
                   所以改成「复制桌号」——好友进同一款游戏的大厅就能看到这张桌、坐下 ✅ */
                Button {
                    UIPasteboard.general.string = Tr("来打四国军棋，桌号 ") + myRoom + Tr("（进「游戏 → 四国军棋」大厅点这张桌坐下）")
                    lobbyMsg = Tr("桌号已复制，去聊天里发给好友就行")
                } label: {
                    Text(Tr("复制桌号邀请")).font(pf(13)).foregroundColor(C.green)
                }
                .buttonStyle(.plain)
            }
            ForEach(0..<4, id: \.self) { i in
                HStack(spacing: 8) {
                    Text("\(i + 1)").font(pf(12)).foregroundColor(.white.opacity(0.5)).frame(width: 14)
                    Text(i < roomNames.count ? (roomNames[i] ?? Tr("空位（电脑）")) : Tr("空位（电脑）"))
                        .font(pf(14))
                        .foregroundColor(i == mySeat ? C.green : .white)
                    Spacer(minLength: 0)
                    if i == mySeat { Text(Tr("我")).font(pf(11.5)).foregroundColor(C.green) }
                }
                .padding(.horizontal, 12).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(i == mySeat ? 0.10 : 0.05)))
            }
            Button { startRoom() } label: {
                Text(roomStarted ? Tr("开局啦") : Tr("开始（缺的人电脑顶上）"))
                    .font(pf(15, .medium)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(Capsule().fill(C.green))
            }
            .buttonStyle(.plain)
            Button { Task { await API.shared.gameTableLeave(myRoom); myRoom = ""; roomStarted = false; await loadTables() } } label: {
                Text(Tr("离开这桌")).font(pf(13)).foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(hex: 0x1B1B1D)))
    }

    private func loadTables() async {
        tables = await API.shared.gameTables(game.id)
    }

    private func createTable() async {
        guard let r = await API.shared.gameTableCreate(game.id) else { lobbyMsg = Tr("开桌失败，再试一次"); return }
        myRoom = r.code
        mySeat = r.seat
        await refreshRoom()
    }

    private func sit(_ code: String) async {
        guard let r = await API.shared.gameTableSit(code) else { lobbyMsg = Tr("坐不进去，换一桌试试"); return }
        myRoom = code
        mySeat = r.seat
        roomNames = r.players
        if r.started { startRoom() }
    }

    private func refreshRoom() async {
        let list = await API.shared.gameTables(game.id)
        if let t = list.first(where: { $0.code == myRoom }) {
            roomNames = t.seatNames
            if t.started == true { roomStarted = true }
        }
    }

    /// 开局：告诉服务器开始，然后真的把网页游戏加载起来（带上桌号/座位）
    private func startRoom() {
        roomStarted = true
        moveSeq = 0
        Task {
            await API.shared.gameTableStart(myRoom)
            await prepare(force: true)
        }
        /* 每 1.5 秒拉一次别人的棋 */
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { return }
                let r = await API.shared.gameTableMoves(myRoom, since: moveSeq)
                moveSeq = r.n
                if !r.list.isEmpty,
                   let data = try? JSONSerialization.data(withJSONObject: r.list),
                   let s = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async {
                        box.web?.evaluateJavaScript("window.chrisOnMoves && window.chrisOnMoves(\(s));")
                    }
                }
            }
        }
    }

    /// 注进网页的那段：桌号、我的座位、同桌的人，以及"我走了一步"怎么告诉原生
    private var roomJs: String {
        let names = roomNames.map { $0 ?? "" }
        var arr = "[]"
        if let d = try? JSONSerialization.data(withJSONObject: names.map { ["name": $0.isEmpty ? "电脑" : $0] }),
           let s = String(data: d, encoding: .utf8) { arr = s }
        return """
        window.chrisRoom = { code: "\(myRoom)", seat: \(mySeat), players: \(arr) };
        window.chrisMove = function (mv) {
          try { window.webkit.messageHandlers.chrisRoom.postMessage({ action: 'move', move: mv }); } catch (e) {}
        };
        """
    }

    /// 一款小游戏要的那几个文件（服务器上 /games/xxx/ 下面就是这套）
    private var gameFiles: [String] {
        ["index.html", "js/adapter.js", "js/engine.js", "js/sound.js", "js/main.js"]
    }

    /// ⚠ 关键：**不要**让内置浏览器自己去连服务器 ——
    /// App 默认连的是 IP（https://43.242.194.89），那个证书 App 自己的网络层是放过的，
    /// 但 WKWebView 不认，页面会直接加载失败（用户看到的「游戏都打不开」就是这个）。
    /// 所以这里用 App 自己的通道把文件下到本机，再从本地文件跑；顺带离线也能玩。
    /// 进/出游戏页时切换音频会话（正文见 body 上的说明）
    static func setGameAudio(_ on: Bool) {
        let s = AVAudioSession.sharedInstance()
        if on {
            try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? s.setActive(true)
        } else {
            try? s.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        }
    }

    private func prepare(force: Bool = false) async {
        loading = true
        errorText = ""
        let path = game.url
        guard !path.isEmpty, let remoteIndex = API.shared.assetURL(path) else {
            loading = false
            errorText = Tr("这款游戏还没配地址（后台「游戏」里填 url）")
            return
        }
        let remoteDir = remoteIndex.deletingLastPathComponent()
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            loading = false
            return
        }
        /* ⚠ 缓存目录要带上**地址的指纹**：以前只按 game.id 存，而且"文件已存在就不重下"，
           所以后台把同一款游戏的 url 换掉（比如四国军棋从 09 换成 11-junqi）以后，
           手机上跑的**还是老那份缓存**（用户看到的"还是你做的那个"就是这个）。
           现在 url 一变目录就变，一定重新下。 */
        let rootKey = "games/\(game.id)-\(GamesPageView.stableKey(game.url))"
        let root = caches.appendingPathComponent(rootKey, isDirectory: true)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            /* 文件清单问服务器（每套游戏目录里那份 files.json），没有才用默认那 5 个 */
            let list = await miniAppFileList(baseDir: remoteDir)
            /* 清单变了（后台给游戏加了文件）也要重下：把清单的指纹存一份比一下 */
            let stamp = GamesPageView.stableKey(list.joined(separator: "|"))
            let stampFile = root.appendingPathComponent(".list")
            let oldStamp = (try? String(contentsOf: stampFile, encoding: .utf8)) ?? ""
            let needAll = force || oldStamp != stamp
            for f in list {
                let dst = root.appendingPathComponent(f)
                if !needAll, let sz = try? dst.resourceValues(forKeys: [.fileSizeKey]).fileSize, sz > 0 { continue }
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try await API.shared.assetData(remoteDir.appendingPathComponent(f))
                try data.write(to: dst, options: .atomic)
            }
            try? stamp.write(to: stampFile, atomically: true, encoding: .utf8)
            localDir = root
            localIndex = root.appendingPathComponent("index.html")
        } catch {
            errorText = Tr("游戏下载失败：") + error.localizedDescription
        }
        loading = false
    }
}

/* 游戏页设置（2026-10-17 用户：轮播给管理换 + 默认壁纸）。
   存 ui.json：gamesBannerIds（逗号分隔、顺序即轮播顺序）/ gamesWallpaper（图片地址）。 */
struct GamesPageAdminSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let games: [MiniApp]
    @State private var picked: [String] = []
    @State private var wallpaper = ""
    @State private var showPick = false
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("游戏页设置"), back: { dismiss() })
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(Tr("轮播（点一下加入/移出，顺序就是轮播顺序）"))
                        .font(pf(14, .semibold)).foregroundColor(C.label)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                        ForEach(games) { g in
                            Button {
                                if let i = picked.firstIndex(of: g.id) { picked.remove(at: i) } else { picked.append(g.id) }
                            } label: {
                                Text(g.name).font(pf(12.5))
                                    .foregroundColor(picked.contains(g.id) ? .white : C.label)
                                    .lineLimit(1)
                                    .padding(.horizontal, 8).frame(height: 30)
                                    .frame(maxWidth: .infinity)
                                    .background(Capsule().fill(picked.contains(g.id) ? C.green : C.cardBg))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text(Tr("默认壁纸（没封面的轮播用这张）"))
                        .font(pf(14, .semibold)).foregroundColor(C.label).padding(.top, 8)
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(C.cardBg)
                            .frame(width: 96, height: 56)
                            .overlay {
                                if !wallpaper.isEmpty {
                                    RemoteImage(path: wallpaper, mode: .fill)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                            }
                        Button(Tr("上传壁纸")) { showPick = true }.font(pf(14)).foregroundColor(C.green)
                        Button(Tr("清除")) { wallpaper = "" }.font(pf(14)).foregroundColor(DDColor.red)
                        Spacer(minLength: 0)
                    }
                    Button {
                        busy = true
                        Task {
                            _ = await API.shared.opsSetUIKey("gamesBannerIds", picked.joined(separator: ","))
                            _ = await API.shared.opsSetUIKey("gamesWallpaper", wallpaper)
                            busy = false
                            app.show(Tr("已保存"))
                            dismiss()
                        }
                    } label: {
                        Text(busy ? Tr("保存中…") : Tr("保存")).font(pf(16, .semibold)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).frame(height: 46)
                            .background(RoundedRectangle(cornerRadius: 23, style: .continuous)
                                .fill(C.green.opacity(busy ? 0.5 : 1)))
                    }
                    .buttonStyle(.plain).padding(.top, 10)
                }
                .padding(16)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .sheet(isPresented: $showPick) {
            PhotoPicker { img in
                busy = true
                Task {
                    if let url = try? await API.shared.upload(image: img) { wallpaper = url }
                    busy = false
                }
            }
        }
        .onAppear {
            picked = UIConfig.text("gamesBannerIds", "").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            wallpaper = UIConfig.text("gamesWallpaper", "").trimmingCharacters(in: .whitespaces)
        }
    }
}

/// WKWebView 包一层：禁掉滚动/回弹，全屏铺满，画布自己吃手势
struct GameWebView: UIViewRepresentable {
    let index: URL
    /// 允许读取的目录（游戏自己那几个 js 就在这里面）
    let dir: URL?
    /// 好友排名那一层（自动报分 + 🏆 面板）
    var rankJs: String = ""
    var box: WebBox? = nil
    /// 报分：由**原生**替网页发（网页是本地 file://，直连服务器会被证书/CORS 拦掉 ——
    /// 这就是以前排行榜一直不生效的原因）
    var onScore: ((String, Int) -> Void)? = nil
    /// 拉榜单：拿到 JSON 字符串后回填到网页里画
    var onRank: ((String, @escaping (String) -> Void) -> Void)? = nil
    /// 棋牌大厅：注入 window.chrisRoom（桌号 / 我的座位 / 同桌的人）
    var roomJs: String = ""
    /// 网页里走了一步 → 发给同桌的人
    var onMove: (([String: Any]) -> Void)? = nil

    func makeCoordinator() -> RankBridge {
        let b = RankBridge()
        return b
    }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        /* 安全区：让**页面自己的文字**避开刘海 / home 指示条（微信小程序就是这样）。
           游戏画面/背景仍然铺满整屏（我们没动 web view 的 frame），
           只有页面内容往下、往上让一点 —— 用户报的「全屏幕排版下字被遮住」就这条。 */
        cfg.userContentController.addUserScript(
            WKUserScript(source: WebSafeArea.js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if !rankJs.isEmpty {
            cfg.userContentController.addUserScript(
                WKUserScript(source: rankJs, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            /* 网页 → 原生 的那根线：报分 / 拉榜都走它 */
            let b = context.coordinator
            b.onScore = onScore
            b.onRank = onRank
            cfg.userContentController.add(b, name: "chrisRank")
        }
        /* 棋牌大厅：把 window.chrisRoom / chrisMove 注进去，再挂一根 chrisRoom 的线 */
        if !roomJs.isEmpty {
            cfg.userContentController.addUserScript(
                WKUserScript(source: roomJs, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            context.coordinator.room.onMove = onMove
            cfg.userContentController.add(context.coordinator.room, name: "chrisRoom")
        }
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.isOpaque = false
        v.backgroundColor = UIColor(red: 0.043, green: 0.055, blue: 0.09, alpha: 1)
        v.scrollView.bounces = false
        v.scrollView.isScrollEnabled = false
        v.scrollView.contentInsetAdjustmentBehavior = .never
        v.loadFileURL(index, allowingReadAccessTo: dir ?? index.deletingLastPathComponent())
        box?.web = v
        context.coordinator.web = v
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) { }
}
