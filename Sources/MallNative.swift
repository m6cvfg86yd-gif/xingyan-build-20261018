import SwiftUI

/* ============================================================
   拼多多风格「商城」——原生版（2026-10-12 从 H5 改成原生）

   以前是服务器上的 /mall/index.html，用 WKWebView 打开；用户要求改成原生的，
   现在整页是 SwiftUI，数据存在本机 JSON（Documents/dd_mall.json），
   第一次打开用内置那 16 个商品当种子（和 H5 里 SEED_PRODUCTS 一模一样的数据）。

   页面：首页（秒杀 + 分类 + 双列瀑布流）/ 推荐（种草）/ 消息 / 购物车 / 我的
        + 商品详情 + 下单（单独购买 / 发起拼单）+ 我的订单 + 收藏 + 足迹 + 搜索

   ⚠ 用户要求：这一页**不显示零钱余额**。下单就是生成一条订单记录（不扣零钱），
   订单状态在「我的 → 我的订单」里能一步步往前走（拼团中 → 待发货 → 待收货 → 已完成）。
   ============================================================ */

/* ---------------------------------------------------------- 数据 */

struct DDProduct: Identifiable, Codable, Hashable {
    var id: String
    /// 商品图：和 H5 一样用 emoji 画（不依赖服务器图片，离线也有图）
    var em: String
    /// 也可以放一张真图（管理里从相册传上来的地址）；有图就优先显示图
    var img: String? = nil
    var title: String
    /// 拼单价
    var price: Double
    /// 单独购买价（划线价）
    var orig: Double
    var sold: String
    /// 几人团
    var grp: Int
    var tags: [String]
    var shop: String
    var cate: String
    /// 是否上架（管理里可以下架；下架的只有管理看得到）
    var on: Bool? = nil

    /// 上架中
    var live: Bool { on ?? true }

    /* ---------------- 2026-10-15 对齐京东加的字段（全可空，老数据/老包都兼容） ---------------- */
    /// 副标题（京东：标题下面那行卖点）
    var subtitle: String? = nil
    var brand: String? = nil
    /// 评分 0~5（没评价就是 nil）
    var rating: Double? = nil
    /// 销量（数，比 sold 那个字符串更细）
    var sales: Int? = nil
    /// 规格（颜色/尺码/套餐），选完价格可能变
    var variants: [DDVariant]? = nil
    /// 参数表：一行是 [名称, 值]
    var params: [[String]]? = nil
    /// 图文详情的图（没有就用主图 + 生成的图文块）
    var detailImages: [String]? = nil
    /// 服务承诺
    var services: [String]? = nil
    /// 店铺 id（关注店铺用；没有就用店铺名）
    var shopId: String? = nil

    /// 店铺标识（关注/取关按它记）
    var shopKey: String { (shopId?.isEmpty == false) ? shopId! : shop }

    /// 规格列表：后台没配就按类目合成几个 —— 京东每个商品都有规格，不能让用户点了没反应
    var specList: [DDVariant] {
        if let v = variants, !v.isEmpty { return v }
        switch cate {
        case "服饰":
            return ["S", "M", "L", "XL"].map { DDVariant(name: $0, price: price, stock: 99) }
        case "运动", "母婴":
            return ["38", "40", "42", "44"].map { DDVariant(name: $0, price: price, stock: 88) }
        case "美妆", "食品":
            return [DDVariant(name: "单件装", price: price, stock: 99),
                    DDVariant(name: "3件装", price: (price * 2.7 * 100).rounded() / 100, stock: 99),
                    DDVariant(name: "整箱装", price: (price * 8.5 * 100).rounded() / 100, stock: 99)]
        default:
            return [DDVariant(name: "标准款", price: price, stock: 99),
                    DDVariant(name: "升级款", price: (price * 1.25 * 100).rounded() / 100, stock: 99)]
        }
    }

    /// 服务承诺（后台没配就给京东最常见的几句）
    var serviceList: [String] {
        if let s = services, !s.isEmpty { return s }
        return ["7天无理由退货", "退货包运费", "正品保障", "极速退款"]
    }

    /// 给服务器（/api/ops/mall）用的字典
    var dict: [String: Any] {
        ["id": id, "em": em, "img": img ?? "", "title": title,
         "price": price, "orig": orig, "sold": sold, "grp": grp,
         "tags": tags, "shop": shop, "cate": cate, "on": live]
    }
}

/// 一个规格（京东的 SKU）
struct DDVariant: Codable, Hashable, Identifiable {
    var name: String
    var price: Double
    var stock: Int
    var id: String { name }
}

struct DDCartLine: Identifiable, Codable, Hashable {
    var pid: String
    var count: Int
    var id: String { pid }
}

/// 一条订单。status：grouping 拼团中 / wait 待发货 / shipped 待收货 / done 已完成 / cancel 已取消
struct DDOrder: Identifiable, Codable, Hashable {
    var id: String
    var pid: String
    var em: String
    var title: String
    var shop: String
    var price: Double
    var count: Int
    var group: Bool
    /// 拼团要几个人
    var need: Int
    /// 已经几个人（含我自己）
    var have: Int
    var status: String
    var at: Date
    /* ---------------- 2026-10-15 对齐京东加的字段 ---------------- */
    /// 下单时选的规格
    var spec: String = ""
    /// 订单号（京东那种长号）
    var orderNo: String = ""
    /// 运费
    var freight: Double = 0
    /// 用掉的优惠券金额
    var couponOff: Double = 0
    /// 发票抬头（空 = 不开发票）
    var invoice: String = ""
    var payWay: String = ""          // 空 = 还没选，结算页会默认成星言支付（2026-10-16 去掉微信支付）
    var remark: String = ""
    /// 收货信息（下单那一刻存下来，以后改地址不影响老订单）
    var addrName: String = ""
    var addrPhone: String = ""
    var addrText: String = ""
    /// 快递公司 / 单号
    var express: String = ""
    var expressNo: String = ""
    /// 付过款的时间（待付款倒计时用）
    var paidAt: Date? = nil
    /// 评价过没有
    var reviewed: Bool = false
    /// 会员立减（星言PLUS 专享价省下来的钱）
    var memberOff: Double = 0

    /// 实付 = 单价×数量 + 运费 − 优惠券 − 会员立减
    var total: Double { max(0, price * Double(count) + freight - couponOff - memberOff) }

    /// 京东那种订单号（纯演示用，本机生成）
    static func makeNo() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMddHHmmss"
        return f.string(from: Date()) + String(Int.random(in: 100000...999999))
    }

    var statusText: String {
        switch status {
        case "paying":   return "待付款"
        case "grouping": return "拼团中"
        case "wait":     return "待发货"
        case "shipped":  return "待收货"
        case "done":     return "已完成"
        case "cancel":   return "已取消"
        default:         return status
        }
    }
    var canConfirm: Bool { status == "shipped" }
    var canCancel: Bool { status == "paying" || status == "grouping" || status == "wait" }
    var canPay: Bool { status == "paying" }
    /// 已完成、还没评价过 → 能去评价晒单
    var canReview: Bool { status == "done" && !reviewed }
    /// 待付款的剩余秒数（30 分钟）
    var payLeft: Int {
        guard status == "paying" else { return 0 }
        return max(0, 1800 - Int(Date().timeIntervalSince(at)))
    }
}

/// 商城数据（单例 + 落盘）
/// 一条**后台下发**的广告（data/mall.json 的 ads[]，后台「商城 → 广告」里写）
/* 商城开屏广告（CHRIS_MALL_SPLASH_V1，2026-10-17 用户：
   「布置下商城开屏3秒广告封面页可以跳过，给管理接上，你不要放图」）
   —— 纯机制：封面由**管理端自己传**（App 里「管理 → 商城后台 → 开屏广告」），
      没传就不显示；代码里不放任何图。 */
struct DDSplash: Codable, Equatable {
    /// 开关
    var on: Bool?
    /// 封面图（/uploads/xxx.jpg 或网址）；空 = 不显示开屏
    var image: String?
    /// 点封面去哪：none / url / product / channel
    var action: String?
    var link: String?
    /// 显示几秒（1~10，默认 3）
    var seconds: Double?
    /// 跳过按钮上的字（默认「跳过」）
    var skipText: String?

    /// 到底要不要显示：开关开着 **而且** 有封面
    var isOn: Bool { (on ?? true) && !(image ?? "").isEmpty }
    var secs: Double { min(10, max(1, seconds ?? 3)) }
    var skip: String { ((skipText ?? "").isEmpty ? "跳过" : skipText!) }
}

struct DDAd: Decodable, Identifiable, Hashable {
    var id: String
    /// grid = 插在瀑布流里的广告卡 · strip = 楼层之间的广告条
    var kind: String?
    var emoji: String?
    var title: String
    var sub: String?
    var cta: String?
    /// 两个十六进制颜色（可空 = 用默认红）
    var top: String?
    var bottom: String?
    /// vip / music / subsidy / none（none 就按 link 打开网页）
    var action: String?
    var link: String?
    var on: Bool?
    var sort: Int?
    /// 这条广告带的券（点进去会发到卡包；没有就是 nil）
    var coupon: DDAdCoupon?

    var isGrid: Bool { (kind ?? "strip") == "grid" }
    var topColor: UInt32 { UInt32((top ?? "").replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0xFFF1EA }
    var bottomColor: UInt32 { UInt32((bottom ?? "").replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0xFF5F3A }

    /// 管理侧写回服务器要的字段表（和 GET /api/mall 给的那份一一对应）
    var dict: [String: Any] {
        ["id": id,
         "kind": kind ?? "strip",
         "emoji": emoji ?? "🛍",
         "title": title,
         "sub": sub ?? "",
         "cta": cta ?? "去看看",
         "top": top ?? "",
         "bottom": bottom ?? "",
         "action": action ?? "none",
         "link": link ?? "",
         "on": on ?? true,
         "sort": sort ?? 99]
    }
}

/// 广告上挂的券（和服务器 mall.json 里 ads[].coupon 一一对应）
/// 配送方式（服务器 mall.json 的 delivery.modes；2026-10-16 用户：「配送里面不要光包邮」）
struct DDDeliveryMode: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var fee: Double
    /// 满多少免运费（0 = 不免/本来就免）
    var freeMin: Double
    var days: String?
    var note: String?
    var on: Bool?

    /// 拉不到后台配置时的兜底三档（和服务器默认那三档一致）
    static let defaults: [DDDeliveryMode] = [
        DDDeliveryMode(id: "d1", name: "普通快递", fee: 8, freeMin: 99, days: "3~5 天送达", note: "全国大部分地区", on: true),
        DDDeliveryMode(id: "d2", name: "次日达", fee: 15, freeMin: 199, days: "次日送达", note: "限城区", on: true),
        DDDeliveryMode(id: "d3", name: "到店自提", fee: 0, freeMin: 0, days: "当天可取", note: "到店出示订单号", on: true)
    ]
}

struct DDAdCoupon: Decodable, Hashable {
    var title: String?
    var off: Double?
    var min: Double?
    var days: Double?
    var kind: String?

    /// 「满 99 减 10」/「会员体验券」这种一句话
    var text: String {
        let o = off ?? 0
        if o > 0 { return Tr("满 ") + String(Int(min ?? 0)) + Tr(" 减 ") + String(Int(o)) }
        return title ?? Tr("权益券")
    }
}

@MainActor
final class DDStore: ObservableObject {
    static let shared = DDStore()

    @Published private(set) var products: [DDProduct] = []
    /// 首页轮播图（管理里可以换/加/删；服务器 data/mall.json 是真源）
    @Published private(set) var banners: [String] = []
    /// 商城名 / 标语（管理页可改；用户要求「商城名」）
    @Published private(set) var mallName: String = "星言商城"
    @Published private(set) var mallSlogan: String = "拼着买 才便宜"
    @Published private(set) var orders: [DDOrder] = []
    @Published private(set) var cart: [DDCartLine] = []
    @Published private(set) var history: [String] = []
    @Published private(set) var favs: [String] = []
    /// 看过的商品 id（最近 60 个，最新的在前）→「我的 → 浏览足迹」
    @Published private(set) var views: [String] = []
    /// 收货地址（没填就显示「还没填收货地址」）
    @Published var address: String = ""
    /* ============================================================
       跳转请求（2026-10-16 用户：「还有那些没跳转的」）

       商城里有好几条路都会"该跳但没跳"：商品页点「加入购物车」、
       订单页点「再来一单」、下单成功之后要去看订单……
       这些动作发起的地方离商城根很远（详情页是 sheet 里再套 sheet、
       聊天里那张商品卡又是另一条路），所以不在各自的地方硬跳，
       统一挂两个请求标记，**由商城根视图 MallNativeView 统一处理**：
       谁发的都能跳，而且商城还没打开时会等它下次打开再跳。
       ============================================================ */
    /// 有人要跳「购物车」
    @Published var wantCart = false
    /// 有人要跳「我的订单」
    @Published var wantOrders = false
    func jumpCart() { wantCart = true }
    func jumpOrders() { wantOrders = true }
    /// 收货地址簿（照京东：多条、可设默认、可编辑删除）——`address` 是改名之前的老字段，只用来迁移
    @Published private(set) var addresses: [DDAddress] = []
    /* ---------------- 2026-10-15 对齐京东加的数据 ---------------- */
    /// 商品评价（本机记录；确认收货后自己也能发）
    @Published private(set) var reviews: [DDReview] = []
    /// 售后单（退款 / 退货 / 换货）
    @Published private(set) var afterSales: [DDAfterSale] = []
    /// 关注的店铺
    @Published private(set) var followedShops: [String] = []
    /// 优惠券（结算时抵钱）
    @Published private(set) var coupons: [DDCoupon] = []
    /// 商城服务通知（成团 / 发货 / 签收）
    @Published private(set) var notices: [DDNotice] = []
    /// 购物车里每条选了什么规格：pid → 规格名
    @Published private(set) var cartSpec: [String: String] = [:]
    /// 发票抬头（结算页用）
    @Published var invoiceTitle: String = ""
    /// 支付方式（演示：只在订单里记一下，不真扣钱）
    /* 2026-10-16 用户：「把商城的微信支付删掉」——默认改成星言支付（名字走后台 payName） */
    @Published var payWay: String = XYPay.name
    /* ---------------- 2026-10-15 对齐京东：会员（星言 PLUS） ---------------- */
    /// 会员到期时间（nil / 已经过去 = 不是会员）
    @Published private(set) var vipUntil: Date? = nil
    /// 自动续费开关（演示：只记状态）
    @Published var vipAutoRenew = true
    /// 会员累计帮省（下单时的会员立减往这里累加）
    @Published private(set) var vipSaved: Double = 0
    /* ---------------- 2026-10-15：卡片可关 / 不感兴趣 ---------------- */
    /// 关掉的小广告 id（广告卡右上角那个 ×）
    @Published private(set) var hiddenAds: [String] = []
    /// 「不感兴趣」的商品 id（推荐流不再出现）
    @Published private(set) var disliked: [String] = []
    /// 「不感兴趣」的类目（少推荐这一类）
    @Published private(set) var mutedCates: [String] = []
    /// 后台下发的广告（空 = 用 App 内置那两条）
    @Published private(set) var ads: [DDAd] = []
    /// 开屏广告（CHRIS_MALL_SPLASH_V1）：管理端配的，没配就是空的
    @Published private(set) var splash = DDSplash()
    /// 首页宫格（管理端可换字换图标）—— 空 = 用内置那八格
    @Published private(set) var channels: [DDChannelItem] = []
    /// 首页宫格"后台到底配过没有"：false = 从没配过（首页用内置八格兜底）；
    /// true = 后台有一份（哪怕是空的 —— 用户自己删光了就该是空的）。
    /// 2026-10-17 用户：「9宫格卡片改了还是不生效 / 那是我删掉的」。
    @Published private(set) var channelsConfigured = false
    /// 管理页要看**全部**广告（含关掉的）；商城那边只显示开着的（ads）
    @Published private(set) var allAds: [DDAd] = []
    /* ---- 商城底栏的红点（2026-10-16 用户：「商城里底栏要有红点」「购物车啥的也要有」）----
       mallNewCoupons：上次看过之后又到账的券（「消息」那颗亮这个，点开就清）
       mallClaimable ：还有几条广告的券没领（「首页 / 推荐」亮这个，领完自动灭） */
    @Published private(set) var mallNewCoupons = 0
    @Published private(set) var mallClaimable = 0
    /// 钱包里的银行卡（结算页「银行卡」那个支付方式要用的：有卡显示尾号，没卡显示"添加银行卡"）
    @Published private(set) var banks: [API.WalletBankCard] = []
    /* ---- 配送方式（2026-10-16「配送里面不要光包邮」）---- */
    @Published private(set) var deliveryModes: [DDDeliveryMode] = DDDeliveryMode.defaults
    @Published var deliveryModeId: String = DDDeliveryMode.defaults.first?.id ?? ""

    var deliveryMode: DDDeliveryMode? {
        deliveryModes.first { $0.id == deliveryModeId } ?? deliveryModes.first
    }
    /// 这一单要多少运费（满额免运费按**商品金额**算）
    func deliveryFee(_ goods: Double) -> Double {
        guard let m = deliveryMode else { return 0 }
        if m.freeMin > 0 && goods >= m.freeMin { return 0 }
        return m.fee
    }
    func applyDelivery(_ list: [DDDeliveryMode]) {
        let live = list.filter { $0.on != false }
        guard !live.isEmpty else { return }
        deliveryModes = live
        if !live.contains(where: { $0.id == deliveryModeId }) { deliveryModeId = live[0].id }
    }

    /// 会员折扣：下单按 95 折算会员价（京东 PLUS 是专享价，这里统一一个系数，能算也能看见）
    static let vipRate = 0.95

    var isVip: Bool {
        guard let d = vipUntil else { return false }
        return d > Date()
    }

    /// 会员还剩几天（不是会员 = 0）
    var vipDaysLeft: Int {
        guard isVip, let d = vipUntil else { return 0 }
        return max(0, Int(ceil(d.timeIntervalSinceNow / 86400)))
    }

    /// 会员到期那天（写成人话）
    var vipUntilText: String {
        guard let d = vipUntil else { return "" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// 会员价 = 拼单价 × 折扣（不是会员就是原价）
    func vipPrice(_ p: DDProduct) -> Double {
        isVip ? ((p.price * DDStore.vipRate * 100).rounded() / 100) : p.price
    }

    /// 这一单会员立减多少（不是会员 = 0）
    func vipOff(_ amount: Double) -> Double {
        isVip ? ((amount * (1 - DDStore.vipRate) * 100).rounded() / 100) : 0
    }

    /// 开通 / 续费：months 个月（演示：不真扣钱，只把到期时间往后推）
    func openVip(months: Int) {
        let base = max(Date(), vipUntil ?? Date())
        vipUntil = Calendar.current.date(byAdding: .month, value: max(1, months), to: base) ?? base
        vipAutoRenew = true
        save()
    }

    func setVipAutoRenew(_ on: Bool) {
        vipAutoRenew = on
        save()
    }

    private struct Box: Codable {
        var products: [DDProduct]
        var orders: [DDOrder]
        var cart: [DDCartLine]
        var history: [String]
        var favs: [String]
        var address: String
        /// 老缓存里没有这个字段（Optional 才不会解码失败）
        var banners: [String]?
        /// 同上：浏览足迹（老缓存里没有）
        var views: [String]?
        /// 同上：地址簿（老缓存里没有）
        var addresses: [DDAddress]?
        var reviews: [DDReview]?
        var afterSales: [DDAfterSale]?
        var followedShops: [String]?
        var coupons: [DDCoupon]?
        var notices: [DDNotice]?
        var cartSpec: [String: String]?
        var invoiceTitle: String?
        var payWay: String?
        /// 会员（老缓存里没有这几个字段）
        var vipUntil: Date?
        var vipAutoRenew: Bool?
        var vipSaved: Double?
        var hiddenAds: [String]?
        var disliked: [String]?
        var mutedCates: [String]?
        /// 开屏广告配置也存一份（老缓存里没有这个字段）
        /// 2026-10-17：不存的话，App 冷启动后 store 里是空的，得等一次成功的
        /// /api/mall 才有 —— 那期间进商城就没有开屏（用户报的「开屏广告又没了」）。
        var splash: DDSplash?
    }

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("dd_mall.json")
    }

    private init() {
        if let d = try? Data(contentsOf: fileURL),
           let b = try? JSONDecoder().decode(Box.self, from: d) {
            products = b.products
            orders = b.orders
            cart = b.cart
            history = b.history
            favs = b.favs
            address = b.address
            banners = b.banners ?? []
            views = b.views ?? []
            addresses = b.addresses ?? []
            reviews = b.reviews ?? []
            afterSales = b.afterSales ?? []
            followedShops = b.followedShops ?? []
            coupons = b.coupons ?? []
            notices = b.notices ?? []
            cartSpec = b.cartSpec ?? [:]
            invoiceTitle = b.invoiceTitle ?? ""
            /* 老存档里存的可能是「微信支付」：读回来直接迁到星言支付，不让它再出现在界面上 */
            let savedWay = b.payWay ?? ""
            payWay = (savedWay.isEmpty || savedWay == "微信支付") ? XYPay.name : savedWay
            vipUntil = b.vipUntil
            vipAutoRenew = b.vipAutoRenew ?? true
            vipSaved = b.vipSaved ?? 0
            hiddenAds = b.hiddenAds ?? []
            disliked = b.disliked ?? []
            mutedCates = b.mutedCates ?? []
            splash = b.splash ?? DDSplash()      // 开屏广告：冷启动也先用手上这份
        }
        if products.isEmpty { products = DDStore.seeds }
        /* 老版本只有一个 address 字符串：升级上来时把它变成地址簿里的第一条，别让用户白填过 */
        if addresses.isEmpty, !address.isEmpty {
            addresses = [DDAddress(id: "a" + String(Int(Date().timeIntervalSince1970 * 1000)),
                                   name: "", phone: "", region: "", detail: address, isDefault: true)]
        }
    }

    private func save() {
        let b = Box(products: products, orders: orders, cart: cart,
                    history: history, favs: favs, address: address, banners: banners,
                    views: views, addresses: addresses,
                    reviews: reviews, afterSales: afterSales, followedShops: followedShops,
                    coupons: coupons, notices: notices, cartSpec: cartSpec,
                    invoiceTitle: invoiceTitle, payWay: payWay,
                    vipUntil: vipUntil, vipAutoRenew: vipAutoRenew, vipSaved: vipSaved,
                    hiddenAds: hiddenAds, disliked: disliked, mutedCates: mutedCates,
                    splash: splash)
        if let d = try? JSONEncoder().encode(b) { try? d.write(to: fileURL) }
    }

    /* ---------------- 和管理端同步（服务器 data/mall.json 是真源） ---------------- */

    /// 上架中的商品（商城首页/搜索只显示这些；管理页看得到全部）
    var live: [DDProduct] { products.filter { $0.live } }

    /* ---------------- 2026-10-15 用户：「拼单功能先关闭，可以后台开启」 ----------------
       后台 ui.json 里写 `mallGroup = 1` 就打开拼单；**默认 0 = 关**。
       关掉之后就是京东那种「直接买」：
         · 商品详情底部只剩「加入购物车 / 立即购买」（不再 单独购买 vs 发起拼单）
         · 结算页不再选拼单方式，直接按这个价结算
         · 订单里不再出现「拼团中 / 邀好友拼单 / 拼单消息」（老订单里的拼团中还在，只是不再新增） */
    static var groupOn: Bool { UIConfig.num("mallGroup", 0) > 0 }

    /// 从服务器拉一份（进商城、管理里改完、下拉刷新都走它）
    func refresh() async {
        let r = await API.shared.mallData()
        /* 2026-10-17 用户：「商城的开屏广告显示不出来」→ 后来又说「开屏广告又没了」——
           病根在这儿：`/api/mall` 没拉回来的时候，返回值全都是空的，
           而下面每一条都是**无条件覆盖** —— 于是轮播图被清成空、广告位被清成空、
           开屏配置被清成空（`splash = sp ?? DDSplash()`）。用户看到的就是
           "进商城好好的，过一会儿开屏广告又没了 / 轮播图也不动了"。
           现在：**拉失败（ok=false）整份原样保留**，什么都不覆盖；
           只有真拉到了才按后台那份走（后台真把某项清空 = 就清空，语义是对的）。 */
        guard r.ok else { return }
        if !r.products.isEmpty { products = r.products }
        banners = r.banners
        if !r.name.isEmpty { mallName = r.name }
        if !r.slogan.isEmpty { mallSlogan = r.slogan }
        ads = r.ads.filter { $0.on != false }.sorted { ($0.sort ?? 99) < ($1.sort ?? 99) }
        allAds = r.ads.sorted { ($0.sort ?? 99) < ($1.sort ?? 99) }
        applyDelivery(r.delivery)
        splash = r.splash ?? DDSplash()
        /* 后台"没配过"（nil）→ 保持 channelsConfigured = false，首页那排用内置八格兜底；
           "配了但删空了"（[]）→ channelsConfigured = true，那排就是空的（不再被兜底顶回来）。
           2026-10-17 用户：「那是我删掉的」——删光之后要真是空的才算生效。 */
        if let chs = r.channels {
            channels = chs.sorted { ($0.sort ?? 99) < ($1.sort ?? 99) }
            channelsConfigured = true
        }
        save()
    }

    /// 管理侧：首页宫格（换字 / 换图标 / 换颜色 / 改顺序 / 隐藏）
    /// 返回**服务器到底收没收到** —— 以前这里把结果丢掉、界面照样提示"已保存"，
    /// 用户看到的却是"改了没生效"（2026-10-17 报的就是这个）。
    @discardableResult
    func opsSetChannels(_ list: [DDChannelItem]) async -> Bool {
        let ok = await API.shared.opsMall(["action": "channels", "channels": list.map { c in
            ["id": c.id, "title": c.title, "icon": c.icon ?? "", "emoji": c.emoji ?? "",
             "action": c.action ?? "subsidy", "tint": c.tint ?? "",
             "on": c.on ?? true, "sort": c.sort ?? 0]
        }])
        await refresh()
        return ok
    }

    /// 管理侧：开屏广告（封面自己传，App 打开商城时 3 秒可跳过）
    func opsSetSplash(_ s: DDSplash) async {
        _ = await API.shared.opsMall(["action": "splash", "splash": [
            "on": s.on ?? true,
            "image": s.image ?? "",
            "action": s.action ?? "none",
            "link": s.link ?? "",
            "seconds": s.seconds ?? 3,
            "skipText": s.skipText ?? "跳过"
        ]])
        await refresh()
    }

    /// 管理侧：改商城名 + 标语
    func opsSetName(_ name: String, _ slogan: String) async {
        _ = await API.shared.opsMall(["action": "settings", "name": name, "slogan": slogan])
        await refresh()
    }

    /// 管理侧：新增或改一件商品
    func opsSave(_ p: DDProduct) async {
        _ = await API.shared.opsMall(["action": "product", "item": p.dict])
        await refresh()
    }

    /// 管理侧：删一件商品
    func opsRemove(_ id: String) async {
        _ = await API.shared.opsMall(["action": "remove", "id": id])
        await refresh()
    }

    /// 管理侧：整份换轮播图
    func opsBanners(_ urls: [String]) async {
        _ = await API.shared.opsMall(["action": "banners", "banners": urls])
        await refresh()
    }

    /// 管理侧：整份换广告位（商城首页那些小广告）
    func opsAds(_ list: [DDAd]) async {
        _ = await API.shared.opsMall(["action": "ads", "ads": list.map { $0.dict }])
        await refresh()
    }

    /* ---------------- 券 + 底栏红点 ---------------- */

    /// 拉一次「我的券」和两个红点计数（进商城、回到前台、领完券都调它）
    func refreshMallBadges() async {
        guard let r = await API.shared.mallAdMine() else { return }
        mallNewCoupons = r.newCount ?? 0
        mallClaimable = r.claimableCount ?? (r.claimable?.count ?? 0)
        /* 服务端的券也并进本地这一份，结算页「优惠券」那一行才选得到 */
        mergeServerCoupons(r.coupons ?? [])
        /* 银行卡也顺手拉一下（结算页要显示尾号 / 添加银行卡） */
        banks = (try? await API.shared.walletBanks()) ?? banks
    }

    /// 结算页「银行卡」那一行显示什么（没绑卡就是"添加银行卡"）
    var bankPayText: String {
        guard let b = banks.first else { return Tr("添加银行卡") }
        let tail = b.tail ?? ""
        return tail.isEmpty ? Tr("银行卡") : (Tr("银行卡（尾号 ") + tail + ")")
    }

    /// 打开商城「消息」→ 清掉那颗红点
    func markMallSeen() {
        guard mallNewCoupons > 0 else { return }
        mallNewCoupons = 0
        Task { await API.shared.mallAdSeen() }
    }

    /// 点广告领券：领到了就顺手把本地红点状态刷新一下
    @discardableResult
    func claimAdCoupon(_ adId: String) async -> API.MallAdClaim? {
        let r = await API.shared.mallAdClaim(adId: adId)
        await refreshMallBadges()
        return r
    }

    /// 把服务端发的券并进本地券包（按 id 去重；本地自己造的券保留）
    private func mergeServerCoupons(_ list: [API.MallCoupon]) {
        let fmt = ISO8601DateFormatter()
        for c in list where !coupons.contains(where: { $0.id == c.id }) {
            let until = fmt.date(from: c.until ?? "") ?? Date().addingTimeInterval(7 * 86400)
            coupons.append(DDCoupon(id: c.id, title: c.title, off: c.off, min: c.min,
                                    until: until, used: c.used ?? false))
        }
    }

    func product(_ id: String) -> DDProduct? { products.first { $0.id == id } }

    /* ---------------- 购物车 ---------------- */

    var cartCount: Int { cart.reduce(0) { $0 + $1.count } }
    var cartTotal: Double {
        cart.reduce(0) { sum, line in
            sum + (product(line.pid)?.price ?? 0) * Double(line.count)
        }
    }

    func addCart(_ pid: String, count: Int = 1) {
        if let i = cart.firstIndex(where: { $0.pid == pid }) {
            cart[i].count += count
        } else {
            cart.append(DDCartLine(pid: pid, count: count))
        }
        /* 第一次加这个商品时，默认选第一个规格（京东加购就带规格） */
        if cartSpec[pid] == nil, let p = product(pid) { cartSpec[pid] = p.specList.first?.name ?? "" }
        save()
    }

    func setCount(_ pid: String, _ n: Int) {
        guard let i = cart.firstIndex(where: { $0.pid == pid }) else { return }
        if n <= 0 { cart.remove(at: i) } else { cart[i].count = n }
        save()
    }

    func clearCart() { cart.removeAll(); save() }

    /* ---------------- 订单 ---------------- */

    var groupingCount: Int { orders.filter { $0.status == "grouping" }.count }

    @discardableResult
    func place(pid: String, count: Int, group: Bool, fromCart: Bool = false,
               spec: String = "", address: DDAddress? = nil, remark: String = "",
               freight: Double = 0, couponOff: Double = 0, invoice: String = "",
               memberOff: Double = 0,
               payWay: String = XYPay.name, paying: Bool = true) -> DDOrder {
        let p = product(pid)
        /* 选了规格就按规格价 */
        var unit = group ? (p?.price ?? 0) : (p?.orig ?? p?.price ?? 0)
        if let v = p?.specList.first(where: { $0.name == spec }) { unit = v.price }
        /* 会员：按会员价成交（不是会员时 vipOff 返回 0） */
        let vipOff = memberOff > 0 ? memberOff : self.vipOff(unit * Double(max(1, count)))
        if vipOff > 0 { vipSaved += vipOff }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let o = DDOrder(id: "dd" + String(now) + String(Int.random(in: 100...999)),
                        pid: pid,
                        em: p?.em ?? "📦",
                        title: p?.title ?? "商品",
                        shop: p?.shop ?? "",
                        price: unit,
                        count: max(1, count),
                        group: group,
                        need: max(2, p?.grp ?? 2),
                        have: group ? 1 : 0,
                        status: paying ? "paying" : (group ? "grouping" : "wait"),
                        at: Date(),
                        spec: spec,
                        orderNo: DDOrder.makeNo(),
                        freight: freight,
                        couponOff: couponOff,
                        invoice: invoice,
                        payWay: payWay,
                        remark: remark,
                        addrName: address?.name ?? "",
                        addrPhone: address?.phone ?? "",
                        addrText: address?.full ?? "",
                        memberOff: vipOff)
        orders.insert(o, at: 0)
        if fromCart { cart.removeAll { $0.pid == pid } }
        /* 2026-10-16：订单**同步一份到服务器** —— 后台才能看到并发货（发货后用户端能看到真实快递轨迹）。
           带推广码的（本机存着 chris.mall.ref，来自好友助力）一起带上，这一单就记在那个分销员名下。 */
        Task {
            let ref = UserDefaults.standard.string(forKey: "chris.mall.ref") ?? ""
            let total = max(0, o.price * Double(o.count) + o.freight - o.couponOff - o.memberOff)
            _ = await API.shared.mallOrderSync(
                id: o.id,
                items: [["title": o.title, "price": o.price, "count": o.count, "img": ""]],
                total: total,
                payWay: o.payWay,
                address: (o.addrName + " " + o.addrPhone + " " + o.addrText).trimmingCharacters(in: .whitespaces),
                at: ISO8601DateFormatter().string(from: o.at),
                remark: o.remark,
                ref: ref,
                /* 2026-10-16 支付宝：这一单**还没付**，别让后台当成已付款（对账要用这个状态） */
                paid: (o.payWay != AliPay.name))
        }
        pushNotice(DDNotice(id: "n" + String(now), title: "订单已提交",
                            body: "「" + o.title + "」等你付款，30 分钟未付会自动取消",
                            at: Date(), kind: "order"))
        save()
        return o
    }

    /// 付款（演示：不真扣钱，只把状态推进）
    func pay(_ id: String) {
        guard let i = orders.firstIndex(where: { $0.id == id }) else { return }
        guard orders[i].status == "paying" else { return }
        orders[i].paidAt = Date()
        orders[i].status = orders[i].group ? "grouping" : "wait"
        pushNotice(DDNotice(id: "n" + String(Int(Date().timeIntervalSince1970 * 1000)),
                            title: "付款成功",
                            body: orders[i].group ? "拼单已发起，人满就发货" : "商家正在打包，48 小时内发货",
                            at: Date(), kind: "order"))
        save()
    }

    /* ---------------- 支付宝（2026-10-16） ----------------
       支付宝是**一次付款对一个订单号** —— 购物车勾了好几件的话，
       合成一个订单号再去付，回调回来才对得上、对账也干净。 */
    @discardableResult
    func placeCombined(lines: [(pid: String, count: Int)], address: DDAddress?, payWay: String) -> DDOrder? {
        let picked = lines.compactMap { l -> (DDProduct, Int)? in
            guard let p = product(l.pid) else { return nil }
            return (p, max(1, l.count))
        }
        guard let first = picked.first else { return nil }
        var sum: Double = 0
        for (p, c) in picked { sum += p.price * Double(c) }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let o = DDOrder(id: "dd" + String(now) + String(Int.random(in: 100...999)),
                        pid: first.0.id,
                        em: first.0.em,
                        title: picked.count > 1
                            ? (Tr("合并付款 ") + String(picked.count) + Tr(" 件商品"))
                            : first.0.title,
                        shop: first.0.shop,
                        price: sum,
                        count: 1,
                        group: false,
                        need: 2,
                        have: 0,
                        status: "paying",
                        at: Date(),
                        spec: "",
                        orderNo: DDOrder.makeNo(),
                        freight: 0,
                        couponOff: 0,
                        invoice: "",
                        payWay: payWay,
                        remark: "",
                        addrName: address?.name ?? "",
                        addrPhone: address?.phone ?? "",
                        addrText: address?.full ?? "",
                        memberOff: 0)
        orders.insert(o, at: 0)
        for (p, _) in picked { cart.removeAll { $0.pid == p.id } }
        pushNotice(DDNotice(id: "n" + String(now), title: "订单已提交",
                            body: "「" + o.title + "」等你付款，30 分钟未付会自动取消",
                            at: Date(), kind: "order"))
        save()
        return o
    }

    /// 把这一单同步到服务器（支付宝签名要用服务端那份订单）
    @discardableResult
    func syncToServer(_ o: DDOrder, paid: Bool) async -> Bool {
        let ref = UserDefaults.standard.string(forKey: "chris.mall.ref") ?? ""
        return await API.shared.mallOrderSync(
            id: o.id,
            items: [["title": o.title, "price": o.price, "count": o.count, "img": ""]],
            total: o.total,
            payWay: o.payWay,
            address: (o.addrName + " " + o.addrPhone + " " + o.addrText).trimmingCharacters(in: .whitespaces),
            at: ISO8601DateFormatter().string(from: o.at),
            remark: o.remark,
            ref: ref,
            paid: paid)
    }

    /// 邀请好友拼单：直接把人数凑满 → 成团，状态进「待发货」
    func invite(_ id: String) {
        guard let i = orders.firstIndex(where: { $0.id == id }) else { return }
        orders[i].have = orders[i].need
        orders[i].status = "wait"
        /* 成团也推一条服务通知（消息 tab 里能看到 —— 对齐京东） */
        pushNotice(DDNotice(id: "n" + String(Int(Date().timeIntervalSince1970 * 1000)),
                            title: "拼单成功",
                            body: "「" + orders[i].title + "」已成团，商家马上打包发货",
                            at: Date(), kind: "group"))
        save()
    }

    func cancelOrder(_ id: String) {
        guard let i = orders.firstIndex(where: { $0.id == id }) else { return }
        orders[i].status = "cancel"
        save()
    }

    func ship(_ id: String) {
        guard let i = orders.firstIndex(where: { $0.id == id }) else { return }
        if orders[i].status == "wait" {
            orders[i].status = "shipped"
            /* 发货就给个快递公司和单号（京东发货后能看物流） */
            let kuaidi = ["顺丰速运", "中通快递", "圆通速递", "韵达快递"]
            orders[i].express = kuaidi[Int.random(in: 0..<kuaidi.count)]
            orders[i].expressNo = "SF" + String(Int(Date().timeIntervalSince1970)) + String(Int.random(in: 100...999))
            pushNotice(DDNotice(id: "n" + String(Int(Date().timeIntervalSince1970 * 1000)),
                                title: "包裹已发出",
                                body: orders[i].express + "：" + orders[i].expressNo,
                                at: Date(), kind: "ship"))
            save()
        }
    }

    func confirm(_ id: String) {
        guard let i = orders.firstIndex(where: { $0.id == id }) else { return }
        orders[i].status = "done"
        pushNotice(DDNotice(id: "n" + String(Int(Date().timeIntervalSince1970 * 1000)),
                            title: "交易完成", body: "去给「" + orders[i].title + "」写个评价吧",
                            at: Date(), kind: "done"))
        save()
    }

    func markReviewed(_ orderId: String) {
        guard let i = orders.firstIndex(where: { $0.id == orderId }) else { return }
        orders[i].reviewed = true
        pushNotice(DDNotice(id: "n" + String(Int(Date().timeIntervalSince1970 * 1000)),
                            title: "评价成功", body: "感谢你的评价", at: Date(), kind: "review"))
        save()
    }

    func removeOrder(_ id: String) {
        orders.removeAll { $0.id == id }
        save()
    }

    /* ---------------- 收藏 / 足迹 ---------------- */

    func isFav(_ pid: String) -> Bool { favs.contains(pid) }

    func toggleFav(_ pid: String) {
        if let i = favs.firstIndex(of: pid) { favs.remove(at: i) } else { favs.insert(pid, at: 0) }
        save()
    }

    func pushHistory(_ q: String) {
        let s = q.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        history.removeAll { $0 == s }
        history.insert(s, at: 0)
        if history.count > 12 { history = Array(history.prefix(12)) }
        save()
    }

    func clearHistory() { history.removeAll(); save() }

    /* ---------------- 浏览足迹 ---------------- */

    /// 记一条浏览足迹（点开商品详情时调）：同一个商品只留最近一次
    func recordView(_ pid: String) {
        guard !pid.isEmpty else { return }
        views.removeAll { $0 == pid }
        views.insert(pid, at: 0)
        if views.count > 60 { views = Array(views.prefix(60)) }
        save()
    }

    /// 足迹 → 商品（被下架/删掉的自动跳过，不会显示成空白卡）
    var viewed: [DDProduct] { views.compactMap { product($0) } }

    func clearViews() { views.removeAll(); save() }

    func setAddress(_ s: String) { address = s; save() }

    /* ---------------- 收货地址簿（照京东那套） ---------------- */

    /// 默认地址（没设默认就用第一条）
    var defaultAddress: DDAddress? {
        addresses.first { $0.isDefault } ?? addresses.first
    }

    /// 地址簿里有没有「信息不全」的（姓名或手机号空着）——下单前提醒一下
    var hasCompleteAddress: Bool {
        guard let a = defaultAddress else { return false }
        return !a.name.isEmpty && a.phone.count >= 6
    }

    /// 收货地址那一行的副标题（下单页 / 我的 都用它）
    var addressLine: String {
        guard let a = defaultAddress else { return "" }
        return a.region + a.detail
    }

    private func normalizeDefault(_ keep: String = "") {
        if addresses.isEmpty { return }
        /* 只允许一个默认：优先 keep，其次原来标了默认的，再次第一条 */
        if !keep.isEmpty, let i = addresses.firstIndex(where: { $0.id == keep }) {
            for k in addresses.indices { addresses[k].isDefault = (k == i) }
            return
        }
        if addresses.contains(where: { $0.isDefault }) {
            var seen = false
            for k in addresses.indices {
                if addresses[k].isDefault {
                    if seen { addresses[k].isDefault = false } else { seen = true }
                }
            }
        } else {
            addresses[0].isDefault = true
        }
    }

    /// 新增一条（京东：新地址默认「设为默认」开关打开时才抢默认）
    func addAddress(_ a: DDAddress) {
        var x = a
        if x.id.isEmpty { x.id = "a" + String(Int(Date().timeIntervalSince1970 * 1000)) }
        if addresses.isEmpty { x.isDefault = true }
        if x.isDefault { for k in addresses.indices { addresses[k].isDefault = false } }
        addresses.append(x)
        normalizeDefault(x.isDefault ? x.id : "")
        save()
    }

    func updateAddress(_ a: DDAddress) {
        guard let i = addresses.firstIndex(where: { $0.id == a.id }) else { return }
        if a.isDefault { for k in addresses.indices { addresses[k].isDefault = false } }
        addresses[i] = a
        normalizeDefault(a.isDefault ? a.id : "")
        save()
    }

    func removeAddress(_ id: String) {
        addresses.removeAll { $0.id == id }
        normalizeDefault()
        save()
    }

    func setDefaultAddress(_ id: String) {
        normalizeDefault(id)
        save()
    }

    /* ---------------- 评价（对齐京东） ---------------- */

    /// 本机发的评价 + 每个商品自带的几条示例评价（确定性生成，不随机跳）
    func reviews(of p: DDProduct) -> [DDReview] {
        let mine = reviews.filter { $0.pid == p.id }
        return (mine + DDReview.samples(for: p)).sorted { $0.at > $1.at }
    }

    /// 平均分（没评价就 nil，界面显示"暂无评价"）
    func rating(of p: DDProduct) -> Double? {
        let list = reviews(of: p)
        guard !list.isEmpty else { return nil }
        return list.reduce(0.0) { $0 + Double($1.rating) } / Double(list.count)
    }

    func addReview(_ r: DDReview) {
        reviews.insert(r, at: 0)
        pushNotice(DDNotice(id: "n" + String(Int(Date().timeIntervalSince1970 * 1000)),
                            title: "评价成功", body: "你对「" + r.title + "」的评价已经发布",
                            at: Date(), kind: "review"))
        save()
    }

    /* ---------------- 售后（退款/退货/换货） ---------------- */

    func addAfterSale(_ a: DDAfterSale) {
        afterSales.insert(a, at: 0)
        pushNotice(DDNotice(id: "n" + String(Int(Date().timeIntervalSince1970 * 1000)),
                            title: "售后已提交", body: a.kind + "申请已提交，商家会在 24 小时内处理",
                            at: Date(), kind: "aftersale"))
        save()
    }

    func afterSales(of orderId: String) -> [DDAfterSale] { afterSales.filter { $0.orderId == orderId } }

    func cancelAfterSale(_ id: String) {
        afterSales.removeAll { $0.id == id }
        save()
    }

    /* ---------------- 关注的店铺 ---------------- */

    func isFollowed(_ key: String) -> Bool { followedShops.contains(key) }

    func toggleFollow(_ key: String) {
        guard !key.isEmpty else { return }
        if let i = followedShops.firstIndex(of: key) { followedShops.remove(at: i) }
        else { followedShops.insert(key, at: 0) }
        save()
    }

    /// 关注过的店铺 → 商品列表（去重）
    var followedProducts: [DDProduct] {
        var out: [DDProduct] = []
        for p in products where followedShops.contains(p.shopKey) && !out.contains(where: { $0.id == p.id }) {
            out.append(p)
        }
        return out
    }

    /* ---------------- 优惠券 ---------------- */

    /// 这张券现在能不能用在 total 上
    func couponUsable(_ c: DDCoupon, total: Double) -> Bool {
        !c.used && Date() < c.until && total >= c.min
    }
    func usableCoupons(_ total: Double) -> [DDCoupon] {
        coupons.filter { couponUsable($0, total: total) }.sorted { $0.off > $1.off }
    }
    func useCoupon(_ id: String) {
        guard let i = coupons.firstIndex(where: { $0.id == id }) else { return }
        coupons[i].used = true
        save()
    }
    /// 第一次打开商城送两张（京东新客券那套）
    func seedCouponsIfNeeded() {
        guard coupons.isEmpty else { return }
        let now = Date()
        coupons = [
            DDCoupon(id: "c5", title: "满 20 减 5", off: 5, min: 20, until: now.addingTimeInterval(30 * 86400), used: false),
            DDCoupon(id: "c12", title: "满 50 减 12", off: 12, min: 50, until: now.addingTimeInterval(30 * 86400), used: false)
        ]
        save()
    }

    /* ---------------- 服务通知 ---------------- */

    func pushNotice(_ n: DDNotice) {
        notices.insert(n, at: 0)
        if notices.count > 60 { notices = Array(notices.prefix(60)) }
    }
    func clearNotices() { notices.removeAll(); save() }

    /// 删掉一条服务通知（消息 tab 里左滑删除用）
    func removeNotice(_ id: String) {
        notices.removeAll { $0.id == id }
        save()
    }

    /* ---------------- 卡片可关 / 不感兴趣（2026-10-15 用户要求） ---------------- */

    /// 广告被 × 掉了（记下来，以后不再出现）
    func hideAd(_ id: String) {
        guard !hiddenAds.contains(id) else { return }
        hiddenAds.append(id)
        save()
    }
    func adHidden(_ id: String) -> Bool { hiddenAds.contains(id) }

    /// 长按商品 →「不感兴趣」：这件商品不再推，同时**少推这一类**
    func notInterested(_ p: DDProduct, muteCate: Bool) {
        if !disliked.contains(p.id) { disliked.append(p.id) }
        if muteCate, !p.cate.isEmpty, !mutedCates.contains(p.cate) { mutedCates.append(p.cate) }
        save()
    }
    /// 恢复（把「少推这一类」撤掉）
    func unmuteCate(_ c: String) {
        mutedCates.removeAll { $0 == c }
        save()
    }

    /* ---------------- 恢复（2026-10-16 用户：「客户把商品都 x 了没有恢复吗」） ----------------
       以前只有「少推的类目」能恢复，而且只能一条一条从首页那条提示里点；
       商品和广告被 × 掉之后没有任何入口能找回来。这里补齐： */
    func restoreDisliked(_ id: String) {
        disliked.removeAll { $0 == id }
        save()
    }
    func restoreAllDisliked() {
        disliked.removeAll()
        mutedCates.removeAll()
        save()
    }
    func unhideAd(_ id: String) {
        hiddenAds.removeAll { $0 == id }
        save()
    }
    func unhideAllAds() {
        hiddenAds.removeAll()
        save()
    }
    /// 被 × 掉的商品（拿得到商品的显示出来，商品下架的也能按 id 列出来）
    var dislikedProducts: [DDProduct] { products.filter { disliked.contains($0.id) } }
    /// 推荐流用的「干净列表」：去掉不感兴趣的；被打过「少推」的类目排到最后
    func feed(_ list: [DDProduct]) -> [DDProduct] {
        let kept = list.filter { !disliked.contains($0.id) }
        let sorted = kept.sorted { a, b in
            let ma = mutedCates.contains(a.cate) ? 1 : 0
            let mb = mutedCates.contains(b.cate) ? 1 : 0
            return ma < mb
        }
        /* ⚠ 2026-10-16 用户：「现在商城什么东西都没了」——
           病根：把商品一个个「不感兴趣」之后，这里会把它们**全部**滤掉，
           商城就成了空白页（没有恢复入口的老版本更是死路）。
           兜底：如果滤完一个都不剩，就退回全量（照样按"少推类目沉底"排），
           商城永远有东西可看；想彻底不看的，去「我的 → 不感兴趣与隐藏」里管。 */
        if sorted.isEmpty && !list.isEmpty {
            return list.sorted { a, b in
                let ma = mutedCates.contains(a.cate) ? 1 : 0
                let mb = mutedCates.contains(b.cate) ? 1 : 0
                return ma < mb
            }
        }
        return sorted
    }

    /* ---------------- 购物车（店铺分组 / 失效 / 规格） ---------------- */

    func cartSpecOf(_ pid: String) -> String { cartSpec[pid] ?? "" }
    func setCartSpec(_ pid: String, _ spec: String) { cartSpec[pid] = spec; save() }

    /// 失效条目：商品被删了或下架了
    var invalidCart: [DDCartLine] {
        cart.filter { l in
            guard let p = product(l.pid) else { return true }
            return !p.live
        }
    }
    /// 有效的条目
    var validCart: [DDCartLine] {
        cart.filter { l in (product(l.pid)?.live ?? false) }
    }
    /// 按店铺分组（京东购物车就是一店一卡片）
    func cartGrouped() -> [(shop: String, lines: [DDCartLine])] {
        var order: [String] = []
        var map: [String: [DDCartLine]] = [:]
        for l in validCart {
            let s = product(l.pid)?.shop ?? "店铺"
            if map[s] == nil { order.append(s) }
            map[s, default: []].append(l)
        }
        return order.map { (shop: $0, lines: map[$0] ?? []) }
    }
    /// 移除失效条目
    func clearInvalidCart() {
        let bad = Set(invalidCart.map { $0.pid })
        cart.removeAll { bad.contains($0.pid) }
        save()
    }

    func removeCartLine(_ pid: String) {
        cart.removeAll { $0.pid == pid }
        save()
    }

    /// 再来一单：把那张订单里的商品重新加回购物车
    func reorder(_ o: DDOrder) {
        addCart(o.pid, count: max(1, o.count))
        setCartSpec(o.pid, o.spec)
    }

    /* ---------------- 分类 / 搜索 ---------------- */

    var categories: [String] {
        var seen: [String] = []
        for p in live where !seen.contains(p.cate) { seen.append(p.cate) }
        return seen
    }

    func search(_ q: String) -> [DDProduct] {
        let s = q.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return live }
        return live.filter {
            $0.title.localizedCaseInsensitiveContains(s)
                || $0.shop.localizedCaseInsensitiveContains(s)
                || $0.cate == s
                || $0.tags.contains { $0.contains(s) }
        }
    }

    /* ---------------- 种子商品（和 H5 里那 16 个一模一样） ---------------- */

    static let seeds: [DDProduct] = [
        DDProduct(id: "p01", em: "🎧", title: "【百亿补贴】无线蓝牙耳机 主动降噪 入耳式 超长续航 苹果安卓通用",
                  price: 39.9, orig: 199, sold: "10万+", grp: 2, tags: ["百亿补贴", "官方直营"], shop: "数码优选旗舰店", cate: "数码"),
        DDProduct(id: "p02", em: "👟", title: "轻便透气跑步鞋 男款夏季网面运动鞋 软底减震",
                  price: 59.9, orig: 159, sold: "3.2万", grp: 2, tags: ["限时秒杀", "退货包运费"], shop: "潮鞋工厂店", cate: "服饰"),
        DDProduct(id: "p03", em: "🍊", title: "现摘沃柑 5斤装 手剥甜橙 新鲜当季水果 产地直发",
                  price: 16.8, orig: 39.9, sold: "8.6万", grp: 2, tags: ["产地直发", "坏果包赔"], shop: "果农直供店", cate: "生鲜"),
        DDProduct(id: "p04", em: "🧴", title: "氨基酸洗面奶 深层清洁温和不紧绷 敏感肌可用 200ml",
                  price: 19.9, orig: 69, sold: "5.1万", grp: 3, tags: ["正品保障"], shop: "肌研美妆专营", cate: "美妆"),
        DDProduct(id: "p05", em: "☕", title: "保温杯 316不锈钢 大容量便携车载水杯 24小时保温",
                  price: 29.9, orig: 99, sold: "2.7万", grp: 2, tags: ["限时秒杀"], shop: "日用家居优选", cate: "家居"),
        DDProduct(id: "p06", em: "🍜", title: "螺蛳粉 广西正宗柳州风味 5包装 加臭加辣速食",
                  price: 24.9, orig: 49.9, sold: "12万", grp: 2, tags: ["百亿补贴", "爆款"], shop: "美味零食铺", cate: "食品"),
        DDProduct(id: "p07", em: "📱", title: "120W超级快充充电宝 20000毫安 大容量 自带四线",
                  price: 69, orig: 199, sold: "4.4万", grp: 2, tags: ["官方补贴"], shop: "数码优选旗舰店", cate: "数码"),
        DDProduct(id: "p08", em: "🧸", title: "儿童毛绒玩具公仔 安抚陪睡娃娃 生日礼物正版授权",
                  price: 22.8, orig: 79, sold: "1.9万", grp: 3, tags: ["母婴优选"], shop: "萌趣玩具城", cate: "母婴"),
        DDProduct(id: "p09", em: "👕", title: "纯棉短袖T恤 男款夏季宽松百搭 三件装 不易变形",
                  price: 39.9, orig: 129, sold: "6.8万", grp: 2, tags: ["退货包运费"], shop: "基础款服饰店", cate: "服饰"),
        DDProduct(id: "p10", em: "🥛", title: "纯牛奶 250ml×12盒 全脂营养早餐奶 整箱实惠装",
                  price: 33.9, orig: 69, sold: "9.3万", grp: 2, tags: ["百亿补贴", "日期新鲜"], shop: "乳品官方旗舰", cate: "食品"),
        DDProduct(id: "p11", em: "🪥", title: "电动牙刷 声波震动 智能定时 情侣款 含4个刷头",
                  price: 45.9, orig: 169, sold: "2.2万", grp: 2, tags: ["限时秒杀"], shop: "口腔护理专营", cate: "美妆"),
        DDProduct(id: "p12", em: "🍚", title: "东北五常大米 10斤装 当季新米 香糯软弹 真空包装",
                  price: 34.9, orig: 79, sold: "7.5万", grp: 2, tags: ["产地直发"], shop: "粮油旗舰店", cate: "食品"),
        DDProduct(id: "p13", em: "⌚", title: "智能运动手环 心率血氧监测 防水计步 长续航 通用腕带",
                  price: 79, orig: 299, sold: "1.6万", grp: 3, tags: ["官方补贴"], shop: "数码优选旗舰店", cate: "数码"),
        DDProduct(id: "p14", em: "🧺", title: "衣物收纳箱 大容量可折叠 防潮防尘 衣柜整理三件套",
                  price: 26.9, orig: 89, sold: "3.7万", grp: 2, tags: ["9.9元包邮"], shop: "日用家居优选", cate: "家居"),
        DDProduct(id: "p15", em: "🍰", title: "千层蛋糕 动物奶油 现做现发 网红下午茶甜品",
                  price: 29.9, orig: 88, sold: "2.5万", grp: 2, tags: ["顺丰冷链"], shop: "甜品烘焙坊", cate: "食品"),
        DDProduct(id: "p16", em: "🧢", title: "棒球帽 男女同款 遮阳防晒 显脸小 可调节",
                  price: 15.9, orig: 59, sold: "4.1万", grp: 2, tags: ["9.9元包邮"], shop: "基础款服饰店", cate: "服饰")
    ]
}

/* ---------------------------------------------------------- 小零件 */

extension View {
    /// 商城一律按**浅色**渲染：用户要求「商城背景不要黑色的」——
    /// 深色模式下 App 的底色是 #191919，商城这一页保持拼多多那种白底/浅灰底
    /// （颜色走 App 那套 C.* 的浅色值：页面 #EDEDED、卡片 #FFFFFF、文字深灰）。
    func ddLight() -> some View { environment(\.colorScheme, .light) }
}

/// 商城的调色板 —— **和服务器上那个 H5 商城（/mall/index.html）里量出来的一模一样**
/// （用户要求「原生的商城颜值不要变，和 h5 的」）。H5 的 CSS 变量：
///   --red:#e02f24  --red-deep:#c81e14  --red-light:#fff1ef  --orange:#ff7a1a
///   --grad-red:135deg #ff5f3a → #ef3323 55% → #d81a10
///   --grad-btn:96deg #ffab2e → #ff5f00 55% → #f43c0a
///   --grad-btn-soft:96deg #ff8b3d → #f5361c
///   --bg:#f5f5f7  --text:#141414  --text-sub:#8a8a90  --text-weak:#b4b4ba
///   --card:#ffffff  --radius:16px  --radius-sm:12px
enum DDColor {
    static let red      = Color(hex: 0xE02F24)
    static let redDeep  = Color(hex: 0xC81E14)
    static let redLight = Color(hex: 0xFFF1EF)
    static let orange   = Color(hex: 0xFF7A1A)
    static let page     = Color(hex: 0xF5F5F7)
    static let card     = Color(hex: 0xFFFFFF)
    static let ink      = Color(hex: 0x141414)
    static let sub      = Color(hex: 0x8A8A90)
    static let weak     = Color(hex: 0xB4B4BA)
    static let line     = Color(hex: 0xEDEBE9)
    /* 2026-10-17 用户：「商城的各个地方有点设计感，不要每个都是平的卡片」——
       卡片底给一层**极淡的竖向渐变**（不是一块死白），配一条细边和一层柔和投影，
       卡片就有"厚度"了；全商城统一用这两个（原来是 .background(DDColor.card) 一片平色）。 */
    static let cardGrad = LinearGradient(colors: [Color(hex: 0xFFFFFF), Color(hex: 0xFBFBFD)],
                                         startPoint: .top, endPoint: .bottom)
    static let cardEdge = Color(hex: 0xEFEDEF)
    static let cardShadow = Color(hex: 0x8A6A5A).opacity(0.07)
    /// 「我的」页那张资料卡：顶上带一点暖红，往下化成白 —— 和顶栏那条红白渐变接得上
    static let mineCardGrad = LinearGradient(colors: [Color(hex: 0xFFF1EB), Color(hex: 0xFFFBF8),
                                                      Color(hex: 0xFFFFFF)],
                                             startPoint: .top, endPoint: .bottom)
    /// 分栏标题前面那根强调条（红→橙）
    static let barGrad = LinearGradient(colors: [Color(hex: 0xFF5F3A), Color(hex: 0xFF9A3C)],
                                        startPoint: .top, endPoint: .bottom)
    /// 顶栏那块红（H5 的 --grad-red）
    static let gradHeader = LinearGradient(
        colors: [Color(hex: 0xFF5F3A), Color(hex: 0xEF3323), Color(hex: 0xD81A10)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    /// 主要按钮（H5 的 --grad-btn）
    static let gradBtn = LinearGradient(
        colors: [Color(hex: 0xFFAB2E), Color(hex: 0xFF5F00), Color(hex: 0xF43C0A)],
        startPoint: .leading, endPoint: .trailing)
    /// 次要按钮（H5 的 --grad-btn-soft）
    static let gradBtnSoft = LinearGradient(
        colors: [Color(hex: 0xFF8B3D), Color(hex: 0xF5361C)],
        startPoint: .leading, endPoint: .trailing)
    /// 商品图那块暖色底
    static let gradThumb = LinearGradient(
        colors: [Color(hex: 0xFFF3EC), Color(hex: 0xFFFBF7)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}

/* 2026-10-15 用户：「顶部的渐变色弄浅色高级感」——
   原来商城顶部是 H5 那套正红（#FF5F3A → #EF3323 → #D81A10），现在换成**很淡的暖白渐变**
   （#FFFBF8 → #FFF1EA → #FFE6DC）：字/图标跟着变深色，搜索框留一条极细描边。
   想回正红（或换成别的）：后台 ui.json 里写
     mallTopGrad = "#FF5F3A,#EF3323,#D81A10"
   2~3 个十六进制颜色，逗号隔开就行。 */
func ddTopGradient() -> LinearGradient {
    func col(_ s: String) -> Color? {
        let v = s.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
        guard let n = UInt32(v, radix: 16) else { return nil }
        return Color(hex: n)
    }
    let raw = UIConfig.text("mallTopGrad", "")
    if !raw.isEmpty {
        let cols = raw.split(separator: ",").map { col(String($0)) }.compactMap { $0 }
        if cols.count >= 2 {
            return LinearGradient(colors: cols, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
    return LinearGradient(colors: [Color(hex: 0xFFFBF8), Color(hex: 0xFFF1EA), Color(hex: 0xFFE6DC)],
                          startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// 「我的」页那条**红白渐变**（2026-10-17 用户：「我的页顶栏底栏红白渐变处理」）——
/// 顶上压一串商城的红，往下很快化成白，和淘宝/京东的个人页一个路数：
/// 红是"这是商城的地盘"，白是把内容托起来。
/// 后台 ui.json 写 mallMineGrad（"#E02F24,#FF6A4D,#FFF1EC" 这种）就能整套换色。
func ddMineTopGradient() -> LinearGradient {
    func col(_ s: String) -> Color? {
        let v = s.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
        guard let n = UInt32(v, radix: 16) else { return nil }
        return Color(hex: n)
    }
    let raw = UIConfig.text("mallMineGrad", "")
    if !raw.isEmpty {
        let cols = raw.split(separator: ",").map { col(String($0)) }.compactMap { $0 }
        if cols.count >= 2 { return LinearGradient(colors: cols, startPoint: .top, endPoint: .bottom) }
    }
    return LinearGradient(colors: [Color(hex: 0xE02F24), Color(hex: 0xFF6A4D),
                                   Color(hex: 0xFFC3B0), Color(hex: 0xF5F5F7)],
                          startPoint: .top, endPoint: .bottom)
}

/// 商品图（emoji + 暖色渐变底，和 H5 的观感一致）
struct DDThumb: View {
    var em: String
    var size: CGFloat
    var radius: CGFloat = 10
    /// 有真图就显示真图（管理里从相册传上来的），没有就用 emoji 顶着
    var img: String? = nil

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(DDColor.gradThumb)
            if let img, !img.isEmpty {
                RemoteImage(path: img, icon: "photo")
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            } else {
                Text(em).font(.system(size: size * 0.46))
            }
        }
        .frame(width: size, height: size)
    }
}

/// 价格：¥ 小一号、数字大一号（拼多多那种写法）
struct DDPrice: View {
    var value: Double
    var size: CGFloat = 17
    var color: Color = DDColor.red

    var body: some View {
        /* 2026-10-15 家长版（京东）价格排版：**¥ 小、整数大、小数小** ——
           京东那种「¥39.9」里 39 特别大、.9 收小，一眼就是电商味。 */
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text("¥").font(pf(size * 0.62, .semibold)).foregroundColor(color)
            Text(DDPrice.split(value).0)
                .font(pf(size * 1.12, .bold)).foregroundColor(color)
            if !DDPrice.split(value).1.isEmpty {
                Text(DDPrice.split(value).1)
                    .font(pf(size * 0.72, .bold)).foregroundColor(color)
            }
        }
    }

    /// 把价格切成 (整数部分, ".小数部分") —— 京东那种大小字排版用
    static func split(_ v: Double) -> (String, String) {
        let s = moneyFmt(v)
        guard s.contains(".") else { return (s, "") }
        let parts = s.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return (s, "") }
        return (String(parts[0]), "." + String(parts[1]))
    }
}

/* ---------------------------------------------------------- 商城首页（根） */

/// 商城二楼的下拉「阀门」——**和会话页二楼完全是同一套**（2026-10-17 用户：
/// 「商城的下拉太容易误触」→「改成和会话页同样的阀门」）：
///   · 同一个后台键 `chatsFloorPull`（默认 120）：两页的阈值一起调，调完重开 App 生效
///   · 同一套 `floorGravity` 阻尼（heavy）：越往后越沉，随手一滑到不了阈值
///   · 同样三颗压感点、点到第三颗松手才开
enum DDMallFloorCfg {
    /// 2026-10-17 用户：「商城二楼还是容易拉下来」——
    /// 阀门本身还是会话页那套（同一个 chatsFloorPull），但商城首页是"一进来就在最上面 +
    /// 顶上是轮播图"，随手往下一滑的行程比会话页长得多，同样 135 就显得太容易。
    /// 所以这里再乘一个**商城专用倍率 mallFloorScale（默认 1.6）**：
    ///   135 × 1.6 ≈ 216 → 手指实际要拉 ~320pt 才到，随手滑一两百不会开。
    /// 想单独调商城：后台 ui.json 写 mallFloorScale（1 = 和会话页完全一样）。
    static var pull: CGFloat {
        let base = max(40, UIConfig.num("chatsFloorPull", 120))
        let scale = UIConfig.num("mallFloorScale", 1.6)
        return max(40, base * max(0.5, scale))
    }

    /// 会话页那个 heavyPull 的同一份公式（照抄，别改一边忘了另一边）
    static func heavy(_ d: CGFloat) -> CGFloat {
        let g = UIConfig.num("floorGravity", 1)
        if g <= 0 || d <= 60 { return d }
        let tail = max(0, d - 60)
        return 60 + CGFloat(pow(Double(tail), 0.82)) * 0.62 + tail * 0.38
    }
}

struct MallNativeView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = DDStore.shared

    @State private var tab = 0
    @State private var openProduct: DDProduct? = nil
    @State private var showSearch = false
    @State private var showOrders = false
    /// 会员中心（顶栏那颗 PLUS）
    @State private var showVip = false
    /// 城市选择页（2026-10-16 用户：「顶部位置做个像美团一样的城市定位」）
    @State private var showCity = false
    /// 商城「我的」顶栏的收货地址 / 客户服务按钮
    @State private var showMineAddress = false
    @State private var showMineService = false
    @ObservedObject private var city = DDCity.shared
    /* 二楼（整页浮层画在最外层，这样能盖住底栏 —— 和会话页二楼一样） */
    @State private var floorUp = false
    @State private var floorPull: CGFloat = 0
    @State private var floorOrders = 0
    @State private var showFloorOrders = false
    @State private var showFloorFav = false
    @State private var showFloorViews = false
    /// 开屏广告（管理端配了封面才显示）
    @State private var showSplash = false
    /// 这次进商城是什么时候（开屏配置晚回来时，只在这几秒内补弹，见 onChange(of: store.splash)）
    @State private var openedAt = Date()
    /// 搜索框右边那颗「扫一扫」（2026-10-17）
    @State private var showScan = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            header
            /* 2026-10-17 用户：「217 的商城就正常」「改回」——
               撤掉后来加的“内容整块上叠 14pt + 负 padding”。那套在部分机型上
               会让内容层参与横向尺寸计算，滑轮播/瀑布流时整页看起来左右漂。
               现在回到简单上下堆叠，宽度始终锁在屏幕内。 */
            content
                .background(
                    UnevenRoundedRectangle(topLeadingRadius: 18,
                                           bottomLeadingRadius: 0,
                                           bottomTrailingRadius: 0,
                                           topTrailingRadius: 18,
                                           style: .continuous)
                        .fill(DDColor.page)
                        .shadow(color: Color.black.opacity(0.07), radius: 8, y: -2)
                )
                .frame(maxWidth: .infinity)
                .clipped()
            tabBar
        }
        .frame(maxWidth: .infinity)
        .background(DDColor.page.ignoresSafeArea())
        /* 开屏广告：整屏封面 + 「跳过 N」，到点自己关 */
        .overlay {
            if showSplash {
                MallSplashAdView(splash: store.splash,
                                 onClose: { withAnimation(.easeOut(duration: 0.22)) { showSplash = false } },
                                 onTap: { openSplashTarget() })
                    .transition(.opacity)
            }
        }
        /* 商城二楼：首页下拉露出来的那一整层 */
        .overlay(alignment: .top) {
            if floorPull > 0.5 || floorUp {
                let screenH = UIScreen.main.bounds.height
                let reveal = floorUp ? screenH : min(floorPull, screenH)
                ZStack(alignment: .top) {
                    DDMallFloor(onClose: { closeMallFloor() },
                                onSearch: { showSearch = true },
                                onOrders: { i in
                                    floorOrders = i
                                    showFloorOrders = true
                                },
                                onFav: { closeMallFloor(); showFloorFav = true },
                                onViews: { closeMallFloor(); showFloorViews = true },
                                onCart: { closeMallFloor(); tab = 3 },
                                onOpen: { p in closeMallFloor(); openProduct_tap(p) },
                                onCity: { showCity = true })
                        .environmentObject(app)
                        .frame(height: screenH)
                        .offset(y: -(screenH - reveal))
                        .ignoresSafeArea()
                    /* 压感提示：**和会话页二楼同款**（1 → 2 → 3 颗点亮，点到第三颗松手才开）。
                       商城这边以前没有这几颗点，用户"随手一滑"也看不出拉到哪了，就误触。 */
                    VStack(spacing: 0) {
                        Spacer().frame(height: L.safeTop + 10)
                        mallPullDots
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                    .opacity(floorUp ? 0 : 1)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
                }
            }
        }
        .sheet(isPresented: $showFloorOrders) {
            DDOrdersView(startFilter: floorOrders).environmentObject(app)
        }
        .sheet(isPresented: $showFloorFav) {
            DDFavView(onOpen: { p in
                showFloorFav = false
                openProduct_tap(p)
            })
            .environmentObject(app)
        }
        .sheet(isPresented: $showFloorViews) {
            DDViewsView(onOpen: { p in
                showFloorViews = false
                openProduct_tap(p)
            })
        }
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .sheet(item: $openProduct) { p in
            /* onCart：详情页里点「加购物车」→ 直接切到购物车那个 tab */
            DDDetailView(product: p,
                         onCart: { tab = 3 },
                         onOpenOther: { openProduct = $0 }).environmentObject(app)
        }
        .sheet(isPresented: $showSearch) {
            DDSearchView { p in
                showSearch = false
                openProduct = p
            }
            .environmentObject(app)
        }
        /* 扫一扫：搜索框右边那颗相机进来（和会话页二楼那颗同一页） */
        .fullScreenCover(isPresented: $showScan) {
            ScannerView { text in handleScanned(text, app: app) }
        }
        .sheet(isPresented: $showOrders) {
            DDOrdersView().environmentObject(app)
        }
        .sheet(isPresented: $showVip) {
            DDVipPageView(onOpen: { p in
                showVip = false
                openProduct_tap(p)
            })
            .environmentObject(app)
        }
        /* 城市选择页（美团那种：当前定位 / 最近访问 / 热门城市 / 搜索） */
        .sheet(isPresented: $showCity) {
            DDCityPickerView().environmentObject(app)
        }
        .sheet(isPresented: $showMineService) {
            DDHelpCenterView().environmentObject(app)
        }
        .sheet(isPresented: $showMineAddress) {
            DDAddressListView().environmentObject(app)
        }
        /* 统一的跳转请求（见 DDStore.wantCart / wantOrders 那段说明）：
           出发点是哪个页面都行 —— 商品详情、订单列表、聊天里那张商品卡 ——
           这里统一收口：要购物车就切到购物车那一栏，要订单就弹「我的订单」。 */
        .onChange(of: store.wantCart) { v in
            guard v else { return }
            store.wantCart = false
            openProduct = nil
            showOrders = false
            tab = 3
        }
        .onChange(of: store.wantOrders) { v in
            guard v else { return }
            store.wantOrders = false
            openProduct = nil
            showOrders = true
        }
        /* 商城还没打开时攒下的请求（比如从聊天卡片里下的单）：一进来就补上 */
        .onAppear {
            /* 开屏广告：本地缓存里已经有配置就先弹（第一次装完那次靠下面 task 刷完再弹） */
            if store.splash.isOn, !showSplash { showSplash = true }
            openedAt = Date()
            /* 2026-10-17 用户报「商城的开屏广告显示不出来」——进商城先把这一刻的状态
               打到后台日志（后台 → 崩溃/日志 里能看到）：配置有没有到 App、封面是哪张、
               显示几秒。有了这一条，下一次就能立刻分辨是「服务端没配到」还是「没触发」。 */
            CrashCatcher.note("开屏广告", "进商城：配置=\(store.splash.isOn ? "有" : "无")｜封面=\(store.splash.image ?? "-")｜秒=\(Int(store.splash.secs))｜首屏=\(store.products.count)件")
            if store.wantCart {
                store.wantCart = false
                tab = 3
            }
            if store.wantOrders {
                store.wantOrders = false
                showOrders = true
            }
        }
        /* 开屏配置**比 onAppear 晚回来**（第一次装完、或者刚从后台切回来）：
           一到就弹，不用等下一次进商城。只在这个页面刚打开的那几秒内弹，
           免得用户正在逛的时候突然糊一屏广告。 */
        .onChange(of: store.splash) { s in
            guard s.isOn, !showSplash else { return }
            guard Date().timeIntervalSince(openedAt) < 5 else { return }
            withAnimation(.easeOut(duration: 0.2)) { showSplash = true }
        }
        /* 进商城先拉一次服务器上的商城数据（商品 + 轮播图）——管理里改完立刻能看到 */
        .task {
            await store.refresh()
            await store.refreshMallBadges()          // 券 + 底栏那几颗红点
            /* 商城配置拉回来了：开屏广告按最新配置弹 */
            if store.splash.isOn, !showSplash { withAnimation(.easeOut(duration: 0.2)) { showSplash = true } }
            /* 顶部城市：没定过就顺手定位一次（美团也是一进来就定位） */
            DDCity.shared.locateIfNeeded()
            MallWeather.shared.refresh()
        }
        .ddLight()
        /* 顺带把状态栏也按浅色算：不然深色模式下状态栏是白字、压在浅色商城上会看不清 */
        .preferredColorScheme(.light)
    }

    /* 2026-10-17 用户：「底栏推荐换成分类页」——第 2 格从「推荐（种草）」换成「分类」 */
    private var titles = ["商城", "分类", "消息", "购物车", "我的"]

    /// 点开屏封面去哪：后台配的是 不跳 / 网址 / 某个商品
    private func openSplashTarget() {
        let a = store.splash.action ?? "none"
        let l = (store.splash.link ?? "").trimmingCharacters(in: .whitespaces)
        withAnimation(.easeOut(duration: 0.2)) { showSplash = false }
        guard !l.isEmpty, a != "none" else { return }
        if a == "product", let p = store.products.first(where: { $0.id == l }) {
            openProduct_tap(p)
            return
        }
        if let u = URL(string: l), u.scheme != nil { openURL(u) }
    }

    /// 收起二楼
    private func closeMallFloor() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
            floorUp = false
            floorPull = 0
        }
    }

    /* ============================================================
       二楼下拉提示（用户：「压感点商城做高级点」→「你来设计」）

       设计思路：**一条会走的轨道 + 三个停靠点**，装在一块悬浮玻璃胶囊里。
         · 轨道：74pt、2pt 细线。底槽半透明白；走过的部分用品牌橙→暖黄渐变铺上，
           所以"拉了多远"是一个连续的、精确的量 —— 不再是三颗孤零零的点
         · 三个停靠点：1/3、2/3、3/3 各一颗。走到哪颗，哪颗**点亮 + 放大 + 起光晕**
           （同时震一下，和会话页同一个 floorHaptic 强度）—— 这就是"圧感"的来源
         · 文案跟着进度换：下拉进入二楼 → 继续下拉 → 松手进入二楼
           （全亮那一刻文字也变橙、整块胶囊轻轻放大，一眼知道"到底了、可以松手"）
         · 胶囊：ultraThinMaterial + 细亮边 + 随进度加深的投影（压在天气背景上不掉档次），
           并且**前 25pt 完全不显示**，再花 40pt 淡入 —— 随手滑一下不会闪出一块 UI
        ⚠ 所有常量都写成 CGFloat：混着字面量容易撞 Swift 的 CGFloat/Double 互转，
          CI 会报 ambiguous use of operator（B1635 栽过一次）。
       ============================================================ */
    private var mallPullDots: some View {
        let p: CGFloat = floorUp ? 1000 : floorPull
        let total: CGFloat = max(1, DDMallFloorCfg.pull)
        let prog: CGFloat = min(1, max(0, p / total))
        let track: CGFloat = 74
        let allLit: Bool = prog >= 0.999
        let litCount: Int = min(3, max(0, Int(prog * 3 + 0.001)))
        let label: String = allLit ? Tr("松手进入二楼")
                         : (litCount >= 1 ? Tr("继续下拉") : Tr("下拉进入二楼"))
        return HStack(spacing: 10) {
            /* 轨道 + 三个停靠点 */
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.34))
                    .frame(width: track, height: 2)
                Capsule()
                    .fill(LinearGradient(colors: [DDColor.orange, Color(hex: 0xFFB35C)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(2, track * prog), height: 2)
                ForEach(0..<3, id: \.self) { i in
                    let at: CGFloat = track * CGFloat(i + 1) / 3
                    let on: Bool = prog * track + 0.5 >= at
                    ZStack {
                        if on {
                            Circle().fill(DDColor.orange.opacity(0.35))
                                .frame(width: 16, height: 16).blur(radius: 4)
                        }
                        Circle()
                            .fill(on ? DDColor.orange : Color.white.opacity(0.55))
                            .frame(width: on ? 8 : 6, height: on ? 8 : 6)
                            .shadow(color: on ? DDColor.orange.opacity(0.55) : .clear, radius: 5)
                    }
                    .frame(width: 16, height: 16)
                    .offset(x: at - 8)
                }
            }
            .frame(width: track, height: 16)

            Text(label)
                .font(pf(11.5, .medium))
                .foregroundColor(allLit ? DDColor.orange : DDColor.ink.opacity(0.55))
                .fixedSize()
        }
        .padding(.leading, 13).padding(.trailing, 15)
        .frame(height: 34)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().stroke(Color.white.opacity(0.34), lineWidth: 0.6))
                .shadow(color: Color.black.opacity(0.10 + 0.10 * prog), radius: 10, y: 3)
        }
        .scaleEffect(allLit ? 1.05 : 1)
        /* 前 25pt 不出现，再用 40pt 淡进来（随手滑一下不会闪） */
        .opacity(min(1, max(0, (p - 25) / 40)))
        .animation(.spring(response: 0.26, dampingFraction: 0.82), value: litCount)
        .animation(.easeOut(duration: 0.16), value: floorPull)
    }

    private var header: some View {
        /* 2026-10-17 用户：「把我的顶栏遮罩红白渐变给首页用」——
           首页顶栏也走「我的」页那条红白渐变，所以顶上这些字/图标一律切白
           （以前只有「我的」页是红底 → 白字，首页是奶油白底 → 深字）。 */
        let onRed = (tab == 0 || tab == 4)
        /* ⚠ 上面那句 let 之后就不能再靠"最后一句自动返回"了（Swift 只在单表达式函数里
           隐式返回）—— 必须显式 return。B1646 那次编译就是栽在这儿（和当初 cell() 一个坑）。 */
        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        /* 红底的那些页（首页 / 我的）→ 返回箭头也跟着走白 */
                        .foregroundColor(onRed ? .white : DDColor.ink)
                        .frame(width: 34, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if tab == 0 {
                    /* 2026-10-16 用户：「顶部位置做个像美团一样的城市定位」——
                       美团左上角就是「📍城市 ▾」，点一下进城市选择页。 */
                    Button { showCity = true } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "location.fill")
                                .font(.system(size: 11, weight: .semibold))
                            Text(city.display)
                                .font(pf(13.5, .medium))
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundColor(onRed ? .white : DDColor.ink)
                        .frame(maxWidth: 84, alignment: .leading)
                        .frame(height: 40)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    /* 2026-10-15 用户：「顶部感觉和京东要一样」——
                       京东顶上是「一条大搜索框 + 右边两个图标」，没有大标题。
                       所以搜索框挪上来当主角，商城名/标语缩成下面一行小字（品牌还留着）。 */
                    /* 2026-10-17 用户：「搜索框加入扫一扫」——
                       以前整条搜索框是一个 Button，没法在里面再放一颗扫码按钮，
                       现在改成"盒子自己点 = 搜索"，右边那颗相机是**独立的 Button**（像淘宝/京东）。 */
                    searchBox
                    Button { showVip = true } label: {
                        Text("PLUS")
                            .font(pf(11.5, .bold)).foregroundColor(Color(hex: 0x5A3E14))
                            .padding(.horizontal, 8).frame(height: 24)
                            .background(Capsule().fill(Color(hex: 0xFFE7B0)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button { showOrders = true } label: {
                        Image(systemName: "doc.text")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(onRed ? .white : DDColor.ink)
                            .frame(width: 34, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(Tr(titles[tab]))
                        /* 红白渐变的那些页 → 标题走白字（别的页还是深色字） */
                        .font(pf(17, .semibold))
                        .foregroundColor(onRed ? .white : DDColor.ink)
                    Spacer(minLength: 0)
                    if tab == 4 {
                        HStack(spacing: 7) {
                            mineHeaderButton("mappin.and.ellipse", Tr("收货地址")) {
                                showMineAddress = true
                            }
                            mineHeaderButton("headphones", Tr("客户服务")) {
                                showMineService = true
                            }
                        }
                    } else {
                        Color.clear.frame(width: 34, height: 40)
                    }
                }
            }
            if tab == 0 {
                HStack(spacing: 4) {
                    Text(store.mallName).font(pf(12.5, .semibold))
                        .foregroundColor(onRed ? .white : DDColor.ink)
                    Text(store.mallSlogan).font(pf(11))
                        .foregroundColor(onRed ? Color.white.opacity(0.82) : DDColor.sub)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        /* 内容已回到普通上下堆叠，不再需要为 14pt 叠层让位。 */
        .padding(.bottom, 8)
        /* ⚠ 红色要**顶到状态栏**（京东就是这样）：只给背景铺到安全区上面，
           内容照旧从安全区下面开始 */
        .background { headerBg.ignoresSafeArea(edges: .top) }
    }

    @ViewBuilder private var headerBg: some View {
        /* 2026-10-16 用户：「商城顶部遮罩底部遮罩磨砂感」——
           顶栏和底栏压一层毛玻璃（ultraThinMaterial），内容从下面滚过去是糊的、不是硬边；
           颜色仍然保留（首页那条红渐变 / 其他页的浅底），只是上面多一层磨砂。
           想要更实/更透：ui.json 写 mallHeaderGlass / mallTabGlass（0~1）。 */
        ZStack {
            if tab == 0 || tab == 4 {
                /* 2026-10-17 用户：「我的页顶栏底栏红白渐变处理」→ 后来「把我的顶栏遮罩
                   红白渐变给首页用」：首页和「我的」页共用**同一条**红白渐变
                   （顶上压一串商城红、往下化成白/页面灰），想整套换色改后台 mallMineGrad。
                   首页原来那条奶油白 ddTopGradient 就留给别的页/老配置了。 */
                ddMineTopGradient()
            } else {
                DDColor.page
            }
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(UIConfig.num("mallHeaderGlass", 0.92))
        }
    }

    /// 商城「我的」顶栏右侧的并排按钮：收货地址 / 客户服务。
    /// 首页和「我的」共用红白渐变，所以这里统一白字 + 淡白玻璃底。
    private func mineHeaderButton(_ icon: String, _ title: String,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(title)
                    .font(pf(11.5, .medium))
                    .lineLimit(1)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Capsule().fill(Color.white.opacity(0.16)))
            .overlay(Capsule().stroke(Color.white.opacity(0.24), lineWidth: 0.7))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var searchBox: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(hex: 0xA79C97))
            Text(Tr("搜索想要的商品")).font(pf(14)).foregroundColor(Color(hex: 0xA79C97))
            Spacer(minLength: 0)
            /* 扫一扫（2026-10-17 用户：「搜索框加入扫一扫」）——
               和淘宝/京东一样，搜索框最右边一颗相机，点了开扫码页 */
            Button { showScan = true } label: {
                Image(systemName: "barcode.viewfinder")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(DDColor.red)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: 34)
        .background(Capsule().fill(Color.white))
        /* 浅色顶部上，白搜索框要一条极细描边 + 一丁点投影才立得住（高级感的来源） */
        .overlay(Capsule().stroke(Color(hex: 0xF0E4DE), lineWidth: 0.6))
        .shadow(color: Color(hex: 0x8A6A5A).opacity(0.06), radius: 6, y: 2)
        .contentShape(Rectangle())
        /* 点盒子本体（不是相机那一下）= 进搜索页 */
        .onTapGesture { showSearch = true }
    }

    @ViewBuilder private var content: some View {
        switch tab {
            case 0: DDHomeTab(onOpen: openProduct_tap, onCart: { tab = 3 },
                              floorUp: $floorUp, floorPull: $floorPull)
            /* 2026-10-17：第 2 格从「推荐（种草）」换成**分类页**（大商城那种左栏+右栏） */
            case 1: DDCategoryTab(onOpen: openProduct_tap, onSearch: { showSearch = true })
            case 2: DDMsgTab(onOrders: { showOrders = true })
            case 3: DDCartTab(onOpen: openProduct_tap, onOrders: { showOrders = true })
            default: DDMineTab(onOrders: { showOrders = true }, onOpen: openProduct_tap)
        }
    }

    /// 点商品 → 打开详情（顺手记一条「浏览足迹」，我的 → 浏览足迹 里能看到）
    private func openProduct_tap(_ p: DDProduct) {
        store.recordView(p.id)
        openProduct = p
    }

    private var tabBar: some View {
        VStack(spacing: 0) {
            HairLine()
            HStack(spacing: 0) {
                /* 底栏红点（2026-10-16 用户要求「商城里底栏要有红点」「购物车啥的也要有」）：
                   · 首页 / 推荐：有券还没领 → 亮（领完自动灭）
                   · 消息：又有券到账 / 奖励进账 → 亮数字，点开这一格就清
                   · 购物车：件数角标；另有「待付款」订单时亮红点
                   · 我的：有待收货订单时亮红点 */
                tabButton(0, "首页", "house.fill", 0,
                          dot: store.mallClaimable > 0)
                tabButton(1, "分类", "square.grid.2x2", 0,
                          dot: store.mallClaimable > 0)
                tabButton(2, "消息", "bell.fill", store.mallNewCoupons,
                          dot: store.mallNewCoupons == 0 && store.groupingCount > 0)
                tabButton(3, "购物车", "cart.fill", store.cartCount,
                          dot: store.orders.contains { $0.status == "paying" })
                tabButton(4, "我的", "person.fill", 0,
                          dot: store.orders.contains { $0.status == "shipped" })
            }
            /* 2026-10-15 用户：「底栏还是太高了」（商城）——
               病根：这里以前又加了 `max(4, L.safeBottom)`（=34），可**外面那层 VStack
               本来就已经避开 home 条那 34 了**，等于同一个 34 算了两遍 → 底栏高一截。
               现在：内容高 49（京东那个量级，图标 23 + 字 10 在里面居中）+
               贴着 home 条上方留 6pt；白色底**铺到屏幕最底**（home 条那一块也是白的，
               和微信/京东一模一样）。想微调：ui.json 的 mallTabH / mallTabPad。 */
            .frame(height: UIConfig.num("mallTabH", 49))
            .padding(.bottom, UIConfig.num("mallTabPad", 2))
        }
        /* 底栏也走磨砂：商品从下面滚过去时，底栏是糊的一层（京东/微信现在的做法） */
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                    .opacity(UIConfig.num("mallTabGlass", 0.92))
                if tab == 4 {
                    /* 2026-10-17 用户：「我的页顶栏底栏红白渐变处理」——
                       底栏也走红白：上边一抹很淡的红，往下化成白，和顶栏那条接得上 */
                    LinearGradient(colors: [Color(hex: 0xFFF0EA), Color(hex: 0xFFFFFF)],
                                   startPoint: .top, endPoint: .bottom)
                        .opacity(0.95)
                } else {
                    DDColor.card.opacity(0.78)
                }
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    private func tabButton(_ i: Int, _ label: String, _ icon: String, _ badge: Int,
                           dot: Bool = false) -> some View {
        Button {
            tab = i
            if i == 2 { store.markMallSeen() }      // 打开「消息」→ 清红点
            if store.mallClaimable > 0 { Task { await store.refreshMallBadges() } }
        } label: {
            VStack(spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: UIConfig.num("mallTabIcon", 23),
                                      weight: tab == i ? .semibold : .regular))
                        .foregroundColor(tab == i ? DDColor.red : DDColor.sub)
                        .frame(width: 28, height: 24)
                    if badge > 0 {
                        Text(badge > 99 ? "99+" : String(badge))
                            .font(pf(9.5, .semibold)).foregroundColor(.white)
                            .padding(.horizontal, 4).frame(height: 14)
                            .background(Capsule().fill(DDColor.redDeep))
                            .offset(x: 9, y: -5)
                    } else if dot {
                        Circle().fill(DDColor.redDeep)
                            .frame(width: 8, height: 8)
                            .offset(x: 8, y: -3)
                    }
                }
                Text(Tr(label))
                    .font(pf(UIConfig.num("mallTabLabel", 10), tab == i ? .medium : .regular))
                    .foregroundColor(tab == i ? DDColor.red : DDColor.sub)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/* ---------------------------------------------------------- 首页 */

struct DDHomeTab: View {
    @EnvironmentObject private var app: AppState
    /// 后台广告可以配一个网址（action = none 时点开它）
    @Environment(\.openURL) private var openLink
    @ObservedObject private var store = DDStore.shared
    var onOpen: (DDProduct) -> Void
    /// 详情页里点「加购物车」→ 外面切到购物车那个 tab
    var onCart: () -> Void = { }
    /* 二楼状态由外面（MallNativeView）持有：二楼是整页浮层，要盖住底栏，
       所以画在商城最外层，这里只负责"下拉了多少 / 拉开没有"。 */
    var floorUp: Binding<Bool>? = nil
    var floorPull: Binding<CGFloat>? = nil
    /// 压感点走到第几颗（点亮一颗震一下，和会话页二楼同一套）
    @State private var floorTick = 0
    /// 这一次拖动已经判定成"滚商品列表"了 —— 整段都不再算下拉
    /// （2026-10-17 用户：「商品往上拉就会下来」：
    ///   手指往上滑时，起手那一两帧常常带着一点点向下的位移，
    ///   以前只看 dy 的瞬时值，就被当成"下拉"开始积累行程，滑完一抬手二楼就下来了。
    ///   现在加一道方向锁：只要这次拖动先往上超过 8pt，整段都不认下拉。）
    @State private var floorGestureLocked = false
    /// 这次拖动的起始时间（2026-10-17 用户：「下滑特别容易出 2 楼」）——
    /// 快速往下一甩（<0.35 秒）是"滚到顶部/回弹"的习惯动作，不该算拉二楼；
    /// 只有慢慢拉、拉到阀门才开（微信二楼也是这种"要故意拉一下"的手感）。
    @State private var floorDragStart: Date? = nil

    /// 打开的频道页（百亿补贴 / 排行榜 / 9.9包邮 / 厂家直供）
    @State private var channel: DDChannelKind? = nil
    /// 广告位点开的东西：会员中心 / 听一听
    @State private var showVipAd = false
    @State private var showMusicAd = false
    /// 宫格第二行那四个功能（京东那种：订单 / 购物车 / 收藏 / 足迹）
    @State private var showAdOrders = false
    @State private var showAdFav = false
    @State private var showAdViews = false
    /* 2026-10-16 商城二楼（用户：「沿用二楼的方案，商城也做个二楼出来」） */
    @State private var topY: CGFloat = 0           // 首页是不是在最上面
    @State private var cate: String? = nil
    @State private var secs = 2 * 3600 + 41 * 60 + 33
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var list: [DDProduct] {
        let base = cate == nil ? store.live : store.live.filter { $0.cate == cate }
        /* 「不感兴趣」的不再出现；「少推这一类」的沉到最后 */
        return store.feed(base)
    }

    /// 只把后台真正标了「限时秒杀」的商品放进秒杀位。
    /// 以前直接拿前 8 个商品假装秒杀，首屏会有明显的“演示数据感”。
    private var saleProducts: [DDProduct] {
        store.live.filter { product in
            product.tags.contains(where: { $0.contains("秒杀") || $0.contains("限时") })
        }
    }

    /// 商城二楼的下拉阀门 = **和会话页二楼完全同一套**（2026-10-17 用户：
    /// 「改成和会话页同样的阀门」）：同一个后台键 chatsFloorPull、同一套阻尼、同样松手才开。
    private var mallFloorPullValue: CGFloat { DDMallFloorCfg.pull }

    /// 震动强度走会话页那个键 floorHaptic（0 关 / 1 轻 / 2 中 / 3 重）——两页手感一致
    private func mallFloorImpact(_ level: Int) {
        let strength = Int(UIConfig.num("floorHaptic", 3))
        guard strength > 0 else { return }
        switch min(level, strength) {
        case 1: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case 2: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        default: UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        }
    }

    var body: some View {
        /* 用 ScrollViewReader：点轮播图 / 「更多抢购」→ 滚到「为你推荐」那一栏
           （以前这两个地方点了没反应，用户报的「有些东西点不了」） */
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    /* 二楼探针：记首页滚到哪儿了（只有在最上面往下拉才算开二楼） */
                    Color.clear.frame(height: 0)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: DDFloorOffsetKey.self,
                                                   value: g.frame(in: .named("ddhome")).minY)
                        })
                    carousel(proxy)
                    /* 2026-10-15 对齐京东：轮播图下面那排频道 */
                    DDChannelRow(onOpen: { channel = $0 }, onFunc: { f in
                        switch f {
                        case "orders": showAdOrders = true
                        case "cart":   onCart()
                        case "fav":    showAdFav = true
                        default:       showAdViews = true
                        }
                    })
                    /* 楼间小广告：**后台下发的**（后台没配就用内置那条百亿补贴） */
                    adStrip
                    if !saleProducts.isEmpty {
                        seckill(proxy)
                    }
                    sectionTitle(Tr("为你推荐"), right: Tr("边逛边拼"))
                    /* 京东那种：标题下面一条可横滑的分类 tab（推荐 / 各分类） */
                    cateRow
                    if !store.mutedCates.isEmpty { mutedNote }
                    /* 商品被"不感兴趣"藏得太多时，首页给一句提示 + 一键恢复（不再出现空商城） */
                    if store.disliked.count >= 20 && store.dislikedProducts.count >= store.live.count {
                        HStack(spacing: 8) {
                            Image(systemName: "hand.thumbsdown").font(.system(size: 12)).foregroundColor(DDColor.sub)
                            Text(Tr("你把商品都隐藏了，先给你看全部")).font(pf(12)).foregroundColor(DDColor.sub)
                            Spacer(minLength: 0)
                            Button {
                                store.restoreAllDisliked()
                                app.show(Tr("已全部恢复"))
                            } label: {
                                Text(Tr("全部恢复")).font(pf(12.5, .medium)).foregroundColor(DDColor.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 6)
                    }
                    grid.id("dd-grid")
                    Spacer().frame(height: 16)
                }
                .padding(.top, 12)
            }
            .background(DDColor.page)
            .coordinateSpace(name: "ddhome")
            .onPreferenceChange(DDFloorOffsetKey.self) { topY = $0 }
            /* 二楼：手指在最上面往下拉 → 跟着手指露出；过阈值松手 → 停住（和会话页二楼一套） */
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { v in
                        /* ⚠ 2026-10-17 用户：「商城二楼还是容易拉下来」——
                           以前这里判 `topY > -6`：只要"大致在最上面"就认下拉，
                           往下滑时列表刚回弹一点点（-5）也会被算成拉二楼。
                           现在收紧到 -1：**必须真的停在最顶上**才开始算。 */
                        guard !(floorUp?.wrappedValue ?? false), topY > -1 else { return }
                        let dy = v.translation.height
                        /* 方向锁（用户：「商品往上拉就会下来」）——
                           这次拖动先往上超过 8pt = 用户在滚商品列表，整段都不算下拉。 */
                        if dy < -8 {
                            floorGestureLocked = true
                            floorPull?.wrappedValue = 0
                            floorTick = 0
                            return
                        }
                        if floorGestureLocked { return }
                        if dy <= 0 { floorPull?.wrappedValue = 0; floorTick = 0; return }
                        if floorDragStart == nil { floorDragStart = Date() }
                        /* 阀门 = 会话页那套：先过阻尼（越拉越沉），再判阈值 */
                        let p = min(DDMallFloorCfg.heavy(dy), UIScreen.main.bounds.height)
                        if abs(p - (floorPull?.wrappedValue ?? 0)) > 0.5 { floorPull?.wrappedValue = p }
                        /* 每点亮一颗提示点震一下（前三颗 medium、第三颗 heavy），和会话页一样 */
                        let step = max(1, mallFloorPullValue / 3)
                        let lit = min(3, Int(p / step))
                        if lit != floorTick {
                            floorTick = lit
                            if lit > 0 { mallFloorImpact(lit >= 3 ? 3 : 2) }
                        }
                    }
                    .onEnded { _ in
                        floorGestureLocked = false
                        /* 快速一甩（<0.35s）= "滚到顶/回弹"的习惯动作，不算拉二楼 */
                        let dt = floorDragStart.map { Date().timeIntervalSince($0) } ?? 1
                        floorDragStart = nil
                        guard !(floorUp?.wrappedValue ?? false) else { return }
                        if dt < 0.35 {
                            withAnimation(.easeOut(duration: 0.18)) { floorPull?.wrappedValue = 0 }
                            floorTick = 0
                            return
                        }
                        if (floorPull?.wrappedValue ?? 0) > mallFloorPullValue {
                            withAnimation(.spring(response: 0.44, dampingFraction: 0.82)) {
                                floorUp?.wrappedValue = true
                            }
                            mallFloorImpact(3)
                        } else {
                            withAnimation(.easeOut(duration: 0.22)) { floorPull?.wrappedValue = 0 }
                        }
                        floorTick = 0
                    }
            )
            .onReceive(ticker) { _ in if secs > 0 { secs -= 1 } }
            /* 频道页整页打开（它自己带返回 + 商品列表 + 商品详情） */
            .sheet(item: $channel) { k in
                DDChannelView(kind: k, onCart: { channel = nil; onCart() })
                    .environmentObject(app)
            }
            /* 广告位点开的两页 */
            .sheet(isPresented: $showVipAd) {
                DDVipPageView { p in
                    showVipAd = false
                    onOpen(p)
                }
                .environmentObject(app)
            }
            .fullScreenCover(isPresented: $showMusicAd) {
                NavigationStack { ListenView().environmentObject(app) }
            }
            /* 宫格第二行那几颗：订单 / 收藏 / 足迹（购物车那颗切 tab，不用弹页） */
            .sheet(isPresented: $showAdOrders) { DDOrdersView().environmentObject(app) }
            .sheet(isPresented: $showAdFav) {
                DDFavView(onOpen: { p in
                    showAdFav = false
                    onOpen(p)
                })
                .environmentObject(app)
            }
            .sheet(isPresented: $showAdViews) {
                DDViewsView(onOpen: { p in
                    showAdViews = false
                    onOpen(p)
                })
            }
        }
    }

    private func toGrid(_ proxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo("dd-grid", anchor: .top) }
    }

    /* ---------------- 首页轮播图（管理页里可以换图 / 加图 / 删图） ----------------
       没有图就不占地方（空数组时整块不画）；有图就横滑一屏一张 + 底下小圆点，
       每 3 秒自动翻一张。 */
    @State private var bannerPage = 0

    @ViewBuilder private func carousel(_ proxy: ScrollViewProxy) -> some View {
        let imgs = store.banners.filter { !$0.isEmpty }
        if !imgs.isEmpty {
            VStack(spacing: 8) {
                TabView(selection: $bannerPage) {
                    ForEach(imgs.indices, id: \.self) { i in
                        Button { toGrid(proxy) } label: {
                            /* 2026-10-17 用户：「商城首页的排版感觉还是不够高级」——
                               轮播那张图：圆角 14→18（大图用大圆角才显高级），
                               底下压一层**从透明到黑 18% 的渐变**，小圆点挪进图里右下角 ——
                               于是"图 + 点"是一个整体，不再是一张图下面吊着一排点。 */
                            ZStack(alignment: .bottomTrailing) {
                                RemoteImage(path: imgs[i], icon: "photo")
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 156)
                                /* 底部一层很淡的黑压在图和点之间：白点才压得住（图太白也不怕），
                                   ⚠ 必须画在**点下面**，不然把点也一起压暗了 */
                                LinearGradient(colors: [.clear, .black.opacity(0.18)],
                                               startPoint: .center, endPoint: .bottom)
                                    .allowsHitTesting(false)
                                if imgs.count > 1 {
                                    HStack(spacing: 5) {
                                        ForEach(imgs.indices, id: \.self) { k in
                                            Capsule()
                                                .fill(k == i
                                                      /* 2026-10-17 用户：「索引选中的圈也拿我们自己的按钮颜色」——
                                                         选中那颗（长条）用品牌橙，没选中的还是半透明白，
                                                         和图里那层淡黑一起看，指示得很清楚 */
                                                      ? DDColor.orange
                                                      : Color.white.opacity(0.45))
                                                .frame(width: k == i ? 14 : 6, height: 6)
                                        }
                                    }
                                    .padding(.trailing, 16)
                                    .padding(.bottom, 14)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .padding(.horizontal, 16)
                        }
                        .buttonStyle(.plain)
                        .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 162)
            }
            /* 自动轮播：**别**用 Timer.publish(...).autoconnect() 写在 body 里。
               商城首页动不动就重画（拉数据、滚动、切 tab 都会），
               每次重画都会新建一个计时器，刚起跳的那个立刻被丢掉 ——
               表现出来的就是用户说的「轮播图不会滚动」：一直停在第 1 张。
               改成 .task 里的循环：跟着这个视图的生死走，只有图片数量变了才重开。 */
            .task(id: imgs.count) {
                guard imgs.count > 1 else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    if Task.isCancelled { return }
                    withAnimation(.easeInOut(duration: 0.35)) {
                        bannerPage = (bannerPage + 1) % max(1, imgs.count)
                    }
                }
            }
        }
    }

    private func seckill(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            /* 2026-10-15 用户：「商城的主页排版不行，功能逻辑主页对齐京东」——
               京东那个秒杀块是**左边一块红（竖排「限时秒杀」+ 倒计时）+ 右边横滑商品**。 */
            HStack(spacing: 0) {
                Button { toGrid(proxy) } label: {
                    VStack(spacing: 5) {
                        Text(Tr("限时")).font(pf(14, .semibold)).foregroundColor(.white)
                        Text(Tr("秒杀")).font(pf(14, .semibold)).foregroundColor(.white)
                        Text(clockText)
                            .font(pf(9.5, .semibold)).foregroundColor(.white)
                            .padding(.horizontal, 5).frame(height: 16)
                            .background(Capsule().fill(Color.black.opacity(0.22)))
                    }
                    .frame(width: 74)
                    .frame(maxHeight: .infinity)
                    .background(LinearGradient(colors: [Color(hex: 0xFF5F3A), Color(hex: 0xD81A10)],
                                               startPoint: .top, endPoint: .bottom))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(saleProducts.prefix(8))) { p in
                            Button { onOpen(p) } label: { seckillCell(p) }
                                .buttonStyle(.plain)
                        }
                        Button { toGrid(proxy) } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(DDColor.sub)
                                Text(Tr("更多")).font(pf(11)).foregroundColor(DDColor.sub)
                            }
                            .frame(width: 54, height: 108)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                }
            }
            .frame(height: 108)
        }
        .padding(.vertical, 10)
        .background(DDColor.cardGrad)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(DDColor.cardEdge.opacity(0.65), lineWidth: 0.5))
        .padding(.horizontal, 16)
    }

    private func seckillCell(_ p: DDProduct) -> some View {
        VStack(spacing: 4) {
            DDThumb(em: p.em, size: 78, radius: 6, img: p.img)
            DDPrice(value: p.price, size: 15)
            Text("¥" + moneyFmt(p.orig))
                .font(pf(10.5)).foregroundColor(DDColor.sub)
                .strikethrough()
        }
        .frame(width: 82)
    }

    private var clockText: String {
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let s = secs % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    private var cateRow: some View {
        /* 2026-10-15 用户要求「功能逻辑对齐京东」——
           京东推荐区上面不是一排胶囊，是**一条可以左右滑的 tab**：
           选中那个字变红 + 底下一道红短线（其余灰字），左边第一个是「推荐」。 */
        let names: [String] = ["推荐"] + store.categories
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                ForEach(names, id: \.self) { c in
                    let on = (c == "推荐" && cate == nil) || cate == c
                    Button {
                        withAnimation(.easeOut(duration: 0.16)) {
                            cate = (c == "推荐") ? nil : (cate == c ? nil : c)
                        }
                    } label: {
                        VStack(spacing: 5) {
                            Text(Tr(c))
                                .font(pf(15, on ? .semibold : .regular))
                                .foregroundColor(on ? DDColor.red : DDColor.ink)
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(on ? DDColor.red : Color.clear)
                                .frame(width: 18, height: 2.5)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(DDColor.cardGrad)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(DDColor.cardEdge.opacity(0.65), lineWidth: 0.5))
        .padding(.horizontal, 16)
    }

    private func sectionTitle(_ t: String, right: String) -> some View {
        /* 2026-10-17 用户：「商城首页的排版感觉还是不够高级」——
           标题这块重排：竖条**细一点、短一点**（3×15，上深下浅的品牌橙渐变，
           不再是一根实心红棍），标题 17pt，右边「更多 ›」收成一组、跟标题同一个视觉重量，
           上下留白按 8pt 网格给足（top 8 / bottom 2）—— 密而不挤。 */
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(DDColor.barGrad)
                .frame(width: 3, height: 15)
                .offset(y: 1)
            Text(t).font(pf(17, .semibold)).foregroundColor(DDColor.ink)
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                Text(right).font(pf(12.5)).foregroundColor(DDColor.sub)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(DDColor.weak)
            }
            .offset(y: -1)
        }
        .padding(.horizontal, 16)      // 首页统一左右 16
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    /// 「已少推：xxx」+ 一键恢复（长按商品选「少推这一类」之后出现）
    private var mutedNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash").font(.system(size: 12)).foregroundColor(DDColor.sub)
            Text(Tr("已少推：") + store.mutedCates.map { Tr($0) }.joined(separator: "、"))
                .font(pf(12)).foregroundColor(DDColor.sub).lineLimit(1)
            Spacer(minLength: 0)
            Button {
                if let c = store.mutedCates.first { store.unmuteCate(c) }
            } label: {
                Text(Tr("恢复")).font(pf(12.5, .medium)).foregroundColor(DDColor.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var grid: some View {
        /* 2026-10-17 用户：「要有点卡片错落的设计感」——
           换成双列独立堆叠的瀑布流（卡片按内容自然高，上下错开），
           不再是 LazyVGrid 那种"一行等高"的表格感。 */
        var cells: [(view: AnyView, h: CGFloat)] = []
        for (i, p) in list.enumerated() {
            cells.append((AnyView(
                Button { onOpen(p) } label: { DDProductCard(product: p) }
                    .buttonStyle(.plain)
                    /* 长按 → 不感兴趣（京东也是长按；选「少推这一类」就把这一类沉到最后） */
                    .contextMenu {
                        Button(role: .destructive) {
                            store.notInterested(p, muteCate: false)
                            app.show(Tr("好的，这件不再推给你"))
                        } label: { Label(Tr("不感兴趣"), systemImage: "hand.thumbsdown") }
                        if !p.cate.isEmpty {
                            Button {
                                store.notInterested(p, muteCate: true)
                                app.show(Tr("好的，少推「") + Tr(p.cate) + Tr("」"))
                            } label: { Label(Tr("不感兴趣，少推这一类"), systemImage: "eye.slash") }
                        }
                    }
            ), DDWaterfallGrid.estimate(p)))
            /* 每 6 个商品插一张小广告（和京东首页一样，左下角标了「广告」） */
            if (i + 1) % 6 == 0 { cells.append((AnyView(adCard(i / 6)), 0.52)) }
        }
        return DDWaterfallGrid(cells: cells).padding(.horizontal, 16)   // 和轮播/宫格同一条边线
    }

    /// 楼间广告条：后台 ads 里 kind=strip 的第一条（没有就用内置那条）
    @ViewBuilder private var adStrip: some View {
        let list = store.ads.filter { !$0.isGrid }
        if list.isEmpty {
            EmptyView()
        } else if let a = list.first, !store.adHidden("ad:" + a.id) {
            DDAdStrip(emoji: a.emoji ?? "🛍", title: a.title, sub: a.sub ?? "",
                      cta: a.cta ?? "去看看", top: a.topColor, bottom: a.bottomColor) {
                runAd(a)
            }
            .padding(.horizontal, 16)
        }
    }

    /// 插在瀑布流里的广告卡：**后台 ads 里 kind=grid 的轮着来**（没有就用内置那两条）
    @ViewBuilder private func adCard(_ n: Int) -> some View {
        let grid = store.ads.filter { $0.isGrid }
        if !grid.isEmpty {
            let a = grid[n % grid.count]
            if !store.adHidden("ad:" + a.id) {
                DDAdCard(emoji: a.emoji ?? "🛍", title: a.title, sub: a.sub ?? "",
                         cta: a.cta ?? "去看看", top: a.topColor, bottom: a.bottomColor,
                         adKey: "ad:" + a.id) { runAd(a) }
            }
        } else if n % 2 == 1 {
            if !store.adHidden("🎧听一听：曲库新歌随便放") {
                DDAdCard(emoji: "🎧", title: "听一听：曲库新歌随便放",
                         sub: "边逛边放，好友还能看到你在听什么", cta: "去听歌",
                         top: 0xB98CFF, bottom: 0x7A45D6) { showMusicAd = true }
            }
        } else {
            if !store.adHidden("👑星言PLUS 会员") {
                DDAdCard(emoji: "👑", title: "星言PLUS 会员",
                         sub: "下单立减 5%，退货免运费，专属客服", cta: "去开通",
                         top: 0xFFE7B0, bottom: 0xD9A94A) { showVipAd = true }
            }
        }
    }

    /// 后台那条广告点开干什么：vip / music / subsidy 走 App 内页；其它就按 link 打开
    private func runAd(_ a: DDAd) {
        /* 带券的广告：点进去先把券发到卡包（每人每条一次），再跳去对应页面。
           领过的人服务端会回 already，这里给一句"已经领过了"，不会重复发。 */
        if let c = a.coupon {
            Task {
                let r = await store.claimAdCoupon(a.id)
                if let r = r {
                    if r.already == true {
                        app.show(Tr("这张券你已经领过了，在「我的 → 卡包」里"))
                    } else if r.coupon != nil {
                        app.show(Tr("已发券：") + c.text + Tr("（卡包 / 下单结算都能用）"))
                    }
                }
            }
        }
        switch a.action ?? "none" {
        case "vip":      showVipAd = true
        case "music":    showMusicAd = true
        case "subsidy":  channel = .subsidy
        default:
            if let s = a.link, !s.isEmpty, let u = URL(string: s) { openLink(u) }
        }
    }
}

/// 双列瀑布流里的那张商品卡
struct DDProductCard: View {
    let product: DDProduct

    private var artColors: [Color] {
        switch product.cate {
        case "服饰": return [Color(hex: 0xF7D6C4), Color(hex: 0xD8A58B)]
        case "美妆": return [Color(hex: 0xF7D8E3), Color(hex: 0xD9A0B5)]
        case "食品": return [Color(hex: 0xF7E5C1), Color(hex: 0xD6B36F)]
        case "家居": return [Color(hex: 0xDDE9E1), Color(hex: 0xA5BEAF)]
        case "数码": return [Color(hex: 0xDCE6F2), Color(hex: 0x9FB2C8)]
        case "运动": return [Color(hex: 0xDCEBDD), Color(hex: 0x9EBDA2)]
        default: return [Color(hex: 0xEEEAE6), Color(hex: 0xC8C0B9)]
        }
    }

    private var artSymbol: String {
        switch product.cate {
        case "服饰": return "tshirt.fill"
        case "美妆": return "sparkles"
        case "食品": return "takeoutbag.and.cup.and.straw.fill"
        case "家居": return "house.fill"
        case "数码": return "iphone"
        case "运动": return "figure.run"
        default: return "bag.fill"
        }
    }

    var body: some View {
        /* 2026-10-17 用户：「商城首页的排版感觉还是不够高级」——
           卡片重排（对齐大商城那种节奏）：
             · 卡片圆角 14→16，图自己的圆角 11（外圆角 = 内圆角 + 6 的内边距，同心才顺眼）
             · 图四周留 6pt 呼吸，图下面文字区左右 9pt、底部 10pt，全按 8pt 网格
             · 标题 13.5pt + 行距 2（两行读起来不挤）
             · 价格 18pt（¥ 小、整数大、小数小），右边跟「已拼 xxx」同一行对齐
             · 店铺名一行、右端挂一枚同色系的小标签（不再是红块，改用品牌色 10% 淡底）
             · 阴影两层：贴地一层 + 扩散一层 —— 卡是"浮"在白底上的，不是贴了条边 */
        VStack(alignment: .leading, spacing: 0) {
            /* 京东那张卡：图**正方形（1:1）且铺满卡片宽度**、圆角 6；
               ⚠ 2026-10-15 用户：「商城每个图片怎么都留点白边」——
               病根是以前固定 150 再 `.aspectRatio(.fit)`：卡比 150 宽，两边就空出来了。
               现在用 .fill 铺满（图按居中裁切，不留边）。 */
            /* 用户：「商品图要么居中」——那就按京东那种：**图完整居中**（.fit 不裁），
               四周的留白是**卡片同色（白）**，看起来是"图上留白"而不是"歪的白边"。 */
            ZStack {
                DDColor.card
                if let img = product.img, !img.isEmpty {
                    RemoteImage(path: img, icon: "photo", mode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    LinearGradient(colors: artColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: artSymbol)
                        .font(.system(size: 42, weight: .light))
                        .foregroundColor(.white.opacity(0.92))
                    Text(product.em)
                        .font(.system(size: 23))
                        .padding(8)
                        .background(Circle().fill(Color.white.opacity(0.58)))
                        .offset(x: 42, y: 42)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fill)
            .clipped()

            VStack(alignment: .leading, spacing: 7) {
                Text(product.title)
                    .font(pf(UIConfig.num("mallCardTitle", 13.5))).foregroundColor(DDColor.ink)
                    .lineSpacing(2)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                /* ⚠ 2026-10-17 用户：「分类里面有不少卡片溢出屏幕」——
                   分类页右栏一列只有 ~130pt，这一行以前是"价格 + 划线价 + 已拼 xxx"
                   三个都不可压缩 → 顶出去。现在：价格优先（layoutPriority 2），
                   划线价和销量都能各自缩到 70% 或省略号，行本身也吃满卡片宽度。 */
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    DDPrice(value: product.price, size: UIConfig.num("mallCardPrice", 18))
                        .layoutPriority(2)
                    Text("¥" + moneyFmt(product.orig))
                        .font(pf(11)).foregroundColor(DDColor.sub).strikethrough()
                        .lineLimit(1).minimumScaleFactor(0.7).layoutPriority(1)
                    Spacer(minLength: 0)
                    /* 没有真实销量数据的商品就不写「已拼 xxx」——不编数字 */
                    if !product.sold.isEmpty {
                        Text(Tr("已拼") + product.sold)
                            .font(pf(10.5)).foregroundColor(DDColor.sub)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 5) {
                    Text(product.shop).font(pf(10.5)).foregroundColor(DDColor.sub)
                        .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                    Spacer(minLength: 0)
                    /* 小标签：包邮 / 退货包运费（取商品自带标签里的头一个），
                       改成品牌色 10% 淡底 —— 比原来那块红底白字安静得多 */
                    if DDStore.groupOn == false, let tag = product.tags.first {
                        Text(tag).font(pf(9.5)).foregroundColor(DDColor.red)
                            .padding(.horizontal, 5).frame(height: 16)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(DDColor.redLight))
                    }
                    /* 拼单开着才显示「x人团」（京东那种直接买） */
                    if DDStore.groupOn {
                        Text(Tr("\(product.grp)人团"))
                            .font(pf(10)).foregroundColor(DDColor.red)
                            .padding(.horizontal, 6).frame(height: 17)
                            .background(Capsule().fill(DDColor.redLight))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .background(DDColor.cardGrad)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(DDColor.cardEdge.opacity(0.7), lineWidth: 0.6))
        .shadow(color: Color.black.opacity(0.055), radius: 9, y: 3)
    }
}

/* ---------------------------------------------------------- 推荐（种草） */

struct DDRecTab: View {
    @ObservedObject private var store = DDStore.shared
    var onOpen: (DDProduct) -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 10) {
                ForEach(store.live) { p in
                    Button { onOpen(p) } label: { recCard(p) }
                        .buttonStyle(.plain)
                }
                Spacer().frame(height: 16)
            }
            .padding(.vertical, 10)
        }
        .background(DDColor.page)
    }

    private func recCard(_ p: DDProduct) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: 0xFFD9CC)).frame(width: 26, height: 26)
                    .overlay(Text("拼").font(pf(12, .semibold)).foregroundColor(DDColor.red))
                Text(p.shop).font(pf(13.5, .medium)).foregroundColor(DDColor.ink)
                Spacer(minLength: 0)
                Text(Tr("种草")).font(pf(11)).foregroundColor(.white)
                    .padding(.horizontal, 6).frame(height: 18)
                    .background(Capsule().fill(DDColor.red))
            }
            Text(p.title).font(pf(15)).foregroundColor(DDColor.ink).lineLimit(3)
            HStack(spacing: 8) {
                DDThumb(em: p.em, size: 96, radius: 10, img: p.img)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        ForEach(p.tags.prefix(2), id: \.self) { t in
                            Text(t).font(pf(10.5)).foregroundColor(DDColor.red)
                                .padding(.horizontal, 5).frame(height: 17)
                                .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(DDColor.redLight))
                        }
                    }
                    DDPrice(value: p.price, size: 18)
                    if !p.sold.isEmpty {
                        Text(Tr("已拼") + p.sold).font(pf(11.5)).foregroundColor(DDColor.sub)
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(DDColor.cardGrad)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DDColor.cardEdge, lineWidth: 0.6))
        .shadow(color: DDColor.cardShadow, radius: 10, y: 3)
        .padding(.horizontal, 10)
    }
}

/* ---------------------------------------------------------- 消息 */

struct DDMsgTab: View {
    @ObservedObject private var store = DDStore.shared
    /// 点消息卡片 → 去看订单（以前整条卡片点不了，只有「邀好友拼单」那颗按钮能点）
    var onOrders: () -> Void

    @State private var confirmClear = false

    /// 还在拼单中、要「邀好友拼单」那一颗的订单
    private var grouping: [DDOrder] { store.orders.filter { $0.status == "grouping" } }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 10) {
                /* 2026-10-15：消息 tab 接**真服务通知** ——
                   DDStore.notices 里是下单/付款/成团/发货/签收/评价/售后时真推的那些。 */
                if store.notices.isEmpty && grouping.isEmpty {
                    Text(Tr("还没有消息")).font(pf(14)).foregroundColor(DDColor.sub)
                        .frame(maxWidth: .infinity).padding(.top, 60)
                    Text(Tr("下单、付款、成团、发货、签收、评价之后，这里都会有服务通知"))
                        .font(pf(12)).foregroundColor(DDColor.sub)
                        .multilineTextAlignment(.center).padding(.horizontal, 30)
                } else {
                    if !store.notices.isEmpty {
                        head(Tr("服务通知"), right: Tr("清空")) { confirmClear = true }
                        ForEach(store.notices) { n in noticeRow(n) }
                    }
                    if !grouping.isEmpty {
                        head(Tr("拼单消息"), right: "")
                        ForEach(grouping) { o in row(o) }
                    }
                }
                Spacer().frame(height: 16)
            }
            .padding(.vertical, 10)
        }
        .background(DDColor.page)
        .alert(Tr("清空服务通知？"), isPresented: $confirmClear) {
            Button(Tr("取消"), role: .cancel) { }
            Button(Tr("清空"), role: .destructive) { store.clearNotices() }
        }
    }

    private func head(_ t: String, right: String, tap: @escaping () -> Void = { }) -> some View {
        HStack {
            Text(t).font(pf(13.5, .medium)).foregroundColor(DDColor.sub)
            Spacer(minLength: 0)
            if !right.isEmpty {
                Button { tap() } label: {
                    Text(right).font(pf(12.5)).foregroundColor(DDColor.sub)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    /* 一条服务通知：左边的图标按类型分（订单 / 发货 / 完成 / 评价 / 成团 / 售后） */
    private func noticeRow(_ n: DDNotice) -> some View {
        /* 2026-10-15 用户：「服务通知要可以左滑删除」——包一层左滑行，滑出「删除」 */
        DDSwipeRow(onTap: { onOrders() }, onDelete: { store.removeNotice(n.id) }) {
            noticeCard(n)
        }
    }

    private func noticeCard(_ n: DDNotice) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(noticeColor(n.kind).opacity(0.12)).frame(width: 38, height: 38)
                Image(systemName: noticeIcon(n.kind))
                    .font(.system(size: 16))
                    .foregroundColor(noticeColor(n.kind))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(n.title).font(pf(14.5, .medium)).foregroundColor(DDColor.ink).lineLimit(2)
                Text(n.body).font(pf(12.5)).foregroundColor(DDColor.sub)
                    .fixedSize(horizontal: false, vertical: true)
                Text(timeText(n.at)).font(pf(11.5)).foregroundColor(DDColor.sub)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(DDColor.cardGrad)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DDColor.cardEdge, lineWidth: 0.6))
        .shadow(color: DDColor.cardShadow, radius: 10, y: 3)
        .contentShape(Rectangle())
    }

    private func noticeIcon(_ kind: String) -> String {
        switch kind {
        case "order":     return "doc.text.fill"
        case "group":     return "person.3.fill"
        case "ship":      return "shippingbox.fill"
        case "done":      return "checkmark.seal.fill"
        case "review":    return "star.fill"
        case "aftersale": return "arrow.uturn.backward.circle.fill"
        default:          return "bell.fill"
        }
    }

    private func noticeColor(_ kind: String) -> Color {
        switch kind {
        case "order":     return DDColor.red
        case "group":     return DDColor.redDeep
        case "ship":      return Color(hex: 0x2E6BFF)
        case "done":      return Color(hex: 0x1CA36B)
        case "review":    return DDColor.orange
        case "aftersale": return DDColor.weak
        default:          return DDColor.red
        }
    }

    /* 拼单消息那一行：用 onTapGesture 而不是再套一层 Button ——
       套 Button 会把里面那颗「邀好友拼单」吃掉（嵌套按钮点不动） */
    private func row(_ o: DDOrder) -> some View {
        HStack(alignment: .top, spacing: 10) {
            DDThumb(em: o.em, size: 46, radius: 8)
            VStack(alignment: .leading, spacing: 4) {
                Text(msgTitle(o)).font(pf(14.5, .medium)).foregroundColor(DDColor.ink).lineLimit(2)
                Text(o.title).font(pf(12.5)).foregroundColor(DDColor.sub).lineLimit(1)
                Text(timeText(o.at)).font(pf(11.5)).foregroundColor(DDColor.sub)
            }
            Spacer(minLength: 0)
            if o.status == "grouping" {
                Button { store.invite(o.id) } label: {
                    Text(Tr("邀好友拼单"))
                        .font(pf(12.5, .medium)).foregroundColor(.white)
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(Capsule().fill(DDColor.red))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(DDColor.cardGrad)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DDColor.cardEdge, lineWidth: 0.6))
        .shadow(color: DDColor.cardShadow, radius: 10, y: 3)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .onTapGesture { onOrders() }
    }

    private func msgTitle(_ o: DDOrder) -> String {
        switch o.status {
        case "grouping":
            let left = max(1, o.need - o.have)
            return Tr("你参与的拼单还差 ") + String(left) + Tr(" 人成团")
        case "wait":    return Tr("拼单成功，商家正在打包")
        case "shipped": return Tr("包裹已发出，注意收货")
        case "done":    return Tr("订单已完成，去评价一下吧")
        default:        return Tr("订单已取消")
        }
    }
}

/* ---------------------------------------------------------- 购物车 */

struct DDCartTab: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var store = DDStore.shared
    var onOpen: (DDProduct) -> Void
    var onOrders: () -> Void

    @State private var checked: Set<String> = []
    @State private var showPay = false
    /// 支付方式 / 星言支付收银台
    @State private var showXYPayCart = false
    /* 支付宝（2026-10-16）：购物车勾的几件合并成一个订单号再去付 */
    @State private var showAliPayCart = false
    @State private var aliPayOrder: DDOrder? = nil
    /// 收货地址：购物车结算也要地址（2026-10-16 用户：没填地址要叫去填、填完会跳转）
    @State private var pickedAddrId = ""
    @State private var showAddrList = false
    @State private var needAddr = false
    @State private var waitAddrThenPay = false

    private var lines: [DDCartLine] { store.cart }
    /// 这次结算用哪条地址：挑的那条优先，其次默认那条
    private var chosenAddr: DDAddress? {
        if !pickedAddrId.isEmpty, let a = store.addresses.first(where: { $0.id == pickedAddrId }) {
            return a
        }
        return store.defaultAddress
    }
    private var addrReady: Bool {
        guard let a = chosenAddr else { return false }
        return !a.full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !a.name.isEmpty && a.phone.count >= 6
    }
    private var total: Double {
        lines.filter { checked.contains($0.pid) }.reduce(0) { sum, l in
            sum + (store.product(l.pid)?.price ?? 0) * Double(l.count)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if lines.isEmpty {
                VStack(spacing: 10) {
                    Text("🛒").font(.system(size: 42))
                    Text(Tr("购物车还是空的")).font(pf(15)).foregroundColor(DDColor.sub)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        /* 京东购物车是按店铺分组的：一店一个表头，下面挂这个店的商品 */
                        ForEach(Array(store.cartGrouped().enumerated()), id: \.offset) { _, g in
                            shopHead(g.shop, g.lines)
                            ForEach(g.lines) { l in line(l) }
                        }
                        /* 失效商品（下架/删掉的）单独一块，能一键清空 */
                        if !store.invalidCart.isEmpty {
                            VStack(spacing: 0) {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle").font(.system(size: 13))
                                        .foregroundColor(DDColor.sub)
                                    Text(Tr("失效商品")).font(pf(13.5, .medium)).foregroundColor(DDColor.ink)
                                    Text(String(store.invalidCart.count) + Tr(" 件")).font(pf(12)).foregroundColor(DDColor.sub)
                                    Spacer(minLength: 0)
                                    Button { store.clearInvalidCart() } label: {
                                        Text(Tr("清空失效")).font(pf(12.5)).foregroundColor(DDColor.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 12).frame(height: 40)
                                ForEach(store.invalidCart) { l in
                                    HStack(spacing: 10) {
                                        Text("📦").font(.system(size: 20))
                                            .frame(width: 46, height: 46)
                                            .background(DDColor.page)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                        Text(store.product(l.pid)?.title ?? Tr("商品已下架"))
                                            .font(pf(12.5)).foregroundColor(DDColor.sub).lineLimit(1)
                                        Spacer(minLength: 0)
                                        Button { store.removeCartLine(l.pid) } label: {
                                            Text(Tr("移除")).font(pf(12.5)).foregroundColor(DDColor.sub)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 12).frame(height: 60)
                                }
                            }
                            .background(DDColor.cardGrad)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DDColor.cardEdge, lineWidth: 0.6))
                            .shadow(color: DDColor.cardShadow, radius: 10, y: 3)
                            .padding(.horizontal, 10)
                        }
                        Spacer().frame(height: 12)
                    }
                    .padding(.vertical, 10)
                }
                bottomBar
            }
        }
        .background(DDColor.page)
    }

    private func line(_ l: DDCartLine) -> some View {
        let p = store.product(l.pid)
        return HStack(spacing: 10) {
            Button { toggle(l.pid) } label: {
                Image(systemName: checked.contains(l.pid) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(checked.contains(l.pid) ? DDColor.red : DDColor.sub)
            }
            .buttonStyle(.plain)

            Button { if let p { onOpen(p) } } label: {
                HStack(spacing: 10) {
                    DDThumb(em: p?.em ?? "📦", size: 64, radius: 8, img: p?.img)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(p?.title ?? "").font(pf(13)).foregroundColor(DDColor.ink).lineLimit(2)
                        DDPrice(value: (p?.price ?? 0) * Double(l.count), size: 15)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            HStack(spacing: 0) {
                step("−") { store.setCount(l.pid, l.count - 1) }
                Text(String(l.count)).font(pf(13)).frame(width: 30)
                step("+") { store.setCount(l.pid, l.count + 1) }
            }
        }
        .padding(12)
        .background(DDColor.cardGrad)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DDColor.cardEdge, lineWidth: 0.6))
        .shadow(color: DDColor.cardShadow, radius: 10, y: 3)
        .padding(.horizontal, 10)
        /* 左滑删除这一条（京东/微信购物车都能滑） */
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { store.removeCartLine(l.pid) } label: { Text(Tr("删除")) }
        }
    }

    /// 店铺表头（京东：一店一行，右边显示这店选了几件）
    private func shopHead(_ shop: String, _ ls: [DDCartLine]) -> some View {
        let n = ls.filter { checked.contains($0.pid) }.count
        return HStack(spacing: 8) {
            Image(systemName: "storefront").font(.system(size: 13)).foregroundColor(DDColor.ink)
            Text(shop).font(pf(13.5, .medium)).foregroundColor(DDColor.ink).lineLimit(1)
            Spacer(minLength: 0)
            Text(n > 0 ? (Tr("已选 ") + String(n) + Tr(" 件")) : Tr("未选"))
                .font(pf(11.5)).foregroundColor(DDColor.sub)
        }
        .padding(.horizontal, 14).frame(height: 34)
    }

    private func step(_ t: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t).font(pf(15, .medium)).foregroundColor(DDColor.ink)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DDColor.page))
        }
        .buttonStyle(.plain)
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            HairLine()
            HStack(spacing: 10) {
                Button { checked = (checked.count == lines.count ? [] : Set(lines.map { $0.pid })) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: checked.count == lines.count && !lines.isEmpty
                              ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 19))
                            .foregroundColor(checked.count == lines.count ? DDColor.red : DDColor.sub)
                        Text(Tr("全选")).font(pf(13.5)).foregroundColor(DDColor.ink)
                    }
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                Text(Tr("合计 ")).font(pf(13)).foregroundColor(DDColor.sub)
                DDPrice(value: total, size: 18)
                Button { showPay = true } label: {
                    Text(Tr("去结算") + (checked.isEmpty ? "" : "(\(checked.count))"))
                        .font(pf(15, .medium)).foregroundColor(.white)
                        .padding(.horizontal, 18).frame(height: 38)
                        .background(Capsule().fill(checked.isEmpty
                                                   ? DDColor.sub : DDColor.red))
                }
                .buttonStyle(.plain)
                .disabled(checked.isEmpty)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(DDColor.card)
        }
        .sheet(isPresented: $showPay) { paySheet }
    }

    private var paySheet: some View {
        VStack(spacing: 0) {
            DDSheetBar(title: Tr("确认下单"))
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    /* 收货地址（和商品结算页一样那一行）：没填就红字提示，点一下进地址簿 */
                    Button { showAddrList = true } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.system(size: 19)).foregroundColor(DDColor.red)
                            VStack(alignment: .leading, spacing: 4) {
                                if let a = chosenAddr {
                                    HStack(spacing: 8) {
                                        Text(a.name.isEmpty ? Tr("未填收货人") : a.name)
                                            .font(pf(15, .medium)).foregroundColor(DDColor.ink)
                                        if !a.phone.isEmpty {
                                            Text(a.phone).font(pf(13)).foregroundColor(DDColor.sub)
                                        }
                                    }
                                    Text(a.full.isEmpty ? Tr("还没填详细地址") : a.full)
                                        .font(pf(13)).foregroundColor(DDColor.sub)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    Text(Tr("请先填写收货地址"))
                                        .font(pf(15)).foregroundColor(DDColor.red)
                                    Text(Tr("点这里新增一条")).font(pf(12.5)).foregroundColor(DDColor.sub)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(DDColor.sub.opacity(0.55))
                                .padding(.top, 4)
                        }
                        .padding(14)
                        .background(DDColor.cardGrad)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DDColor.cardEdge, lineWidth: 0.6))
                        .shadow(color: DDColor.cardShadow, radius: 10, y: 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    ForEach(lines.filter { checked.contains($0.pid) }) { l in
                        HStack(spacing: 10) {
                            DDThumb(em: store.product(l.pid)?.em ?? "📦", size: 46, radius: 8, img: store.product(l.pid)?.img)
                            Text(store.product(l.pid)?.title ?? "")
                                .font(pf(13)).foregroundColor(DDColor.ink).lineLimit(2)
                            Spacer(minLength: 0)
                            Text("×" + String(l.count)).font(pf(13)).foregroundColor(DDColor.sub)
                        }
                        .padding(12)
                        .background(DDColor.cardGrad)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DDColor.cardEdge, lineWidth: 0.6))
                        .shadow(color: DDColor.cardShadow, radius: 10, y: 3)
                    }
                    Text(Tr("合计 ") + "¥" + moneyFmt(total))
                        .font(pf(16, .semibold)).foregroundColor(DDColor.red)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, 14)
                    /* 会员：下单时还会再减这一笔（place() 里按同一套算） */
                    if store.isVip {
                        Text(Tr("PLUS会员立减 ") + "-¥" + moneyFmt(store.vipOff(total)))
                            .font(pf(12.5)).foregroundColor(DDColor.red)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.horizontal, 14)
                    }
                    Spacer().frame(height: 8)
                    /* 支付方式：**不弹窗**，直接在结算页里上下选（用户 2026-10-16 要求） */
                    DDPayWayList(payWay: $store.payWay)
                        .background(DDColor.cardGrad)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DDColor.cardEdge, lineWidth: 0.6))
                        .shadow(color: DDColor.cardShadow, radius: 10, y: 3)
                    Spacer().frame(height: 8)
                    /* 配送方式：也要能选（2026-10-16「配送里面不要光包邮」） */
                    DDDeliveryList(goods: total)
                        .background(DDColor.cardGrad)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DDColor.cardEdge, lineWidth: 0.6))
                        .shadow(color: DDColor.cardShadow, radius: 10, y: 3)
                    Spacer().frame(height: 8)
                }
                .padding(.vertical, 10)
            }
            Button {
                payAll()
            } label: {
                Text(Tr("提交订单"))
                    .font(pf(16, .medium)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 23, style: .continuous).fill(DDColor.gradBtn))
                    .padding(.horizontal, 14)
            }
            .buttonStyle(.plain)
            .padding(.bottom, max(10, L.safeBottom))
            .padding(.top, 6)
        }
        .background(DDColor.page.ignoresSafeArea())
        .sheet(isPresented: $showXYPayCart) {
            XYPaySheet(amount: payableTotal, target: cartPayTitle, note: Tr("购物车结算"),
                       onSuccess: { realPayAll() })
                .environmentObject(app)
        }
        .sheet(isPresented: $showAliPayCart) {
            if let o = aliPayOrder {
                AliPayWaitingSheet(amount: o.total, orderId: o.id,
                                   sync: { _ = await store.syncToServer(o, paid: false) }) { paid in
                    if paid {
                        store.pay(o.id)
                        app.show(Tr("支付宝付款成功"))
                    } else {
                        app.show(Tr("还没收到这笔付款，订单在「我的订单 → 待付款」里"))
                    }
                }
                .environmentObject(app)
            }
        }
        .sheet(isPresented: $showAddrList) {
            DDAddressListView(pick: { a in pickedAddrId = a.id })
        }
        .alert(Tr("请先填写收货地址"), isPresented: $needAddr) {
            Button(Tr("去填写")) { showAddrList = true }
            Button(Tr("取消"), role: .cancel) { waitAddrThenPay = false }
        } message: {
            Text(Tr("收货人、手机号、详细地址都要填，填好就直接接着付款"))
        }
        .onChange(of: showAddrList) { v in
            guard !v, waitAddrThenPay else { return }
            if addrReady {
                waitAddrThenPay = false
                /* 等地址页那一层真的收完再往下走（不然两层 sheet 会撞在一起） */
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { payAll() }
            }
        }
        .ddLight()
    }

    private var cartPayTitle: String {
        let n = lines.filter { checked.contains($0.pid) }.count
        return n > 0 ? Tr("合并付款 ") + String(n) + Tr(" 件商品") : Tr("购物车结算")
    }

    /// 购物车这一次要付多少（含会员立减）
    private var payableTotal: Double {
        max(0, total - (store.isVip ? store.vipOff(total) : 0) + store.deliveryFee(total))
    }

    private func payAll() {
        /* 购物车结算也一样：没填/填不全地址 → 先弹一句 + 跳到地址页，填好自动接着付 */
        guard addrReady else {
            waitAddrThenPay = true
            needAddr = true
            return
        }
        /* 2026-10-16：支付方式现在**只有星言支付 + 银行卡**，所以不用再判 XYPay.on ——
           以前后台把星言支付一关，这里就直连下单、**不弹收银台**，用户看到的就是"面容支付没接"。 */
        if store.payWay == XYPay.name {
            showXYPayCart = true
            return
        }
        realPayAll()
    }

    private func realPayAll() {
        let paid = (store.payWay == XYPay.name)
        /* 支付宝：合并成一个订单号（一次付款对一单，回调回来才对得上、对账也干净） */
        if store.payWay == AliPay.name {
            let picked = lines.filter { checked.contains($0.pid) }
                .map { (pid: $0.pid, count: $0.count) }
            if let o = store.placeCombined(lines: picked, address: chosenAddr, payWay: store.payWay) {
                checked = []
                showPay = false
                aliPayOrder = o
                store.jumpOrders()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showAliPayCart = true }
                return
            }
        }
        for l in lines where checked.contains(l.pid) {
            /* ⚠ 以前这里连地址都没传（address 默认 nil）—— 购物车下单下来的单子是"没地址"的。
               现在把结算页选的那条地址带上。 */
            let o = store.place(pid: l.pid, count: l.count, group: false,
                                fromCart: true, address: chosenAddr)
            /* 星言支付 = 当场付掉（推进到待发货 + 「付款成功」通知） */
            if paid { store.pay(o.id) }
        }
        checked = []
        showPay = false
        app.show(paid ? Tr("支付成功") : Tr("下单成功，去「我的订单」看进度"))
        /* 下完单直接把人送到「我的订单」（京东也是这样：下单成功 = 进订单页看进度） */
        store.jumpOrders()
    }

    private func toggle(_ pid: String) {
        if checked.contains(pid) { checked.remove(pid) } else { checked.insert(pid) }
    }
}

/* ---------------------------------------------------------- 我的 */

struct DDMineTab: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var store = DDStore.shared
    var onOrders: () -> Void
    var onOpen: (DDProduct) -> Void

    @State private var showFav = false
    @State private var showViews = false
    @State private var showMyReviews = false
    @State private var showAfterSales = false
    @State private var showCoupons = false
    @State private var showFollowed = false
    @State private var showService = false
    /// 分销 / 裂变（我的推广）
    @State private var showDist = false
    /// 不感兴趣 / 已隐藏（恢复页）
    @State private var showHidden = false
    /// 会员中心（京东：我的页顶上那张金卡点进去）
    @State private var showVip = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            /* 2026-10-17 用户：「我的页面颜色合格了，卡片排版还是不够专业」——
               和首页用同一套节奏：左右边距统一 12、卡片间距 12、
               每张卡 16 圆角 + 同一条细边 + 两层阴影（贴地 + 扩散）。
               这样"我的"整页看起来是**一组浮起来的白卡**，而不是几张拼在一起的板子。 */
            VStack(spacing: 12) {
                profileCard
                DDVipBanner { showVip = true }
                    .padding(.horizontal, 12)
                orderCard
                toolCard
                Spacer().frame(height: 16)
            }
            .padding(.vertical, 12)
        }
        .background(DDColor.page)
        .sheet(isPresented: $showFav) {
            DDFavView(onOpen: { p in
                showFav = false
                onOpen(p)
            })
            .environmentObject(app)
        }
        .sheet(isPresented: $showViews) {
            DDViewsView(onOpen: { p in
                showViews = false
                onOpen(p)
            })
        }
        .sheet(isPresented: $showMyReviews) { DDMyReviewsView() }
        .sheet(isPresented: $showAfterSales) { DDAfterSaleListView() }
        .sheet(isPresented: $showCoupons) { DDCouponSheet(total: 0) { _ in } }
        .sheet(isPresented: $showFollowed) {
            DDShopFollowListView(onOpen: { p in
                showFollowed = false
                onOpen(p)
            })
        }
        .sheet(isPresented: $showService) { DDHelpCenterView().environmentObject(app) }
        /* 我的推广（分销 + 裂变） */
        .sheet(isPresented: $showDist) { DistMeView().environmentObject(app) }
        .sheet(isPresented: $showHidden) { MallHiddenView().environmentObject(app) }
        .sheet(isPresented: $showVip) {
            DDVipPageView(onOpen: { p in
                showVip = false
                onOpen(p)
            })
            .environmentObject(app)
        }
    }

    private var profileCard: some View {
        /* 2026-10-17 用户：「我的页面也要有设计感」——
           资料卡做成"hero"：顶上继续那条红白渐变、头像加白圈和柔光、
           名字旁边挂会员标，底下压一格三栏数据（订单 / 收藏 / 足迹）。
           以前就是一行"头像 + 名字 + 一个数字"，太平。 */
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Avatar(path: app.me?.avatar ?? "", size: 64, radius: 32)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2.5))
                    .shadow(color: DDColor.red.opacity(0.16), radius: 8, y: 3)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(app.me?.nickname ?? app.me?.username ?? Tr("我"))
                            .font(pf(18, .semibold)).foregroundColor(DDColor.ink).lineLimit(1)
                        if store.isVip {
                            Text("PLUS")
                                .font(pf(10.5, .bold))
                                .foregroundColor(Color(hex: 0x5A3E14))
                                .padding(.horizontal, 6).frame(height: 18)
                                .background(Capsule().fill(LinearGradient(
                                    colors: [Color(hex: 0xFFE7B0), Color(hex: 0xFFC861)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing)))
                        }
                    }
                    Text(Tr("星言号 ") + (app.me?.username ?? ""))
                        .font(pf(12.5)).foregroundColor(DDColor.sub).lineLimit(1)
                        /* 2026-10-17 用户：「星言号要长按可以复制」 */
                        .copyOnLongPress(app.me?.username ?? "") { app.show($0) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 14)

            HairLine(inset: 16, color: DDColor.red.opacity(0.10))

            HStack(spacing: 0) {
                statCell(String(store.orders.count), Tr(DDStore.groupOn ? "我的拼单" : "我的订单")) { onOrders() }
                statDivider
                statCell(String(store.favs.count), Tr("我的收藏")) { showFav = true }
                statDivider
                statCell(String(store.viewed.count), Tr("浏览足迹")) { showViews = true }
            }
            .padding(.vertical, 14)
        }
        .background(DDColor.mineCardGrad)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(DDColor.cardEdge.opacity(0.7), lineWidth: 0.6))
        .shadow(color: Color.black.opacity(0.05), radius: 2, y: 1)
        .shadow(color: DDColor.cardShadow, radius: 14, y: 5)
        .padding(.horizontal, 12)
    }

    /// hero 卡下面那一栏数据（点得进去）
    private func statCell(_ n: String, _ label: String, _ tap: @escaping () -> Void) -> some View {
        Button { tap() } label: {
            VStack(spacing: 4) {
                Text(n).font(pf(18.5, .semibold)).foregroundColor(DDColor.ink).monospacedDigit()
                Text(label).font(pf(11.5)).foregroundColor(DDColor.sub)
            }
            .frame(maxWidth: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statDivider: some View {
        Rectangle().fill(DDColor.cardEdge).frame(width: 0.6, height: 24)
    }

    private var orderCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text(Tr("我的订单")).font(pf(16, .semibold)).foregroundColor(DDColor.ink)
                Spacer(minLength: 0)
                Button { onOrders() } label: {
                    HStack(spacing: 2) {
                        Text(Tr("全部订单")).font(pf(12.5)).foregroundColor(DDColor.sub)
                        Chevron(size: 8, line: 1.4)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
            HairLine(inset: 16)
            HStack(spacing: 0) {
                /* 拼单关了就不再有「拼团中」（京东那种：待付款 / 待发货 / 待收货 / 已完成） */
                if DDStore.groupOn {
                    orderEntry("拼团中", "person.2.fill", store.orders.filter { $0.status == "grouping" }.count)
                } else {
                    orderEntry("待付款", "creditcard.fill", store.orders.filter { $0.status == "paying" }.count)
                }
                orderEntry("待发货", "shippingbox.fill", store.orders.filter { $0.status == "wait" }.count)
                orderEntry("待收货", "truck.box.fill", store.orders.filter { $0.status == "shipped" }.count)
                orderEntry("已完成", "checkmark.seal.fill", store.orders.filter { $0.status == "done" }.count)
            }
            .padding(.vertical, 14)
        }
        .background(DDColor.cardGrad)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(DDColor.cardEdge.opacity(0.7), lineWidth: 0.6))
        .shadow(color: Color.black.opacity(0.05), radius: 2, y: 1)
        .shadow(color: DDColor.cardShadow, radius: 14, y: 5)
        .padding(.horizontal, 12)
    }

    private func orderEntry(_ label: String, _ icon: String, _ n: Int) -> some View {
        Button { onOrders() } label: {
            VStack(spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    /* 带底色的小圆角方块（同工具行、宫格的观感） */
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(LinearGradient(colors: [DDColor.red.opacity(0.16), DDColor.red.opacity(0.07)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 40, height: 40)
                        Image(systemName: icon)
                            .font(.system(size: 19))
                            .foregroundColor(DDColor.red)
                    }
                    if n > 0 {
                        Text(String(n)).font(pf(9.5, .semibold)).foregroundColor(.white)
                            .padding(.horizontal, 4).frame(height: 14)
                            .background(Capsule().fill(DDColor.redDeep))
                            .offset(x: 6, y: -4)
                    }
                }
                Text(Tr(label)).font(pf(11.5)).foregroundColor(DDColor.ink)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var toolCard: some View {
        VStack(spacing: 0) {
            toolRow("我的收藏", "heart.fill", Tr("\(store.favs.count) 件")) { showFav = true }
            HairLine(inset: 52)
            /* ⚠ 以前这里的动作是空的 `{ }`，点了没反应 —— 用户报的「有些东西点不了」就是它 */
            toolRow("浏览足迹", "clock.fill", Tr("\(store.viewed.count) 件")) { showViews = true }
            HairLine(inset: 52)
            toolRow("我的评价", "star.bubble", Tr("\(store.reviews.count) 条")) { showMyReviews = true }
            HairLine(inset: 52)
            toolRow("退款/售后", "arrow.uturn.backward", Tr("\(store.afterSales.count) 单")) { showAfterSales = true }
            HairLine(inset: 52)
            toolRow("我的优惠券", "ticket", Tr("\(store.usableCoupons(99999).count) 张可用")) { showCoupons = true }
            HairLine(inset: 52)
            toolRow("关注的店铺", "heart.circle", Tr("\(store.followedShops.count) 家")) { showFollowed = true }
            /* 2026-10-16：分销 / 裂变入口（不是分销账号也能点，进去会提示怎么开通） */
            HairLine(inset: 52)
            toolRow("我的推广", "person.badge.plus", Tr("赚佣金 / 帮好友助力")) { showDist = true }
            HairLine(inset: 52)
            /* 2026-10-16：× 掉的东西要能找回来 */
            toolRow("不感兴趣与隐藏", "hand.thumbsdown",
                    Tr("\(store.disliked.count) 件商品 · \(store.hiddenAds.count) 条广告")) { showHidden = true }
            HairLine(inset: 52)
            toolRow("联系客服", "bubble.left.and.bubble.right", "") { showService = true }
        }
        .background(DDColor.cardGrad)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(DDColor.cardEdge.opacity(0.7), lineWidth: 0.6))
        .shadow(color: Color.black.opacity(0.05), radius: 2, y: 1)
        .shadow(color: DDColor.cardShadow, radius: 14, y: 5)
        .padding(.horizontal, 12)
    }

    private func toolRow(_ title: String, _ icon: String, _ right: String,
                         _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 12) {
                /* 2026-10-17「我的页面也要有设计感」——
                   图标从小红点换成**带底色的小圆角方块**（浅红底 + 红图标），
                   和首页宫格、频道的观感统一 */
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [DDColor.red.opacity(0.16), DDColor.red.opacity(0.07)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 32, height: 32)
                    Image(systemName: icon)
                        .font(.system(size: 15))
                        .foregroundColor(DDColor.red)
                }
                Text(Tr(title)).font(pf(15.5)).foregroundColor(DDColor.ink)
                Spacer(minLength: 0)
                Text(right).font(pf(12.5)).foregroundColor(DDColor.sub).lineLimit(1)
                Chevron(size: 9, line: 1.5)
            }
            .padding(.horizontal, 14).frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

}

/* ---------------------------------------------------------- 商品详情 */

struct DDDetailView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = DDStore.shared

    let product: DDProduct
    /// 加进购物车之后要干什么（商城那边传进来：跳到「购物车」那个 tab）
    private let onCart: (() -> Void)?
    /// 点了「看了又看 / 进店」换商品（商城那边把 sheet 的 item 换掉）
    private let onOpenOther: ((DDProduct) -> Void)?

    init(product: DDProduct, onCart: (() -> Void)? = nil, onOpenOther: ((DDProduct) -> Void)? = nil) {
        self.product = product
        self.onCart = onCart
        self.onOpenOther = onOpenOther
    }

    @State private var showOrder = false
    @State private var group = true
    /// 选中的规格（默认第一个；京东加购带规格）
    @State private var pickedSpec = ""
    @State private var showSpec = false
    @State private var showShare = false
    @State private var showService = false
    @State private var showShop = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    hero
                    priceCard
                    serviceRow
                    /* 拼单关了就不显示「正在拼单」那一块（后台 ui.json 写 mallGroup=1 会回来） */
                    if DDStore.groupOn { groupCard }
                    shopCard
                    DDReviewSection(product: product)
                    DDParamSection(product: product)
                    DDDetailLongSection(product: product)
                    sectionTitle(Tr("看了又看"))
                    recommendRow
                    Spacer().frame(height: 12)
                }
                .padding(.vertical, 10)
            }
            bottomBar
        }
        .background(DDColor.page.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showOrder) {
            DDOrderSheet(product: product, group: group, spec: pickedSpec)
                .environmentObject(app)
        }
        .sheet(isPresented: $showSpec) {
            DDSpecSheet(product: product) { v in pickedSpec = v.name }
                .ddLight()
        }
        .sheet(isPresented: $showShare) { DDShareSheet(product: product).environmentObject(app) }
        .sheet(isPresented: $showService) { DDHelpCenterView(product: product).environmentObject(app) }
        .sheet(isPresented: $showShop) {
            DDShopPageView(shop: product.shop, onOpen: { p in
                showShop = false
                onOpenOther?(p)
            })
        }
        .ddLight()
        /* 进详情页就把规格默认选第一个（京东加购带规格） */
        .onAppear { if pickedSpec.isEmpty { pickedSpec = product.specList.first?.name ?? "" } }
    }

    /// 服务承诺那一条（京东：7天无理由 / 运费险 …）
    private var serviceRow: some View {
        HStack(spacing: 14) {
            ForEach(product.serviceList.prefix(4), id: \.self) { s in
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 11)).foregroundColor(DDColor.red)
                    Text(s).font(pf(11.5)).foregroundColor(DDColor.sub)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(DDColor.cardGrad)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DDColor.cardEdge, lineWidth: 0.6))
        .shadow(color: DDColor.cardShadow, radius: 10, y: 3)
        .padding(.horizontal, 10)
    }

    private func sectionTitle(_ t: String) -> some View {
        HStack {
            Text(t).font(pf(15, .semibold)).foregroundColor(DDColor.ink)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.top, 4)
    }

    /// 看了又看（同店铺/同类目随便挑几个）
    private var recommendRow: some View {
        let others = store.live.filter { $0.id != product.id && ($0.cate == product.cate || $0.shop == product.shop) }.prefix(6)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(others)) { p in
                    Button { onOpenOther?(p) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            DDThumb(em: p.em, size: 104, radius: 10, img: p.img)
                            DDPrice(value: p.price, size: 15)
                            Text(p.title).font(pf(11.5)).foregroundColor(DDColor.sub)
                                .lineLimit(2).frame(width: 104, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(DDColor.ink)
                    .frame(width: 34, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(Tr("商品详情")).font(pf(17, .semibold)).foregroundColor(DDColor.ink)
            Spacer(minLength: 0)
            Button { store.toggleFav(product.id) } label: {
                Image(systemName: store.isFav(product.id) ? "heart.fill" : "heart")
                    .font(.system(size: 17))
                    .foregroundColor(store.isFav(product.id) ? DDColor.redDeep : DDColor.ink)
                    .frame(width: 34, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { showShare = true } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 17))
                    .foregroundColor(DDColor.ink)
                    .frame(width: 34, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(DDColor.card)
        .overlay(HairLine(), alignment: .bottom)
    }

    private var hero: some View {
        ZStack {
            DDColor.gradThumb
            if let img = product.img, !img.isEmpty {
                RemoteImage(path: img, icon: "photo")
                    .frame(maxWidth: .infinity).frame(height: 260).clipped()
            } else {
                Text(product.em).font(.system(size: 150))
            }
        }
        .frame(height: 260)
    }

    private var priceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                DDPrice(value: product.price, size: 26)
                if DDStore.groupOn {
                    Text(Tr("单独购买 ¥") + moneyFmt(product.orig))
                        .font(pf(12)).foregroundColor(DDColor.sub).strikethrough()
                } else {
                    /* 不拼单就只有这一个价（京东那样），划线价留着做对比 */
                    Text("¥" + moneyFmt(product.orig))
                        .font(pf(12)).foregroundColor(DDColor.sub).strikethrough()
                }
                Spacer(minLength: 0)
                if !product.sold.isEmpty {
                    Text(Tr("已拼") + product.sold).font(pf(12)).foregroundColor(DDColor.sub)
                }
            }
            Text(product.title).font(pf(16, .medium)).foregroundColor(DDColor.ink)
            HStack(spacing: 5) {
                ForEach(product.tags, id: \.self) { t in
                    Text(t).font(pf(11)).foregroundColor(DDColor.red)
                        .padding(.horizontal, 6).frame(height: 18)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(DDColor.redLight))
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(DDColor.cardGrad)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DDColor.cardEdge, lineWidth: 0.6))
        .shadow(color: DDColor.cardShadow, radius: 10, y: 3)
        .padding(.horizontal, 10)
    }

    private var groupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(Tr("正在拼单")).font(pf(15, .semibold)).foregroundColor(DDColor.ink)
                Text(Tr("\(product.grp)人团")).font(pf(11)).foregroundColor(.white)
                    .padding(.horizontal, 6).frame(height: 18)
                    .background(Capsule().fill(DDColor.red))
                Spacer(minLength: 0)
                Text(Tr("还差 1 人成团")).font(pf(12)).foregroundColor(DDColor.sub)
            }
            ForEach(0..<2, id: \.self) { i in
                HStack(spacing: 10) {
                    Circle().fill(Color(hex: 0xFFD9CC)).frame(width: 34, height: 34)
                        .overlay(Text(i == 0 ? "拼" : "友")
                            .font(pf(13, .semibold)).foregroundColor(DDColor.red))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(i == 0 ? Tr("拼友 138****6621") : Tr("拼友 186****3302"))
                            .font(pf(13.5)).foregroundColor(DDColor.ink)
                        Text(Tr("还剩 ") + String(23 - i * 7) + Tr(" 小时"))
                            .font(pf(11.5)).foregroundColor(DDColor.sub)
                    }
                    Spacer(minLength: 0)
                    Button { app.show(Tr("已加入 TA 的拼单")) } label: {
                        Text(Tr("去拼单"))
                            .font(pf(13, .medium)).foregroundColor(.white)
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(Capsule().fill(DDColor.red))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(DDColor.cardGrad)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DDColor.cardEdge, lineWidth: 0.6))
        .shadow(color: DDColor.cardShadow, radius: 10, y: 3)
        .padding(.horizontal, 10)
    }

    private var shopCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle().fill(Color(hex: 0xFFD9CC)).frame(width: 36, height: 36)
                    .overlay(Text("店").font(pf(14, .semibold)).foregroundColor(DDColor.red))
                VStack(alignment: .leading, spacing: 2) {
                    Text(product.shop).font(pf(14.5, .medium)).foregroundColor(DDColor.ink)
                    Text(Tr("分类：") + Tr(product.cate)).font(pf(12)).foregroundColor(DDColor.sub)
                }
                Spacer(minLength: 0)
                /* 京东那三颗：进店 / 关注 / 客服 */
                Button { showShop = true } label: {
                    Text(Tr("进店")).font(pf(12.5)).foregroundColor(DDColor.ink)
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(Capsule().fill(DDColor.page))
                }
                .buttonStyle(.plain)
                Button { store.toggleFollow(product.shopKey) } label: {
                    Text(store.isFollowed(product.shopKey) ? Tr("已关注") : Tr("关注"))
                        .font(pf(12.5)).foregroundColor(store.isFollowed(product.shopKey) ? DDColor.sub : DDColor.red)
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(Capsule().stroke(store.isFollowed(product.shopKey) ? DDColor.sub.opacity(0.4) : DDColor.red, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button { showService = true } label: {
                    Text(Tr("客服")).font(pf(12.5)).foregroundColor(DDColor.ink)
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(Capsule().fill(DDColor.page))
                }
                .buttonStyle(.plain)
            }
            HairLine()
            Text(Tr("商品介绍")).font(pf(14, .semibold)).foregroundColor(DDColor.ink)
            Text(product.title + Tr(DDStore.groupOn
                                    ? "。产地直发、坏果包赔、退货包运费，拼单更便宜。"
                                    : "。产地直发、坏果包赔、退货包运费，48 小时内发货。"))
                .font(pf(13.5)).foregroundColor(DDColor.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(DDColor.cardGrad)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DDColor.cardEdge, lineWidth: 0.6))
        .shadow(color: DDColor.cardShadow, radius: 10, y: 3)
        .padding(.horizontal, 10)
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            HairLine()
            HStack(spacing: 10) {
                Button { addToCart() } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "cart.badge.plus").font(.system(size: 19))
                        Text(Tr("购物车")).font(pf(10.5))
                    }
                    .foregroundColor(DDColor.ink)
                    .frame(width: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if DDStore.groupOn {
                    /* 拼单开着：单独购买 / 发起拼单 两颗（原来的样子） */
                    Button {
                        group = false
                        showOrder = true
                    } label: {
                        buyButton(Tr("单独购买"), "¥" + moneyFmt(product.orig), Color(hex: 0xFF8B3D))
                    }
                    .buttonStyle(.plain)
                    Button {
                        group = true
                        showOrder = true
                    } label: {
                        buyButton(Tr("发起拼单"), "¥" + moneyFmt(product.price), nil)
                    }
                    .buttonStyle(.plain)
                } else {
                    /* 拼单关着：京东那种「加入购物车 / 立即购买」 */
                    /* ⚠ 2026-10-16 用户：「加入购物车…也不跳转」——
                       以前这里调的是 justAddToCart()（只加、不跳），
                       下面那个真正会跳购物车的 addToCart() 根本没被用到。
                       现在点「加入购物车」= 加进购物车 + 关掉商品页 + **切到购物车那一栏**。 */
                    Button { addToCart() } label: {
                        buyButton(Tr("加入购物车"), "", Color(hex: 0xFF8B3D))
                    }
                    .buttonStyle(.plain)
                    Button {
                        group = false
                        showOrder = true
                    } label: {
                        buyButton(Tr("立即购买"), "¥" + moneyFmt(product.price), nil)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.top, 8)
            .padding(.bottom, max(8, L.safeBottom))
        }
        .background(DDColor.card)
    }

    /// 底部那颗大按钮（拼单开着/关着都用它画，样式统一）
    private func buyButton(_ title: String, _ price: String, _ solid: Color?) -> some View {
        VStack(spacing: 1) {
            Text(title).font(pf(15, .medium))
            if !price.isEmpty { Text(price).font(pf(11.5)) }
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity).frame(height: 44)
        .background {
            if let solid { RoundedRectangle(cornerRadius: 22, style: .continuous).fill(solid) }
            else { RoundedRectangle(cornerRadius: 22, style: .continuous).fill(DDColor.gradBtn) }
        }
    }

    /// 只加购物车：不跳页、不关详情（京东那颗「加入购物车」就是这样）
    private func justAddToCart() {
        if !pickedSpec.isEmpty { store.setCartSpec(product.id, pickedSpec) }
        store.addCart(product.id)
        app.show(Tr("已加入购物车"))
    }

    /// 加入购物车：提示一下 → 关掉详情页 → **自动跳到「购物车」那个 tab**
    /// （用户报的「购物车不会自动跳转到购物车」就是这里）
    private func addToCart() {
        if !pickedSpec.isEmpty { store.setCartSpec(product.id, pickedSpec) }
        store.addCart(product.id)
        app.show(Tr("已加入购物车"))
        store.jumpCart()      // 统一请求：商城根那边切到购物车那一栏
        onCart?()
        dismiss()
    }
}

/* ---------------------------------------------------------- 下单 */

struct DDOrderSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = DDStore.shared

    let product: DDProduct
    /// 下单用哪个规格（商品详情页选好传进来）
    private let spec: String
    @State private var group: Bool
    @State private var count = 1
    /// 这次下单用哪条地址（空 = 用默认那条）
    @State private var pickedAddrId = ""
    @State private var showAddrList = false
    /// 优惠券 / 备注 / 发票（对齐京东结算页）
    @State private var couponOff: Double = 0
    @State private var couponTitle = ""
    @State private var showCoupon = false
    @State private var remark = ""
    @State private var invoice = ""
    @State private var showInvoice = false
    /// 会员中心（结算页点「PLUS会员」那行进）
    @State private var showVip = false
    /// 没填收货地址时弹的那句话（点「去填写」直接跳地址页）
    @State private var needAddr = false
    /// 这一单是"因为没填地址被打回来"的 —— 地址填好回来自动接着付
    @State private var waitAddrThenPay = false
    /// 星言支付收银台（支付方式本身就在页面上选，不用弹窗）
    @State private var showXYPay = false
    /* 支付宝（2026-10-16）：下单后盖一层「等付款」，自动查单 */
    @State private var showAliPay = false
    @State private var aliPayOrder: DDOrder? = nil

    init(product: DDProduct, group: Bool, spec: String = "") {
        self.product = product
        self.spec = spec
        _group = State(initialValue: group)
    }

    /// 单价：拼单关着就只有一个价（product.price）
    private var unit: Double { (DDStore.groupOn && !group) ? product.orig : product.price }
    private var total: Double { unit * Double(count) }

    var body: some View {
        VStack(spacing: 0) {
            DDSheetBar(title: Tr("确认订单"))
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        DDThumb(em: product.em, size: 68, radius: 8, img: product.img)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(product.title).font(pf(13.5)).foregroundColor(DDColor.ink).lineLimit(2)
                            DDPrice(value: unit, size: 17)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(DDColor.cardGrad)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DDColor.cardEdge, lineWidth: 0.6))
                    .shadow(color: DDColor.cardShadow, radius: 10, y: 3)

                    /* 拼单开着才选方式；关着就直接按这个价买（京东那样） */
                    if DDStore.groupOn {
                        VStack(spacing: 0) {
                            pick(Tr("发起拼单") + "（\(product.grp)人团）", Tr("按拼单价，人满发货"), true)
                            HairLine(inset: 14)
                            pick(Tr("单独购买"), Tr("按单买价，不用等人"), false)
                        }
                        .background(DDColor.cardGrad)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DDColor.cardEdge, lineWidth: 0.6))
                        .shadow(color: DDColor.cardShadow, radius: 10, y: 3)
                    }

                    HStack(spacing: 0) {
                        Text(Tr("数量")).font(pf(14.5)).foregroundColor(DDColor.ink)
                        Spacer(minLength: 0)
                        Button { if count > 1 { count -= 1 } } label: {
                            Text("−").font(pf(16, .medium)).foregroundColor(DDColor.ink)
                                .frame(width: 30, height: 30)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DDColor.page))
                        }
                        .buttonStyle(.plain)
                        Text(String(count)).font(pf(14)).frame(width: 36)
                        Button { count += 1 } label: {
                            Text("+").font(pf(16, .medium)).foregroundColor(DDColor.ink)
                                .frame(width: 30, height: 30)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DDColor.page))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(14)
                    .background(DDColor.cardGrad)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DDColor.cardEdge, lineWidth: 0.6))
                    .shadow(color: DDColor.cardShadow, radius: 10, y: 3)

                    /* 收货地址：显示默认那条，点一下进地址簿挑（照京东） */
                    Button { showAddrList = true } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.system(size: 19)).foregroundColor(DDColor.red)
                            VStack(alignment: .leading, spacing: 4) {
                                if let a = chosenAddr {
                                    HStack(spacing: 8) {
                                        Text(a.name.isEmpty ? Tr("未填收货人") : a.name)
                                            .font(pf(15, .medium)).foregroundColor(DDColor.ink)
                                        if !a.phone.isEmpty {
                                            Text(a.phone).font(pf(13)).foregroundColor(DDColor.sub)
                                        }
                                    }
                                    Text(a.full.isEmpty ? Tr("还没填详细地址") : a.full)
                                        .font(pf(13)).foregroundColor(DDColor.sub)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    Text(Tr("请先填写收货地址"))
                                        .font(pf(15)).foregroundColor(DDColor.red)
                                    Text(Tr("点这里新增一条")) .font(pf(12.5)).foregroundColor(DDColor.sub)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(DDColor.sub.opacity(0.55))
                                .padding(.top, 4)
                        }
                        .padding(14)
                        .background(DDColor.cardGrad)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DDColor.cardEdge, lineWidth: 0.6))
                        .shadow(color: DDColor.cardShadow, radius: 10, y: 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    /* 优惠券 / 发票 / 备注 / 配送 / 支付方式（京东结算页那几行） */
                    VStack(spacing: 0) {
                        payRow(Tr("优惠券"), couponOff > 0 ? ("-¥" + moneyFmt(couponOff)) : Tr("不使用"), red: couponOff > 0) {
                            showCoupon = true
                        }
                        HairLine(inset: 14)
                        /* 会员立减（京东 PLUS 那行）：开着就减，没开就提示开通 */
                        payRow(Tr("PLUS会员"),
                               memberOff > 0
                                 ? ("-¥" + moneyFmt(memberOff))
                                 : (DDStore.groupOn ? Tr("未开通") : Tr("未开通 · 立省 ¥" + moneyFmt(wouldSave))),
                               red: memberOff > 0) { showVip = true }
                        HairLine(inset: 14)
                        payRow(Tr("发票"), invoice.isEmpty ? Tr("不开发票") : invoice, red: false) { showInvoice = true }
                        HairLine(inset: 14)
                        /* 配送：真正的配送方式 + 运费（2026-10-16「不要光包邮」） */
                        DDDeliveryList(goods: goodsAmount)
                        HairLine(inset: 14)
                        /* 支付方式直接摊在这一段里，点哪行选哪行（不弹窗） */
                        DDPayWayList(payWay: $store.payWay)
                    }
                    .background(DDColor.cardGrad)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DDColor.cardEdge, lineWidth: 0.6))
                    .shadow(color: DDColor.cardShadow, radius: 10, y: 3)

                    HStack(spacing: 10) {
                        Text(Tr("备注")).font(pf(14)).foregroundColor(DDColor.ink)
                        TextField(Tr("给商家留言（可不填）"), text: $remark)
                            .font(pf(13.5))
                    }
                    .padding(.horizontal, 14).frame(height: 48)
                    .background(DDColor.cardGrad)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DDColor.cardEdge, lineWidth: 0.6))
                    .shadow(color: DDColor.cardShadow, radius: 10, y: 3)

                    HStack {
                        Text(Tr("合计")).font(pf(14)).foregroundColor(DDColor.sub)
                        Spacer(minLength: 0)
                        DDPrice(value: payable, size: 20)
                    }
                    .padding(.horizontal, 4)
                    Spacer().frame(height: 8)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            Button { submit() } label: {
                Text((DDStore.groupOn && group) ? Tr("发起拼单") : Tr("立即支付"))
                    .font(pf(16, .medium)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 23, style: .continuous).fill(DDColor.gradBtn))
                    .padding(.horizontal, 14)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            .padding(.bottom, max(10, L.safeBottom))
        }
        .background(DDColor.page.ignoresSafeArea())
        .sheet(isPresented: $showAddrList) {
            DDAddressListView(pick: { a in pickedAddrId = a.id })
        }
        /* 没填地址：先提醒，点「去填写」直接跳地址页 */
        .alert(Tr("请先填写收货地址"), isPresented: $needAddr) {
            Button(Tr("去填写")) { showAddrList = true }
            Button(Tr("取消"), role: .cancel) { waitAddrThenPay = false }
        } message: {
            Text(Tr("收货人、手机号、详细地址都要填，填好就直接接着付款"))
        }
        /* 从地址页回来：这一单是因为没地址被拦下的，填好了就自动继续 */
        .onChange(of: showAddrList) { v in
            guard !v, waitAddrThenPay else { return }
            let a = chosenAddr
            let full = (a?.full ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = a != nil && !full.isEmpty && !(a!.name.isEmpty) && (a!.phone.count >= 6)
            if ok {
                waitAddrThenPay = false
                /* 等地址页那一层真的收完再往下走（不然两层 sheet 会撞在一起） */
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { submit() }
            }
        }
        .sheet(isPresented: $showCoupon) {
            DDCouponSheet(total: payable) { c in
                couponOff = c?.off ?? 0
                couponTitle = c?.title ?? ""
                if let c = c { store.useCoupon(c.id) }
            }
        }
        .sheet(isPresented: $showInvoice) {
            DDInvoiceSheet(title: $invoice).ddLight()
        }
        .sheet(isPresented: $showVip) {
            DDVipPageView().environmentObject(app)
        }
        /* 星言支付收银台：验过（指纹/面容 或 支付密码）才真下单 */
        .sheet(isPresented: $showXYPay) {
            XYPaySheet(amount: payable, target: product.title,
                       note: (DDStore.groupOn && group ? Tr("发起拼单") : Tr("立即购买")) + " ×" + String(count),
                       onSuccess: { doSubmit() })
                .environmentObject(app)
        }
        /* 支付宝：调起支付宝 + 等它回调（钱真到账了才把单标成已付） */
        .sheet(isPresented: $showAliPay) {
            if let o = aliPayOrder {
                AliPayWaitingSheet(amount: o.total, orderId: o.id,
                                   sync: { _ = await store.syncToServer(o, paid: false) }) { paid in
                    if paid {
                        store.pay(o.id)
                        app.show(Tr("支付宝付款成功"))
                    } else {
                        app.show(Tr("还没收到这笔付款，订单在「我的订单 → 待付款」里"))
                    }
                }
                .environmentObject(app)
            }
        }
        .ddLight()
    }

    /// 这一单的商品金额（不含优惠）
    private var goodsAmount: Double {
        let u = product.specList.first { $0.name == spec }?.price ?? unit
        return u * Double(count)
    }

    /// 会员立减（不是会员 = 0）
    private var memberOff: Double { store.vipOff(goodsAmount) }
    /// 不是会员的话，开通能省这么多（结算页那行提示用）
    private var wouldSave: Double { (goodsAmount * (1 - DDStore.vipRate) * 100).rounded() / 100 }

    /// 应付 = 单价×数量 − 优惠券 − 会员立减 + 运费（运费按配送方式算）
    private var payable: Double {
        max(0, goodsAmount - couponOff - memberOff + store.deliveryFee(goodsAmount))
    }

    private func payRow(_ l: String, _ r: String, red: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack {
                Text(l).font(pf(14)).foregroundColor(DDColor.ink)
                Spacer(minLength: 0)
                Text(r).font(pf(13.5)).foregroundColor(red ? DDColor.red : DDColor.sub)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DDColor.sub.opacity(0.55))
            }
            .padding(.horizontal, 14).frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 这次下单用哪条地址：下单页里挑的那条优先，其次默认那条
    private var chosenAddr: DDAddress? {
        if !pickedAddrId.isEmpty, let a = store.addresses.first(where: { $0.id == pickedAddrId }) {
            return a
        }
        return store.defaultAddress
    }

    private func pick(_ title: String, _ sub: String, _ isGroup: Bool) -> some View {
        Button { group = isGroup } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(pf(15, .medium)).foregroundColor(DDColor.ink)
                    Text(sub).font(pf(12)).foregroundColor(DDColor.sub)
                }
                Spacer(minLength: 0)
                Image(systemName: group == isGroup ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(group == isGroup ? DDColor.red : DDColor.sub)
            }
            .padding(.horizontal, 14).frame(height: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func submit() {
        /* ⚠ 2026-10-16 用户：「立即支付，没填地址要叫填写地址，然后要会跳转」。
           以前这里不看地址，直接就把单下出去了（地址是空的）。
           现在：地址没有 / 收货人 / 手机号 / 详细地址不全 → **先弹一句 + 点「去填写」
           直接跳到地址页**；填好回来这一单**自动接着往下走**（不用再点一次支付）。 */
        let a = chosenAddr
        let full = (a?.full ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let incomplete = (a?.name.isEmpty ?? true) || ((a?.phone.count ?? 0) < 6)
        if a == nil || full.isEmpty || incomplete {
            waitAddrThenPay = true
            needAddr = true
            return
        }
        /* 选了星言支付：先走收银台（指纹/面容 或 支付密码），验过了才真下单 */
        if store.payWay == XYPay.name {
            showXYPay = true
            return
        }
        doSubmit()
    }

    /// 真正下单（星言支付验过之后也走这里）
    private func doSubmit() {
        /* 拼单关着：不管从哪儿进来都按「直接买」下单 */
        let o = store.place(pid: product.id, count: count, group: DDStore.groupOn && group, spec: spec,
                            address: chosenAddr, remark: remark.trimmingCharacters(in: .whitespaces),
                            freight: 0, couponOff: couponOff, invoice: invoice, memberOff: memberOff,
                            payWay: store.payWay, paying: true)
        /* 星言支付 = 当场付掉，直接推到「待发货」+ 一条「付款成功」服务通知 */
        if store.payWay == XYPay.name { store.pay(o.id) }
        /* 支付宝 = 先把单落下来（状态「待付款」，服务端也记成未付），再调起支付宝 */
        if store.payWay == AliPay.name {
            dismiss()
            aliPayOrder = o
            store.jumpOrders()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showAliPay = true }
            return
        }
        dismiss()
        app.show(doneText)
        /* 下完单 / 付完款 → 直接跳到「我的订单」（京东那种：订单提交成功就进订单页） */
        store.jumpOrders()
    }

    private var doneText: String {
        (store.payWay == XYPay.name) ? Tr("支付成功") : Tr("订单已提交，去付款")
    }
}

/* ---------------------------------------------------------- 我的订单 */

struct DDOrdersView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = DDStore.shared
    @State private var filter = 0

    /// 从商城二楼那几格点进来时，直接落在对应的筛选上（0 全部 / 1 待付款 / 2 待发货 / 3 待收货）
    init(startFilter: Int = 0) {
        _filter = State(initialValue: max(0, startFilter))
    }

    /// 点订单卡进详情（京东那套）
    @State private var detailOrder: DDOrder?
    /// 待付款订单「立即付款」走不走星言支付收银台
    @State private var payWithXY: DDOrder? = nil
    /* 支付宝（2026-10-16）：待付款那一单点了「支付宝付款」→ 盖这层等回调 */
    @State private var payWithAli: DDOrder? = nil

    /// 拼单关了就把「拼团中」换成「待付款」（京东那排）
    private var names: [String] {
        DDStore.groupOn ? ["全部", "拼团中", "待发货", "待收货", "已完成"]
                        : ["全部", "待付款", "待发货", "待收货", "已完成"]
    }

    private var list: [DDOrder] {
        switch filter {
        case 1: return store.orders.filter { DDStore.groupOn ? $0.status == "grouping" : $0.status == "paying" }
        case 2: return store.orders.filter { $0.status == "wait" }
        case 3: return store.orders.filter { $0.status == "shipped" }
        case 4: return store.orders.filter { $0.status == "done" }
        default: return store.orders
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            DDSheetBar(title: Tr("我的订单"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(names.indices, id: \.self) { i in
                        Button { filter = i } label: {
                            Text(Tr(names[i]))
                                .font(pf(13.5, filter == i ? .semibold : .regular))
                                .foregroundColor(filter == i ? .white : DDColor.ink)
                                .padding(.horizontal, 14).frame(height: 30)
                                .background(Capsule().fill(filter == i
                                                            ? DDColor.red : DDColor.page))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }
            .padding(.vertical, 8)
            .background(DDColor.page)

            if list.isEmpty {
                VStack(spacing: 8) {
                    Text("📦").font(.system(size: 38))
                    Text(Tr("这里还没有订单")).font(pf(14.5)).foregroundColor(DDColor.sub)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DDColor.page)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(list) { o in card(o) }
                        Spacer().frame(height: 14)
                    }
                    .padding(.vertical, 10)
                }
                .background(DDColor.page)
            }
        }
        .background(DDColor.page.ignoresSafeArea())
        .sheet(item: $detailOrder) { o in
            DDOrderDetailView(orderId: o.id).environmentObject(app)
        }
        /* 星言支付收银台（待付款那一单） */
        .sheet(item: $payWithXY) { o in
            XYPaySheet(amount: o.total, target: o.title,
                       note: Tr("订单付款 · ") + o.statusText,
                       onSuccess: {
                           store.pay(o.id)
                           app.show(Tr("支付成功"))
                      })
                .environmentObject(app)
        }
        /* 支付宝付款（待付款那一单） */
        .sheet(item: $payWithAli) { o in
            AliPayWaitingSheet(amount: o.total, orderId: o.id,
                               sync: { _ = await store.syncToServer(o, paid: false) }) { paid in
                if paid {
                    store.pay(o.id)
                    app.show(Tr("支付宝付款成功"))
                } else {
                    app.show(Tr("还没收到这笔付款，订单还在「待付款」"))
                }
            }
            .environmentObject(app)
        }
        .ddLight()
    }

    private func card(_ o: DDOrder) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(o.shop).font(pf(13.5, .medium)).foregroundColor(DDColor.ink).lineLimit(1)
                Spacer(minLength: 0)
                Text(Tr(o.statusText))
                    .font(pf(12.5, .medium))
                    .foregroundColor(o.status == "done" || o.status == "cancel" ? DDColor.sub : DDColor.red)
            }
            if o.canPay {
                Text(Tr("还剩 ") + String(format: "%02d:%02d", o.payLeft / 60, o.payLeft % 60) + Tr(" 未付款"))
                    .font(pf(11.5)).foregroundColor(DDColor.red)
            }
            HStack(alignment: .top, spacing: 10) {
                DDThumb(em: o.em, size: 62, radius: 8)
                VStack(alignment: .leading, spacing: 4) {
                    Text(o.title).font(pf(13)).foregroundColor(DDColor.ink).lineLimit(2)
                    if o.group, DDStore.groupOn {
                        Text(Tr("拼团 ") + "\(o.have)/\(o.need)" + Tr(" 人"))
                            .font(pf(11.5)).foregroundColor(DDColor.sub)
                    }
                    Text(timeText(o.at)).font(pf(11)).foregroundColor(DDColor.sub)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    DDPrice(value: o.price, size: 15)
                    Text("×" + String(o.count)).font(pf(11.5)).foregroundColor(DDColor.sub)
                }
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                    if o.canPay {
                        Button { store.cancelOrder(o.id) } label: { smallBtn(Tr("取消订单"), false) }
                            .buttonStyle(.plain)
                        Button { payOrder(o) } label: { smallBtn(Tr("立即付款"), true) }
                            .buttonStyle(.plain)
                    }
                if o.status == "grouping", DDStore.groupOn {
                    Button { store.invite(o.id) } label: { smallBtn(Tr("邀好友拼单"), true) }
                        .buttonStyle(.plain)
                }
                if o.status == "wait" {
                    Button { store.ship(o.id) } label: { smallBtn(Tr("提醒发货"), false) }
                        .buttonStyle(.plain)
                }
                if o.canConfirm {
                    Button { store.confirm(o.id) } label: { smallBtn(Tr("确认收货"), true) }
                        .buttonStyle(.plain)
                }
                if o.canCancel {
                    Button { store.cancelOrder(o.id) } label: { smallBtn(Tr("取消订单"), false) }
                        .buttonStyle(.plain)
                }
                if o.status == "done" || o.status == "cancel" {
                    if o.status == "done" && !o.reviewed {
                        Button {
                            store.reorder(o)
                            app.show(Tr("已加入购物车"))
                            store.jumpCart()      // 「再来一单」= 加进购物车 + 跳过去（京东就是这样）
                        } label: { smallBtn(Tr("再来一单"), false) }
                            .buttonStyle(.plain)
                    }
                    Button { store.removeOrder(o.id) } label: { smallBtn(Tr("删除"), false) }
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(DDColor.cardGrad)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DDColor.cardEdge, lineWidth: 0.6))
        .shadow(color: DDColor.cardShadow, radius: 10, y: 3)
        .padding(.horizontal, 10)
        /* 点卡片任意位置 → 订单详情（里面那颗小按钮仍然能点，Button 优先） */
        .contentShape(Rectangle())
        .onTapGesture { detailOrder = o }
    }

    private func smallBtn(_ t: String, _ filled: Bool) -> some View {
        Text(t)
            .font(pf(12.5))
            .foregroundColor(filled ? .white : DDColor.ink)
            .padding(.horizontal, 12).frame(height: 30)
            .background(Capsule().fill(filled ? DDColor.red : DDColor.page))
    }

    /// 付这一单：选了星言支付就先过收银台（指纹/面容 或 支付密码）
    private func payOrder(_ o: DDOrder) {
        if store.payWay == XYPay.name {
            payWithXY = o
            return
        }
        /* 支付宝：直接调起支付宝，等回调（钱到了才标已付） */
        if store.payWay == AliPay.name {
            payWithAli = o
            return
        }
        store.pay(o.id)
        app.show(Tr("支付成功"))
    }
}

/* ---------------------------------------------------------- 收藏 / 搜索 */

struct DDFavView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = DDStore.shared
    var onOpen: (DDProduct) -> Void

    private var list: [DDProduct] { store.products.filter { store.isFav($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            DDSheetBar(title: Tr("我的收藏"))
            if list.isEmpty {
                Text(Tr("还没有收藏的商品")).font(pf(14.5)).foregroundColor(DDColor.sub)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                        GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(list) { p in
                            Button { onOpen(p) } label: { DDProductCard(product: p) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(DDColor.page.ignoresSafeArea())
        .ddLight()
    }
}

/* ---------------------------------------------------------- 浏览足迹 */

/// 我看过的商品（点开详情就记一条；和「我的收藏」一个样子）
struct DDViewsView: View {
    @ObservedObject private var store = DDStore.shared
    var onOpen: (DDProduct) -> Void

    private var list: [DDProduct] { store.viewed }

    var body: some View {
        VStack(spacing: 0) {
            DDSheetBar(title: Tr("浏览足迹"))
            if list.isEmpty {
                Text(Tr("还没有浏览记录")).font(pf(14.5)).foregroundColor(DDColor.sub)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                        GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(list) { p in
                            Button { onOpen(p) } label: { DDProductCard(product: p) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                }
                Button {
                    store.clearViews()
                } label: {
                    Text(Tr("清空浏览足迹"))
                        .font(pf(14.5)).foregroundColor(DDColor.sub)
                        .frame(maxWidth: .infinity).frame(height: 44)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
            }
        }
        .background(DDColor.page.ignoresSafeArea())
        .ddLight()
    }
}

struct DDSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = DDStore.shared
    var onOpen: (DDProduct) -> Void

    @State private var q = ""
    /// 排序："" 综合 / "sales" 销量 / "priceUp" 价格升序 / "priceDown" 价格降序
    @State private var sort = ""
    /// 只看有货（至少一个规格还有库存）
    @State private var onlyStock = false

    private var kw: String { q.trimmingCharacters(in: .whitespaces) }

    /* 热搜榜：词全是从**真商品**里数出来的（分类 / 标签 / 店铺），按"有几件商品"排，
       谁的商品多谁靠前 —— 不编关键词（以前那 6 个是写死的）。 */
    private var hot: [String] {
        var score: [String: Int] = [:]
        for p in store.live {
            for k in ([p.cate, p.shop] + p.tags) where !k.isEmpty {
                score[k, default: 0] += 1
            }
        }
        return score.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(10).map { $0.key }
    }

    /// 联想词：打了几个字 → 从分类 / 标签 / 店铺 / 标题里挑含它的（最多 6 条）
    private var suggest: [String] {
        let k = kw
        guard !k.isEmpty else { return [] }
        var out: [String] = []
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, t != k, !out.contains(t), out.count < 6 { out.append(t) }
        }
        for p in store.live where p.cate.localizedCaseInsensitiveContains(k) { add(p.cate) }
        for p in store.live {
            for t in p.tags where t.localizedCaseInsensitiveContains(k) { add(t) }
        }
        for p in store.live where p.shop.localizedCaseInsensitiveContains(k) { add(p.shop) }
        for p in store.live where p.title.localizedCaseInsensitiveContains(k) { add(p.title) }
        return out
    }

    /// 结果：先按词筛，再「只看有货」，最后排序
    private var result: [DDProduct] {
        var list = store.search(kw)
        if onlyStock { list = list.filter { $0.inStock } }
        switch sort {
        case "sales":     list.sort { $0.salesNum > $1.salesNum }
        case "priceUp":   list.sort { $0.price < $1.price }
        case "priceDown": list.sort { $0.price > $1.price }
        default: break
        }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if kw.isEmpty { idle } else { found }
        }
        .background(DDColor.page.ignoresSafeArea())
        .ddLight()
    }

    private var searchBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(DDColor.ink)
                        .frame(width: 32, height: 38)
                }
                .buttonStyle(.plain)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14)).foregroundColor(DDColor.weak)
                    TextField(Tr("搜索想要的商品"), text: $q)
                        .font(pf(14.5))
                        .submitLabel(.search)
                        .onSubmit { store.pushHistory(kw) }
                    if !q.isEmpty {
                        Button { q = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15)).foregroundColor(DDColor.weak)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12).frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 10).fill(DDColor.card))
            }
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 8)
        .background(DDColor.page)
    }

    /// 还没打字：搜索历史 + 热搜榜
    private var idle: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                if !store.history.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text(Tr("搜索历史")).font(pf(14.5, .semibold)).foregroundColor(DDColor.ink)
                            Spacer(minLength: 0)
                            Button { store.clearHistory() } label: {
                                Text(Tr("清空")).font(pf(12.5)).foregroundColor(DDColor.sub)
                            }
                            .buttonStyle(.plain)
                        }
                        chips(store.history, fill: true)
                    }
                }
                DDSearchHotBoard(words: hot) { w in pick(w) }
                Spacer().frame(height: 10)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
        }
        .background(DDColor.page)
    }

    /// 打了字：联想词 + 排序筛选条 + 结果
    private var found: some View {
        VStack(spacing: 0) {
            if !suggest.isEmpty {
                DDSuggestList(words: suggest) { w in pick(w) }
            }
            DDSearchFilterBar(sort: sort, onlyStock: onlyStock,
                              onSort: { sort = $0 },
                              onStock: { onlyStock.toggle() })
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(result) { p in
                        Button {
                            store.pushHistory(kw)
                            onOpen(p)
                        } label: { resultRow(p) }
                        .buttonStyle(.plain)
                    }
                    if result.isEmpty {
                        Text(Tr("没有找到相关商品")).font(pf(14)).foregroundColor(DDColor.sub)
                            .padding(.top, 50)
                    }
                    Spacer().frame(height: 14)
                }
                .padding(.vertical, 10)
            }
            .background(DDColor.page)
        }
    }

    /// 点了热搜 / 联想词：填进输入框 + 记一条历史
    private func pick(_ w: String) {
        q = w
        store.pushHistory(w)
    }

    private func chips(_ arr: [String], fill: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 8)], spacing: 8) {
            ForEach(arr, id: \.self) { s in
                Button { q = s } label: {
                    Text(s)
                        .font(pf(13)).foregroundColor(fill ? DDColor.ink : DDColor.red)
                        .padding(.horizontal, 10).frame(height: 30)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(fill ? DDColor.card : DDColor.redLight))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func resultRow(_ p: DDProduct) -> some View {
        HStack(spacing: 10) {
            DDThumb(em: p.em, size: 62, radius: 8, img: p.img)
            VStack(alignment: .leading, spacing: 5) {
                Text(p.title).font(pf(13.5)).foregroundColor(DDColor.ink).lineLimit(2)
                HStack(spacing: 6) {
                    DDPrice(value: p.price, size: 16)
                    if !p.sold.isEmpty {
                        Text(Tr("已拼") + p.sold).font(pf(11.5)).foregroundColor(DDColor.sub)
                    }
                }
                Text(p.shop).font(pf(11.5)).foregroundColor(DDColor.sub).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(DDColor.cardGrad)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DDColor.cardEdge, lineWidth: 0.6))
        .shadow(color: DDColor.cardShadow, radius: 10, y: 3)
        .padding(.horizontal, 10)
    }
}

/* ---------------------------------------------------------- 公共小条 */

/// 商城里的「左滑删除」行（消息 tab 的服务通知用）
/// ⚠ 和会话列表**同一套**手势层（ChatsView 的 RowSwipeCatcher）：
///    SwiftUI 的 DragGesture 在 iOS 26 SDK 下会把 ScrollView 的竖滑吃掉（踩过），
///    UIKit 的 pan 能声明「和滚动同时识别」，竖向照常滚，横向才算左滑。
struct DDSwipeRow<Content: View>: View {
    var onTap: () -> Void
    var onDelete: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var dx: CGFloat = 0
    @State private var start: CGFloat = 0
    private var actW: CGFloat { UIConfig.num("mallSwipeW", 84) }

    var body: some View {
        ZStack(alignment: .trailing) {
            content()
                .offset(x: dx)
            Button { onDelete() } label: {
                VStack(spacing: 3) {
                    Image(systemName: "trash.fill").font(.system(size: 16))
                    Text(Tr("删除")).font(pf(12))
                }
                .foregroundColor(.white)
                .frame(width: actW)
                .frame(maxHeight: .infinity)
                .background(DDColor.red)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(dx < -4 ? 1 : 0)
            .allowsHitTesting(dx <= -actW * 0.55)
        }
        .padding(.horizontal, 10)
        /* 手势层盖在内容上（宽度跟着滑开量收，露出来的删除键才点得到） */
        .overlay(alignment: .leading) {
            RowSwipeCatcher(
                onTap: { _ in
                    if dx != 0 { close() } else { onTap() }
                },
                onBegan: { start = dx },
                onChanged: { v in
                    var x = min(0, start + v)                       // 只能往左
                    if x < -actW { x = -(actW + min(26, (-x - actW) * 0.25)) }   // 拉过头有一点阻尼
                    dx = x
                },
                onEnded: { _, vx in
                    let open = vx <= -260 || (-dx > actW * 0.45 && vx < 260)
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        dx = open ? -actW : 0
                    }
                }
            )
            .frame(width: max(0, L.width - 20 + dx))
        }
    }

    private func close() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { dx = 0 }
    }
}

/// sheet 上那条「取消 + 标题」的顶栏（这些页面是弹出来的，不需要返回箭头）
struct DDSheetBar: View {
    @Environment(\.dismiss) private var dismiss
    let title: String

    var body: some View {
        ZStack {
            Text(Tr(title)).font(pf(17, .semibold)).foregroundColor(DDColor.ink)
            HStack {
                Button { dismiss() } label: {
                    Text(Tr("关闭")).font(pf(16)).foregroundColor(DDColor.ink)
                        .frame(height: 44)
                        .padding(.horizontal, 14)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
        }
        .frame(height: L.navH)
        .background(DDColor.card)
        .overlay(HairLine(), alignment: .bottom)
    }
}

/// 「x 分钟前 / 昨天 / 10-12 15:20」这种时间
func ddTimeText(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) {
        let mins = Int(Date().timeIntervalSince(d) / 60)
        if mins < 1 { return "刚刚" }
        if mins < 60 { return "\(mins) 分钟前" }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return "今天 " + f.string(from: d)
    }
    if cal.isDateInYesterday(d) {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return "昨天 " + f.string(from: d)
    }
    let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
    return f.string(from: d)
}

private func timeText(_ d: Date) -> String { ddTimeText(d) }

/* ============================================================ 结算页的「支付方式」
   用户 2026-10-16：「支付方式不要弹窗口出来，直接在那里上下选」——
   所以这里做成一张卡片里上下排列的选项，点哪行就是选哪行，右边打勾。
   以前是点一行 → 弹系统确认框，要再抬手点第二次，结算页里显得很跳。 */
/* ---------------- 结算页的配送方式（2026-10-16：不要光包邮） ----------------
   一行一行列出来（不弹窗），点哪行用哪行；右边显示这一单的运费（满额显示"免运费"）。 */
struct DDDeliveryList: View {
    /// 商品金额（用来算满额免运费）
    let goods: Double
    @ObservedObject private var store = DDStore.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(Tr("配送")).font(pf(14)).foregroundColor(DDColor.ink)
                Spacer(minLength: 0)
                Text(store.deliveryMode?.days ?? "").font(pf(12)).foregroundColor(DDColor.sub)
            }
            .padding(.horizontal, 14).frame(height: 40)
            HairLine(inset: 14)
            ForEach(store.deliveryModes) { m in
                let on = (store.deliveryMode?.id == m.id)
                Button { store.deliveryModeId = m.id } label: {
                    HStack(spacing: 10) {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18))
                            .foregroundColor(on ? DDColor.red : DDColor.sub.opacity(0.45))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.name).font(pf(14.5)).foregroundColor(DDColor.ink)
                            Text((m.note ?? "") + (m.freeMin > 0 ? ("　满 ¥" + moneyFmt(m.freeMin) + " 免运费") : ""))
                                .font(pf(11.5)).foregroundColor(DDColor.sub).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        let fee = (m.freeMin > 0 && goods >= m.freeMin) ? 0 : m.fee
                        Text(fee <= 0 ? Tr("免运费") : ("¥" + moneyFmt(fee)))
                            .font(pf(13.5, .medium))
                            .foregroundColor(fee <= 0 ? C.green : DDColor.red)
                    }
                    .padding(.horizontal, 14).frame(height: 54)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                HairLine(inset: 14)
            }
        }
    }
}

struct DDPayWayList: View {
    @Binding var payWay: String
    /// 没绑卡时点「添加银行卡」→ 外面弹绑卡页（绑完这张卡自动可用）
    var onAddCard: (() -> Void)? = nil
    @ObservedObject private var store = DDStore.shared

    /// 可选项：**只有我们自己的支付 + 银行卡**（2026-10-16 用户：
    /// 「把商城的微信支付删掉」「就留我们自己的和添加银行卡」）。
    /// 星言支付的名字走后台 payName，不写死。
    private var ways: [String] {
        var out: [String] = [XYPay.name]
        /* 2026-10-16 用户选「B」：加支付宝（官方接口那条）。
           后台 ui.json 的 alipayOn 写 0 就能整条藏掉，不用出新包。 */
        if AliPay.on { out.append(AliPay.name) }
        out.append(store.bankPayText)
        return out
    }

    /// 银行卡那一行：没绑卡先去绑卡（绑完回来再点一次就选中了）
    private func tap(_ w: String) {
        if w == store.bankPayText && store.banks.isEmpty {
            onAddCard?()
            return
        }
        payWay = w
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(Tr("支付方式")).font(pf(14)).foregroundColor(DDColor.ink)
                Spacer(minLength: 0)
                Text(Tr("点一下选中")).font(pf(12)).foregroundColor(DDColor.sub)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            HairLine(inset: 14)
            ForEach(ways.indices, id: \.self) { i in
                let w = ways[i]
                let on = (payWay == w)
                Button { tap(w) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: w == AliPay.name ? "a.circle.fill"
                                          : (w == XYPay.name ? "wallet.pass.fill" : "creditcard.fill"))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(w == AliPay.name ? Color(hex: 0x1677FF)
                                             : (w == XYPay.name ? DDColor.red : Color(hex: 0x2E6BFF)))
                            .frame(width: 22)
                        Text(w).font(pf(14.5)).foregroundColor(DDColor.ink)
                        Spacer(minLength: 0)
                        if w == store.bankPayText && store.banks.isEmpty {
                            Text(Tr("去绑卡")).font(pf(12)).foregroundColor(C.link)
                        }
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18))
                            .foregroundColor(on ? DDColor.red : DDColor.sub.opacity(0.45))
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 50)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if i < ways.count - 1 { HairLine(inset: 14) }
            }
        }
    }
}
