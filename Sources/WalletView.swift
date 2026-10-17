import SwiftUI

/* ============================================================
   钱包（我 → 服务 → 钱包）
   尺寸照参考图量的（iPhone @3x，420×912pt）：
     · 页顶留 6pt，然后一张全宽白卡（卡上沿一条 0.5pt 分隔线）
     · 每行 56.4pt：图标 20pt 在 x=18，文字 x=56.7（17pt），右边数值 16pt，
       箭头右边距 18pt；行与行之间 0.5pt 分隔线，左边缩进 56pt 画到右边
     · 两张卡之间空 12pt；底部两个蓝色链接（#576B95 / 13pt）居中，距安全区 26pt
   内容全部来自后台「钱包页」模块（GET /api/wallet），零钱那一行显示真实余额。
   ============================================================ */

struct WalletView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var realtime = Realtime.shared

    @State private var cfg: WalletConfig?
    @State private var showBills = false
    @State private var showCoin = false
    @State private var showCards = false
    @State private var showBiz = false
    @State private var showScore = false
    /// 钱包页里的「客服中心」：进真正的客服中心页（不是那句「暂时没有在线客服」）
    @State private var showSupport = false
    /// 钱包页里的「身份信息」「支付设置」
    @State private var showIdentity = false
    @State private var showPaySettings = false
    /// 钱包页里的「支付分」：进新的支付分页面（微信那套）
    @State private var showPayScore = false
    /// 「安全分」那一行显示真实分数（wallet.json 里加一项 action=score 就会读出来）
    @State private var creditText = ""
    /// 点开看过的金额（每次进页面都清空 → 默认都是星号）
    @State private var revealed: Set<String> = []
    /// 手势密码（安全锁）：开了以后进「零钱 / 经营账户」要先画一遍
    @State private var needGesture = false
    @State private var pendingAction = ""
    @State private var pendingLabel = ""
    /// 没实名 → 整页显示「请先实名认证」（服务端强制拦，不给看金额）
    @State private var needReal = false

    private var st: WalletStyle { cfg?.style ?? WalletStyle() }

    /// 卡片：第一张 5 行、第二张 2 行，都是后台配的
    private var groups: [WalletGroup] {
        let list = cfg?.groups ?? []
        return list.filter { ($0.enabled != false) && !(($0.items ?? []).filter { $0.enabled != false }.isEmpty) }
    }

    private var footLinks: [WalletFoot] {
        (cfg?.footer ?? []).filter { $0.enabled != false }
    }

    var body: some View {
        if needReal {
            NeedRealNameView { dismiss() }
        } else {
        VStack(spacing: 0) {
            NavBar(title: cfg?.title ?? "钱包", back: { dismiss() }) {
                /* 后台「隐藏开关」：ui.json 里 billsShow 写 0 → 右上角这颗「账单」不画
                   （2026-10-16 用户：「后台服务页账单页都做个隐藏开关」）。 */
                if UIConfig.num("billsShow", 1) > 0 {
                    Button {
                        run((cfg?.right?.action ?? "bills"), (cfg?.right?.label ?? "账单"))
                    } label: {
                            Text(Tr(cfg?.right?.label ?? "账单"))
                            .font(pf(17))
                            .foregroundColor(C.label)
                            .frame(height: L.navH)
                            .padding(.trailing, 18)
                    }
                    .buttonStyle(.plain)
                }
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 6)
                    /* 没实名：顶部挂一条提示（金额已经被服务端藏成 ¥****），点一下去实名 */
                    if cfg?.isLocked ?? false {
                        Button {
                            RealNameGate.shared.prompt()
                        } label: {
                            HStack(spacing: 6) {
                                Text("⚠️").font(pf(14))
                                Text(Tr("按国家规定，完成实名认证后才能查看和使用钱包金额"))
                                    .font(pf(13))
                                    .foregroundColor(Color(hex: 0xB06A12))
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                Text(Tr("去认证")).font(pf(13, .medium)).foregroundColor(C.green)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.dyn(0xFFF7E6, 0x3A2E17)))
                            .padding(.horizontal, 12)
                            .padding(.bottom, 6)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(groups) { g in
                        card(g).padding(.top, g.id == groups.first?.id ? 0 : st.gap)
                    }
                    Color.clear.frame(height: 24)
                }
            }
            .background(C.pageBg)

            footer
        }
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .navigationDestination(isPresented: $showBills) { BillsView() }
        .navigationDestination(isPresented: $showCoin) { BalancePageView() }
        .navigationDestination(isPresented: $showCards) { BankCardsView() }
        .navigationDestination(isPresented: $showBiz) { BizAccountView() }
        .navigationDestination(isPresented: $showScore) { SecurityScoreView() }
        .sheet(isPresented: $showSupport) { SupportView().environmentObject(app) }
        .sheet(isPresented: $showIdentity) { IdentityView().environmentObject(app) }
        .sheet(isPresented: $showPaySettings) { PaySettingsView().environmentObject(app) }
        .sheet(isPresented: $showPayScore) { PayScoreView().environmentObject(app) }
        .sheet(isPresented: $needGesture) {
            GestureLockView { openAfterLock(pendingAction, pendingLabel) }
        }
        .task { await load() }
        .onChange(of: realtime.event) { ev in
            if ev.type == "transfer" || ev.type == "balance" || ev.type == "ui" { Task { await load() } }
        }
        }
    }

    /* ---------------------------------------------------------- 一张白卡 */

    private func card(_ g: WalletGroup) -> some View {
        let rows = (g.items ?? []).filter { $0.enabled != false }
        let s = st
        return VStack(spacing: 0) {
            Rectangle().fill(C.hairline).frame(height: 0.5)
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, it in
                row(it)
                if idx < rows.count - 1 {
                    HairLine(inset: s.divider)
                }
            }
        }
        .background(C.cardBg)
    }

    /* ---------------------------------------------------------- 一行 */

    private func row(_ it: WalletItem) -> some View {
        let s = st
        let rawValue = (it.action == "score" && !creditText.isEmpty) ? creditText : (it.value ?? "")
        let masked = !rawValue.isEmpty && s.mask && (it.mask ?? true)
        let value = (masked && !revealed.contains(it.id)) ? WalletView.maskMoney(rawValue) : rawValue
        let note = it.note ?? ""
        return Button {
            run(it.action ?? "soon", it.label)
        } label: {
            HStack(spacing: 0) {
                SVGIcon(markup: WalletIcon.markup(it.icon, it.svg), size: s.icon,
                        color: Color(hexString: it.color ?? "#1180E0", fallback: 0x1180E0))
                    .frame(width: s.icon, height: s.icon)
                    .padding(.leading, s.iconX)

            Text(Tr(it.label))
                    .font(pf(s.labelFont))
                    .foregroundColor(s.labelColorV)
                    .padding(.leading, max(0, s.textX - s.iconX - s.icon))

                if !note.isEmpty {
                    Text(note)
                        .font(pf(s.noteFont))
                        .foregroundColor(s.noteColorV)
                        .padding(.leading, 11.7)
                }

                Spacer(minLength: 0)

                if !value.isEmpty {
                    MoneyLabel(text: value, size: s.valueFont, curSize: s.curFontSize, color: s.valueColorV)
                        .padding(.trailing, 11)
                        .onTapGesture {
                            guard masked, s.canReveal else { return }
                            if revealed.contains(it.id) { revealed.remove(it.id) } else { revealed.insert(it.id) }
                        }
                }

                Chevron(size: 9, line: 1.6)
                    .padding(.trailing, s.rightPad)
            }
            .frame(height: s.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /* ---------------------------------------------------------- 底部两个链接 */

    private var footer: some View {
        HStack(spacing: 19) {
            ForEach(footLinks) { f in
                Button {
                    run(f.action ?? "soon", f.label)
                } label: {
            Text(Tr(f.label))
                        .font(pf(st.footFont))
                        .foregroundColor(st.footerColorV)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 26)
        .background(C.pageBg)
    }

    /* ---------------------------------------------------------- 动作 */

    private func run(_ action: String, _ label: String) {
        /* 零钱 / 经营账户：设了手势密码就先验一遍（微信那种安全锁） */
        if GestureStore.enabled, action == "balance" || label == "经营账户" {
            pendingAction = label == "经营账户" ? "biz" : action
            pendingLabel = label
            needGesture = true
            return
        }
        openAfterLock(label == "经营账户" ? "biz" : action, label)
    }

    /// 验过手势（或本来就没开锁）之后真正打开
    private func openAfterLock(_ action: String, _ label: String) {
        switch action {
        case "balance":
            showCoin = true               // 进「零钱」页（照参考图做的那一页）
        case "biz":
            showBiz = true                // 经营账户
        case "score":
            showPayScore = true           // 支付分（微信那套：分数 + 三维度 + 免押服务）
        case "bills":
            showBills = true            // 进「账单」页（真实转账记录）
        case "card":
            showCards = true            // 进「银行卡」页（绑定 / 解绑，对应功能清单里的「银行卡」）
        case "settings":
            showPaySettings = true        // 支付设置（支付密码 / 免密 / 自动续费）
        case "identity":
            showIdentity = true           // 身份信息（实名 + 证件有效期/职业/地址）
        case "service":
            showSupport = true            // 先到客服中心（常见问题页），里面的「联系在线客服」进独立客服页
        default:
            /* 后台把动作写成 soon（或者没写）时，按名字兜底 —— 这几个页面其实都做好了，
               不能让用户点进去看到「还没开发」 */
            if label.contains("经营账户") { showBiz = true }
            else if label.contains("客服") { showSupport = true }
            else if label.contains("零钱") { showCoin = true }
            else if label.contains("账单") { showBills = true }
            else if label.contains("银行卡") { showCards = true }
            else { app.show("「\(label)」还没接后端，先把页面做出来") }
        }
    }

    private func load() async {
        revealed = []          // 进来先全部打星号
        do {
            cfg = try await API.shared.walletConfig()
        } catch let e as APIError {
            /* 没实名：服务端硬拦（强制实名）。这里显示「请先实名」的页面，
               不能用内置兜底配置 —— 那看着就像"金额字变大了"（以前踩过这个坑）。 */
            if case .needRealName = e {
                needReal = true
                return
            }
            if cfg == nil { cfg = WalletFallback.config(balance: app.me?.balance ?? 0) }
        } catch {
            if cfg == nil { cfg = WalletFallback.config(balance: app.me?.balance ?? 0) }
        }
        /* 钱包里配了「安全分」那一行的话，把真实分数读出来填上 */
        let wantScore = (cfg?.groups ?? []).contains { g in
            (g.items ?? []).contains { $0.action == "score" }
        }
        if wantScore, let s = try? await API.shared.securityScore() {
            creditText = "\(s.score)"
        }
    }

    /// ¥122.00 → ¥****
    static func maskMoney(_ text: String) -> String {
        if text.contains("¥") { return "¥****" }
        return String(text.map { $0.isNumber ? "*" : $0 })
    }
}
