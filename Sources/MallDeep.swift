import SwiftUI

/* ============================================================
   商城「对齐京东」补的数据模型 + 页面（2026-10-15 用户：「全部做出来对齐」）

   这一批补的是京东有、我们原来没有的：
     · 评价（评分 / 好评率 / 评价列表 / 我发表评价·晒单）
     · 规格 SKU（选规格改价）
     · 参数表、图文详情、服务承诺
     · 订单详情页 + 物流轨迹 + 申请售后（退款/退货/换货）
     · 优惠券、发票、备注、配送/支付方式、待付款倒计时
     · 关注店铺、联系客服、分享商品给好友
   ⚠ 评价：本机发的是真评价；另外每个商品带几条**示例评价**（`isDemo=true`，界面上标了「示例」），
      要纯真实数据的话把 `DDReview.samples` 关掉即可。
   ============================================================ */

/// 一条评价
struct DDReview: Identifiable, Codable, Hashable {
    var id: String
    var pid: String
    var title: String
    /// 谁写的（本机发的存自己昵称）
    var name: String
    var avatar: String = ""
    /// 1~5 星
    var rating: Int
    var text: String
    /// 晒单图（本机发的可以选；示例是空的）
    var images: [String] = []
    /// 买的哪个规格
    var spec: String = ""
    var at: Date
    var likes: Int = 0
    /// 示例数据（界面上会标出来，免得当真）
    var isDemo: Bool = false

    /// 按类目给几条示例评价（确定性：同一个商品每次都是这几条，不随机跳）
    static func samples(for p: DDProduct) -> [DDReview] {
        var h = 7
        for u in p.id.unicodeScalars { h = (h &* 31 &+ Int(u.value)) % 9973 }
        let pool = pools(p.cate)
        let n = 3 + h % 3
        let names = ["j***8", "大***猫", "小***子", "林***生", "A***a", "阿***1"]
        return (0..<n).map { i in
            let k = (h + i * 37) % pool.count
            let star = 4 + ((h + i) % 3 == 0 ? 1 : 0)
            return DDReview(id: "demo-\(p.id)-\(i)", pid: p.id, title: p.title,
                            name: names[(h + i) % names.count], avatar: "",
                            rating: min(5, star), text: pool[k], images: [],
                            spec: p.specList[min(i, p.specList.count - 1)].name,
                            at: Date().addingTimeInterval(-Double((i + 1) * 86400 * (1 + h % 4))),
                            likes: (h + i * 13) % 28, isDemo: true)
        }
    }

    static func pools(_ cate: String) -> [String] {
        switch cate {
        case "数码":
            return ["做工比想象中好，细节到位，用了一天很稳。",
                    "发货快，包装结实，连接很顺，没有杂音。",
                    "性价比高，同价位算很能打的，会回购。",
                    "重量轻，手感不错，续航够我用两天。",
                    "和详情页一样，没夸大，客服回复也快。"]
        case "服饰", "鞋包":
            return ["版型正，不显胖，面料摸着舒服。",
                    "洗过一次不变形，颜色和图片一致。",
                    "尺码标准，按平时的号拍就行。",
                    "细节走线很整齐，比商场便宜一半。",
                    "上身效果比想象好，通勤穿刚好。"]
        case "食品":
            return ["日期很新，口感不错，家里人都说好吃。",
                    "包装完好没有压坏，份量足。",
                    "味道正，不齁，会再买。",
                    "独立小包装，办公室当零食很方便。"]
        case "美妆":
            return ["质地清爽不油腻，吸收快。",
                    "味道淡，用了一周没有不适。",
                    "小支装随身带很方便，性价比可以。"]
        case "家居":
            return ["用料厚实，保温效果确实好。",
                    "容量比想象大，放包里不漏。",
                    "做工好，没有异味，家里人都喜欢。",
                    "清洗方便，日常用足够了。"]
        default:
            return ["东西不错，和描述一致。",
                    "发货很快，包装好。",
                    "价格实惠，质量超出预期。"]
        }
    }
}

/// 售后单（退款 / 退货 / 换货）
struct DDAfterSale: Identifiable, Codable, Hashable {
    var id: String
    var orderId: String
    /// 退款 / 退货退款 / 换货
    var kind: String
    var reason: String
    var text: String
    var status: String      // 处理中 / 商家已同意 / 已完成 / 已取消
    var at: Date
    var amount: Double
    var title: String
}

/// 优惠券
struct DDCoupon: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var off: Double
    /// 满多少能用
    var min: Double
    var until: Date
    var used: Bool
}

/// 商城服务通知
struct DDNotice: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var body: String
    var at: Date
    var kind: String
}

/* ============================================================ 小零件 */

/// 五角星（京东那种：实心/空心）
struct DDStars: View {
    var value: Double
    var size: CGFloat = 12
    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { i in
                Image(systemName: Double(i) + 0.5 < value ? "star.fill" : "star")
                    .font(.system(size: size))
                    .foregroundColor(Double(i) + 0.5 < value ? Color(hex: 0xFF9500) : DDColor.sub.opacity(0.5))
            }
        }
    }
}

/// 给评价打星（可点）
struct DDStarPicker: View {
    @Binding var value: Int
    var size: CGFloat = 26
    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { i in
                Button { value = i } label: {
                    Image(systemName: i <= value ? "star.fill" : "star")
                        .font(.system(size: size))
                        .foregroundColor(i <= value ? Color(hex: 0xFF9500) : DDColor.sub.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            Text(value >= 5 ? Tr("非常满意") : (value == 4 ? Tr("满意") : (value == 3 ? Tr("一般") : Tr("不满意"))))
                .font(pf(13)).foregroundColor(DDColor.sub).padding(.leading, 4)
        }
    }
}

/* ============================================================ 评价区 */

struct DDReviewSection: View {
    @ObservedObject private var store = DDStore.shared
    let product: DDProduct
    @State private var showAll = false

    private var list: [DDReview] { store.reviews(of: product) }
    private var avg: Double { store.rating(of: product) ?? 0 }
    private var good: Int {
        let l = list
        guard !l.isEmpty else { return 0 }
        return Int((Double(l.filter { $0.rating >= 4 }.count) / Double(l.count) * 100).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(Tr("商品评价")).font(pf(15, .semibold)).foregroundColor(DDColor.ink)
                if !list.isEmpty {
                    Text(String(format: "%.1f", avg))
                        .font(pf(14, .semibold)).foregroundColor(Color(hex: 0xFF9500))
                    DDStars(value: avg, size: 11)
                    Text(Tr("好评 ") + String(good) + "%").font(pf(12)).foregroundColor(DDColor.sub)
                }
                Spacer(minLength: 0)
                if list.count > 2 {
                    Button { showAll = true } label: {
                        HStack(spacing: 2) {
                            Text(Tr("全部 ") + String(list.count) + Tr(" 条")).font(pf(12.5)).foregroundColor(DDColor.sub)
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                                .foregroundColor(DDColor.sub.opacity(0.7))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if list.isEmpty {
                Text(Tr("还没有评价，确认收货后可以来晒单")).font(pf(13)).foregroundColor(DDColor.sub)
            } else {
                ForEach(list.prefix(2)) { r in
                    DDReviewRow(review: r)
                }
            }
        }
        .padding(14)
        .background(DDColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 10)
        .sheet(isPresented: $showAll) {
            DDReviewListView(product: product).ddLight()
        }
    }
}

struct DDReviewRow: View {
    let review: DDReview
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(DDColor.page).frame(width: 26, height: 26)
                    .overlay(Image(systemName: "person.fill").font(.system(size: 12)).foregroundColor(DDColor.sub))
                Text(review.name).font(pf(13)).foregroundColor(DDColor.ink)
                Text(shortDay(review.at)).font(pf(11.5)).foregroundColor(DDColor.sub)
                Spacer(minLength: 0)
                if review.isDemo {
                    Text(Tr("示例")).font(pf(10)).foregroundColor(DDColor.sub)
                        .padding(.horizontal, 4).frame(height: 14)
                        .background(RoundedRectangle(cornerRadius: 3).fill(DDColor.page))
                }
            }
            DDStars(value: Double(review.rating), size: 11)
            Text(review.text).font(pf(13.5)).foregroundColor(DDColor.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !review.spec.isEmpty {
                Text(review.spec).font(pf(11.5)).foregroundColor(DDColor.sub)
            }
            if !review.images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(review.images.prefix(3), id: \.self) { u in
                        RemoteImage(path: u, icon: "photo")
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .overlay(HairLine(), alignment: .bottom)
    }
    private func shortDay(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

struct DDReviewListView: View {
    @ObservedObject private var store = DDStore.shared
    let product: DDProduct
    var body: some View {
        VStack(spacing: 0) {
            DDSheetBar(title: Tr("商品评价"))
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.reviews(of: product)) { r in
                        DDReviewRow(review: r).padding(.horizontal, 14)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .background(DDColor.page.ignoresSafeArea())
    }
}

/* ============================================================ 参数 / 图文详情 / 服务 */

/// 参数表（京东商品详情下半屏那张表）
struct DDParamSection: View {
    let product: DDProduct
    private var rows: [[String]] {
        if let p = product.params, !p.isEmpty { return p }
        /* 没有后台参数就按我们手上真有的数据生成（不编品牌/型号） */
        var out: [[String]] = [["商品名称", product.title]]
        if let b = product.brand, !b.isEmpty { out.append(["品牌", b]) }
        out.append(["店铺", product.shop])
        out.append(["分类", product.cate])
        out.append(["规格", product.specList.map { $0.name }.joined(separator: " / ")])
        out.append(["发货地", product.shop.hasPrefix("永康") ? "浙江 永康"
                    : (product.shop.hasPrefix("深圳") ? "广东 深圳"
                       : (product.shop.hasPrefix("义乌") ? "浙江 义乌" : "国内"))])
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Tr("规格参数")).font(pf(15, .semibold)).foregroundColor(DDColor.ink)
                .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)
            ForEach(rows.indices, id: \.self) { i in
                HStack(alignment: .top, spacing: 10) {
                    Text(rows[i][0]).font(pf(13)).foregroundColor(DDColor.sub)
                        .frame(width: 76, alignment: .leading)
                    Text(rows[i].count > 1 ? rows[i][1] : "").font(pf(13)).foregroundColor(DDColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(i % 2 == 0 ? DDColor.page.opacity(0.5) : Color.clear)
            }
            Spacer().frame(height: 8)
        }
        .background(DDColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 10)
    }
}

/// 图文详情（京东详情页往下拉那一屏屏）
struct DDDetailLongSection: View {
    let product: DDProduct
    private var imgs: [String] {
        if let d = product.detailImages, !d.isEmpty { return d }
        return (product.img?.isEmpty == false) ? [product.img!] : []
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Tr("图文详情")).font(pf(15, .semibold)).foregroundColor(DDColor.ink)
            ForEach(imgs, id: \.self) { u in
                RemoteImage(path: u, icon: "photo")
                    .frame(maxWidth: .infinity).frame(height: 260).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(Tr("商品说明")).font(pf(14, .medium)).foregroundColor(DDColor.ink)
                ForEach(product.serviceList, id: \.self) { s in
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12)).foregroundColor(DDColor.red)
                        Text(s).font(pf(13)).foregroundColor(DDColor.sub)
                    }
                }
                Text(product.title + Tr("。厂家直发，支持一件代发；收到货有质量问题 7 天内可退换，运费由商家承担。"))
                    .font(pf(13)).foregroundColor(DDColor.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DDColor.page.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(14)
        .background(DDColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 10)
    }
}

/* ============================================================ 规格选择 */

struct DDSpecSheet: View {
    let product: DDProduct
    var onDone: (DDVariant) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picked: String = ""

    private var list: [DDVariant] { product.specList }
    private var cur: DDVariant? { list.first { $0.name == picked } ?? list.first }

    var body: some View {
        VStack(spacing: 0) {
            DDSheetBar(title: Tr("选择规格"))
            HStack(alignment: .top, spacing: 12) {
                DDThumb(em: product.em, size: 84, radius: 10, img: product.img)
                VStack(alignment: .leading, spacing: 6) {
                    DDPrice(value: cur?.price ?? product.price, size: 20)
                    Text(Tr("已选：") + (cur?.name ?? "-")).font(pf(12.5)).foregroundColor(DDColor.sub)
                    Text(Tr("库存 ") + String(cur?.stock ?? 0) + Tr(" 件")).font(pf(12)).foregroundColor(DDColor.sub)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            HairLine()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(Tr("规格")).font(pf(14, .medium)).foregroundColor(DDColor.ink)
                    /* 规格一般 2~5 个：横向一条（和京东一样），多了能滑 */
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(list) { v in
                                Button { picked = v.name } label: {
                                    Text(v.name)
                                        .font(pf(13.5, picked == v.name ? .semibold : .regular))
                                        .foregroundColor(picked == v.name ? DDColor.red : DDColor.ink)
                                        .padding(.horizontal, 14).frame(height: 32)
                                        .background(RoundedRectangle(cornerRadius: 6)
                                            .fill(picked == v.name ? DDColor.redLight : DDColor.page))
                                        .overlay(RoundedRectangle(cornerRadius: 6)
                                            .stroke(picked == v.name ? DDColor.red : Color.clear, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(14)
            }
            Button {
                if let v = cur { onDone(v) }
                dismiss()
            } label: {
                Text(Tr("确定"))
                    .font(pf(16, .medium)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 23).fill(DDColor.gradBtn))
                    .padding(.horizontal, 14)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            .padding(.bottom, max(10, L.safeBottom * 0.6))
        }
        .background(DDColor.page.ignoresSafeArea())
        .onAppear { if picked.isEmpty { picked = list.first?.name ?? "" } }
    }
}

/* ============================================================ 店铺 / 客服 / 分享 */

/// 店铺页：这家店在卖的东西（点店铺名/进店进来）
struct DDShopPageView: View {
    @ObservedObject private var store = DDStore.shared
    @Environment(\.dismiss) private var dismiss
    let shop: String
    var onOpen: (DDProduct) -> Void

    /// 被 × 掉（不感兴趣）的也在这家店里过滤掉，和首页 / 频道页一致
    private var list: [DDProduct] { store.feed(store.live).filter { $0.shop == shop } }
    private var key: String { list.first?.shopKey ?? shop }

    var body: some View {
        VStack(spacing: 0) {
            DDSheetBar(title: shop)
            HStack(spacing: 12) {
                Circle().fill(DDColor.redLight).frame(width: 44, height: 44)
                    .overlay(Text("店").font(pf(16, .semibold)).foregroundColor(DDColor.red))
                VStack(alignment: .leading, spacing: 3) {
                    Text(shop).font(pf(15.5, .medium)).foregroundColor(DDColor.ink)
                    Text(Tr("在售 ") + String(list.count) + Tr(" 件 · 48小时内发货")).font(pf(12)).foregroundColor(DDColor.sub)
                }
                Spacer(minLength: 0)
                Button { store.toggleFollow(key) } label: {
                    Text(store.isFollowed(key) ? Tr("已关注") : Tr("关注"))
                        .font(pf(13, .medium))
                        .foregroundColor(store.isFollowed(key) ? DDColor.sub : DDColor.red)
                        .padding(.horizontal, 14).frame(height: 30)
                        .background(Capsule().fill(store.isFollowed(key) ? DDColor.page : DDColor.redLight))
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            HairLine()
            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(list) { p in
                        Button { onOpen(p) } label: { DDProductCard(product: p) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(10)
            }
        }
        .background(DDColor.page.ignoresSafeArea())
        .ddLight()
    }
}

/// 客服：常见问题 + 转人工（走 App 里「在线客服」那个会话）
struct DDServiceSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    let product: DDProduct?
    @State private var busy = false

    private let faq = ["怎么发货？多久到？", "支持七天无理由退货吗？", "可以改地址吗？", "优惠券怎么用？", "发票怎么开？"]

    var body: some View {
        VStack(spacing: 0) {
            DDSheetBar(title: Tr("客服"))
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    if let p = product {
                        HStack(spacing: 10) {
                            DDThumb(em: p.em, size: 46, radius: 8, img: p.img)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(p.title).font(pf(13.5)).foregroundColor(DDColor.ink).lineLimit(2)
                                Text(p.shop).font(pf(12)).foregroundColor(DDColor.sub)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .background(DDColor.card)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Tr("常见问题")).font(pf(14, .semibold)).foregroundColor(DDColor.ink)
                            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
                        ForEach(faq, id: \.self) { q in
                            HStack {
                                Text(Tr(q)).font(pf(14)).foregroundColor(DDColor.ink)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(DDColor.sub.opacity(0.6))
                            }
                            .padding(.horizontal, 14).frame(height: 48)
                            .contentShape(Rectangle())
                            .onTapGesture { app.show(Tr("这个问题客服会在线回答你")) }
                            HairLine(inset: 14)
                        }
                    }
                    .background(DDColor.card)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Spacer().frame(height: 8)
                }
                .padding(10)
            }
            Button {
                Task {
                    busy = true
                    if let r = try? await API.shared.supportHuman() {
                        app.wantChatsTab = true
                        app.pendingPushChatId = r.chatId
                        dismiss()
                    } else {
                        app.show(Tr("客服暂时不在线，稍后再试"))
                    }
                    busy = false
                }
            } label: {
                Text(busy ? Tr("正在接入…") : Tr("转人工客服"))
                    .font(pf(16, .medium)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 23).fill(DDColor.gradBtn))
                    .padding(.horizontal, 14)
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .padding(.top, 6)
            .padding(.bottom, max(10, L.safeBottom * 0.6))
        }
        .background(DDColor.page.ignoresSafeArea())
        .ddLight()
    }
}

/// 分享商品：复制链接 / 转发给好友（复用聊天那套「转发给」）
struct DDShareSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    let product: DDProduct
    @State private var showForward = false

    var body: some View {
        VStack(spacing: 0) {
            DDSheetBar(title: Tr("分享商品"))
            HStack(spacing: 10) {
                DDThumb(em: product.em, size: 56, radius: 8, img: product.img)
                VStack(alignment: .leading, spacing: 4) {
                    Text(product.title).font(pf(14)).foregroundColor(DDColor.ink).lineLimit(2)
                    DDPrice(value: product.price, size: 16)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            HStack(spacing: 12) {
                tile(Tr("转发给朋友"), "paperplane.fill") { showForward = true }
                tile(Tr("复制链接"), "link") { copyLink() }
            }
            .padding(.horizontal, 14).padding(.bottom, max(14, L.safeBottom * 0.6))
        }
        .background(DDColor.page.ignoresSafeArea())
        .ddLight()
        .sheet(isPresented: $showForward) {
            /* 2026-10-15 用户：「商城里的分享应该是卡片可以直接跳转的」——
               现在转发的是 kind = "mall" 的**商品卡片**，对方点一下直接进商品页
               （以前发的是「一行字 + 网址」，收端只能看到一串文字）。 */
            ForwardPickerView(items: [ForwardItem(kind: "mall", content: mallCardJSON)]) {
                dismiss()
            }
            .environmentObject(app)
        }
    }

    private func tile(_ t: String, _ icon: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 22)).foregroundColor(DDColor.ink)
                Text(Tr(t)).font(pf(12.5)).foregroundColor(DDColor.sub)
            }
            .frame(maxWidth: .infinity).frame(height: 84)
            .background(DDColor.card)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func copyLink() {
        UIPasteboard.general.string = "https://aa.x8iu.com/#mall/" + product.id
        app.show(Tr("链接已复制"))
        dismiss()
    }

    /// 转发出去的卡片正文（kind = "mall"）：收端点一下直接进商品页，不用去浏览器
    private var mallCardJSON: String {
        var d: [String: Any] = ["id": product.id, "em": product.em, "title": product.title,
                                "price": product.price, "orig": product.orig, "shop": product.shop]
        if let img = product.img, !img.isEmpty { d["img"] = img }
        guard let data = try? JSONSerialization.data(withJSONObject: d),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }
}

/* ============================================================ 订单详情（京东那套） */

struct DDOrderDetailView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var store = DDStore.shared
    @Environment(\.dismiss) private var dismiss
    let orderId: String

    @State private var showAfterSale = false
    @State private var showReview = false
    @State private var showService = false
    /// 待付款那一单：走星言支付收银台
    @State private var showXYPay = false

    private var o: DDOrder? { store.orders.first { $0.id == orderId } }

    /// 立即付款：选了星言支付就先过收银台（指纹/面容 或 支付密码）
    private func payNow() {
        guard let o = o else { return }
        if store.payWay == XYPay.name {
            showXYPay = true
            return
        }
        store.pay(o.id)
        app.show(Tr("支付成功"))
    }

    var body: some View {
        VStack(spacing: 0) {
            DDSheetBar(title: Tr("订单详情"))
            if let o = o {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        statusCard(o)
                        if o.status == "shipped" || o.status == "done" {
                            logisticsCard(o)
                        }
                        goodsCard(o)
                        priceCard(o)
                        if !o.addrText.isEmpty || !o.addrName.isEmpty {
                            infoCard(Tr("收货信息"), [o.addrName + " " + o.addrPhone, o.addrText])
                        }
                        infoCard(Tr("订单信息"), [
                            Tr("订单号：") + (o.orderNo.isEmpty ? o.id : o.orderNo),
                            Tr("下单时间：") + ddTimeText(o.at),
                            Tr("支付方式：") + o.payWay,
                            o.invoice.isEmpty ? Tr("发票：不开发票") : (Tr("发票：") + o.invoice),
                            o.remark.isEmpty ? Tr("备注：无") : (Tr("备注：") + o.remark)
                        ])
                        if !store.afterSales(of: o.id).isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(Tr("售后")).font(pf(15, .semibold)).foregroundColor(DDColor.ink)
                                ForEach(store.afterSales(of: o.id)) { a in
                                    HStack {
                                        Text(a.kind + " · " + a.status).font(pf(13.5)).foregroundColor(DDColor.ink)
                                        Spacer(minLength: 0)
                                        Text("¥" + moneyFmt(a.amount)).font(pf(13)).foregroundColor(DDColor.sub)
                                    }
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DDColor.card)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        Spacer().frame(height: 8)
                    }
                    .padding(10)
                }
                actionBar(o)
            } else {
                Text(Tr("订单不存在")).font(pf(14)).foregroundColor(DDColor.sub)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DDColor.page.ignoresSafeArea())
        .ddLight()
        .sheet(isPresented: $showAfterSale) {
            if let o = o { DDAfterSaleSheet(order: o).ddLight() }
        }
        .sheet(isPresented: $showReview) {
            if let o = o { DDReviewEditSheet(order: o).ddLight() }
        }
        /* 客服中心：**带着这一单**进去（改地址 / 催发货 / 退货都能直接问） */
        .sheet(isPresented: $showService) {
            DDHelpCenterView(order: o).environmentObject(app)
        }
        /* 星言支付收银台 */
        .sheet(isPresented: $showXYPay) {
            if let o = o {
                XYPaySheet(amount: o.total, target: o.title, note: Tr("订单付款 · ") + Tr(o.statusText),
                           onSuccess: {
                               store.pay(o.id)
                               app.show(Tr("支付成功"))
                           })
                    .environmentObject(app)
            }
        }
    }

    /* ---------------- 各块 ---------------- */

    private func statusCard(_ o: DDOrder) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Tr(o.statusText)).font(pf(19, .semibold)).foregroundColor(DDColor.ink)
            if o.canPay {
                Text(Tr("还剩 ") + mmss(o.payLeft) + Tr(" 未付款，超时自动取消"))
                    .font(pf(13)).foregroundColor(DDColor.red)
            } else if o.status == "grouping" {
                Text(Tr("还差 ") + String(max(0, o.need - o.have)) + Tr(" 人成团，人满发货"))
                    .font(pf(13)).foregroundColor(DDColor.sub)
            } else if o.status == "shipped" {
                Text(Tr("包裹已发出，注意查收")).font(pf(13)).foregroundColor(DDColor.sub)
            } else if o.status == "done" {
                Text(Tr("交易已完成")).font(pf(13)).foregroundColor(DDColor.sub)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(DDColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func logisticsCard(_ o: DDOrder) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(Tr("物流信息")).font(pf(15, .semibold)).foregroundColor(DDColor.ink)
                Spacer(minLength: 0)
                Text((o.express.isEmpty ? Tr("快递") : o.express) + " " + o.expressNo)
                    .font(pf(12)).foregroundColor(DDColor.sub).lineLimit(1)
            }
            DDLogisticsTimeline(order: o)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DDColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func goodsCard(_ o: DDOrder) -> some View {
        HStack(alignment: .top, spacing: 10) {
            DDThumb(em: o.em, size: 68, radius: 8)
            VStack(alignment: .leading, spacing: 5) {
                Text(o.title).font(pf(13.5)).foregroundColor(DDColor.ink).lineLimit(2)
                if !o.spec.isEmpty { Text(Tr("规格：") + o.spec).font(pf(12)).foregroundColor(DDColor.sub) }
                HStack {
                    DDPrice(value: o.price, size: 15)
                    Spacer(minLength: 0)
                    Text("×" + String(o.count)).font(pf(13)).foregroundColor(DDColor.sub)
                }
            }
        }
        .padding(12)
        .background(DDColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func priceCard(_ o: DDOrder) -> some View {
        VStack(spacing: 8) {
            row(Tr("商品金额"), "¥" + moneyFmt(o.price * Double(o.count)))
            row(Tr("运费"), o.freight > 0 ? ("¥" + moneyFmt(o.freight)) : Tr("包邮"))
            if o.couponOff > 0 { row(Tr("优惠券"), "-¥" + moneyFmt(o.couponOff), red: true) }
            if o.memberOff > 0 { row(Tr("PLUS会员立减"), "-¥" + moneyFmt(o.memberOff), red: true) }
            HairLine()
            HStack {
                Text(Tr("实付款")).font(pf(14.5, .medium)).foregroundColor(DDColor.ink)
                Spacer(minLength: 0)
                DDPrice(value: o.total, size: 19)
            }
        }
        .padding(14)
        .background(DDColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func infoCard(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(pf(15, .semibold)).foregroundColor(DDColor.ink)
            ForEach(lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }, id: \.self) { t in
                Text(t).font(pf(13)).foregroundColor(DDColor.sub)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DDColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func row(_ l: String, _ r: String, red: Bool = false) -> some View {
        HStack {
            Text(l).font(pf(13.5)).foregroundColor(DDColor.sub)
            Spacer(minLength: 0)
            Text(r).font(pf(13.5)).foregroundColor(red ? DDColor.red : DDColor.ink)
        }
    }

    /* ---------------- 底部操作（京东那种一排按钮） ---------------- */

    private func actionBar(_ o: DDOrder) -> some View {
        VStack(spacing: 0) {
            HairLine()
            HStack(spacing: 10) {
                if o.canPay {
                    small(Tr("取消订单"), false) { store.cancelOrder(o.id) }
                    small(Tr("立即付款"), true) { payNow() }
                } else if o.status == "grouping" {
                    small(Tr("取消订单"), false) { store.cancelOrder(o.id) }
                    if DDStore.groupOn { small(Tr("邀好友拼单"), false) { store.invite(o.id) } }
                } else if o.status == "wait" {
                    small(Tr("申请退款"), false) { showAfterSale = true }
                    small(Tr("提醒发货"), true) { store.ship(o.id); app.show(Tr("已提醒商家发货")) }
                } else if o.status == "shipped" {
                    small(Tr("申请售后"), false) { showAfterSale = true }
                    small(Tr("确认收货"), true) { store.confirm(o.id) }
                } else if o.status == "done" {
                    small(Tr("再来一单"), false) {
                        store.reorder(o)
                        app.show(Tr("已加入购物车"))
                        store.jumpCart()      // 加进购物车之后直接跳过去（京东就是这样）
                    }
                    small(o.reviewed ? Tr("已评价") : Tr("评价晒单"), true) { if o.canReview { showReview = true } }
                }
                small(Tr("客服"), false) { showService = true }
            }
            .padding(.horizontal, 12).padding(.top, 8)
            .padding(.bottom, max(8, L.safeBottom * 0.6))
        }
        .background(DDColor.card)
    }

    private func small(_ t: String, _ primary: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t).font(pf(13.5, primary ? .medium : .regular))
                .foregroundColor(primary ? .white : DDColor.ink)
                .frame(maxWidth: .infinity).frame(height: 36)
                .background(Capsule().fill(primary ? AnyShapeStyle(DDColor.gradBtn) : AnyShapeStyle(DDColor.page)))
        }
        .buttonStyle(.plain)
    }

    private func mmss(_ s: Int) -> String {
        String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// 物流轨迹（京东那条时间轴）：按状态生成一条真实可读的轨迹
struct DDLogisticsTimeline: View {
    let order: DDOrder
    private var steps: [(String, String, Bool)] {
        var out: [(String, String, Bool)] = []
        out.append((Tr("已下单"), ddTimeText(order.at), true))
        if order.paidAt != nil || order.status != "paying" {
            out.append((Tr("已付款"), ddTimeText(order.paidAt ?? order.at), true))
        }
        if order.status == "grouping" {
            out.append((Tr("等待成团"), Tr("还差 ") + String(max(0, order.need - order.have)) + Tr(" 人"), true))
        }
        if order.status == "shipped" || order.status == "done" {
            out.append((Tr("包裹已揽收"), (order.express.isEmpty ? "" : order.express + " ") + order.expressNo, true))
            out.append((Tr("运输中"), Tr("已发往目的地分拨中心"), true))
        }
        if order.status == "done" {
            out.append((Tr("已签收"), Tr("交易完成，感谢购买"), true))
        } else if order.status == "shipped" {
            out.append((Tr("派送中"), Tr("快递员正在派送，请保持电话畅通"), false))
        }
        return out.reversed()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(steps.indices, id: \.self) { i in
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 0) {
                        Circle()
                            .fill(i == 0 ? DDColor.red : DDColor.sub.opacity(0.35))
                            .frame(width: 8, height: 8)
                            .padding(.top, 5)
                        if i != steps.count - 1 {
                            Rectangle().fill(DDColor.sub.opacity(0.2)).frame(width: 1.2)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    .frame(width: 10)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(steps[i].0).font(pf(13.5, i == 0 ? .medium : .regular))
                            .foregroundColor(i == 0 ? DDColor.red : DDColor.ink)
                        Text(steps[i].1).font(pf(12)).foregroundColor(DDColor.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 14)
                    Spacer(minLength: 0)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/* ============================================================ 申请售后 */

struct DDAfterSaleSheet: View {
    @ObservedObject private var store = DDStore.shared
    @Environment(\.dismiss) private var dismiss
    let order: DDOrder

    @State private var kind = "退款"
    @State private var reason = "不想要了"
    @State private var text = ""

    private let kinds = ["退款", "退货退款", "换货"]
    private let reasons = ["不想要了", "拍错了", "尺寸/规格不合适", "质量问题", "发错货", "少件/破损"]

    var body: some View {
        VStack(spacing: 0) {
            DDSheetBar(title: Tr("申请售后"))
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        DDThumb(em: order.em, size: 52, radius: 8)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(order.title).font(pf(13.5)).foregroundColor(DDColor.ink).lineLimit(2)
                            Text(Tr("可退金额 ¥") + moneyFmt(order.total)).font(pf(12.5)).foregroundColor(DDColor.sub)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(DDColor.card)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 8) {
                        Text(Tr("售后类型")).font(pf(14, .medium)).foregroundColor(DDColor.ink)
                        HStack(spacing: 8) {
                            ForEach(kinds, id: \.self) { k in
                                Button { kind = k } label: {
                                    Text(Tr(k))
                                        .font(pf(13.5, kind == k ? .semibold : .regular))
                                        .foregroundColor(kind == k ? DDColor.red : DDColor.ink)
                                        .padding(.horizontal, 14).frame(height: 32)
                                        .background(RoundedRectangle(cornerRadius: 6)
                                            .fill(kind == k ? DDColor.redLight : DDColor.page))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(DDColor.card)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 0) {
                        Text(Tr("退款原因")).font(pf(14, .medium)).foregroundColor(DDColor.ink)
                            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
                        ForEach(reasons, id: \.self) { r in
                            Button { reason = r } label: {
                                HStack {
                                    Text(Tr(r)).font(pf(14)).foregroundColor(DDColor.ink)
                                    Spacer(minLength: 0)
                                    Image(systemName: reason == r ? "largecircle.fill.circle" : "circle")
                                        .font(.system(size: 17))
                                        .foregroundColor(reason == r ? DDColor.red : DDColor.sub.opacity(0.5))
                                }
                                .padding(.horizontal, 14).frame(height: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(DDColor.card)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    TextField(Tr("补充说明（可不填）"), text: $text)
                        .font(pf(14))
                        .padding(.horizontal, 12).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 10).fill(DDColor.card))
                    Spacer().frame(height: 6)
                }
                .padding(10)
            }
            Button {
                store.addAfterSale(DDAfterSale(id: "as" + String(Int(Date().timeIntervalSince1970 * 1000)),
                                               orderId: order.id, kind: kind, reason: reason,
                                               text: text, status: "处理中", at: Date(),
                                               amount: order.total, title: order.title))
                dismiss()
            } label: {
                Text(Tr("提交申请"))
                    .font(pf(16, .medium)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 23).fill(DDColor.gradBtn))
                    .padding(.horizontal, 14)
            }
            .buttonStyle(.plain)
            .padding(.top, 6).padding(.bottom, max(10, L.safeBottom * 0.6))
        }
        .background(DDColor.page.ignoresSafeArea())
    }
}

/* ============================================================ 评价晒单 */

struct DDReviewEditSheet: View {
    @ObservedObject private var store = DDStore.shared
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    let order: DDOrder

    @State private var stars = 5
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            DDSheetBar(title: Tr("评价晒单"))
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        DDThumb(em: order.em, size: 52, radius: 8)
                        Text(order.title).font(pf(13.5)).foregroundColor(DDColor.ink).lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(DDColor.card)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 10) {
                        Text(Tr("给个评价")).font(pf(14, .medium)).foregroundColor(DDColor.ink)
                        DDStarPicker(value: $stars)
                        TextEditor(text: $text)
                            .font(pf(14.5))
                            .frame(minHeight: 110)
                            .scrollContentBackground(.hidden)
                            .background(Color.clear)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(DDColor.sub.opacity(0.25), lineWidth: 1))
                            .overlay(alignment: .topLeading) {
                                if text.isEmpty {
                                    Text(Tr("说说这件商品怎么样，给后面的人一个参考"))
                                        .font(pf(13)).foregroundColor(DDColor.sub.opacity(0.7))
                                        .padding(.top, 10).padding(.leading, 10).allowsHitTesting(false)
                                }
                            }
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(DDColor.card)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Spacer().frame(height: 6)
                }
                .padding(10)
            }
            Button {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                store.addReview(DDReview(id: "r" + String(Int(Date().timeIntervalSince1970 * 1000)),
                                         pid: order.pid, title: order.title,
                                         name: app.me?.nickname ?? app.me?.username ?? Tr("我"),
                                         avatar: app.me?.avatar ?? "",
                                         rating: stars,
                                         text: t.isEmpty ? Tr("好评，东西不错") : t,
                                         images: [], spec: order.spec, at: Date(), likes: 0, isDemo: false))
                store.markReviewed(order.id)
                dismiss()
                app.show(Tr("评价已发布"))
            } label: {
                Text(Tr("发布评价"))
                    .font(pf(16, .medium)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 23).fill(DDColor.gradBtn))
                    .padding(.horizontal, 14)
            }
            .buttonStyle(.plain)
            .padding(.top, 6).padding(.bottom, max(10, L.safeBottom * 0.6))
        }
        .background(DDColor.page.ignoresSafeArea())
        .onAppear { stars = 5 }
    }
}

/* ============================================================ 优惠券 / 售后列表 / 我的评价 */

struct DDCouponSheet: View {
    @ObservedObject private var store = DDStore.shared
    @Environment(\.dismiss) private var dismiss
    let total: Double
    var onPick: (DDCoupon?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            DDSheetBar(title: Tr("选择优惠券"))
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    Button { onPick(nil); dismiss() } label: {
                        HStack {
                            Text(Tr("不使用优惠券")).font(pf(14.5)).foregroundColor(DDColor.ink)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                                .foregroundColor(DDColor.sub.opacity(0.6))
                        }
                        .padding(14).background(DDColor.card)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    ForEach(store.coupons) { c in
                        let ok = store.couponUsable(c, total: total)
                        Button { onPick(c); dismiss() } label: {
                            HStack(spacing: 12) {
                                VStack(spacing: 2) {
                                    Text("¥" + moneyFmt(c.off)).font(pf(20, .semibold))
                                        .foregroundColor(ok ? DDColor.red : DDColor.sub)
                                    Text(Tr("满 ") + moneyFmt(c.min) + Tr(" 可用")).font(pf(11)).foregroundColor(DDColor.sub)
                                }
                                .frame(width: 84)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(c.title).font(pf(14.5, .medium)).foregroundColor(DDColor.ink)
                                    Text(Tr("有效期至 ") + dayText(c.until)).font(pf(11.5)).foregroundColor(DDColor.sub)
                                    if !ok { Text(Tr("本单不可用")).font(pf(11.5)).foregroundColor(DDColor.sub) }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(DDColor.sub.opacity(0.6))
                            }
                            .padding(12)
                            .background(DDColor.card)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .opacity(ok ? 1 : 0.55)
                        }
                        .buttonStyle(.plain)
                        .disabled(!ok)
                    }
                    Spacer().frame(height: 8)
                }
                .padding(10)
            }
        }
        .background(DDColor.page.ignoresSafeArea())
        .ddLight()
    }
    private func dayText(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

/// 我的 → 退款/售后
struct DDAfterSaleListView: View {
    @ObservedObject private var store = DDStore.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            DDSheetBar(title: Tr("退款/售后"))
            if store.afterSales.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .font(.system(size: 38, weight: .light)).foregroundColor(DDColor.sub.opacity(0.7))
                    Text(Tr("还没有售后记录")).font(pf(14.5)).foregroundColor(DDColor.sub)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(store.afterSales) { a in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(a.kind).font(pf(14, .medium)).foregroundColor(DDColor.ink)
                                    Text(a.status).font(pf(12.5)).foregroundColor(DDColor.red)
                                    Spacer(minLength: 0)
                                    Text(ddTimeText(a.at)).font(pf(11.5)).foregroundColor(DDColor.sub)
                                }
                                Text(a.title).font(pf(13.5)).foregroundColor(DDColor.ink).lineLimit(2)
                                Text(Tr("原因：") + a.reason + (a.text.isEmpty ? "" : (" · " + a.text)))
                                    .font(pf(12.5)).foregroundColor(DDColor.sub)
                                HStack {
                                    Text(Tr("退款金额 ¥") + moneyFmt(a.amount)).font(pf(13)).foregroundColor(DDColor.ink)
                                    Spacer(minLength: 0)
                                    Button { store.cancelAfterSale(a.id) } label: {
                                        Text(Tr("撤销申请")).font(pf(12.5)).foregroundColor(DDColor.sub)
                                            .padding(.horizontal, 10).frame(height: 28)
                                            .background(Capsule().fill(DDColor.page))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(12)
                            .background(DDColor.card)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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

/// 开票信息（京东：个人/公司，抬头 + 税号）
struct DDInvoiceSheet: View {
    @Binding var title: String
    @Environment(\.dismiss) private var dismiss
    @State private var kind = 0
    @State private var name = ""
    @State private var taxNo = ""

    var body: some View {
        VStack(spacing: 0) {
            DDSheetBar(title: Tr("发票信息"))
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 0) {
                        Button { kind = 0 } label: {
                            row(Tr("不开发票"), kind == 0)
                        }.buttonStyle(.plain)
                        HairLine(inset: 14)
                        Button { kind = 1 } label: {
                            row(Tr("电子普通发票 · 个人"), kind == 1)
                        }.buttonStyle(.plain)
                        HairLine(inset: 14)
                        Button { kind = 2 } label: {
                            row(Tr("电子普通发票 · 单位"), kind == 2)
                        }.buttonStyle(.plain)
                    }
                    .background(DDColor.card)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    if kind > 0 {
                        VStack(spacing: 0) {
                            HStack(spacing: 10) {
                                Text(kind == 2 ? Tr("单位名称") : Tr("抬头")).font(pf(14)).foregroundColor(DDColor.ink)
                                TextField(Tr("请输入"), text: $name).font(pf(14))
                            }
                            .padding(.horizontal, 14).frame(height: 48)
                            if kind == 2 {
                                HairLine(inset: 14)
                                HStack(spacing: 10) {
                                    Text(Tr("税号")).font(pf(14)).foregroundColor(DDColor.ink)
                                    TextField(Tr("请输入纳税人识别号"), text: $taxNo).font(pf(14))
                                }
                                .padding(.horizontal, 14).frame(height: 48)
                            }
                        }
                        .background(DDColor.card)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    Spacer().frame(height: 6)
                }
                .padding(10)
            }
            Button {
                if kind == 0 { title = "" }
                else { title = kind == 1 ? (name.isEmpty ? Tr("个人") : name) : (name + (taxNo.isEmpty ? "" : (" · " + taxNo))) }
                dismiss()
            } label: {
                Text(Tr("确定")).font(pf(16, .medium)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 23).fill(DDColor.gradBtn))
                    .padding(.horizontal, 14)
            }
            .buttonStyle(.plain)
            .padding(.top, 6).padding(.bottom, max(10, L.safeBottom * 0.6))
        }
        .background(DDColor.page.ignoresSafeArea())
    }

    private func row(_ t: String, _ on: Bool) -> some View {
        HStack {
            Text(t).font(pf(14.5)).foregroundColor(DDColor.ink)
            Spacer(minLength: 0)
            Image(systemName: on ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 18)).foregroundColor(on ? DDColor.red : DDColor.sub.opacity(0.5))
        }
        .padding(.horizontal, 14).frame(height: 48)
        .contentShape(Rectangle())
    }
}

/// 我关注的店铺（店家 + 在售件数，点一下看这家店）
struct DDShopFollowListView: View {
    @ObservedObject private var store = DDStore.shared
    @Environment(\.dismiss) private var dismiss
    var onOpen: (DDProduct) -> Void

    private var shops: [(key: String, name: String, count: Int)] {
        var out: [(String, String, Int)] = []
        for key in store.followedShops {
            let list = store.live.filter { $0.shopKey == key }
            let name = list.first?.shop ?? key
            out.append((key, name, list.count))
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            DDSheetBar(title: Tr("关注的店铺"))
            if shops.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "heart.circle")
                        .font(.system(size: 38, weight: .light)).foregroundColor(DDColor.sub.opacity(0.7))
                    Text(Tr("还没有关注的店铺")).font(pf(14.5)).foregroundColor(DDColor.sub)
                    Text(Tr("在商品详情页点「关注」就行")).font(pf(12)).foregroundColor(DDColor.sub.opacity(0.8))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(shops, id: \.key) { s in
                            HStack(spacing: 12) {
                                Circle().fill(DDColor.redLight).frame(width: 40, height: 40)
                                    .overlay(Text("店").font(pf(15, .semibold)).foregroundColor(DDColor.red))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(s.name).font(pf(15, .medium)).foregroundColor(DDColor.ink)
                                    Text(Tr("在售 ") + String(s.count) + Tr(" 件")).font(pf(12)).foregroundColor(DDColor.sub)
                                }
                                Spacer(minLength: 0)
                                Button { store.toggleFollow(s.key) } label: {
                                    Text(Tr("取关")).font(pf(12.5)).foregroundColor(DDColor.sub)
                                        .padding(.horizontal, 10).frame(height: 28)
                                        .background(Capsule().fill(DDColor.page))
                                }
                                .buttonStyle(.plain)
                                Button {
                                    if let first = store.live.first(where: { $0.shopKey == s.key }) {
                                        onOpen(first)
                                    }
                                } label: {
                                    Text(Tr("进店")).font(pf(12.5)).foregroundColor(DDColor.ink)
                                        .padding(.horizontal, 10).frame(height: 28)
                                        .background(Capsule().fill(DDColor.page))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(12)
                            .background(DDColor.card)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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

/// 我的 → 我的评价
struct DDMyReviewsView: View {
    @ObservedObject private var store = DDStore.shared
    @Environment(\.dismiss) private var dismiss
    private var mine: [DDReview] { store.reviews }
    var body: some View {
        VStack(spacing: 0) {
            DDSheetBar(title: Tr("我的评价"))
            if mine.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "star.bubble")
                        .font(.system(size: 38, weight: .light)).foregroundColor(DDColor.sub.opacity(0.7))
                    Text(Tr("还没有评价过")).font(pf(14.5)).foregroundColor(DDColor.sub)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(mine) { r in
                            DDReviewRow(review: r).padding(.horizontal, 14)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .background(DDColor.page.ignoresSafeArea())
        .ddLight()
    }
}
