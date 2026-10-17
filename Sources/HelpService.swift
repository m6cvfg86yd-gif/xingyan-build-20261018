import SwiftUI

/* ============================================================
   常见问题 + 账户升级服务（微信「帮助与反馈」和「支付 → 账户升级」那两页）
   · 常见问题：搜索 + 热门 + 分类（内容就是后台客服中心里配的问答）
   · 账户升级服务：三档账户等级、单笔/单日额度、还差哪一步、立即升级
   ============================================================ */

/* ---------------------------------------------------------- 常见问题 */
struct FAQView: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var cfg: API.FAQPayload?
    @State private var q = ""
    @State private var openCat: API.SupportCategory?
    @State private var showSupport = false
    /// 「联系在线客服」进独立客服页（不再跳普通聊天）
    @State private var showKefu = false

    private var cats: [API.SupportCategory] { cfg?.categories ?? [] }

    private var hits: [(cat: String, item: API.SupportItem)] {
        let key = q.trimmingCharacters(in: .whitespaces)
        if key.isEmpty { return [] }
        var out: [(String, API.SupportItem)] = []
        for c in cats {
            for it in (c.items ?? []) where
                it.q.localizedCaseInsensitiveContains(key) || it.a.localizedCaseInsensitiveContains(key) {
                out.append((c.title, it))
            }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("常见问题"), back: { dismiss() })
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    searchBar
                    if !q.trimmingCharacters(in: .whitespaces).isEmpty {
                        hitList
                    } else {
                        hotCard
                        categoryCard
                        contactFoot
                    }
                    Color.clear.frame(height: 24)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { cfg = try? await API.shared.faq() }
        .navigationDestination(isPresented: Binding(
            get: { openCat != nil },
            set: { if !$0 { openCat = nil } }
        )) {
            if let c = openCat { SupportCategoryView(cat: c, keyword: q) }
        }
        .sheet(isPresented: $showSupport) {
            SupportView().environmentObject(app)
        }
        .sheet(isPresented: $showKefu) {
            KefuPage().environmentObject(app)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(C.searchIcon)
            TextField(cfg?.searchHint ?? Tr("搜索你的问题"), text: $q)
                .font(pf(14.5))
                .foregroundColor(C.label)
            if !q.isEmpty {
                Button { q = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundColor(C.searchIcon)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(C.searchBg))
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    @ViewBuilder private var hitList: some View {
        if hits.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 34, weight: .light))
                    .foregroundColor(C.subLabel)
                Text(Tr("没找到相关的，换个说法试试")).font(pf(14)).foregroundColor(C.subLabel)
                    Button { showKefu = true } label: {
                        Text(Tr("联系在线客服"))
                        .font(pf(15, .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 22)
                        .frame(height: 40)
                        .background(Capsule().fill(C.green))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        } else {
            GroupCard {
                ForEach(Array(hits.enumerated()), id: \.offset) { idx, hit in
                    if idx > 0 { HairLine(inset: 16) }
                    QAItem(category: hit.cat, item: hit.item, forceOpen: true)
                }
            }
            .padding(.top, 10)
        }
    }

    @ViewBuilder private var hotCard: some View {
        let hot = cfg?.hot ?? []
        if !hot.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(Tr("热门问题")).font(pf(13)).foregroundColor(C.subLabel)
                    .padding(.horizontal, 8).padding(.bottom, 6)
                GroupCard {
                    ForEach(Array(hot.enumerated()), id: \.offset) { idx, it in
                        if idx > 0 { HairLine(inset: 16) }
                        QAItem(category: "", item: it, forceOpen: true)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 12)
        }
    }

    @ViewBuilder private var categoryCard: some View {
        if !cats.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(Tr("按分类看")).font(pf(13)).foregroundColor(C.subLabel)
                    .padding(.horizontal, 8).padding(.bottom, 6)
                GroupCard {
                    ForEach(Array(cats.enumerated()), id: \.element.id) { idx, c in
                        if idx > 0 { HairLine(inset: 58) }
                        Button { openCat = c } label: {
                            HStack(spacing: 12) {
                                Image(systemName: faqSymbol(c.title))
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.white)
                                    .frame(width: 30, height: 30)
                                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(C.green))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(c.title).font(pf(16.5)).foregroundColor(C.label)
                                    Text("\((c.items ?? []).count) " + Tr("个问题"))
                                        .font(pf(12)).foregroundColor(C.subLabel)
                                }
                                Spacer(minLength: 8)
                                Chevron(size: 9, line: 1.6)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 60)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 12)
        }
    }

    private var contactFoot: some View {
        VStack(spacing: 10) {
            Text(Tr("还有问题？找在线客服"))
                .font(pf(13)).foregroundColor(C.subLabel)
            Button { showKefu = true } label: {
                Text(Tr("联系在线客服"))
                    .font(pf(15, .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .frame(height: 42)
                    .background(Capsule().fill(C.green))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 22)
    }

    private func faqSymbol(_ title: String) -> String {
        if title.contains("账号") || title.contains("登录") { return "person.crop.circle" }
        if title.contains("支付") || title.contains("钱") || title.contains("提现") { return "creditcard" }
        if title.contains("聊天") || title.contains("通话") || title.contains("消息") { return "bubble.left.and.bubble.right" }
        if title.contains("安全") || title.contains("隐私") { return "lock.shield" }
        return "questionmark.circle"
    }
}

/* ---------------------------------------------------------- 账户升级服务 */
struct WalletUpgradeView: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var info: API.WalletLevel?
    @State private var busy = false
    @State private var showRealName = false
    @State private var showBankCards = false
    @State private var tip = ""

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("账户升级服务"), back: { dismiss() })
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    levelHeader
                    limitsCard
                    stepsCard
                    levelsCard
                    upgradeButton
                    if !tip.isEmpty {
                        Text(tip)
                            .font(pf(13))
                            .foregroundColor(C.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .padding(.top, 10)
                    }
                    footNote
                    Color.clear.frame(height: 26)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { await load() }
        .sheet(isPresented: $showRealName) {
            RealNameView().environmentObject(app)
        }
        .sheet(isPresented: $showBankCards) {
            /* BankCardsView 自己就带导航栈了，外面别再套一层（套两层会白屏 / 直接闪退） */
            BankCardsView().environmentObject(app)
        }
    }

    private var levelHeader: some View {
        VStack(spacing: 6) {
            Text(info?.levelName ?? "…")
                .font(pf(19, .medium))
                .foregroundColor(.white)
            Text(info?.tip ?? "")
                .font(pf(12.5))
                .foregroundColor(Color.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        /* 2026-10-17：绿色渐变按钮改成跟全 App 主色走（ui.json: greenColor） */
        .background(LinearGradient(colors: [C.green, C.green.opacity(0.82)],
                                   startPoint: .top, endPoint: .bottom))
    }

    private var limitsCard: some View {
        GroupCard {
            HStack(spacing: 0) {
                limitCell(Tr("单笔上限"), money(info?.single))
                Rectangle().fill(C.hairline).frame(width: 0.5, height: 40)
                limitCell(Tr("单日上限"), money(info?.day))
                Rectangle().fill(C.hairline).frame(width: 0.5, height: 40)
                limitCell(Tr("今日剩余"), money(info?.leftToday))
            }
            .padding(.vertical, 14)
        }
        .padding(.top, 10)
    }

    private func limitCell(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(pfMoney(17)).foregroundColor(C.label)
            Text(title).font(pf(12)).foregroundColor(C.subLabel)
        }
        .frame(maxWidth: .infinity)
    }

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Tr("升级要做的两步")).font(pf(13)).foregroundColor(C.subLabel)
                .padding(.horizontal, 8).padding(.bottom, 6)
            GroupCard {
                let steps: [API.WalletLevelStep] = info?.steps ?? []
                ForEach(0..<steps.count, id: \.self) { i in
                    if i > 0 { HairLine(inset: 16) }
                    stepRow(steps[i])
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 14)
    }

    private func stepRow(_ st: API.WalletLevelStep) -> some View {
        let done: Bool = (st.done == true)
        return Button {
            guard !done else { return }
            if st.key == "realname" { showRealName = true } else { showBankCards = true }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundColor(done ? C.green : C.subLabel)
                VStack(alignment: .leading, spacing: 3) {
                    Text(st.name ?? "").font(pf(16)).foregroundColor(C.label)
                    Text(st.hint ?? "").font(pf(12)).foregroundColor(C.subLabel)
                }
                Spacer(minLength: 8)
                Text(done ? Tr("已完成") : Tr("去完成"))
                    .font(pf(13))
                    .foregroundColor(done ? C.subLabel : C.green)
                /* 原来写的是 if !done { Chevron(...) }，Swift 类型检查偶尔会报
                   "type of expression is ambiguous without a type annotation"，
                   导致云端构建时好时坏。改成用透明度控制，结果一样但不再有歧义。 */
                Chevron(size: 9, line: 1.6).opacity(done ? 0 : 1)
            }
            .padding(.horizontal, 16)
            .frame(height: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var levelsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Tr("各等级额度")).font(pf(13)).foregroundColor(C.subLabel)
                .padding(.horizontal, 8).padding(.bottom, 6)
            GroupCard {
                let rows: [API.WalletLevelRow] = info?.levels ?? []
                ForEach(0..<rows.count, id: \.self) { i in
                    if i > 0 { HairLine(inset: 16) }
                    levelRow(rows[i])
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 14)
    }

    private func levelRow(_ lv: API.WalletLevelRow) -> some View {
        let cur: Bool = (lv.current == true)
        return HStack(spacing: 10) {
            Text(lv.name ?? "").font(pf(15)).foregroundColor(C.label)
            if cur {
                Text(Tr("当前")).font(pf(10.5)).foregroundColor(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Capsule().fill(C.green))
            }
            Spacer(minLength: 6)
            Text("单笔 " + money(lv.single) + " · 单日 " + money(lv.day))
                .font(pf(12.5)).foregroundColor(C.subLabel)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var upgradeButton: some View {
        Button { upgrade() } label: {
            Text(busy ? Tr("升级中…") : (info?.level == 2 ? Tr("已经是最高等级") : Tr("立即升级")))
                .font(pf(17, .medium))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(info?.level == 2 ? C.subLabel : C.green))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .disabled(busy || info?.level == 2)
    }

    private var footNote: some View {
        Text(Tr("升级不收费，只是把身份信息补全：实名认证 + 绑定一张银行卡。信息只存在我们服务器，卡号只记末四位。"))
            .font(pf(12.5))
            .foregroundColor(C.subLabel)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 16)
    }

    private func money(_ v: Double?) -> String {
        guard let v = v else { return "—" }
        /* 额度这类大数字：千分位、不要小数（¥20,000）；小额照常两位小数 */
        let f = moneyFmt(v)
        if v >= 1000 { return "¥" + String(f.split(separator: ".").first ?? "") }
        return "¥" + f
    }

    private func load() async {
        info = try? await API.shared.walletLevel()
    }

    private func upgrade() {
        busy = true
        tip = ""
        Task {
            do {
                _ = try await API.shared.walletUpgrade()
                await load()
                app.show(Tr("账户已升级，额度提到最高档"))
            } catch {
                tip = (error as? LocalizedError)?.errorDescription ?? "升级失败，再试一次"
                await load()
            }
            busy = false
        }
    }
}
