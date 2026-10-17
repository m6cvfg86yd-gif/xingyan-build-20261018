import SwiftUI

/* ============================================================
   商城尾款（2026-10-15 对齐京东 · 第二批）

     · 首页「频道」那一排 + 频道页：百亿补贴 / 排行榜 / 9.9包邮 / 厂家直供
     · 搜索页：联想词 + 热搜榜 + 筛选排序（销量 / 价格 / 只看有货）
     · 消息 tab：接**真服务通知**（DDStore.notices：下单/付款/成团/发货/签收/评价/售后）

   ⚠ 一律用 /api/mall 下发的**真商品**算，不编数据：
     · 排行榜按销量（sold 里那串 "10万+" 也认）
     · 9.9包邮按拼单价 ≤ 9.9 真筛
     · 厂家直供按商品自带的标签筛
     · 百亿补贴：有「补贴」标签的就用标签；这条曲库里现在没有这种标签，
       就按**折扣力度**排（省得最多的在前），并在页头写清楚是按折扣排的
   ============================================================ */

/// 首页那四个频道
enum DDChannelKind: String, CaseIterable, Identifiable {
    case subsidy, rank, cheap, factory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .subsidy: return "百亿补贴"
        case .rank:    return "排行榜"
        case .cheap:   return "9.9包邮"
        case .factory: return "厂家直供"
        }
    }

    /// 页头那行小字：这一页到底按什么排的，写清楚（不糊弄）
    var sub: String {
        switch self {
        case .subsidy: return "平台补贴：按折扣力度排，省得最多的在前"
        case .rank:    return "按销量排（拼的人越多越靠前）"
        case .cheap:   return "9.9 元以内，包邮到家"
        case .factory: return "工厂发货：厂家直供 / 一件代发"
        }
    }

    var icon: String {
        switch self {
        case .subsidy: return "yensign.circle.fill"
        case .rank:    return "chart.bar.fill"
        case .cheap:   return "tag.fill"
        case .factory: return "shippingbox.fill"
        }
    }

    var tint: Color {
        switch self {
        case .subsidy: return DDColor.red
        case .rank:    return DDColor.orange
        case .cheap:   return Color(hex: 0x1CA36B)
        case .factory: return Color(hex: 0x2E6BFF)
        }
    }
}

/* 2026-10-17 用户：「百亿补贴那些位置都给管理换字换图标」——
   首页那排宫格（4 个频道 + 4 个功能）改成**管理端可配**：
   文字、图标（emoji 优先，其次 SF Symbol 名）、颜色、顺序、显示/隐藏都能改，
   改完用户重开商城就是新的，不用出包。后台没配就用下面这套内置的。 */
struct DDChannelItem: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    /// SF Symbol 名（没填 emoji 时用它）
    var icon: String?
    /// emoji（填了就优先画它）
    var emoji: String?
    /// subsidy / rank / cheap / factory（进频道页）或 orders / cart / fav / views（功能）
    var action: String?
    /// 自定颜色（#RRGGBB，空 = 用该动作的默认色）
    var tint: String?
    var on: Bool?
    var sort: Int?

    var live: Bool { on ?? true }

    /// 图标：emoji 优先 → 配置的 SF Symbol → 动作的默认图标
    var symbol: String { (icon?.isEmpty == false) ? icon! : (DDChannelKind(rawValue: action ?? "")?.icon ?? "tag.fill") }
    var emojiText: String { emoji ?? "" }
    var tintColor: Color {
        if let t = tint, t.count == 7, t.hasPrefix("#"),
           let v = UInt32(t.dropFirst(), radix: 16) { return Color(hex: v) }
        return DDChannelKind(rawValue: action ?? "")?.tint ?? DDColor.red
    }

    /// 内置那八格（后台没配时用它，保证任何情况下首页都不会空）
    static let builtin: [DDChannelItem] = [
        DDChannelItem(id: "ch1", title: "百亿补贴", icon: "yensign.circle.fill", emoji: "💰",
                      action: "subsidy", tint: nil, on: true, sort: 1),
        DDChannelItem(id: "ch2", title: "排行榜", icon: "chart.bar.fill", emoji: "🏆",
                      action: "rank", tint: nil, on: true, sort: 2),
        DDChannelItem(id: "ch3", title: "9.9包邮", icon: "tag.fill", emoji: "🏷️",
                      action: "cheap", tint: nil, on: true, sort: 3),
        DDChannelItem(id: "ch4", title: "厂家直供", icon: "shippingbox.fill", emoji: "🏭",
                      action: "factory", tint: nil, on: true, sort: 4),
        DDChannelItem(id: "fn1", title: "我的订单", icon: "doc.text", emoji: "📄",
                      action: "orders", tint: nil, on: true, sort: 5),
        DDChannelItem(id: "fn2", title: "购物车", icon: "cart", emoji: "🛒",
                      action: "cart", tint: nil, on: true, sort: 6),
        DDChannelItem(id: "fn3", title: "我的收藏", icon: "heart", emoji: "❤️",
                      action: "fav", tint: nil, on: true, sort: 7),
        DDChannelItem(id: "fn4", title: "浏览足迹", icon: "clock", emoji: "👣",
                      action: "views", tint: nil, on: true, sort: 8)
    ]
}

extension DDProduct {
    /// 省了多少（原价 - 拼单价）
    var saveMoney: Double { max(0, orig - price) }
    /// 折扣力度 0~1（越大越便宜）
    var discountRate: Double { orig > 1 ? max(0, min(1, 1 - price / orig)) : 0 }
    /// 销量（数字）：优先用 sales 字段；没有就把 sold 那串 "10万+" / "3.2万" 算出来
    var salesNum: Int {
        if let s = sales { return s }
        let t = sold.replacingOccurrences(of: "+", with: "").trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("万") { return Int((Double(String(t.dropLast())) ?? 0) * 10000) }
        return Int(t) ?? 0
    }
    /// 有没有货：至少一个规格还有库存（京东「只看有货」用）
    var inStock: Bool { specList.contains { $0.stock > 0 } }
    /// 提到的「补贴」标签（没有标签就 false）
    var hasSubsidy: Bool {
        tags.contains { $0.contains("补贴") } || title.contains("补贴")
    }
}

/* ---------------------------------------------------------- 首页频道入口 */

/* 2026-10-15 用户：「商城和京东一样插点小广告」
   京东首页就是这样：**双列瀑布流里插广告位**（左下角标「广告」）+ 楼层之间的广告条。
   我们插的全是自家内容（会员 / 百亿补贴 / 听一听），所以不坑人，也都标了「广告」。 */

/// 瀑布流里插的那种小广告卡（和商品卡一样大，左下角标「广告」）
struct DDAdCard: View {
    let emoji: String
    let title: String
    let sub: String
    let cta: String
    let top: UInt32
    let bottom: UInt32
    /// × 掉这一张时用的标识（后台广告传 "ad:<id>"；不传就用 emoji+标题）
    var adKey: String = ""
    var onTap: () -> Void

    var body: some View {
        Button { onTap() } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: [Color(hex: top), Color(hex: bottom)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(emoji).font(.system(size: 64))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text(Tr("广告"))
                        .font(pf(9.5)).foregroundColor(.white.opacity(0.92))
                        .padding(.horizontal, 5).frame(height: 15)
                        .background(Capsule().fill(Color.black.opacity(0.28)))
                        .padding(6)
                }
                .frame(height: 150)
                .clipped()
                .overlay(alignment: .topTrailing) {
                    /* 右上角那颗 ×（京东的广告位也能关掉） */
                    Button { DDStore.shared.hideAd(adKey.isEmpty ? (emoji + title) : adKey) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold)).foregroundColor(.white.opacity(0.9))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.black.opacity(0.3)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(5)
                }
                Text(Tr(title)).font(pf(14, .medium)).foregroundColor(DDColor.ink)
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(Tr(sub)).font(pf(11.5)).foregroundColor(DDColor.sub)
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(Tr(cta))
                    .font(pf(12, .medium)).foregroundColor(.white)
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Capsule().fill(Color.black.opacity(0.22)))
            }
            .padding(8)
            .background(DDColor.card)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// 楼层之间的广告条（矮一点，一行字 + 一颗按钮）
struct DDAdStrip: View {
    let emoji: String
    let title: String
    let sub: String
    let cta: String
    let top: UInt32
    let bottom: UInt32
    var onTap: () -> Void

    var body: some View {
        Button { onTap() } label: {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    LinearGradient(colors: [Color(hex: top), Color(hex: bottom)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(emoji).font(.system(size: 26)).frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text(Tr("广告")).font(pf(8.5)).foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, 4).frame(height: 13)
                        .background(Capsule().fill(Color.black.opacity(0.25)))
                        .padding(3)
                }
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(Tr(title)).font(pf(14, .medium)).foregroundColor(DDColor.ink).lineLimit(1)
                    Text(Tr(sub)).font(pf(11.5)).foregroundColor(DDColor.sub).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(Tr(cta)).font(pf(12.5, .medium)).foregroundColor(.white)
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(Capsule().fill(Color(hex: bottom)))
            }
            .padding(10)
            .background(DDColor.card)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 首页轮播图下面那一排（京东首页也是这么排的）
struct DDChannelRow: View {
    var onOpen: (DDChannelKind) -> Void
    /// 第二行那四个**常用功能**（京东那排宫格不只放频道，还放订单/购物车/收藏/足迹）
    var onFunc: (String) -> Void = { _ in }
    @ObservedObject private var store = DDStore.shared

    /// 后台配了就用后台的（按时段/开关过滤），没配就用内置那八格
    private var items: [DDChannelItem] {
        /* ⚠ 2026-10-17 用户：「9宫格卡片改了还是不生效」「那是我删掉的」——
           以前只要"过滤完是空的"就退回内置八格，所以用户**删光了**也还是看到那八格（以为没生效）。
           现在按"后台到底配过没有"分：
             · 没配过（channelsConfigured = false）→ 内置八格兜底，首页不留白
             · 配过（哪怕是空的）→ 就按后台那份来，删光了就是空的（这一排整块不画） */
        guard store.channelsConfigured else { return DDChannelItem.builtin }
        return store.channels.filter { $0.live }
    }

    var body: some View {
        /* 后台把宫格删光（配过、但是空的）→ 这一排整块不画，别留一张空白卡 */
        if items.isEmpty {
            EmptyView()
        } else {
        /* 2026-10-15 用户：「商城的主页排版不行，功能逻辑主页对齐京东」——
           京东首页是**两行 8 个宫格**：第一行频道，第二行常用功能（订单/购物车/收藏/足迹）。 */
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 0), GridItem(.flexible(), spacing: 0),
                            GridItem(.flexible(), spacing: 0), GridItem(.flexible(), spacing: 0)],
                  spacing: 12) {
            ForEach(items) { it in
                cell(item: it) {
                    if let k = DDChannelKind(rawValue: it.action ?? "") { onOpen(k) }
                    else { onFunc(it.action ?? "") }
                }
            }
        }
        .padding(.vertical, 14)
        .background(DDColor.cardGrad)
        /* 2026-10-17 用户：「商城首页的排版感觉还是不够高级」——
           宫格这张卡：圆角 14→16、留白按 8pt 网格给足（上下 14、格距 14），
           阴影换成"两层"（贴地一层 + 扩散一层），边缘的线更淡一点——
           一眼就看得出这是一块**浮起来的玻璃白卡**，不是贴了条边框的色块。 */
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(DDColor.cardEdge.opacity(0.65), lineWidth: 0.5))
        .padding(.horizontal, 16)
        }
    }

    /// 一格：图标优先画后台配的 emoji，没有就画 SF Symbol（颜色也是后台配的）
    private func cell(item: DDChannelItem, tap: @escaping () -> Void) -> some View {
        let tint = item.tintColor
        /* ⚠ 上面那句 let 之后就不能再靠"最后一句自动返回"了（Swift 只在单表达式函数里隐式返回），
           必须显式 return —— B1006 那次编译就是栽在这儿。 */
        return Button { tap() } label: {
            VStack(spacing: 7) {
                ZStack {
                    /* 图标底座：从圆改成**圆角方形**（大商城那排宫格都是方的），
                       颜色用同色系的浅渐变 + 一条几乎看不见的高光边 —— 比"一个圆"高级得多 */
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.17), tint.opacity(0.07)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 46, height: 46)
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.55), lineWidth: 0.7)
                        .frame(width: 46, height: 46)
                    if item.emojiText.isEmpty {
                        Image(systemName: item.symbol)
                            .font(.system(size: 20, weight: .medium)).foregroundColor(tint)
                    } else {
                        Text(item.emojiText).font(.system(size: 22))
                    }
                }
                Text(Tr(item.title)).font(pf(11.5, .medium)).foregroundColor(DDColor.ink)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/* ---------------------------------------------------------- 频道页 */

/// 频道页（百亿补贴 / 排行榜 / 9.9包邮 / 厂家直供）
struct DDChannelView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = DDStore.shared

    let kind: DDChannelKind
    /// 详情页里点「加购物车」→ 外面把 tab 切到购物车
    var onCart: () -> Void = { }

    @State private var openProduct: DDProduct? = nil

    private var list: [DDProduct] {
        /* 被 × 掉（不感兴趣）的不再出现在频道页里，和首页一致 */
        let all = store.feed(store.live)
        switch kind {
        case .rank:
            return all.sorted { $0.salesNum != $1.salesNum ? $0.salesNum > $1.salesNum : $0.price < $1.price }
        case .cheap:
            return all.filter { $0.price <= 9.9 }.sorted { $0.price < $1.price }
        case .factory:
            return all.filter { p in p.tags.contains { $0.contains("厂家") || $0.contains("一件代发") } }
                .sorted { $0.salesNum > $1.salesNum }
        case .subsidy:
            let tagged = all.filter { $0.hasSubsidy }
            if !tagged.isEmpty { return tagged.sorted { $0.discountRate > $1.discountRate } }
            return all.sorted { $0.discountRate != $1.discountRate
                ? $0.discountRate > $1.discountRate : $0.saveMoney > $1.saveMoney }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            head
            ScrollView(showsIndicators: false) {
                if list.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray").font(.system(size: 28)).foregroundColor(DDColor.weak)
                        Text(Tr("这一栏暂时没有商品")).font(pf(14)).foregroundColor(DDColor.sub)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 70)
                } else if kind == .rank {
                    ranked
                } else {
                    grid
                }
            }
            .background(DDColor.page)
        }
        .background(DDColor.page.ignoresSafeArea())
        .swipeBack { dismiss() }
        /* ⚠ ddLight 放最外面：侧滑返回那一层自己也有个背景（C.pageBg），
           不放外面的话深色模式下会闪一块黑 */
        .ddLight()
        .preferredColorScheme(.light)
        .sheet(item: $openProduct) { p in
            DDDetailView(product: p,
                         onCart: { openProduct = nil; onCart() },
                         onOpenOther: { openProduct = $0 })
                .environmentObject(app)
        }
    }

    private var head: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(DDColor.ink)
                        .frame(width: 34, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text(Tr(kind.title)).font(pf(17, .semibold)).foregroundColor(DDColor.ink)
                Spacer(minLength: 0)
                Text("\(list.count) " + Tr("件")).font(pf(12.5)).foregroundColor(DDColor.sub)
            }
            HStack(spacing: 6) {
                Image(systemName: kind.icon).font(.system(size: 11.5))
                Text(Tr(kind.sub)).font(pf(12)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundColor(DDColor.sub)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 9)
        .background(ddTopGradient())
        .overlay(HairLine(), alignment: .bottom)
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                  spacing: 10) {
            ForEach(list) { p in
                Button { openProduct = p } label: { DDProductCard(product: p) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 16)
    }

    private var ranked: some View {
        LazyVStack(spacing: 10) {
            ForEach(Array(list.enumerated()), id: \.element.id) { i, p in
                Button { openProduct = p } label: { rankRow(i + 1, p) }
                    .buttonStyle(.plain)
            }
            Spacer().frame(height: 16)
        }
        .padding(.vertical, 10)
    }

    private func rankRow(_ n: Int, _ p: DDProduct) -> some View {
        HStack(spacing: 10) {
            Text("\(n)")
                .font(pf(12.5, .bold)).foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(rankTint(n)))
            DDThumb(em: p.em, size: 68, radius: 10, img: p.img)
            VStack(alignment: .leading, spacing: 5) {
                Text(p.title).font(pf(13.5)).foregroundColor(DDColor.ink).lineLimit(2)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    DDPrice(value: p.price, size: 16)
                    Text("¥" + moneyFmt(p.orig))
                        .font(pf(11)).foregroundColor(DDColor.sub).strikethrough()
                }
                HStack(spacing: 6) {
                    if !p.sold.isEmpty {
                        Text(Tr("已拼") + p.sold).font(pf(11)).foregroundColor(DDColor.sub)
                    }
                    Text(p.cate).font(pf(10.5)).foregroundColor(DDColor.red)
                        .padding(.horizontal, 5).frame(height: 16)
                        .background(Capsule().fill(DDColor.redLight))
                    Spacer(minLength: 0)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(DDColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 10)
    }

    private func rankTint(_ n: Int) -> Color {
        n == 1 ? DDColor.redDeep : (n == 2 ? DDColor.orange : (n == 3 ? Color(hex: 0xF7B500) : DDColor.weak))
    }
}

/* ---------------------------------------------------------- 搜索：热搜榜 / 联想词 / 排序筛选 */

/// 热搜榜（两列带名次；词是从真商品里数出来的，不是编的）
struct DDSearchHotBoard: View {
    var words: [String]
    var onTap: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "flame.fill").font(.system(size: 12)).foregroundColor(DDColor.orange)
                Text(Tr("热搜榜")).font(pf(14.5, .semibold)).foregroundColor(DDColor.ink)
                Spacer(minLength: 0)
                Text(Tr("按商品热度")).font(pf(11.5)).foregroundColor(DDColor.sub)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                      spacing: 8) {
                ForEach(Array(words.enumerated()), id: \.element) { i, w in
                    Button { onTap(w) } label: {
                        HStack(spacing: 7) {
                            Text("\(i + 1)")
                                .font(pf(11.5, .bold))
                                .foregroundColor(i < 3 ? .white : DDColor.sub)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(i < 3 ? hotTint(i) : DDColor.page))
                            Text(w).font(pf(13)).foregroundColor(DDColor.ink).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 9).fill(DDColor.card))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func hotTint(_ i: Int) -> Color {
        i == 0 ? DDColor.redDeep : (i == 1 ? DDColor.orange : Color(hex: 0xF7B500))
    }
}

/// 输入框下面那一列联想词
struct DDSuggestList: View {
    var words: [String]
    var onTap: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(words, id: \.self) { w in
                Button { onTap(w) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13)).foregroundColor(DDColor.weak)
                        Text(w).font(pf(14)).foregroundColor(DDColor.ink).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.left")
                            .font(.system(size: 12)).foregroundColor(DDColor.weak)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                HairLine()
            }
        }
        .background(DDColor.card)
    }
}

/// 搜索结果的排序 / 筛选条（综合 · 销量 · 价格 · 只看有货）
struct DDSearchFilterBar: View {
    var sort: String
    var onlyStock: Bool
    var onSort: (String) -> Void
    var onStock: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            item(Tr("综合"), on: sort.isEmpty) { onSort("") }
            item(Tr("销量"), on: sort == "sales") { onSort(sort == "sales" ? "" : "sales") }
            item(priceText, on: sort == "priceUp" || sort == "priceDown") {
                onSort(sort == "priceUp" ? "priceDown" : (sort == "priceDown" ? "" : "priceUp"))
            }
            Button { onStock() } label: {
                HStack(spacing: 4) {
                    Image(systemName: onlyStock ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12))
                    Text(Tr("只看有货")).font(pf(12.5, onlyStock ? .medium : .regular))
                }
                .foregroundColor(onlyStock ? DDColor.red : DDColor.sub)
                .frame(maxWidth: .infinity).frame(height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(DDColor.card)
    }

    private var priceText: String {
        sort == "priceUp" ? Tr("价格↑") : (sort == "priceDown" ? Tr("价格↓") : Tr("价格"))
    }

    private func item(_ t: String, on: Bool, tap: @escaping () -> Void) -> some View {
        Button { tap() } label: {
            Text(t)
                .font(pf(12.5, on ? .semibold : .regular))
                .foregroundColor(on ? DDColor.red : DDColor.sub)
                .frame(maxWidth: .infinity).frame(height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
