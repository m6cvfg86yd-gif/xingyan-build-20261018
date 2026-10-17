import SwiftUI

/* ============================================================
   商城后台的「订单发货 / 发券 / 售后」三块（2026-10-16 用户：
   「缺的补上」「给 app 管理」「后台部分」）。

   对着京东商家后台补的：
     · 订单发货：待发货列表 → 填快递公司 + 运单号 → 发货（用户端立刻能看到**真实**快递轨迹）
     · 发券：给某个人发 / 给所有人发（面额、门槛、有效期、张数），发完对方收到系统消息
     · 售后：用户提交退款/退货/换货 → 这里审核，同意就退到零钱
   数据都在服务器（/api/ops/mallorders、/api/ops/coupon/send、/api/ops/aftersales）。
   ============================================================ */

struct MallOpsSection: View {
    @EnvironmentObject private var app: AppState

    @State private var orders: [API.OpsOrderRow] = []
    @State private var afterSales: [API.AfterSaleRow] = []
    @State private var loading = true
    @State private var shipping: API.OpsOrderRow? = nil
    @State private var pushing: API.OpsOrderRow? = nil
    @State private var reviewing: API.AfterSaleRow? = nil
    @State private var showSend = false
    /// 只发这个人的券（空 = 所有人）
    @State private var sendTo = ""

    var body: some View {
        VStack(spacing: 10) {
            orderCard
            afterSaleCard
            couponCard
        }
        .task { await load() }
        .sheet(item: $shipping) { o in
            ShipSheet(order: o) { await load() }.environmentObject(app)
        }
        .sheet(item: $pushing) { o in
            PushTrackSheet(order: o) { await load() }.environmentObject(app)
        }
        .sheet(item: $reviewing) { a in
            AfterSaleReviewSheet(row: a) { await load() }.environmentObject(app)
        }
        .sheet(isPresented: $showSend) {
            SendCouponSheet(to: sendTo) { await load() }.environmentObject(app)
        }
    }

    private func load() async {
        async let a = API.shared.opsMallOrders()
        async let b = API.shared.opsAfterSales()
        orders = await a
        afterSales = await b
        loading = false
    }

    /* ---------------- 订单发货 ---------------- */

    private var orderCard: some View {
        VStack(spacing: 0) {
            header(Tr("订单发货"), sub: Tr("待发货 ") + String(orders.count) + Tr(" 单"),
                   reload: { Task { await load() } })
            if loading {
                hint(Tr("正在拉订单…"))
            } else if orders.isEmpty {
                hint(Tr("没有待发货的订单。用户在商城下单后，这里就会出现。"))
            } else {
                ForEach(orders) { o in
                    HairLine(inset: 16)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(o.buyer ?? Tr("买家")).font(pf(14.5, .medium)).foregroundColor(C.label)
                            Text("¥" + moneyFmt(o.total ?? 0)).font(pf(14)).foregroundColor(DDColor.red)
                            Spacer(minLength: 0)
                            Text(o.statusText ?? "").font(pf(12)).foregroundColor(C.subLabel)
                        }
                        Text((o.items ?? []).joined(separator: "、"))
                            .font(pf(13)).foregroundColor(C.label).lineLimit(2)
                        if let ad = o.address, !ad.isEmpty {
                            Text(Tr("收货：") + ad).font(pf(12)).foregroundColor(C.subLabel).lineLimit(2)
                        }
                        HStack(spacing: 8) {
                            Button { shipping = o } label: {
                                Text(Tr("填单号发货")).font(pf(13.5, .medium)).foregroundColor(.white)
                                    .padding(.horizontal, 14).frame(height: 32)
                                    .background(Capsule().fill(C.green))
                            }
                            .buttonStyle(.plain)
                            Button { pushing = o } label: {
                                Text(Tr("补物流")).font(pf(13)).foregroundColor(C.link)
                                    .padding(.horizontal, 12).frame(height: 32)
                                    .background(Capsule().stroke(C.hairline, lineWidth: 0.8))
                            }
                            .buttonStyle(.plain)
                            Spacer(minLength: 0)
                            Text(o.id).font(pf(10.5)).foregroundColor(C.subLabel)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
            }
        }
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /* ---------------- 售后 ---------------- */

    private var afterSaleCard: some View {
        VStack(spacing: 0) {
            header(Tr("售后处理"), sub: Tr("待处理 ") + String(afterSales.count) + Tr(" 单"), reload: nil)
            if afterSales.isEmpty {
                hint(Tr("没有待处理的售后。用户在订单里点「申请退款」后会出现在这里。"))
            } else {
                ForEach(afterSales) { a in
                    HairLine(inset: 16)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(a.buyer ?? "").font(pf(14.5, .medium)).foregroundColor(C.label)
                            Text(kindText(a.kind)).font(pf(12)).foregroundColor(C.orange)
                            Spacer(minLength: 0)
                            Text("¥" + moneyFmt(a.total ?? 0)).font(pf(14)).foregroundColor(DDColor.red)
                        }
                        Text(a.item ?? "").font(pf(13)).foregroundColor(C.label).lineLimit(1)
                        Text(Tr("理由：") + (a.reason ?? "")).font(pf(12)).foregroundColor(C.subLabel)
                        Button { reviewing = a } label: {
                            Text(Tr("处理这一单")).font(pf(13.5, .medium)).foregroundColor(.white)
                                .padding(.horizontal, 14).frame(height: 32)
                                .background(Capsule().fill(DDColor.redDeep))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
            }
        }
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func kindText(_ k: String?) -> String {
        switch k ?? "" {
        case "return":   return Tr("退货")
        case "exchange": return Tr("换货")
        default:         return Tr("退款")
        }
    }

    /* ---------------- 发券 ---------------- */

    private var couponCard: some View {
        VStack(spacing: 0) {
            header(Tr("发券"), sub: Tr("给某个人发 / 给所有人发"), reload: nil)
            HStack(spacing: 8) {
                TextField(Tr("发给谁的账号（留空 = 所有人）"), text: $sendTo)
                    .font(pf(14)).autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 12).frame(height: 42)
                    .background(RoundedRectangle(cornerRadius: 10).fill(C.fieldBg))
                Button { showSend = true } label: {
                    Text(Tr("去发券")).font(pf(14, .medium)).foregroundColor(.white)
                        .padding(.horizontal, 16).frame(height: 42)
                        .background(Capsule().fill(C.green))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func header(_ title: String, sub: String, reload: (() -> Void)?) -> some View {
        HStack(spacing: 8) {
            Text(title).font(pf(16, .semibold)).foregroundColor(C.label)
            Text(sub).font(pf(12)).foregroundColor(C.subLabel)
            Spacer(minLength: 0)
            if let r = reload {
                Button { r() } label: {
                    Text(Tr("刷新")).font(pf(12.5)).foregroundColor(C.link)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func hint(_ t: String) -> some View {
        Text(t).font(pf(12.5)).foregroundColor(C.subLabel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.bottom, 14)
    }
}

/* ---------------- 发货：填快递公司 + 单号 ---------------- */

struct ShipSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    let order: API.OpsOrderRow
    var onDone: () async -> Void

    @State private var company = "顺丰"
    @State private var no = ""
    @State private var busy = false
    private let companies = ["顺丰", "圆通", "中通", "申通", "韵达", "京东", "极兔", "邮政", "EMS", "德邦"]

    var body: some View {
        VStack(spacing: 0) {
            DDSheetBar(title: Tr("发货"))
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(order.buyer ?? "").font(pf(15, .medium)).foregroundColor(C.label)
                        Text((order.items ?? []).joined(separator: "、")).font(pf(13)).foregroundColor(C.label)
                        if let ad = order.address { Text(ad).font(pf(12)).foregroundColor(C.subLabel) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(C.cardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Text(Tr("快递公司")).font(pf(12.5)).foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 8) {
                        ForEach(companies, id: \.self) { c in
                            Button { company = c } label: {
                                Text(c).font(pf(14, company == c ? .semibold : .regular))
                                    .foregroundColor(company == c ? .white : C.label)
                                    .frame(maxWidth: .infinity).frame(height: 36)
                                    .background(RoundedRectangle(cornerRadius: 10)
                                        .fill(company == c ? C.green : C.cardBg))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    TextField(Tr("运单号（比如 SF1234567890）"), text: $no)
                        .font(pf(15)).autocorrectionDisabled(true)
                        .textInputAutocapitalization(.characters)
                        .padding(.horizontal, 12).frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: 12).fill(C.fieldBg))
                    Text(Tr("填完发货，用户那边就能看到**快递公司的真实轨迹**（自动去快递100 查）。"))
                        .font(pf(12)).foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            Button { Task { await ship() } } label: {
                Text(busy ? Tr("正在发货…") : Tr("确认发货"))
                    .font(pf(16, .medium)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 23).fill(busy ? C.subLabel : C.green))
                    .padding(.horizontal, 14)
            }
            .buttonStyle(.plain).disabled(busy)
            .padding(.top, 6).padding(.bottom, max(10, L.safeBottom))
        }
        .background(C.pageBg.ignoresSafeArea())
        .ddLight()
    }

    private func ship() async {
        let n = no.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { app.show(Tr("运单号不能空")); return }
        busy = true
        let ok = await API.shared.opsShip(orderId: order.id, company: company, no: n)
        busy = false
        if ok { app.show(Tr("已发货，用户能看到物流了")); await onDone(); dismiss() }
        else { app.show(Tr("发货失败，检查网络或权限")) }
    }
}

/* ---------------- 补一条物流 ---------------- */

struct PushTrackSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    let order: API.OpsOrderRow
    var onDone: () async -> Void

    @State private var text = "快件已到达派送点，请保持电话畅通"
    @State private var busy = false
    private let presets = ["商家已打包出库", "快件已到达派送点，请保持电话畅通", "已签收，感谢惠顾"]

    var body: some View {
        VStack(spacing: 0) {
            DDSheetBar(title: Tr("补一条物流"))
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(presets, id: \.self) { p in
                        Button { text = p } label: {
                            HStack {
                                Text(p).font(pf(14)).foregroundColor(C.label)
                                Spacer(minLength: 0)
                                if text == p { Image(systemName: "checkmark").foregroundColor(C.green) }
                            }
                            .padding(.horizontal, 14).frame(height: 46)
                            .background(C.cardBg)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    TextField(Tr("也可以自己写一句"), text: $text)
                        .font(pf(15)).padding(.horizontal, 12).frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: 12).fill(C.fieldBg))
                    Text(Tr("写「已签收」时会把这单标成已完成。"))
                        .font(pf(12)).foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            Button { Task { await push() } } label: {
                Text(busy ? Tr("正在写入…") : Tr("写入物流"))
                    .font(pf(16, .medium)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 23).fill(busy ? C.subLabel : C.green))
                    .padding(.horizontal, 14)
            }
            .buttonStyle(.plain).disabled(busy)
            .padding(.top, 6).padding(.bottom, max(10, L.safeBottom))
        }
        .background(C.pageBg.ignoresSafeArea())
        .ddLight()
    }

    private func push() async {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        busy = true
        let ok = await API.shared.opsPushTrack(orderId: order.id, text: t)
        busy = false
        if ok { app.show(Tr("已写入物流")); await onDone(); dismiss() }
        else { app.show(Tr("写入失败")) }
    }
}

/* ---------------- 售后审核 ---------------- */

struct AfterSaleReviewSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    let row: API.AfterSaleRow
    var onDone: () async -> Void

    @State private var note = "已同意退款，钱退到零钱"
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            DDSheetBar(title: Tr("售后处理"))
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.buyer ?? "").font(pf(15, .medium)).foregroundColor(C.label)
                        Text(row.item ?? "").font(pf(13)).foregroundColor(C.label)
                        Text(Tr("金额：") + "¥" + moneyFmt(row.total ?? 0))
                            .font(pf(13)).foregroundColor(DDColor.red)
                        Text(Tr("理由：") + (row.reason ?? "")).font(pf(13)).foregroundColor(C.subLabel)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(C.cardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    TextField(Tr("给用户的说明（驳回时一定要写）"), text: $note)
                        .font(pf(14)).padding(.horizontal, 12).frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: 12).fill(C.fieldBg))

                    Button { Task { await review(true) } } label: {
                        Text(Tr("同意退款（退回零钱）")).font(pf(15.5, .medium)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).frame(height: 46)
                            .background(RoundedRectangle(cornerRadius: 23).fill(C.green))
                    }
                    .buttonStyle(.plain).disabled(busy)

                    Button { Task { await review(false) } } label: {
                        Text(Tr("驳回")).font(pf(15.5)).foregroundColor(C.red)
                            .frame(maxWidth: .infinity).frame(height: 46)
                            .background(RoundedRectangle(cornerRadius: 23).fill(C.cardBg))
                    }
                    .buttonStyle(.plain).disabled(busy)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        .background(C.pageBg.ignoresSafeArea())
        .ddLight()
    }

    private func review(_ pass: Bool) async {
        busy = true
        let ok = await API.shared.opsAfterSaleReview(orderId: row.orderId, pass: pass, note: note)
        busy = false
        if ok { app.show(pass ? Tr("已同意并退款") : Tr("已驳回")); await onDone(); dismiss() }
        else { app.show(Tr("处理失败")) }
    }
}

/* ---------------- 发券 ---------------- */

struct SendCouponSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    let to: String
    var onDone: () async -> Void

    @State private var title = "客服券"
    @State private var off = "8"
    @State private var min = "50"
    @State private var days = "7"
    @State private var count = "1"
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            DDSheetBar(title: to.isEmpty ? Tr("给所有人发券") : Tr("给他发券"))
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    Text(to.isEmpty ? Tr("这次会发给**所有没被封的账号**，一人几张看下面。")
                                    : (Tr("发给：") + to))
                        .font(pf(12.5)).foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    fld(Tr("券名（比如 客服券 / 补贴券）"), $title)
                    fld(Tr("面额（元）"), $off, num: true)
                    fld(Tr("门槛（满多少能用，元）"), $min, num: true)
                    fld(Tr("有效期（天）"), $days, num: true)
                    fld(Tr("每人几张（1~10）"), $count, num: true)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            Button { Task { await send() } } label: {
                Text(busy ? Tr("正在发…") : Tr("发券"))
                    .font(pf(16, .medium)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 23).fill(busy ? C.subLabel : C.green))
                    .padding(.horizontal, 14)
            }
            .buttonStyle(.plain).disabled(busy)
            .padding(.top, 6).padding(.bottom, max(10, L.safeBottom))
        }
        .background(C.pageBg.ignoresSafeArea())
        .ddLight()
    }

    private func fld(_ ph: String, _ text: Binding<String>, num: Bool = false) -> some View {
        TextField(ph, text: text)
            .font(pf(15))
            .keyboardType(num ? .decimalPad : .default)
            .padding(.horizontal, 14).frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 12).fill(C.fieldBg))
    }

    private func send() async {
        let n = title.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { app.show(Tr("券名不能空")); return }
        busy = true
        let sent = await API.shared.opsSendCoupon(
            to: to.isEmpty ? "all" : to,
            title: n,
            off: Double(off) ?? 0,
            min: Double(min) ?? 0,
            days: Int(days) ?? 7,
            count: Int(count) ?? 1)
        busy = false
        if let s = sent { app.show(Tr("已发出 ") + String(s) + Tr(" 张券")); await onDone(); dismiss() }
        else { app.show(Tr("发券失败（账号不存在或没权限）")) }
    }
}
