import SwiftUI

/* ============================================================
   账单（钱包页右上角「账单」进来）

   **时间轴按微信的来**（2026-10-16 用户：「年月日账单排排清楚…滚动时间轴都按照微信对齐」）：
     · 年 + 月：一整块吸顶的行 ——「2026年10月」在左、右边是「支出 ¥x 收入 ¥y」。
       滚动时它像微信那样**钉在顶上**，下面这个月的账单从它底下过。
     · 日：每天的账单前面加一小行「10月16日 星期五」＋ 当天的支出。
       所以**同一个人一天里转了好几次**、隔了几天又转，全都一眼看得清，年月日不会糊在一起。
     · 每一笔：一行一笔，一行都不合并（对方头像 + 「转账给张三 / 张三转给你」+
       时刻 + 金额）；还没收款的那笔把状态也带出来。
     · 尺寸还是照参考图量的（iPhone @3x，420×912pt）：
       顶栏高 52.4：「全部账单 ▾」药丸 90×36 在 x=16.7、
       「查找交易」搜索框 101.7×36 在 x=124.3、「收支统计 ›」贴右 18，
       顶栏下面一条 0.5pt 分隔线
       ／白卡里每行 80：图标 48 圆角 12 在 x=16、标题 x=81（17pt）、
       时间 x=81（13pt #B2B2B2）、金额贴右 18（16pt，收入 #FFC406，支出深色）
    数据来自 GET /api/bills（真实转账记录）。
   ============================================================ */

struct BillsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var realtime = Realtime.shared

    @State private var bills: [BillRecord] = []
    @State private var months: [String] = []
    @State private var summary: BillSummary?
    @State private var month = ""                 // 空 = 全部
    @State private var loading = true
    @State private var showMonths = false
    @State private var showStats = false
    /// 右上角那三个点的面板开着没有
    @State private var showMoreMenu = false
    /// 分享导出的账单文件（系统分享面板）
    @State private var shareFile: ShareFile?
    /// 「选择月份」那张滚轮里的年 / 月
    @State private var pickYear = 2026
    @State private var pickMonth = 10
    /// 查找交易：点一下进整页搜索
    @State private var showSearch = false
    @State private var filter = "all"             // all / out / in
    @State private var query = ""
    @State private var openBill: BillRecord?
    @State private var showDetail = false
    @State private var style = BillsPageStyle()
    @State private var faq: [BalanceFaq] = []
    @State private var showFaq = false
    @State private var faqAnswer: String?
    /// 顶部那颗「全部账单 ▾」的下拉开着没有
    @State private var showFilterMenu = false

    /* 顶栏那两颗（全部账单 / 查找交易）：底色比原来浅一点、圆角更大、
       再加一条 0.5 的细边 —— 这就是"渲染高级一点"的那点事 */
    private let fieldBg = Color.dyn(0xF1F2F5, 0x2C2C2E)
    private let fieldEdge = Color.dyn(0xE3E4E8, 0x3A3A3C)
    private let fieldInk = Color.dyn(0x3A3A3A, 0xEDEDED)
    private let timeGray = Color.dyn(0xB2B2B2, 0x8A8A8E)
    private let sumGray = Color.dyn(0x7B7B7B, 0x8A8A8E)
    private let incomeGold = Color(hex: 0xFFC406)

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("账单"), back: { dismiss() }) {
                Button {
                    withAnimation(.easeOut(duration: 0.12)) {
                        showMoreMenu.toggle()
                        showFilterMenu = false
                    }
                } label: {
                    WeChatDots()
                        .frame(width: 44, height: L.navH)
                }
                .buttonStyle(.plain)
            }
            /* 右上角那三个点：点开是微信那种小面板（常见问题 / 导出 / 分享账单） */
            .overlay(alignment: .topTrailing) {
                if showMoreMenu {
                    moreMenu
                        .padding(.trailing, 12)
                        .padding(.top, L.navH + 4)
                }
            }
            .zIndex(3)

            topBar
                /* 那颗「全部账单 ▾」点开的下拉：全部账单 / 支出 / 收入 + 按月份 */
                .overlay(alignment: .topLeading) {
                    if showFilterMenu {
                        filterMenu
                            .padding(.leading, 16)
                            .padding(.top, 52.4 + 6)
                    }
                }
                .zIndex(2)

            /* 选月份：**在页面上摊开**（用户 2026-10-16：「账单日期的选也不要弹窗，也上下选」）。
               以前是弹一张 sheet，手要抬两次；现在是年 / 月两个滚轮直接从顶栏下面展开，
               滚到要看的年月点「完成」。 */
            if showMonths {
                monthPickerInline
            }

            /* 顶部那张蓝色「支出 / 收入 / 结余」大卡：
               2026-10-16 用户说「把大卡片关掉那个蓝色的」→ 默认**不显示**。
               后台 ui.json 里写 billSummaryCard = 1 就能再开回来（不用出包）。 */
            if UIConfig.num("billSummaryCard", 0) > 0 {
                summaryCard
            }

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if loading {
                        ProgressView().padding(.vertical, 40)
                    } else if filtered.isEmpty {
                        Text(Tr("还没有账单"))
                            .font(pf(14))
                            .foregroundColor(C.subLabel)
                            .padding(.vertical, 60)
                    } else {
                        ForEach(groups, id: \.month) { g in
                            Section {
                                ForEach(g.days, id: \.day) { d in
                                    dayRow(d)
                                    VStack(spacing: 0) {
                                        ForEach(Array(d.rows.enumerated()), id: \.element.id) { idx, b in
                                            row(b)
                                            if idx < d.rows.count - 1 { HairLine(inset: 64) }
                                        }
                                    }
                                    .background(C.cardBg)
                                }
                            } header: {
                                monthHeader(g)
                            }
                        }
                    }
                    Color.clear.frame(height: 24)
                }
            }
            .background(C.pageBg)
            /* 面板开着的时候，点列表任意地方就收起来（微信也是点一下别处就收） */
            .overlay {
                if showFilterMenu || showMoreMenu {
                    Color.black.opacity(0.05)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { closeMenus() }
                }
            }
            .zIndex(0)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .confirmationDialog(Tr("账单常见问题"), isPresented: $showFaq, titleVisibility: .visible) {
            ForEach(faq.indices, id: \.self) { i in
                Button(faq[i].q) { faqAnswer = faq[i].a }
            }
            Button(Tr("关闭"), role: .cancel) { }
        }
        .alert("账单常见问题", isPresented: Binding(get: { faqAnswer != nil }, set: { if !$0 { faqAnswer = nil } })) {
            Button(Tr("知道了"), role: .cancel) { faqAnswer = nil }
        } message: {
            Text(faqAnswer ?? "")
        }
        .navigationDestination(isPresented: $showDetail) {
            if let b = openBill { billDetail(b) }
        }
        /* 收支统计：支付宝那种真统计页（柱状图 + 构成 + 往来最多） */
        .navigationDestination(isPresented: $showStats) {
            BillsStatsView()
        }
        /* 查找交易：一整页搜索 */
        .navigationDestination(isPresented: $showSearch) {
            BillSearchView()
        }
        .sheet(item: $shareFile) { f in ShareSheet(items: [f.url]) }
        .task { await load("") }
        /* 对方收款 / 退回：账单这一页也跟着刷（不然状态还停在「待对方收款」） */
        .onChange(of: realtime.event) { ev in
            if ev.type == "transfer" || ev.type == "balance" { Task { await load(month) } }
        }
    }

    /* ---------------------------------------------------------- 顶栏 */

    /* ============================================================
       顶部那张「汇总卡」——支付宝账单页最标志性的东西：
       大字支出 + 下面收入/结余两小块，配一层蓝渐变。
       数据就用已有的 summary（选月份时就是那个月的）。
       ============================================================ */
    private var summaryCard: some View {
        let out = summary?.out ?? 0
        let income = summary?.inSum ?? 0
        let net = income - out
        let title = month.isEmpty ? Tr("本月支出") : (monthLabel(month) + Tr("支出"))
        return VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(pf(13))
                .foregroundColor(.white.opacity(0.78))
            Text(money(out))
                .font(pfMoney(34, .semibold))
                .foregroundColor(.white)
                .monospacedDigit()
                .padding(.top, 8)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Rectangle()
                .fill(Color.white.opacity(0.22))
                .frame(height: 0.5)
                .padding(.vertical, 14)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(Tr("收入"))
                        .font(pf(12))
                        .foregroundColor(.white.opacity(0.70))
                    Text(money(income))
                        .font(pfMoney(16, .medium))
                        .foregroundColor(.white)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(Tr("结余"))
                        .font(pf(12))
                        .foregroundColor(.white.opacity(0.70))
                    Text(money(net))
                        .font(pfMoney(16, .medium))
                        .foregroundColor(.white)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            /* 支付宝那套蓝（#1677FF → #0A5BD3） */
            LinearGradient(colors: [Color(hex: 0x1677FF), Color(hex: 0x0A5BD3)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) {
                    showFilterMenu.toggle()
                    showMoreMenu = false
                }
            } label: {
                HStack(spacing: 3) {
                    Text(Tr(filterName)).font(pf(13)).foregroundColor(fieldInk)
                    DownChevron(size: 9, color: fieldInk)
                }
                .frame(width: 92, height: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fieldBg))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(fieldEdge, lineWidth: 0.5))
            }
            .buttonStyle(.plain)

            /* 查找交易：**点一下进一整页搜索**（BillSearchView：搜索框 + 筛选 + 按月分组结果），
               不是原来那种就地过滤的小输入框 —— 2026-10-16 用户：「不是搜索框做高级，是里面的那页」 */
            Button { showSearch = true } label: {
                HStack(spacing: 6) {
                    SVGIcon(markup: I.searchSmall, size: 13.5, color: C.subLabel)
                        .frame(width: 13.5, height: 13.5)
                    Text(Tr("查找交易"))
                        .font(pf(13.5))
                        .foregroundColor(C.subLabel)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 11)
                .frame(width: 126, height: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fieldBg))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(fieldEdge, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .padding(.leading, 14)

            Spacer(minLength: 0)

            Button { showStats = true } label: {
                HStack(spacing: 5) {
                    Text(Tr("收支统计")).font(pf(13)).foregroundColor(sumGray)
                    Chevron(size: 6, line: 1.4, color: sumGray)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16.7)
        .frame(height: 52.4)
        .overlay(alignment: .bottom) { HairLine() }
    }

    private var filterName: String {
        filter == "out" ? "只看支出" : (filter == "in" ? "只看收入" : "全部账单")
    }

    /* ---------------------------------------------------------- 两个下拉面板 */

    private func closeMenus() {
        withAnimation(.easeOut(duration: 0.12)) {
            showFilterMenu = false
            showMoreMenu = false
        }
    }

    /// 「全部账单 ▾」点开的那块：账单范围 + 按月份看（微信账单那颗下拉就是这个）
    private var filterMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            menuTitle("账单范围")
            menuRow(Tr("全部账单"), filter == "all") { filter = "all"; closeMenus() }
            menuRow(Tr("只看支出"), filter == "out") { filter = "out"; closeMenus() }
            menuRow(Tr("只看收入"), filter == "in") { filter = "in"; closeMenus() }

            if !months.isEmpty {
                HairLine()
                menuTitle("按月份看")
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        menuRow(Tr("全部月份"), month.isEmpty) {
                            Task { await load("") }
                            closeMenus()
                        }
                        ForEach(months, id: \.self) { m in
                            menuRow(monthLabel(m), month == m) {
                                Task { await load(m) }
                                closeMenus()
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .frame(width: 178)
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 20, y: 8)
    }

    /// 右上角三个点的面板（微信那个「···」也是这么一小块）
    private var moreMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            menuRow(Tr("账单常见问题"), false) {
                closeMenus()
                showFaq = true
            }
            HairLine(inset: 14)
            menuRow(Tr("导出账单（CSV）"), false) {
                closeMenus()
                exportCsv()
            }
            HairLine(inset: 14)
            menuRow(Tr("分享账单文件"), false) {
                closeMenus()
                shareCsv()
            }
        }
        .frame(width: 190)
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 20, y: 8)
    }

    private func menuTitle(_ t: String) -> some View {
        Text(Tr(t))
            .font(pf(12))
            .foregroundColor(C.subLabel)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    /// 面板里的一行：`label ……… ✓`（选中的那一项右边打绿勾，跟微信一样）
    private func menuRow(_ title: String, _ on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 8) {
                Text(title)
                    .font(pf(15))
                    .foregroundColor(C.label)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if on {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(hex: 0x07C160))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /* ---------------------------------------------------------- 月份行 */

    private func monthHeader(_ g: MonthGroup) -> some View {
        let s = monthSum(g.month)
        return HStack(spacing: 0) {
            Button { openMonthPicker() } label: {
                HStack(spacing: 4) {
                    Text(monthLabel(g.month)).font(pf(style.monthFont)).foregroundColor(C.label)
                    DownChevron(size: 9, color: C.label)
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            Text("支出 \(money(s.out)) 收入 \(money(s.income))")
                .font(pfMoney(style.sumFont))
                .foregroundColor(sumGray)
        }
        .padding(.leading, 17)
        .padding(.trailing, 18)
        .frame(height: 46)
        /* ⚠ 这一行是**吸顶**的（见 body 里的 pinnedViews）：滚动时它钉在顶上，
           底色必须不透明，不然下面滚过去的账单会从它后面透出来 */
        .background(C.pageBg)
        .overlay(alignment: .bottom) { HairLine() }
    }

    /* ---------------------------------------------------------- 「日」那一行 */

    /* ---------------------------------------------------------- 选月份（滚轮） */

    /// 有账单的那些年份（滚轮左边那一列）
    private var availableYears: [Int] {
        var s = Set<Int>()
        for m in months { if let y = Int(m.prefix(4)) { s.insert(y) } }
        if let y = Int(month.prefix(4)), y > 0 { s.insert(y) }
        if s.isEmpty { s.insert(Calendar.current.component(.year, from: Date())) }
        return s.sorted(by: >)
    }

    /// 打开滚轮：先把当前选中的月份拨到那一格
    private func openMonthPicker() {
        let base = month.isEmpty ? (months.first ?? "") : month
        let p = base.split(separator: "-")
        let cal = Calendar.current
        pickYear = (p.count == 2 ? Int(p[0]) : nil) ?? cal.component(.year, from: Date())
        pickMonth = (p.count == 2 ? Int(p[1]) : nil) ?? cal.component(.month, from: Date())
        withAnimation(.easeOut(duration: 0.16)) { showMonths = true }
    }

    private func closeMonthPicker() {
        withAnimation(.easeOut(duration: 0.16)) { showMonths = false }
    }

    /// 「2026年10月 ▾」点开的这块 —— 直接在页面上摊开，不是弹窗：
    /// 一条「全部月份」，下面年 / 月两个滚轮（上下滚着选），右下角一颗「完成」。
    private var monthPickerInline: some View {
        let years = availableYears
        return VStack(spacing: 0) {
            Button {
                closeMonthPicker()
                Task { await load("") }
            } label: {
                HStack(spacing: 6) {
                    Text(Tr("全部月份")).font(pf(15)).foregroundColor(C.label)
                    Spacer(minLength: 0)
                    if month.isEmpty {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(C.green)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 46)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HairLine()

            HStack(spacing: 0) {
                Picker("", selection: $pickYear) {
                    ForEach(years, id: \.self) { y in Text("\(y)" + Tr("年")).tag(y) }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
                .clipped()

                Picker("", selection: $pickMonth) {
                    ForEach(1...12, id: \.self) { m in Text("\(m)" + Tr("月")).tag(m) }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
                .clipped()
            }
            .frame(height: 170)

            HStack(spacing: 10) {
                Text(Tr("滚到要看的年月，点「完成」"))
                    .font(pf(12))
                    .foregroundColor(C.subLabel)
                Spacer(minLength: 0)
                Button {
                    closeMonthPicker()
                    Task { await load(String(format: "%04d-%02d", pickYear, pickMonth)) }
                } label: {
                    Text(Tr("完成"))
                        .font(pf(14, .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .frame(height: 32)
                        .background(Capsule().fill(C.green))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// 每天前面的一小行：`10月16日 星期五` ＋ 当天的支出。
    /// 微信的日期是跟在每一行后面的；这里把「日」单独拎一行出来，
    /// 好处是**同一个人一天里转了好几次**一眼就能数清，年月日也不会糊成一团。
    private func dayRow(_ d: DayGroup) -> some View {
        HStack(spacing: 0) {
            Text(TimeFmt.billDay(d.rows.first?.createdAt))
                .font(pf(13))
                .foregroundColor(sumGray)
            Spacer(minLength: 8)
            Text(dayRight(d.rows))
                .font(pfMoney(12.5))
                .foregroundColor(sumGray)
        }
        .padding(.horizontal, 17)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(C.pageBg)
    }

    /// 这一天右边那个小结：有支出就写支出，只有收入就写收入，都没有就空着
    private func dayRight(_ rows: [BillRecord]) -> String {
        let out = rows.filter { $0.mine }.reduce(0) { $0 + $1.amount }
        if out > 0 { return "支出 " + money(out) }
        let inc = rows.filter { !$0.mine && ($0.status ?? "") == "received" }.reduce(0) { $0 + $1.amount }
        if inc > 0 { return "收入 " + money(inc) }
        return ""
    }

    /* ---------------------------------------------------------- 一行账单 */

    private func row(_ b: BillRecord) -> some View {
        Button {
            openBill = b
            showDetail = true
        } label: {
            HStack(spacing: 0) {
                Avatar(path: b.peerAvatar ?? "", size: style.icon, radius: style.icon * 0.25)
                    .padding(.leading, 16)
                VStack(alignment: .leading, spacing: 11) {
                    Text(rowTitle(b))
                        .font(pf(style.titleFont))
                        .foregroundColor(C.label)
                        .lineLimit(1)
                    Text(rowSub(b))
                        .font(pf(style.timeFont))
                        .foregroundColor(timeGray)
                        .lineLimit(1)
                }
                .padding(.leading, 17)
                Spacer(minLength: 8)
                /* 收入不带 +，只有支出带 -（跟参考图一致） */
                MoneyLabel(text: (b.mine ? "-" : "") + (style.showCurV ? money(b.amount) : moneyFmt(b.amount)),
                           size: style.amountFont, curSize: style.curFontSize,
                           color: b.mine ? C.label : incomeGold,
                           weight: style.amountWeightV)
                    .padding(.trailing, 18)
            }
            .frame(height: style.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 微信那一行写的是「转账给张三」/「张三转给你」——
    /// 同一个人转了好几笔的时候，这样一眼就知道哪笔转出去、哪笔收进来。
    private func rowTitle(_ b: BillRecord) -> String {
        /* 红包 / 充值 / 提现 / 会员不是「转给某人」，服务端已经把它们写成一句说明
           （「发红包 · 拼手气红包」「充值」「开通XX会员」），直接用那句更清楚 */
        let kind = b.walletKind ?? ""
        if !kind.isEmpty, let n = b.note, !n.isEmpty { return n }
        return b.mine ? ("转账给" + b.peer) : (b.peer + "转给你")
    }

    /// 时刻（只到分）；还没收款的把状态也带出来（微信里也是露在外面的）
    private func rowSub(_ b: BillRecord) -> String {
        let t = TimeFmt.billClock(b.createdAt)
        if (b.status ?? "pending") == "pending" { return t + " · " + b.stateText }
        return t
    }

    /* ---------------------------------------------------------- 点一条 → 账单详情 */

    @ViewBuilder
    private func billDetail(_ b: BillRecord) -> some View {
        let meId = app.me?.id ?? ""
        let chat = Chat(id: (b.chatId?.isEmpty == false ? b.chatId! : (b.peerId ?? b.id)),
                        type: "direct",
                        title: b.peer,
                        avatar: b.peerAvatar)
        let json: [String: Any] = [
            "id": b.id,
            "amount": b.amount,
            "note": b.note ?? "",
            "status": b.status ?? "pending",
            "method": b.method ?? "balance",
            "fromId": b.mine ? meId : (b.peerId ?? ""),
            "toId": b.mine ? (b.peerId ?? "") : meId,
            "createdAt": b.createdAt ?? "",
            "expiresAt": b.expiresAt ?? 0,
            "receivedAt": b.receivedAt ?? "",
            "refundedAt": b.refundedAt ?? ""
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json),
           let s = String(data: data, encoding: .utf8),
           let info = TransferInfo(json: s) {
            BillDetailView(chat: chat, info: info)
        } else {
            Text(Tr("这条账单读不出来")).font(pf(14)).foregroundColor(C.subLabel)
        }
    }

    /* ---------------------------------------------------------- 分组 / 汇总 / 数据 */

    /// 一天（年-月-日）里的所有账单
    private struct DayGroup: Hashable { var day: String; var rows: [BillRecord] }
    /// 一个月（年-月）里的所有天
    private struct MonthGroup: Hashable { var month: String; var days: [DayGroup] }

    private var filtered: [BillRecord] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return bills.filter { b in
            if filter == "out" && !b.mine { return false }
            if filter == "in" && b.mine { return false }
            if !q.isEmpty {
                let hay = (b.peer + " " + (b.note ?? "")).lowercased()
                if !hay.contains(q) { return false }
            }
            return true
        }
    }

    private var groups: [MonthGroup] {
        var out: [MonthGroup] = []
        for b in filtered {
            let m = String((b.createdAt ?? "").prefix(7))
            let d = String((b.createdAt ?? "").prefix(10))
            /* 月份 / 日期都按**服务端给的顺序**（已经是从新到旧）连着走：
               同一个月就接到上一个月里，同一天就接到上一天里 */
            var g: MonthGroup
            if out.last?.month == m { g = out.removeLast() } else { g = MonthGroup(month: m, days: []) }
            if g.days.last?.day == d {
                var day = g.days.removeLast()
                day.rows.append(b)
                g.days.append(day)
            } else {
                g.days.append(DayGroup(day: d, rows: [b]))
            }
            out.append(g)
        }
        return out
    }

    private func monthSum(_ m: String) -> (out: Double, income: Double) {
        var o = 0.0
        var i = 0.0
        for b in bills where String((b.createdAt ?? "").prefix(7)) == m {
            if b.mine { o += b.amount }
            else if (b.status ?? "") == "received" { i += b.amount }
        }
        return (o, i)
    }

    private func monthLabel(_ m: String) -> String {
        let parts = m.split(separator: "-")
        guard parts.count == 2, let mm = Int(parts[1]) else { return m }
        return "\(parts[0])年\(mm)月"
    }

    private func money(_ v: Double) -> String { "¥" + moneyFmt(v) }

    /// 导出账单：拼一份 CSV 复制到剪贴板（手机上先这样，之后可以接分享）
    private func exportCsv() {
        guard !bills.isEmpty else { app.show(Tr("还没有账单可以导出")); return }
        UIPasteboard.general.string = csvText()
        app.show("已复制 \(bills.count) 笔账单到剪贴板（CSV）")
    }

    /// 分享账单：落成一个 CSV 文件，交给系统分享面板（微信里是"用作证明材料"那条）
    private func shareCsv() {
        guard !bills.isEmpty else { app.show(Tr("还没有账单可以导出")); return }
        guard let url = writeTempFile(name: "星言账单.csv", text: csvText()) else {
            app.show(Tr("账单导出失败，再试一次"))
            return
        }
        shareFile = ShareFile(url: url)
    }

    private func csvText() -> String {
        var lines = ["时间,对方,方向,金额,状态,说明,支付方式,单号"]
        for b in bills {
            let fields = [
                TimeFmt.bill(b.createdAt),
                rowTitle(b),
                b.mine ? "支出" : "收入",
                (b.mine ? "-" : "+") + moneyFmt(b.amount),
                b.stateText,
                b.note ?? "",
                (b.method ?? "balance") == "card" ? "银行卡" : "零钱",
                b.id
            ]
            lines.append(fields.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    private func load(_ m: String) async {
        loading = true
        if let d = try? await API.shared.bills(month: m.isEmpty ? nil : m) {
            bills = d.bills
            months = d.months ?? []
            summary = d.summary
            month = m
            if let s = d.style { style = s }
            faq = d.faq ?? []
        }
        loading = false
    }
}

/// 小的下箭头（月份、筛选那种 ▾）
struct DownChevron: View {
    var size: CGFloat = 9
    var line: CGFloat = 1.6
    var color: Color = .gray
    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: size / 2, y: size / 2))
            p.addLine(to: CGPoint(x: size, y: 0))
        }
        .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
        .frame(width: size, height: size / 2)
    }
}
