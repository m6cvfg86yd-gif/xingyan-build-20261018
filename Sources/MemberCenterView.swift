import SwiftUI
import UIKit

/* ============================================================
   会员中心（我 → 会员中心）

   · 顶上深色金卡：当前身份 / 到期时间 / 剩余天数 / 升级加速倍数
   · 选档位（会员 / 超级会员）+ 选时长（月 / 季 / 年，各自带价格）
   · 立即开通 / 续费 → 输支付密码 → 走零钱扣款
   · 权益列表（后台配的文案）、自动续费开关、兑换码、开通记录
   ============================================================ */

struct MemberCenterView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = MemberStore.shared
    @ObservedObject private var growth = GrowthStore.shared

    @State private var tierId = ""
    @State private var months = 1
    @State private var showPay = false
    /// 付完钱那一页要显示的东西（商品 / 金额 / 到期时间）
    @State private var payResult: MemberPayResult?
    /// 这次点的是「续费」还是「开通」（付完之后提示不一样）
    @State private var payingRenew = false
    @State private var code = ""
    @State private var redeeming = false
    /* 会员中心那几处动画（都很轻，只动透明度/位移/阴影，不碰重绘性能） */
    @State private var shine = false        // 英雄卡上那道慢慢扫过的光
    @State private var glow = false         // 开通按钮的呼吸光
    @State private var appear = false       // 权益一行行错落进场

    private let durations: [(Int, String)] = [(1, "1 个月"), (3, "3 个月"), (12, "12 个月")]

    private var tier: MemberTier? {
        store.tiers.first(where: { $0.id == tierId }) ?? store.tiers.first
    }
    private var price: Double { tier?.priceOf(months) ?? 0 }
    private var gold: Color { Color(hexString: (tier?.color?.isEmpty == false) ? tier!.color! : "#E0B44A") }
    private var gold2: Color { Color(hexString: (tier?.color2?.isEmpty == false) ? tier!.color2! : "#B8862A") }

    var body: some View {
        VStack(spacing: 0) {
            /* 顶栏标题也能在后台「会员中心」页里改（store.info?.title） */
            NavBar(title: (store.info?.title?.isEmpty == false) ? store.info!.title! : Tr("会员中心"),
                   back: { dismiss() })

            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    heroCard
                    if store.info?.enabled != false {
                        tierCards
                        durationRow
                        buyBar
                        benefitsCard
                        if store.active { autoRenewCard }
                        redeemCard
                        if !(store.info?.history ?? []).isEmpty { historyCard }
                    } else {
                        PanelCard {
                            Text(Tr("会员功能还没开"))
                                .font(pf(14)).foregroundColor(C.subLabel)
                                .padding(16)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 30)
            }
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task {
            await store.refresh()
            if tierId.isEmpty { tierId = store.me?.tier ?? store.tiers.first?.id ?? "" }
            /* 动画起手：卡片扫光（每 3 秒扫一道）、按钮呼吸光、权益错落进场 */
            withAnimation(.linear(duration: 1.5).delay(1.2).repeatForever(autoreverses: false)) { shine = true }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { glow = true }
            withAnimation(.easeOut(duration: 0.4)) { appear = true }
        }
        .sheet(isPresented: $showPay) {
            MemberPaySheet(amount: price,
                           purpose: (store.active ? Tr("续费") : Tr("开通")) + (tier?.name ?? "会员")) { pwd in
                await store.open(tierId: tierId, months: months, payPassword: pwd)
            } onDone: {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                /* 付完立刻刷新，别等退出去再进来：我的资料（要挂徽章）、会话列表、
                   通讯录、成长加速都更一遍；会员中心自己那份也在 open() 里更过了 */
                Task {
                    app.me = try? await API.shared.me()
                    await app.loadChats()
                    await app.loadContacts()
                    await GrowthStore.shared.refresh()
                    await store.refresh()
                }
                payResult = MemberPayResult(
                    title: (tier?.name ?? Tr("会员")) + " · " + "\(months) " + Tr("个月"),
                    amount: price,
                    expireText: expireAfterPay(),
                    isRenew: payingRenew
                )
            }
        }
        /* 付完钱弹一页「支付成功」（大对勾 + 金额 + 商品/支付方式/到期时间） */
        .sheet(item: $payResult) { r in
            MemberPayDoneView(result: r) {
                payResult = nil
                app.show(r.isRenew ? Tr("续费成功") : Tr("开通成功，权益已生效"))
            }
        }
    }

    /// 付完之后到期时间（store 在 open() 里已经更新过，这里直接读）
    private func expireAfterPay() -> String {
        guard let t = store.me?.expireAt, t > 0 else { return "-" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日"
        return f.string(from: Date(timeIntervalSince1970: t / 1000))
    }

    /* ---------------------------------------------------------- 顶上那张卡 */

    private var heroCard: some View {
        PanelHeroCard(glow: gold) {
            HStack(alignment: .center, spacing: 12) {
                Avatar(path: app.me?.avatarPath ?? "", size: 56, radius: 28, circle: true, level: growth.shownLevel)
                    .overlay(Circle().stroke(gold.opacity(0.85), lineWidth: 1.6))

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(app.me?.name ?? "")
                            .font(pf(17, .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        MemberBadge(tier: store.me?.tier,
                                    short: store.me?.short,
                                    color: store.me?.color,
                                    color2: store.me?.color2,
                                    height: 14)
                    }
                    Text(store.active ? (store.me?.name ?? Tr("会员")) : Tr("还不是会员"))
                        .font(pf(12.5))
                        .foregroundColor(.white.opacity(0.72))
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 3) {
                    Text("¥" + moneyFmt(store.balance))
                        .font(pf(13, .medium))
                        .foregroundColor(.white)
                    Text(Tr("零钱余额"))
                        .font(pf(11))
                        .foregroundColor(.white.opacity(0.55))
                }
            }

            if store.active {
                HStack(spacing: 8) {
                    chip(Tr("到期 ") + expireText, gold)
                    chip(Tr("升级加速 ") + boostText, gold)
                    Spacer(minLength: 0)
                }
            } else {
                Text(store.info?.sub ?? Tr("开通会员，升级更快、标识更亮"))
                    .font(pf(12.5))
                    .foregroundColor(.white.opacity(0.72))
            }
        }
        /* 一道斜着扫过的光（会员卡那种质感）：纯位移 + 渐变，不贵 */
        .overlay(alignment: .topLeading) {
            LinearGradient(colors: [Color.white.opacity(0), Color.white.opacity(0.22), Color.white.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: 90, height: 260)
                .rotationEffect(.degrees(20))
                .offset(x: shine ? 420 : -160, y: -50)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var expireText: String {
        guard let t = store.me?.expireAt, t > 0 else { return "-" }
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd"
        return f.string(from: Date(timeIntervalSince1970: t / 1000))
    }
    private var boostText: String {
        let b = store.me?.boost ?? 1
        return String(format: "%.1f", b) + "x"
    }

    private func chip(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(pf(11.5, .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(tint.opacity(0.28)))
            .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.7))
    }

    /* ---------------------------------------------------------- 档位 */

    private var tierCards: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelSectionTitle(text: Tr("选择档位"))
            HStack(spacing: 10) {
                ForEach(store.tiers) { t in
                    Button { withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { tierId = t.id } } label: {
                        let on = (tier?.id == t.id)
                        let c1 = Color(hexString: (t.color?.isEmpty == false) ? t.color! : "#E0B44A")
                        let c2 = Color(hexString: (t.color2?.isEmpty == false) ? t.color2! : "#B8862A")
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text(t.name).font(pf(15, .semibold)).foregroundColor(on ? .white : C.label)
                                Spacer(minLength: 0)
                                if on { Image(systemName: "checkmark.circle.fill").foregroundColor(.white) }
                            }
                            Text("¥" + String(format: "%.0f", t.price?.month ?? 0) + Tr(" / 月"))
                                .font(pf(12.5)).foregroundColor(on ? .white.opacity(0.85) : C.subLabel)
                            Text(Tr("升级 ") + String(format: "%.1f", t.boost ?? 1) + "x · " + Tr("群上限 ")
                                 + "\(t.groupMax ?? 0)")
                                .font(pf(11)).foregroundColor(on ? .white.opacity(0.7) : C.subLabel)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(on ? AnyShapeStyle(LinearGradient(colors: [c1, c2],
                                                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                                         : AnyShapeStyle(C.cardBg))
                        )
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(on ? Color.clear : C.hairline, lineWidth: 0.7))
                        .scaleEffect(on ? 1.02 : 1)      // 选中那一下轻轻"弹"起来
                        .shadow(color: Color.black.opacity(on ? 0.16 : 0.05), radius: 8, y: 3)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var durationRow: some View {
        HStack(spacing: 8) {
            ForEach(durations, id: \.0) { d in
                let on = months == d.0
                Button { withAnimation(.easeOut(duration: 0.14)) { months = d.0 } } label: {
                    VStack(spacing: 2) {
                        Text(d.1).font(pf(13.5, on ? .medium : .regular))
                        Text("¥" + String(format: "%.0f", tier?.priceOf(d.0) ?? 0))
                            .font(pf(11))
                    }
                    .foregroundColor(on ? .white : C.label)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(on ? AnyShapeStyle(LinearGradient(colors: [gold, gold2],
                                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                                     : AnyShapeStyle(C.cardBg))
                    )
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(on ? Color.clear : C.hairline, lineWidth: 0.7))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var buyBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.active ? Tr("续费后到期时间顺延") : Tr("开通后立即生效"))
                    .font(pf(11.5)).foregroundColor(C.subLabel)
                Text("¥" + moneyFmt(price))
                    .font(pfMoney(22, .medium)).foregroundColor(C.label)
            }
            Spacer(minLength: 0)
            Button {
                guard !tierId.isEmpty else { app.show(Tr("先选一个档位")); return }
                payingRenew = store.active
                showPay = true
            } label: {
                Text(store.active ? Tr("立即续费") : Tr("立即开通"))
                    .font(pf(16, .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .frame(height: 44)
                    .background(
                        Capsule().fill(LinearGradient(colors: [gold, gold2],
                                                      startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                    /* 呼吸光：这是整页最该点的按钮，让它一直"亮着" */
                    .shadow(color: gold2.opacity(glow ? 0.60 : 0.28), radius: glow ? 13 : 7, y: 3)
                    .scaleEffect(glow ? 1.015 : 1)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background { CardGlassBox(radius: 16) }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(C.hairline, lineWidth: 0.7))
    }

    /* ---------------------------------------------------------- 权益 */

    private var benefitsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelSectionTitle(text: Tr("会员权益"))
            PanelCard {
                ForEach(Array(store.benefits.enumerated()), id: \.offset) { idx, b in
                    HStack(spacing: 11) {
                        PanelIcon(symbol: b.icon ?? "star.fill", colors: [gold, gold2])
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.title ?? "").font(pf(15.5)).foregroundColor(C.label)
                            if let d = b.desc, !d.isEmpty {
                                Text(d).font(pf(12)).foregroundColor(C.subLabel)
                            }
                        }
                        Spacer(minLength: 0)
                        if store.active { Image(systemName: "checkmark").foregroundColor(gold) }
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 56)
                    /* 一行行错落进场（每行晚 50ms），看着有节奏但不花 */
                    .opacity(appear ? 1 : 0)
                    .offset(y: appear ? 0 : 10)
                    .animation(.easeOut(duration: 0.38).delay(Double(idx) * 0.05), value: appear)
                    if idx < store.benefits.count - 1 { PanelDivider() }
                }
            }
        }
    }

    private var autoRenewCard: some View {
        PanelCard {
            HStack(spacing: 11) {
                PanelIcon(symbol: "arrow.triangle.2.circlepath", colors: [gold, gold2])
                VStack(alignment: .leading, spacing: 2) {
                    Text(Tr("自动续费")).font(pf(15.5)).foregroundColor(C.label)
                    Text(Tr("到期前自动从零钱续上，随时能关")).font(pf(12)).foregroundColor(C.subLabel)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { store.me?.autoRenew == true },
                    set: { v in Task { await store.setAuto(v); app.show(v ? Tr("已开启自动续费") : Tr("已关闭自动续费")) } }
                ))
                .labelsHidden()
                .tint(gold)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 60)
        }
    }

    private var redeemCard: some View {
        PanelCard {
            HStack(spacing: 10) {
                PanelIcon(symbol: "ticket.fill", colors: PanelTint.purple)
                TextField(Tr("输入会员兑换码"), text: $code)
                    .font(pf(15))
                    .autocapitalization(.allCharacters)
                    .disableAutocorrection(true)
                Button {
                    let c = code.trimmingCharacters(in: .whitespaces)
                    guard !c.isEmpty else { return }
                    redeeming = true
                    Task {
                        let msg = await store.redeem(c)
                        redeeming = false
                        code = ""
                        app.show(msg)
                    }
                } label: {
                    Text(redeeming ? Tr("兑换中…") : Tr("兑换"))
                        .font(pf(14, .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(Capsule().fill(LinearGradient(colors: [gold, gold2],
                                                                  startPoint: .topLeading, endPoint: .bottomTrailing)))
                }
                .buttonStyle(.plain)
                .disabled(redeeming)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 60)
        }
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelSectionTitle(text: Tr("开通记录"))
            PanelCard {
                let rows = store.info?.history ?? []
                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, h in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text((store.tiers.first { $0.id == h.tier }?.name ?? Tr("会员"))
                                 + (h.months ?? 0 > 0 ? (" · \(h.months ?? 0) 个月") : (" · \(h.days ?? 0) 天")))
                                .font(pf(15)).foregroundColor(C.label)
                            Text(h.at ?? "")
                                .font(pf(11.5)).foregroundColor(C.subLabel)
                        }
                        Spacer(minLength: 0)
                        if let p = h.price, p > 0 {
                            Text("-¥" + moneyFmt(p))
                                .font(pf(14, .medium)).foregroundColor(C.label)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 56)
                    if idx < rows.count - 1 { PanelDivider() }
                }
            }
        }
    }
}
