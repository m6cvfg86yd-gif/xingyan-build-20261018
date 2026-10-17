import SwiftUI

/* ============================================================
   收支统计（账单页顶栏「收支统计 ›」进来）

   2026-10-16 用户：「把收支统计按照支付宝这种的做出来」。
   支付宝那张统计页长这样，这里照着它搭：
     · 上面「支出 / 收入」两个 tab（选中一条短横线）
     · 一个**大数字**：这个月的合计，下面一行跟上月比（↑↓ 百分比）
     · 一张**柱状图**：近 6 个月的走势，点哪根就切到哪个月
     · **构成**：钱都花在哪几类上（转账 / 红包 / 充值 / 提现 / 会员），
       每行一条占比的横条 + 百分比 + 笔数
     · **往来最多**：跟哪几个人来往最多（谁转了几笔、一共多少）

   数据还是那份真实账单（GET /api/bills?limit=200），全在手机上算，不加新接口。
   ============================================================ */

struct BillsStatsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var bills: [BillRecord] = []
    @State private var loading = true
    /// 0 = 支出，1 = 收入
    @State private var kind = 0
    /// 选中的月份，形如 2026-10
    @State private var month = ""

    private let expColor = Color(hex: 0xFA5151)
    private let incColor = Color(hex: 0xFFC406)
    private let barTrack = Color.dyn(0xF0F0F0, 0x2C2C2E)

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("收支统计"), back: { dismiss() })

            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    if loading, bills.isEmpty {
                        ProgressView().padding(.vertical, 60)
                    } else if bills.isEmpty {
                        Text(Tr("还没有账单"))
                            .font(pf(14))
                            .foregroundColor(C.subLabel)
                            .padding(.vertical, 60)
                    } else {
                        tabs
                        bigNumber
                        chartCard
                        if !categories.isEmpty { categoryCard }
                        if !topPeers.isEmpty { peerCard }
                    }
                    Color.clear.frame(height: 20)
                }
                .padding(.top, 4)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { await load() }
    }

    /* ---------------------------------------------------------- 支出 / 收入 */

    private var tabs: some View {
        HStack(spacing: 30) {
            tabButton("支出", 0)
            tabButton("收入", 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private func tabButton(_ t: String, _ i: Int) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { kind = i }
        } label: {
            VStack(spacing: 6) {
                Text(Tr(t))
                    .font(pf(16, kind == i ? .semibold : .regular))
                    .foregroundColor(kind == i ? C.label : C.subLabel)
                Capsule()
                    .fill(kind == i ? (i == 0 ? expColor : incColor) : Color.clear)
                    .frame(width: 22, height: 3)
            }
        }
        .buttonStyle(.plain)
    }

    /* ---------------------------------------------------------- 大数字 */

    private var bigNumber: some View {
        let cur = value(month)
        let prev = value(prevMonth(month))
        let n = countOf(month)
        return VStack(spacing: 8) {
            Text(kind == 0 ? Tr("支出合计") : Tr("收入合计"))
                .font(pf(13))
                .foregroundColor(C.subLabel)
            Text("¥" + moneyFmt(cur))
                .font(pfMoney(32, .semibold))
                .foregroundColor(C.label)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if prev > 0 {
                let diff = (cur - prev) / prev * 100
                Text((diff >= 0 ? "↑ " : "↓ ") + String(format: "%.1f", abs(diff)) + "%  较上月 · 上月 ¥" + moneyFmt(prev))
                    .font(pf(12))
                    .foregroundColor(C.subLabel)
            } else {
                Text("共 \(n) 笔")
                    .font(pf(12))
                    .foregroundColor(C.subLabel)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 14)
    }

    /* ---------------------------------------------------------- 柱状图 */

    private var chartCard: some View {
        let list = monthsShown
        let top = max(1, list.map { value($0) }.max() ?? 1)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(Tr("近 6 个月"))
                    .font(pf(14, .medium))
                    .foregroundColor(C.label)
                Spacer(minLength: 8)
                Text(kind == 0 ? Tr("支出") : Tr("收入"))
                    .font(pf(12))
                    .foregroundColor(C.subLabel)
            }
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(list, id: \.self) { m in
                    let v = value(m)
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { month = m }
                    } label: {
                        VStack(spacing: 0) {
                            Text(m == month ? moneyFmt(v) : "")
                                .font(pfMoney(11))
                                .foregroundColor(kind == 0 ? expColor : incColor)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(height: 16)
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill((kind == 0 ? expColor : incColor)
                                            .opacity(m == month ? 1 : 0.22))
                                    .frame(width: 18, height: barHeight(v, top))
                            }
                            .frame(height: 96)
                            Text(shortMonth(m))
                                .font(pf(11))
                                .foregroundColor(m == month ? C.label : C.subLabel)
                                .frame(height: 18)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 14)
    }

    /// 柱子高度：按这半年里最大的那个等比（最小也给 4pt，不然"这个月没花钱"看不出来）
    private func barHeight(_ v: Double, _ top: Double) -> CGFloat {
        guard v > 0 else { return 4 }
        return max(8, CGFloat(v / top) * 92)
    }

    /* ---------------------------------------------------------- 构成 */

    private var categoryCard: some View {
        let list = categories
        let total = max(0.01, list.reduce(0) { $0 + $1.amount })
        return VStack(alignment: .leading, spacing: 0) {
            Text(Tr("构成"))
                .font(pf(14, .medium))
                .foregroundColor(C.label)
                .padding(.bottom, 6)
            ForEach(Array(list.enumerated()), id: \.offset) { _, c in
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(catColor(c.name).opacity(0.14))
                                .frame(width: 30, height: 30)
                            Image(systemName: catIcon(c.name))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(catColor(c.name))
                        }
                        Text(Tr(c.name))
                            .font(pf(15))
                            .foregroundColor(C.label)
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("¥" + moneyFmt(c.amount))
                                .font(pfMoney(14))
                                .foregroundColor(C.label)
                                .monospacedDigit()
                            Text("\(c.count) 笔 · " + pct(c.amount / total))
                                .font(pf(11.5))
                                .foregroundColor(C.subLabel)
                        }
                    }
                    /* 占比那条横条（支付宝那张图里就是一排这个） */
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(barTrack)
                            Capsule()
                                .fill(catColor(c.name))
                                .frame(width: max(4, g.size.width * CGFloat(c.amount / total)))
                        }
                    }
                    .frame(height: 6)
                    .padding(.leading, 40)
                }
                .padding(.vertical, 10)
            }
        }
        .padding(16)
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 14)
    }

    /* ---------------------------------------------------------- 往来最多 */

    private var peerCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Tr("往来最多"))
                .font(pf(14, .medium))
                .foregroundColor(C.label)
                .padding(.bottom, 4)
            ForEach(Array(topPeers.enumerated()), id: \.offset) { i, p in
                HStack(spacing: 12) {
                    Text("\(i + 1)")
                        .font(pf(13, .semibold))
                        .foregroundColor(i == 0 ? expColor : C.subLabel)
                        .frame(width: 18)
                    Avatar(path: p.avatar, size: 34, radius: 9)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.name)
                            .font(pf(15))
                            .foregroundColor(C.label)
                            .lineLimit(1)
                        Text("\(p.count) 笔")
                            .font(pf(11.5))
                            .foregroundColor(C.subLabel)
                    }
                    Spacer(minLength: 8)
                    Text("¥" + moneyFmt(p.amount))
                        .font(pfMoney(14))
                        .foregroundColor(C.label)
                        .monospacedDigit()
                }
                .padding(.vertical, 9)
                if i < topPeers.count - 1 { HairLine(inset: 0) }
            }
        }
        .padding(16)
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 14)
    }

    /* ---------------------------------------------------------- 算数 */

    /// 这笔算不算当前这一栏（支出：转出去就算，待收款也算；收入：只算已经收到的）
    private func counted(_ b: BillRecord) -> Bool {
        if kind == 0 { return b.mine }
        return !b.mine && (b.status ?? "") == "received"
    }

    private func monthOf(_ b: BillRecord) -> String { String((b.createdAt ?? "").prefix(7)) }

    private func prevMonth(_ m: String) -> String {
        let p = m.split(separator: "-")
        guard p.count == 2, let y = Int(p[0]), let mm = Int(p[1]) else { return "" }
        return mm <= 1 ? String(format: "%04d-12", y - 1) : String(format: "%04d-%02d", y, mm - 1)
    }

    /// 图表画 6 根：从选中的月份往前数 6 个月（哪个月没花钱就空着）
    private var monthsShown: [String] {
        guard !month.isEmpty else { return [] }
        var out = [month]
        var cur = month
        while out.count < 6 {
            cur = prevMonth(cur)
            if cur.isEmpty { break }
            out.insert(cur, at: 0)
        }
        return out
    }

    private func shortMonth(_ m: String) -> String {
        let p = m.split(separator: "-")
        guard p.count == 2, let mm = Int(p[1]) else { return m }
        return "\(mm)月"
    }

    private func value(_ m: String) -> Double {
        guard !m.isEmpty else { return 0 }
        return bills.filter { monthOf($0) == m && counted($0) }.reduce(0) { $0 + $1.amount }
    }

    private func countOf(_ m: String) -> Int {
        guard !m.isEmpty else { return 0 }
        return bills.filter { monthOf($0) == m && counted($0) }.count
    }

    private struct Cat { var name: String; var amount: Double; var count: Int }

    private var categories: [Cat] {
        var map: [String: Cat] = [:]
        for b in bills where monthOf(b) == month && counted(b) {
            let k = catName(b)
            var c = map[k] ?? Cat(name: k, amount: 0, count: 0)
            c.amount += b.amount
            c.count += 1
            map[k] = c
        }
        return map.values.sorted { $0.amount > $1.amount }
    }

    private func catName(_ b: BillRecord) -> String {
        switch b.walletKind ?? "" {
        case "redpacket": return "红包"
        case "recharge":  return "充值"
        case "withdraw":  return "提现"
        case "member":    return "会员"
        default:          return "转账"
        }
    }

    private func catIcon(_ n: String) -> String {
        switch n {
        case "红包": return "gift.fill"
        case "充值": return "plus.circle.fill"
        case "提现": return "banknote.fill"
        case "会员": return "crown.fill"
        default:     return "arrow.left.arrow.right"
        }
    }

    private func catColor(_ n: String) -> Color {
        switch n {
        case "红包": return Color(hex: 0xFA5151)
        case "充值": return Color(hex: 0x10AEFF)
        case "提现": return Color(hex: 0x07C160)
        case "会员": return Color(hex: 0xE8A33D)
        default:     return Color(hex: 0x576B95)
        }
    }

    private func pct(_ v: Double) -> String {
        String(format: "%.1f%%", max(0, v) * 100)
    }

    private struct PeerRow { var name: String; var avatar: String; var amount: Double; var count: Int }

    /// 跟谁来往最多（只算转账，红包/充值那种没有"对方"）
    private var topPeers: [PeerRow] {
        var map: [String: PeerRow] = [:]
        for b in bills where monthOf(b) == month && counted(b) && (b.walletKind ?? "").isEmpty {
            let key = (b.peerId?.isEmpty == false ? b.peerId! : b.peer)
            var r = map[key] ?? PeerRow(name: b.peer, avatar: b.peerAvatar ?? "", amount: 0, count: 0)
            r.amount += b.amount
            r.count += 1
            map[key] = r
        }
        return Array(map.values.sorted { $0.amount > $1.amount }.prefix(3))
    }

    private func load() async {
        loading = true
        if let d = try? await API.shared.bills(limit: 200) {
            bills = d.bills
            if month.isEmpty {
                /* 默认落在最近有账单的那个月 */
                var keys: [String] = []
                for b in d.bills {
                    let m = String((b.createdAt ?? "").prefix(7))
                    if m.count == 7, !keys.contains(m) { keys.append(m) }
                }
                month = keys.first ?? ""
            }
        }
        loading = false
    }
}
