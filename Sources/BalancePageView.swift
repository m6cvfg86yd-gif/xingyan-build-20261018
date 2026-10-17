import SwiftUI

/* ============================================================
   零钱（钱包页点「零钱」进来）
   尺寸照参考图量的（iPhone @3x，420×912pt）：整页白底；
   金币 48 居中（导航栏下 59）；「我的零钱」17pt（金币下 ~36）；
   余额 44pt 半粗（标题下 12）；冻结提示 13pt 橙（余额下 24）；
   底下贴着屏幕底部：充值 183.7×47.7 圆角 8（绿），空 16，
   提现同尺寸（#F2F2F2），空 71 是「常见问题 / 账户升级服务」13pt（#576B95），
   空 10 是说明 12pt（#B3B3B3），最后留 25pt。
   文案/按钮/链接/样式都来自后台「零钱页」模块（GET /api/balance-page），余额是真的。
   ============================================================ */

struct BalancePageView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var realtime = Realtime.shared

    @State private var cfg: BalancePageConfig?
    @State private var showBills = false
    @State private var showRecharge = false
    @State private var rechargeAmount = ""
    @State private var showWithdraw = false
    @State private var showFaq = false
    /// 常见问题 / 账户升级服务：微信那两页（整页打开，不是一个弹框）
    @State private var showFaqPage = false
    @State private var showUpgrade = false
    @State private var faqAnswer: String?
    /// 没实名 → 整页显示「请先实名认证」（服务端强制拦，不显示任何金额）
    @State private var needReal = false

    private var st: BalanceStyle { cfg?.style ?? BalanceStyle() }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部导航：左边返回箭头 + 中间「零钱明细」（和参考代码一致）
            NavBar(title: cfg?.navTitle ?? "零钱明细", back: { dismiss() })

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    top
                    Spacer(minLength: 40)
                    bottom
                }
                .frame(minHeight: 912 - L.safeTop - L.navH - L.safeBottom - 20, alignment: .top)
            }
            .background(st.pageBg)
        }
        .background(st.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .navigationDestination(isPresented: $showBills) { BillsView() }
        /* 充值 / 提现：微信那套完整页面（金额 + 到账银行卡 + 服务费 + 支付密码） */
        /* 充值和提现一样：**单独一整页**（微信零钱这两个入口都是整页，不是弹窗） */
        .navigationDestination(isPresented: $showRecharge) {
            RechargeView().environmentObject(app)
        }
        /* 提现对齐微信：**单独一整页**（不是半屏弹窗）——从零钱页推上去，
           左上有返回、右边能侧滑回来，页面里是「提现到 / 金额 / 服务费 / 提现 / 常见问题」 */
        .navigationDestination(isPresented: $showWithdraw) {
            WithdrawView().environmentObject(app)
        }
        .confirmationDialog(Tr("常见问题"), isPresented: $showFaq, titleVisibility: .visible) {
            ForEach((cfg?.faq ?? []).indices, id: \.self) { i in
                Button(cfg!.faq![i].q) { faqAnswer = cfg!.faq![i].a }
            }
            Button(Tr("关闭"), role: .cancel) { }
        }
        .sheet(isPresented: $showFaqPage) {
            FAQView().environmentObject(app)
        }
        .sheet(isPresented: $showUpgrade) {
            WalletUpgradeView().environmentObject(app)
        }
        .alert("常见问题", isPresented: Binding(get: { faqAnswer != nil }, set: { if !$0 { faqAnswer = nil } })) {
            Button(Tr("知道了"), role: .cancel) { faqAnswer = nil }
        } message: {
            Text(faqAnswer ?? "")
        }
        .task { await load() }
        .onChange(of: realtime.event) { ev in
            if ev.type == "balance" || ev.type == "transfer" || ev.type == "ui" { Task { await load() } }
        }
        /* 强制实名：没实名时整页盖一层「请先实名」（服务端 403 拦下来的）。
           这样不会因为拿不到配置而退回默认样式（默认金额字号 64，就是"字变大"那个坑）。 */
        .overlay {
            if needReal {
                NeedRealNameView { dismiss() }
                    .environmentObject(app)
            }
        }
    }

    /* ---------------------------------------------------------- 上面：金币 + 我的零钱 + 余额 */

    private var top: some View {
        VStack(spacing: 0) {
            // 黄色圆形 ¥ 图标
            ZStack {
                Circle().fill(st.circleColorV)
                Text("¥")
                    .font(pfMoney(st.yenFont))
                    .foregroundColor(st.yenColorV)
            }
            .frame(width: st.circle, height: st.circle)
            .padding(.top, st.topPad)

            Text(cfg?.title ?? "我的零钱")
                .font(pf(st.titleFont))
                .foregroundColor(Color.dyn(0x000000, 0xEDEDED))
                .padding(.top, st.gapTitleV)

            /* 没实名：服务端不下发真数字，这里直接显示 ¥****（连 0.00 都不给看） */
            MoneyLabel(text: (cfg?.isLocked ?? false) ? "¥****" : money(cfg?.balance ?? app.me?.balance ?? 0),
                       size: st.amountFont, curSize: st.curFont, topAlign: true,
                       color: Color.dyn(0x000000, 0xEDEDED))
                .padding(.top, st.gapAmountV)

            if cfg?.isLocked ?? false {
                Button {
                    app.show(Tr("请先完成实名认证"))
                    RealNameGate.shared.prompt()
                } label: {
                    HStack(spacing: 4) {
                        Text(Tr("按国家规定，完成实名认证后才能查看和使用零钱"))
                            .font(pf(max(12, st.noteFont - 1)))
                            .foregroundColor(Color(hex: 0xE6A23C))
                        Text(Tr("去认证")).font(pf(max(12, st.noteFont - 1), .medium)).foregroundColor(C.green)
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, st.gapNoteV)
            }
            if let note = cfg?.note, !note.isEmpty {
                HStack(spacing: 4) {
                    Text(note).font(pf(st.noteFont)).foregroundColor(st.noteColorV)
                    Chevron(size: 6, line: 1.4, color: st.noteColorV)
                }
                .padding(.top, st.gapNoteV)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /* ---------------------------------------------------------- 底部：充值 / 提现 / 链接 / 说明 */

    private var bottom: some View {
        VStack(spacing: 0) {
            Button {
                run(cfg?.recharge?.action ?? "recharge", cfg?.recharge?.label ?? "充值")
            } label: {
                Text(cfg?.recharge?.label ?? "充值")
                    .font(pf(17))
                    .foregroundColor(st.rechargeInkV)
                    .frame(width: st.btnW, height: st.btnH)
                    .background(RoundedRectangle(cornerRadius: st.btnR, style: .continuous).fill(st.rechargeBgV))
            }
            .buttonStyle(.plain)

            Button {
                run(cfg?.withdraw?.action ?? "withdraw", cfg?.withdraw?.label ?? "提现")
            } label: {
                Text(cfg?.withdraw?.label ?? "提现")
                    .font(pf(17))
                    .foregroundColor(st.withdrawInkV)
                    .frame(width: st.btnW, height: st.btnH)
                    .background(RoundedRectangle(cornerRadius: st.btnR, style: .continuous).fill(st.withdrawBgV))
            }
            .buttonStyle(.plain)
            .padding(.top, 16)

            HStack(spacing: 15) {
                ForEach((cfg?.links ?? []).filter { $0.enabled != false }) { l in
                    Button {
                        run(l.action ?? "soon", l.label)
                    } label: {
            Text(Tr(l.label)).font(pf(st.linkFont)).foregroundColor(st.linkColorV)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 71)

            if let f = cfg?.footer, !f.isEmpty {
                Text(f)
                    .font(pf(st.footFont))
                    .foregroundColor(st.footerColorV)
                    .padding(.top, 10)
            }
            Color.clear.frame(height: 25)
        }
    }

    /* ---------------------------------------------------------- 动作 */

    private func run(_ action: String, _ label: String) {
        switch action {
        case "recharge": rechargeAmount = ""; showRecharge = true
        /* 后台「隐藏开关」：billsShow = 0 → 零钱页那一条「账单」点了也不进（账单页藏了） */
        case "bills": if UIConfig.num("billsShow", 1) > 0 { showBills = true }
        case "withdraw": showWithdraw = true
        /* 常见问题 / 账户升级服务：微信那两页，整页打开 */
        case "faq": showFaqPage = true
        case "upgrade": showUpgrade = true
        default: app.show("「\(label)」还没接后端，先把页面做出来")
        }
    }

    private func money(_ v: Double) -> String { "¥" + moneyFmt(v) }

    private func load() async {
        do {
            cfg = try await API.shared.balancePage()
        } catch let e as APIError {
            /* 没实名：服务端硬拦（强制实名）→ 整页给「请先实名」，
               不用默认配置兜底（那样金额字号会变成默认的 64，看着像"字变大了"）。 */
            if case .needRealName = e { needReal = true; return }
        } catch { }
    }
}
