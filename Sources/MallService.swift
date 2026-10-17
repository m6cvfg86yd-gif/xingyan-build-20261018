import SwiftUI

/* ============================================================
   客服中心（2026-10-15 对齐京东）

   京东那套客服是「一页三块」：
     ① 上面一块上下文（是哪个商品 / 哪一单，直接带过来）
     ② 「在线客服」：能问、答不上来再转人工（快捷问题一排 chips）
     ③ 「常见问题」：分组的，点一下**就地展开答案**（不是弹个 toast）
   ⚠ 答案只写和我们这套系统对得上的（发货 48 小时、订单里看物流、7 天无理由、
     优惠券在结算页抵、发票在结算页填…），不编「48 小时必达」这种我们做不到的承诺。
   ============================================================ */

struct DDFaq {
    let q: String
    let a: String
}

enum DDHelp {
    /// 常见问题（分了 4 组，和京东那种「订单物流 / 退换 / 支付发票 / 优惠会员」一样）
    static let groups: [(String, [DDFaq])] = [
        ("订单与物流", [
            DDFaq(q: "多久发货？",
                  a: "付款后 48 小时内发货（预售 / 定制款以商品页写的为准）。发货后订单详情里能看到快递公司和单号。"),
            DDFaq(q: "怎么查物流？",
                  a: "「我的 → 我的订单」点开那一单，最上面就是物流轨迹，每一站的更新时间都在。"),
            DDFaq(q: "可以改收货地址吗？",
                  a: "没发货前可以：在订单详情里点「客服」，把新地址发过来，这边帮你改。已经发货的只能联系快递改派。"),
            DDFaq(q: "一直没发货怎么办？",
                  a: "超过 48 小时还没发，在订单详情里点「提醒发货」，商家会收到；还不动就点「客服」转人工。"),
        ]),
        ("退换与售后", [
            DDFaq(q: "支持七天无理由退货吗？",
                  a: "支持（生鲜、定制类除外）。在「我的 → 退款/售后」里选那一单提交申请，商家 24 小时内处理。"),
            DDFaq(q: "退款多久到账？",
                  a: "商家同意后按原路退回（退到零钱），一般 1~3 个工作日到账；订单详情里能看到进度。"),
            DDFaq(q: "收到的货有问题怎么办？",
                  a: "在订单详情里点「申请售后」，选退款 / 退货 / 换货，能传图说明；商家同意后按提示寄回。"),
        ]),
        ("支付与发票", [
            DDFaq(q: "支持哪些支付方式？",
                  a: "结算页里能选支付方式：星言支付（刷脸 / 指纹或支付密码验证）和银行卡。"),
            DDFaq(q: "怎么开发票？",
                  a: "结算页那行「发票」点开，填抬头（个人 / 单位）就行；开完的抬头也会记在你的商城账号里。"),
            DDFaq(q: "订单能改价吗？",
                  a: "拼单价 / 秒杀价是固定价，改不了；有优惠券的话在结算页会自动可选。"),
        ]),
        ("优惠与会员", [
            DDFaq(q: "优惠券怎么用？",
                  a: "结算页那行「优惠券」里挑一张能用的，金额会当场减掉；用过的券不会再出现。"),
            DDFaq(q: "会员有什么好处？",
                  a: "星言 PLUS 会员下单有会员价（结算页显示「会员立减」），还能优先发货、退货免运费。"),
            DDFaq(q: "怎么联系人工客服？",
                  a: "这一页底下那颗「转人工客服」就是把你的问题接到 App 里的客服会话，工作时间内有人回。"),
        ]),
    ]

    /// 快捷问题（在线客服那一排 chips，点一下直接问）
    static let quick = ["多久发货？", "怎么查物流？", "七天无理由怎么退？", "怎么开发票？", "优惠券怎么用？", "会员有什么好处？"]

    /// 智能客服：按关键词给一条**和我们这套对得上**的答案
    static func answer(_ text: String, order: DDOrder?, product: DDProduct?) -> String {
        let t = text.lowercased()
        func hit(_ keys: String...) -> Bool { keys.contains { t.contains($0) } }

        if hit("物流", "快递", "到哪", "单号", "几天到", "什么时候到") {
            if let o = order, !o.expressNo.isEmpty {
                return "这一单是 \(o.express) \(o.expressNo)，最新的物流在订单详情最上面那条轨迹里。"
            }
            return "已付款的订单 48 小时内发出，发货后订单详情里会出现快递公司和单号。"
        }
        if hit("退货", "退款", "售后", "换货", "坏了", "破损", "无理由") {
            return "在「我的 → 退款/售后」里选那一单提交申请就行；7 天无理由、退货包运费，商家 24 小时内处理。"
        }
        if hit("发票", "抬头", "开票") {
            return "结算页那行「发票」点开就能填抬头（个人 / 单位），开过的会记在你的商城账号里。"
        }
        if hit("优惠券", "券", "便宜", "优惠", "补贴") {
            return "结算页那行「优惠券」里能挑一张可用的，金额当场减掉。"
        }
        if hit("会员", "plus", "vip", "权益") {
            return "星言 PLUS 会员下单走会员价（结算页会显示「会员立减」），还能优先发货、退货免运费。"
        }
        if hit("运费", "包邮", "邮费") {
            return "这一整套都是包邮的，结算页「配送」那行写的就是「快递 · 包邮」。"
        }
        if hit("地址", "改收货", "收货人", "电话") {
            return "没发货前可以改：把新地址发过来就行；已经发货的只能联系快递改派。"
        }
        if hit("发货", "催", "还没发") {
            return "付款后 48 小时内发货。还没发货的订单，点开详情有「提醒发货」。"
        }
        if hit("尺码", "规格", "颜色", "型号", "参数") {
            let spec = product.map { $0.specList.map { $0.name }.joined(separator: " / ") } ?? ""
            return spec.isEmpty
                ? "商品详情里有「规格」和「参数」两块，点规格能看每一档的价格和库存。"
                : "这件可以选：\(spec)。详情页点「规格」那一行能换。"
        }
        if hit("价格", "多少钱", "降价") {
            if let p = product { return "这件现在是 ¥" + moneyFmt(p.price) + "（原价 ¥" + moneyFmt(p.orig) + "）。" }
            return "价格以商品页上的为准，结算页会再自动算上能用的优惠券。"
        }
        if hit("你好", "您好", "在吗", "人工") {
            return "在的，我是智能客服。直接把问题打出来就行；要是答不上来，点下面「转人工客服」我给你接一位同事。"
        }
        return "这个问题我拿不准，别耽误你：点下面「转人工客服」，我给你接一位同事（工作时间 9:00–22:00）。"
    }
}

/// 客服中心（商品详情 / 订单详情 / 我的 三处都进这一页）
struct DDHelpCenterView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = DDStore.shared

    /// 从哪儿进来的：带商品 / 带订单（都为 nil = 从「我的」进来的通用客服）
    var product: DDProduct? = nil
    var order: DDOrder? = nil

    @State private var chat: [(me: Bool, text: String)] = []
    @State private var input = ""
    @State private var opened = ""
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            DDSheetBar(title: Tr("客服"))
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    contextCard
                    onlineCard
                    faqCard
                    Spacer().frame(height: 8)
                }
                .padding(10)
            }
            bottom
        }
        .background(DDColor.page.ignoresSafeArea())
        .ddLight()
        .onAppear {
            if chat.isEmpty {
                chat.append((false, Tr("你好，我是星言商城的智能客服。发货、物流、退换、发票、优惠券都能问我。")))
            }
        }
    }

    /* ---------------- 上下文：这件商品 / 这一单 ---------------- */

    @ViewBuilder private var contextCard: some View {
        if let p = product {
            HStack(spacing: 10) {
                DDThumb(em: p.em, size: 46, radius: 6, img: p.img)
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.title).font(pf(13.5)).foregroundColor(DDColor.ink).lineLimit(2)
                    Text(p.shop).font(pf(12)).foregroundColor(DDColor.sub)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(DDColor.card)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else if let o = order {
            HStack(spacing: 10) {
                DDThumb(em: o.em, size: 46, radius: 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(o.title).font(pf(13.5)).foregroundColor(DDColor.ink).lineLimit(2)
                    Text(Tr("订单 ") + (o.orderNo.isEmpty ? o.id : o.orderNo) + " · " + Tr(o.statusText))
                        .font(pf(11.5)).foregroundColor(DDColor.sub).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(DDColor.card)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    /* ---------------- 在线客服：对话 + 快捷问题 ---------------- */

    private var onlineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: 0x1CA36B)).frame(width: 7, height: 7)
                Text(Tr("在线客服")).font(pf(15, .semibold)).foregroundColor(DDColor.ink)
                Spacer(minLength: 0)
                Text(Tr("9:00–22:00")).font(pf(11.5)).foregroundColor(DDColor.sub)
            }

            ForEach(Array(chat.enumerated()), id: \.offset) { _, m in
                HStack {
                    if m.me { Spacer(minLength: 40) }
                    Text(m.text)
                        .font(pf(13.5))
                        .foregroundColor(m.me ? .white : DDColor.ink)
                        .padding(.horizontal, 11).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(m.me ? DDColor.red : DDColor.page))
                        .fixedSize(horizontal: false, vertical: true)
                    if !m.me { Spacer(minLength: 40) }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(DDHelp.quick, id: \.self) { q in
                        Button { ask(q) } label: {
                            Text(Tr(q)).font(pf(12.5)).foregroundColor(DDColor.red)
                                .padding(.horizontal, 10).frame(height: 28)
                                .background(Capsule().fill(DDColor.redLight))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .background(DDColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func ask(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        chat.append((true, q))
        input = ""
        chat.append((false, DDHelp.answer(q, order: order, product: product)))
    }

    /* ---------------- 常见问题（点开就地展开答案） ---------------- */

    private var faqCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Tr("常见问题")).font(pf(15, .semibold)).foregroundColor(DDColor.ink)
                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)
            ForEach(Array(DDHelp.groups.enumerated()), id: \.offset) { _, g in
                Text(Tr(g.0)).font(pf(12.5, .medium)).foregroundColor(DDColor.sub)
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(Array(g.1.enumerated()), id: \.offset) { _, f in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(Tr(f.q)).font(pf(14)).foregroundColor(DDColor.ink)
                            Spacer(minLength: 0)
                            Image(systemName: opened == f.q ? "chevron.up" : "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(DDColor.sub.opacity(0.7))
                        }
                        if opened == f.q {
                            Text(Tr(f.a)).font(pf(13)).foregroundColor(DDColor.sub)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 11)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            opened = (opened == f.q ? "" : f.q)
                        }
                    }
                    HairLine(inset: 12)
                }
            }
        }
        .background(DDColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /* ---------------- 底下：输入框 + 转人工 ---------------- */

    private var bottom: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField(Tr("把问题打出来，比如「多久发货」"), text: $input)
                    .font(pf(14))
                    .submitLabel(.send)
                    .onSubmit { ask(input) }
                    .padding(.horizontal, 12).frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DDColor.page))
                Button { ask(input) } label: {
                    Text(Tr("发送")).font(pf(14, .medium)).foregroundColor(.white)
                        .frame(width: 62, height: 38)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DDColor.red))
                }
                .buttonStyle(.plain)
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
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 22).fill(DDColor.gradBtn))
            }
            .buttonStyle(.plain)
            .disabled(busy)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, max(8, L.safeBottom * 0.6))
        .background(DDColor.card)
    }
}
