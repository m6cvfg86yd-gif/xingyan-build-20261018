import SwiftUI

/* ============================================================
   游戏详情 + 游戏排行榜（微信「发现 → 游戏」里点一款进去的那一页）

   2026-10-16 用户：「游戏界面跟微信的游戏界面对一下看看缺少啥」。
   微信那边点一款游戏不是直接开局，而是先看这一页：
     · 顶上大封面（海报）+ 名字 + 一句话介绍
     · **好友排行**：谁最高分多少（就在这一页里）
     · 底下一条「开始游戏」大按钮 + 分享
   排行榜页则是把每款游戏的前几名摆在一起，一眼看谁最厉害。
   ============================================================ */

struct GameDetailView: View {
    let game: MiniApp
    /// 点「开始游戏」：交给外面（外面要记「最近在玩」+ 打开内置浏览器）
    var onPlay: (MiniApp) -> Void

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var rank: GameRank?
    @State private var loadingRank = true
    @State private var shareApp: MiniApp?

    private let pageBg = Color.dyn(0xEDEDED, 0x111114)
    private let cardBg = Color.dyn(0xFFFFFF, 0x1B1B1D)
    private let ink = C.label
    private let subInk = C.subLabel

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: game.name, back: { dismiss() })

            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    cover
                    titleRow
                    rankCard
                    Color.clear.frame(height: 8)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            bottomBar
        }
        .background(pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .hidesTabBar()
        .swipeBack { dismiss() }
        .sheet(item: $shareApp) { g in
            ForwardPickerView(items: [ForwardItem(kind: "miniapp", content: miniAppSharePayload(g))]) { shareApp = nil }
                .environmentObject(app)
        }
        .task { await loadRank() }
    }

    /* ---------------------------------------------------------- 封面 */

    private var cover: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x2B2F3A), Color(hex: 0x171B22)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(game.iconText).font(.system(size: 76))
            if let cv = game.cover, !cv.isEmpty {
                RemoteImage(path: cv, mode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
        }
        .frame(height: 196)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var titleRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(game.name).font(pf(19, .semibold)).foregroundColor(ink).lineLimit(1)
                Text(Tr("小游戏"))
                    .font(pf(11))
                    .foregroundColor(C.green)
                    .padding(.horizontal, 7)
                    .frame(height: 19)
                    .background(Capsule().fill(C.green.opacity(0.12)))
                Spacer(minLength: 0)
            }
            if let d = game.desc, !d.isEmpty {
                Text(d).font(pf(13.5)).foregroundColor(subInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let line = myScoreLine {
                Text(line)
                    .font(pf(12.5))
                    .foregroundColor(subInk)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(cardBg))
    }

    /* ---------------------------------------------------------- 好友排行 */

    private var rankCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(Tr("好友排行")).font(pf(15, .medium)).foregroundColor(ink)
                Spacer(minLength: 0)
                if (rank?.total ?? 0) > 3 {
                    Text(playersText(rank?.total ?? 0))
                        .font(pf(11.5)).foregroundColor(subInk)
                }
            }
            .padding(.bottom, 6)

            if loadingRank {
                HStack(spacing: 8) {
                    ProgressView().tint(subInk)
                    Text(Tr("正在加载…")).font(pf(13)).foregroundColor(subInk)
                }
                .padding(.vertical, 14)
            } else if topRows.isEmpty {
                Text(Tr("还没有好友的成绩，你先玩一局上榜"))
                    .font(pf(13)).foregroundColor(subInk)
                    .padding(.vertical, 14)
            } else {
                ForEach(Array(topRows.enumerated()), id: \.offset) { i, r in
                    HStack(spacing: 12) {
                        /* 名次用**服务端给的真实名次**（r.rank）。
                           以前这里写的是 `r.rank ?? (i+1)` —— 拿不到真实名次时按列表下标补一个，
                           看着就是"假名次"（2026-10-16 用户：「排行数字真实」）。
                           现在拿不到就不显示数字，绝不编一个出来。 */
                        Text(r.rank.map { "\($0)" } ?? "—")
                            .font(pf(13, .semibold))
                            .foregroundColor(i == 0 ? Color(hex: 0xE8A33D) : subInk)
                            .frame(width: 18)
                        Avatar(path: r.avatar ?? "", size: 34, radius: 9)
                        Text(r.isMe ? Tr("我") : (r.name ?? Tr("好友")))
                            .font(pf(14.5))
                            .foregroundColor(ink)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(r.scoreText)")
                            .font(pfMoney(14.5))
                            .foregroundColor(ink)
                            .monospacedDigit()
                    }
                    .padding(.vertical, 8)
                    if i < topRows.count - 1 { HairLine(inset: 64) }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(cardBg))
    }

    /// 榜单前 5（只显示有分的）
    private var topRows: [GameRankRow] {
        Array((rank?.rows ?? []).filter { $0.scoreText > 0 }.prefix(5))
    }

    /// 「我的最高分 128 · 第 3 名」（英文那边就写 My best 128 · #3）
    private var myScoreLine: String? {
        guard let my = rank?.myScore, my > 0 else { return nil }
        let r = rank?.myRank ?? 0
        if Lang.isEnglish { return "My best \(my)" + (r > 0 ? " · #\(r)" : "") }
        return "我的最高分 \(my)" + (r > 0 ? " · 第 \(r) 名" : "")
    }

    private func playersText(_ n: Int) -> String {
        Lang.isEnglish ? "\(n) players" : "共 \(n) 人在玩"
    }

    /* ---------------------------------------------------------- 底部那条 */

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button { shareApp = game } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(ink)
                    .frame(width: 48, height: 46)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(cardBg))
            }
            .buttonStyle(.plain)

            Button { onPlay(game); dismiss() } label: {
                Text(Tr("开始游戏"))
                    .font(pf(16, .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [C.green, C.green.opacity(0.78)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, max(10, L.safeBottom + 6))
        .background(pageBg)
    }

    private func loadRank() async {
        loadingRank = true
        rank = await API.shared.gameRank(game.id)
        loadingRank = false
    }
}

/* ============================================================
   游戏排行榜：每款游戏一张卡（我 + 好友的最高分）
   ============================================================ */

struct GameRankBoardView: View {
    let games: [MiniApp]

    @Environment(\.dismiss) private var dismiss
    @State private var ranks: [String: GameRank] = [:]
    @State private var loading = true

    private let pageBg = Color.dyn(0xEDEDED, 0x111114)
    private let cardBg = Color.dyn(0xFFFFFF, 0x1B1B1D)
    private let ink = C.label
    private let subInk = C.subLabel

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("游戏排行榜"), back: { dismiss() })

            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    if loading {
                        ProgressView().padding(.vertical, 50)
                    } else if games.isEmpty {
                        Text(Tr("还没有游戏")).font(pf(14)).foregroundColor(subInk)
                            .padding(.vertical, 50)
                    } else {
                        /* 2026-10-16 用户：「排行榜那个里面的排名是游戏排名不是人」——
                           所以这里排的是**游戏**：按「玩的人数 → 最高分」从高到低，
                           每个人的好友榜单（人）留在游戏详情页里看。 */
                        Color.clear.frame(height: 2)
                        ForEach(Array(rankedGames.enumerated()), id: \.element.app.id) { _, item in
                            boardRow(item.app, rank: item.rank)
                        }
                    }
                    Color.clear.frame(height: 20)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }
        }
        .background(pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .hidesTabBar()
        .swipeBack { dismiss() }
        .task { await loadAll() }
    }

    /// 游戏榜：先按「有几好友在玩」排，人一样多再比最高分
    private var rankedGames: [(app: MiniApp, rank: Int)] {
        func metric(_ g: MiniApp) -> (Int, Int) {
            let r = ranks[g.id]
            let players = r?.total ?? 0
            let best = (r?.rows ?? []).map { $0.scoreText }.max() ?? 0
            return (players, best)
        }
        let sorted = games.sorted { a, b in
            let ma = metric(a), mb = metric(b)
            if ma.0 != mb.0 { return ma.0 > mb.0 }
            if ma.1 != mb.1 { return ma.1 > mb.1 }
            return a.name < b.name
        }
        /* ⚠ 2026-10-16 用户：「排行数字真实」——
           指标完全一样的两款游戏**并列同名次**，后面的名次跟着跳（1,2,2,4…），
           不是按数组下标 1,2,3,4 硬排。 */
        var out: [(app: MiniApp, rank: Int)] = []
        var last: (Int, Int)? = nil
        var lastRank = 0
        for (i, g) in sorted.enumerated() {
            let m = metric(g)
            if let l = last, l == m {
                out.append((g, lastRank))
            } else {
                lastRank = i + 1
                out.append((g, lastRank))
                last = m
            }
        }
        return out
    }

    /// 名次徽章（123 名给金银铜，其余灰）
    private func rankColor(_ rank: Int) -> Color {
        switch rank {
        case 1: return Color(hex: 0xE8A33D)
        case 2: return Color(hex: 0xA7A7AD)
        case 3: return Color(hex: 0xC98A5B)
        default: return C.subLabel
        }
    }

    /// 一行一个**游戏**：名次 + 圆形图标 + 名字 + 右边「N 人在玩 / 最高分」
    private func boardRow(_ g: MiniApp, rank: Int) -> some View {
        let r = ranks[g.id]
        let players = r?.total ?? 0
        let best = (r?.rows ?? []).map { $0.scoreText }.max() ?? 0
        let medal = rankColor(rank)
        return HStack(spacing: 12) {
            Text("\(rank)")
                .font(pf(15, .semibold))
                .foregroundColor(rank <= 3 ? medal : C.subLabel)
                .frame(width: 22)
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color(hex: 0x2B2F3A), Color(hex: 0x171B22)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(g.iconText).font(.system(size: 22))
                if let cv = g.cover, !cv.isEmpty {
                    RemoteImage(path: cv)
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                }
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(g.name).font(pf(15.5, .medium)).foregroundColor(ink).lineLimit(1)
                Text(players > 0 ? (Lang.isEnglish ? "\(players) players" : "\(players) 人在玩")
                                 : Tr("还没有人玩过"))
                    .font(pf(12))
                    .foregroundColor(subInk)
            }
            Spacer(minLength: 8)
            if best > 0 {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(best)").font(pfMoney(15)).foregroundColor(ink).monospacedDigit()
                    Text(Tr("最高分")).font(pf(11.5)).foregroundColor(subInk)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(cardBg))
    }

    private func boardCard(_ g: MiniApp) -> some View {
        let r = ranks[g.id]
        let rows = Array((r?.rows ?? []).filter { $0.scoreText > 0 }.prefix(3))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(LinearGradient(colors: [Color(hex: 0x2B2F3A), Color(hex: 0x171B22)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text(g.iconText).font(.system(size: 22))
                    if let cv = g.cover, !cv.isEmpty {
                        RemoteImage(path: cv).frame(width: 42, height: 42)
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                }
                .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(g.name).font(pf(15, .medium)).foregroundColor(ink).lineLimit(1)
                    Text(myScoreText(r))
                        .font(pf(12)).foregroundColor(subInk)
                }
                Spacer(minLength: 6)
            }
            .padding(.bottom, rows.isEmpty ? 0 : 6)

            if rows.isEmpty {
                Text(Tr("还没有好友的成绩"))
                    .font(pf(12.5)).foregroundColor(subInk)
                    .padding(.top, 6)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    HStack(spacing: 10) {
                        /* 名次一律用服务端的真实名次（拿不到就显示 —，不编数字） */
                        Text(row.rank.map { "\($0)" } ?? "—")
                            .font(pf(12.5, .semibold))
                            .foregroundColor(i == 0 ? Color(hex: 0xE8A33D) : subInk)
                            .frame(width: 16)
                        Avatar(path: row.avatar ?? "", size: 28, radius: 8)
                        Text(row.isMe ? Tr("我") : (row.name ?? Tr("好友")))
                            .font(pf(14)).foregroundColor(ink).lineLimit(1)
                        Spacer(minLength: 6)
                        Text("\(row.scoreText)").font(pfMoney(14)).foregroundColor(ink)
                            .monospacedDigit()
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(cardBg))
    }

    /// 每款游戏的榜单并行拉（串行的话四五款要等好几秒）
    private func loadAll() async {
        loading = true
        var out: [String: GameRank] = [:]
        await withTaskGroup(of: Optional<GameRank>.self) { grp in
            for g in games {
                grp.addTask { await API.shared.gameRank(g.id) }
            }
            for await r in grp {
                /* 服务端把游戏标识一起回了，直接拿它当键（不用再自己配一遍） */
                if let r, let id = r.game, !id.isEmpty { out[id] = r }
            }
        }
        ranks = out
        loading = false
    }

    private func myScoreText(_ r: GameRank?) -> String {
        let mine = r?.myScore ?? 0
        guard mine > 0 else { return Tr("我还没玩过") }
        return Lang.isEnglish ? "My best \(mine)" : "我的最高分 \(mine)"
    }
}
