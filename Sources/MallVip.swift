import SwiftUI

/* ============================================================
   会员中心（星言 PLUS，2026-10-15 对齐京东）

   京东会员页的骨架：金色会员卡（头像 + 到期时间 + 已省）→ 权益一排 →
   开通/续费套餐（月/季/年）→ 会员专享商品 → 说明。
   ⚠ 演示环境：开通只写本机的到期时间（dd_mall.json），**不真扣钱**；
     开通之后结算页会多一行「会员立减」，这个是真的会算进订单金额里。
   ============================================================ */

/// 会员套餐（京东：月卡 / 季卡 / 年卡）
struct DDVipPlan: Identifiable {
    var id: Int { months }
    let months: Int
    let title: String
    let price: Double
    let tag: String
}

struct DDVipPageView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = DDStore.shared

    /// 会员专享商品点开 → 外面换商品（商城那边传进来）
    var onOpen: ((DDProduct) -> Void)? = nil

    @State private var picked = 3          // 默认季卡（京东默认推的就是季卡）
    @State private var confirm = false

    private let plans: [DDVipPlan] = [
        DDVipPlan(months: 1, title: "月卡", price: 9.9, tag: ""),
        DDVipPlan(months: 3, title: "季卡", price: 26, tag: "省 ¥3.7"),
        DDVipPlan(months: 12, title: "年卡", price: 88, tag: "最划算"),
    ]

    private var plan: DDVipPlan { plans.first { $0.months == picked } ?? plans[1] }

    /// 权益（京东那排图标 + 名字）
    private let rights: [(String, String, String)] = [
        ("tag.fill", "会员价", "下单立减 5%"),
        ("shippingbox.fill", "优先发货", "48 小时内优先发"),
        ("arrow.uturn.backward.circle.fill", "退货免运费", "退货运费我出"),
        ("bubble.left.and.bubble.right.fill", "专属客服", "转人工优先接"),
        ("ticket.fill", "专属优惠券", "每月可领"),
        ("gift.fill", "生日礼", "生日当月有礼"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            DDSheetBar(title: Tr("会员中心"))
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    vipCard
                    rightsCard
                    planCard
                    goodsCard
                    noteCard
                    Spacer().frame(height: 10)
                }
                .padding(10)
            }
        }
        .background(DDColor.page.ignoresSafeArea())
        .ddLight()
        .alert(store.isVip ? Tr("续费会员？") : Tr("开通会员？"), isPresented: $confirm) {
            Button(Tr("取消"), role: .cancel) { }
            Button(Tr("确认")) {
                store.openVip(months: plan.months)
                app.show(store.isVip ? Tr("会员已开通 · 到期 ") + store.vipUntilText : Tr("已开通"))
            }
        } message: {
            Text(Tr("演示环境：只写本机到期时间，不会真的扣钱。"))
        }
    }

    /* ---------------- 金色会员卡 ---------------- */

    private var vipCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Avatar(path: app.me?.avatar ?? "", size: 46, radius: 23)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.me?.nickname ?? app.me?.username ?? Tr("我"))
                        .font(pf(15, .semibold)).foregroundColor(.white).lineLimit(1)
                    Text(store.isVip
                         ? Tr("星言PLUS会员 · ") + store.vipUntilText + Tr(" 到期")
                         : Tr("还不是 PLUS 会员"))
                        .font(pf(11.5)).foregroundColor(.white.opacity(0.9))
                }
                Spacer(minLength: 0)
                Text("PLUS")
                    .font(pf(17, .bold)).foregroundColor(Color(hex: 0x8A5A18))
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(Capsule().fill(Color(hex: 0xFFE7B0)))
            }
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.isVip ? String(store.vipDaysLeft) : "—")
                        .font(pf(19, .bold)).foregroundColor(.white)
                    Text(Tr("剩余天数")).font(pf(11)).foregroundColor(.white.opacity(0.85))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("¥" + moneyFmt(store.vipSaved))
                        .font(pf(19, .bold)).foregroundColor(.white)
                    Text(Tr("会员帮省")).font(pf(11)).foregroundColor(.white.opacity(0.85))
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(
            LinearGradient(colors: [Color(hex: 0x3A2B18), Color(hex: 0x6B4A1E), Color(hex: 0x2A1F12)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /* ---------------- 权益 ---------------- */

    private var rightsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "crown.fill").font(.system(size: 13)).foregroundColor(Color(hex: 0xB8860B))
                Text(Tr("会员权益")).font(pf(15, .semibold)).foregroundColor(DDColor.ink)
                Spacer(minLength: 0)
                Text(Tr("共 6 项")).font(pf(11.5)).foregroundColor(DDColor.sub)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8)],
                      spacing: 12) {
                ForEach(Array(rights.enumerated()), id: \.offset) { _, r in
                    VStack(spacing: 5) {
                        ZStack {
                            Circle().fill(Color(hex: 0xFFF3D6)).frame(width: 38, height: 38)
                            Image(systemName: r.0).font(.system(size: 16)).foregroundColor(Color(hex: 0xB8860B))
                        }
                        Text(Tr(r.1)).font(pf(12.5, .medium)).foregroundColor(DDColor.ink).lineLimit(1)
                        Text(Tr(r.2)).font(pf(10.5)).foregroundColor(DDColor.sub)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(12)
        .background(DDColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /* ---------------- 开通 / 续费 ---------------- */

    private var planCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(store.isVip ? Tr("续费会员") : Tr("开通会员"))
                .font(pf(15, .semibold)).foregroundColor(DDColor.ink)

            HStack(spacing: 8) {
                ForEach(plans) { p in
                    Button { picked = p.months } label: {
                        VStack(spacing: 4) {
                            Text(Tr(p.title)).font(pf(13.5, .medium)).foregroundColor(DDColor.ink)
                            HStack(alignment: .firstTextBaseline, spacing: 1) {
                                Text("¥").font(pf(11, .semibold)).foregroundColor(DDColor.red)
                                Text(moneyFmt(p.price)).font(pf(18, .bold)).foregroundColor(DDColor.red)
                            }
                            Text(p.tag.isEmpty ? " " : Tr(p.tag))
                                .font(pf(10.5)).foregroundColor(Color(hex: 0xB8860B)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(picked == p.months ? Color(hex: 0xFFF8E8) : DDColor.page))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(picked == p.months ? Color(hex: 0xD9A94A) : Color.clear, lineWidth: 1.2))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Button { confirm = true } label: {
                Text((store.isVip ? Tr("立即续费") : Tr("立即开通")) + " · " + Tr(plan.title))
                    .font(pf(16, .medium)).foregroundColor(Color(hex: 0x3A2B18))
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 22)
                        .fill(LinearGradient(colors: [Color(hex: 0xFFE7B0), Color(hex: 0xD9A94A)],
                                             startPoint: .leading, endPoint: .trailing)))
            }
            .buttonStyle(.plain)

            if store.isVip {
                HStack {
                    Text(Tr("到期自动续费")).font(pf(13)).foregroundColor(DDColor.ink)
                    Spacer(minLength: 0)
                    Toggle("", isOn: Binding(
                        get: { store.vipAutoRenew },
                        set: { v in
                            store.setVipAutoRenew(v)
                            app.show(v ? Tr("已开启自动续费") : Tr("已关闭自动续费"))
                        }))
                        .labelsHidden().tint(DDColor.red)
                }
                Text(Tr("演示环境：不会真的扣钱。"))
                    .font(pf(11)).foregroundColor(DDColor.sub)
            }
        }
        .padding(12)
        .background(DDColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /* ---------------- 会员专享（会员价商品） ---------------- */

    private var goodsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(Tr("会员专享")).font(pf(15, .semibold)).foregroundColor(DDColor.ink)
                Spacer(minLength: 0)
                Text(Tr("下单自动按会员价")).font(pf(11.5)).foregroundColor(DDColor.sub)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(store.live.prefix(8)) { p in
                        let vp = (p.price * DDStore.vipRate * 100).rounded() / 100
                        Button { onOpen?(p) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                DDThumb(em: p.em, size: 108, radius: 6, img: p.img)
                                Text(p.title).font(pf(12)).foregroundColor(DDColor.ink)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                                    .frame(width: 108, alignment: .leading)
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    DDPrice(value: vp, size: 15)
                                    Text("¥" + moneyFmt(p.price))
                                        .font(pf(10.5)).foregroundColor(DDColor.sub).strikethrough()
                                }
                            }
                            .frame(width: 108, alignment: .leading)
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

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Tr("会员说明")).font(pf(13.5, .semibold)).foregroundColor(DDColor.ink)
            Text(Tr("· 会员价 = 商品价 × 95%，结算页会显示「会员立减」。"))
            Text(Tr("· 开通记录只存在这台手机上（换手机要重新开通）。"))
            Text(Tr("· 这是演示环境：不接支付，不会真的扣任何钱。"))
        }
        .font(pf(12))
        .foregroundColor(DDColor.sub)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(DDColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// 会员入口那一小条（「我的」页用；京东也有这么一条金卡）
struct DDVipBanner: View {
    @ObservedObject private var store = DDStore.shared
    var onOpen: () -> Void

    var body: some View {
        Button { onOpen() } label: {
            HStack(spacing: 10) {
                Image(systemName: "crown.fill").font(.system(size: 17))
                    .foregroundColor(Color(hex: 0x5A3E14))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color(hex: 0xFFE7B0)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.isVip ? Tr("星言PLUS会员") : Tr("开通星言PLUS"))
                        .font(pf(14.5, .semibold)).foregroundColor(Color(hex: 0x5A3E14))
                    Text(store.isVip
                         ? Tr("会员价 · 到期 ") + store.vipUntilText
                         : Tr("会员价下单立减 5%，退货免运费"))
                        .font(pf(11.5)).foregroundColor(Color(hex: 0x7A5A28))
                }
                Spacer(minLength: 0)
                Text(store.isVip ? Tr("查看") : Tr("去开通"))
                    .font(pf(12.5, .medium)).foregroundColor(Color(hex: 0x5A3E14))
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Capsule().fill(Color(hex: 0xFFE7B0)))
            }
            .padding(12)
            /* 2026-10-17：圆角跟「我的」页其它卡统一到 16（8 太小、跟旁边的白卡不是一套），
               再加一条同色系的细边 + 一层很淡的投影，金卡也是"浮"起来的 */
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0xFFF6E0), Color(hex: 0xFFE9BE)],
                                     startPoint: .leading, endPoint: .trailing)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(hex: 0xE8CFA0).opacity(0.7), lineWidth: 0.6))
            .shadow(color: Color(hex: 0xD9A94A).opacity(0.14), radius: 12, y: 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
