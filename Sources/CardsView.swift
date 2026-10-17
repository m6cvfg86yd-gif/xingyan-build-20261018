import SwiftUI

/* ============================================================
   卡包（照微信那套：我 → 卡包）
     · 上面按类分：优惠券 / 会员卡 / 礼品卡 / 票
     · 一张卡点开 = 卡面（名称、面额/折扣、有效期、说明）+ 核销码 + 「核销」按钮
     · 用过的卡标灰、沉到「已使用」那一组
   数据和发卡都在服务端（data/cards.json，管理侧 /api/ops/cards 发卡）。
   ⚠ 这一页和聊天页完全无关，不会碰到那个"一点就闪"的巨型视图。
   ============================================================ */

struct WalletCard: Decodable, Identifiable, Hashable {
    var id: String
    var userId: String?
    var kind: String?
    var title: String?
    var sub: String?
    var amount: Double?
    var code: String?
    var used: Bool?
    var usedAt: String?
    var validTo: String?
    var note: String?
    var createdAt: String?

    var kindName: String {
        switch kind ?? "coupon" {
        case "member": return Tr("会员卡")
        case "gift":   return Tr("礼品卡")
        case "ticket": return Tr("票")
        default:       return Tr("优惠券")
        }
    }
    var symbol: String {
        switch kind ?? "coupon" {
        case "member": return "crown.fill"
        case "gift":   return "gift.fill"
        case "ticket": return "ticket.fill"
        default:       return "ticket.fill"
        }
    }
    var tint: Color {
        switch kind ?? "coupon" {
        case "member": return Color(hex: 0xD9A13B)
        case "gift":   return Color(hex: 0xC0433F)
        case "ticket": return Color(hex: 0x3E7BD6)
        default:       return C.green
        }
    }
}

struct CardsView: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var cards: [WalletCard] = []
    @State private var loading = true
    @State private var open: WalletCard? = nil
    /// 「为什么是空的」定位用：这次请求成没成、拿到几条（显示在空页上 + 进诊断打点）
    @State private var diagNote = ""

    private var live: [WalletCard] { cards.filter { $0.used != true } }
    private var used: [WalletCard] { cards.filter { $0.used == true } }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("卡包"), back: { dismiss() })
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    if loading && cards.isEmpty {
                        Text(Tr("正在加载…")).font(pf(14)).foregroundColor(C.subLabel)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    } else if cards.isEmpty {
                        Text(Tr("还没有卡券")).font(pf(14)).foregroundColor(C.subLabel)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                        Text(Tr("商家发卡、别人赠送之后会出现在这里")).font(pf(12.5)).foregroundColor(C.subLabel)
                            .frame(maxWidth: .infinity).padding(.top, 6)
                        if !diagNote.isEmpty {
                            Text(diagNote).font(pf(11.5)).foregroundColor(C.subLabel)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity).padding(.horizontal, 26).padding(.top, 10)
                        }
                    } else {
                        if !live.isEmpty {
                            sectionTitle(Tr("可用"))
                            cardList(live)
                        }
                        if !used.isEmpty {
                            sectionTitle(Tr("已使用"))
                            cardList(used)
                        }
                        if !diagNote.isEmpty {
                            Text(diagNote).font(pf(11.5)).foregroundColor(C.subLabel)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 22).padding(.top, 10)
                        }
                    }
                    Spacer().frame(height: 30)
                }
                .padding(.top, 10)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { await load() }
        .sheet(item: $open) { c in cardDetail(c) }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(pf(13)).foregroundColor(C.subLabel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22).padding(.top, 8)
    }

    private func cardList(_ list: [WalletCard]) -> some View {
        GroupCard {
            ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                if i > 0 { HairLine(inset: 16) }
                Button { open = c } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(c.tint.opacity(0.16))
                            Image(systemName: c.symbol)
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundColor(c.tint)
                        }
                        .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(c.title ?? "").font(pf(16)).foregroundColor(C.label).lineLimit(1)
                            Text(subText(c)).font(pf(12.5)).foregroundColor(C.subLabel).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Chevron(size: 9, line: 1.6).padding(.trailing, 3)
                    }
                    .padding(.horizontal, 16).frame(height: 66)
                    .contentShape(Rectangle())
                }
                .buttonStyle(MenuPressStyle())
            }
        }
    }

    private func subText(_ c: WalletCard) -> String {
        var parts: [String] = [c.kindName]
        if let a = c.amount, a > 0 { parts.append("¥" + String(format: "%.0f", a)) }
        if let v = c.validTo, !v.isEmpty { parts.append(Tr("有效期至 ") + v) }
        if c.used == true { parts.append(Tr("已使用")) }
        return parts.joined(separator: " · ")
    }

    private func cardDetail(_ c: WalletCard) -> some View {
        VStack(spacing: 0) {
            NavBar(title: c.title ?? Tr("卡券"), back: { open = nil })
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    /* 卡面 */
                    VStack(spacing: 8) {
                        Image(systemName: c.symbol)
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundColor(.white)
                        Text(c.title ?? "").font(pf(20, .semibold)).foregroundColor(.white)
                        if let a = c.amount, a > 0 {
                            Text("¥" + String(format: "%.0f", a)).font(pf(26, .bold)).foregroundColor(.white)
                        }
                        if let s = c.sub, !s.isEmpty {
                            Text(s).font(pf(13)).foregroundColor(.white.opacity(0.9))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
                    .background(
                        LinearGradient(colors: [c.tint, c.tint.opacity(0.72)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 16)

                    GroupCard {
                        row(Tr("类型"), c.kindName)
                        HairLine(inset: 16)
                        row(Tr("有效期"), (c.validTo ?? "").isEmpty ? Tr("长期有效") : (c.validTo ?? ""))
                        if let n = c.note, !n.isEmpty {
                            HairLine(inset: 16)
                            row(Tr("使用说明"), n)
                        }
                        if c.used == true {
                            HairLine(inset: 16)
                            row(Tr("状态"), Tr("已核销"))
                        }
                    }

                    /* 核销码 */
                    GroupCard {
                        VStack(spacing: 8) {
                            Text(Tr("核销码")).font(pf(13)).foregroundColor(C.subLabel)
                            Text(c.code ?? "-")
                                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                                .foregroundColor(c.used == true ? C.subLabel : C.label)
                            Text(Tr("到店出示这一串给商家核销"))
                                .font(pf(12)).foregroundColor(C.subLabel)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }

                    if c.used != true {
                        Button {
                            Task {
                                if await API.shared.cardUse(id: c.id) {
                                    app.show(Tr("已核销"))
                                    await load()
                                    open = nil
                                } else {
                                    app.show(Tr("核销失败，可能已经用过了"))
                                }
                            }
                        } label: {
                            Text(Tr("核销这张卡"))
                                .font(pf(17, .semibold)).foregroundColor(.white)
                                .frame(maxWidth: .infinity).frame(height: 48)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(C.green))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                    }
                    Spacer().frame(height: 30)
                }
                .padding(.top, 12)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        /* 2026-10-16：卡券详情这一层补左滑返回（滑一下 = 退回卡包） */
        .swipeBack { open = nil }
    }

    private func row(_ t: String, _ v: String) -> some View {
        HStack(spacing: 12) {
            Text(t).font(pf(16)).foregroundColor(C.label)
            Spacer(minLength: 8)
            Text(v).font(pf(14)).foregroundColor(C.subLabel)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16).frame(minHeight: 50)
    }

    private func load() async {
        /* 带打点的那一版：请求成败 + 拿到几条都记下来（「卡包是空的」一次就能定位） */
        let r = await API.shared.walletCardsDiag()
        DiagLog.shared.note(r.note)
        await MainActor.run {
            cards = r.cards
            diagNote = r.note
            loading = false
        }
    }
}
