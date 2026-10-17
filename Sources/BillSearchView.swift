import SwiftUI

/* ============================================================
   账单搜索（账单页顶上那颗「查找交易」点进来的一整页）

   2026-10-16 用户：「搜索位置渲染高级一点…不是搜索框做高级，是里面的那页」——
   所以这是**独立的一页**，不是原来那种就地过滤的小输入框：
     · 顶上一整条搜索框（自动聚焦、带放大镜和一键清空、取消退出）
     · 下面一排筛选（全部/支出/收入 ＋ 全部时间/近一月/近三月/今年）
     · 没输内容：显示「最近搜索」（本机记着，能一条条删）
     · 输了内容：按月分组出结果，顶上告诉你「找到 N 笔」
     · 每一行右边还是金额（收入金色、支出深色），点一下进账单详情
   ============================================================ */

struct BillSearchView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var q = ""
    /// 0 全部 / 1 支出 / 2 收入
    @State private var kind = 0
    /// 0 全部时间 / 1 近一月 / 2 近三月 / 3 今年
    @State private var span = 0
    @State private var bills: [BillRecord] = []
    @State private var loading = true
    @State private var history: [String] = []
    @State private var openBill: BillRecord?
    @State private var showDetail = false
    @FocusState private var focused: Bool

    private let fieldBg = Color.dyn(0xF1F2F5, 0x2C2C2E)
    private let fieldEdge = Color.dyn(0xE3E4E8, 0x3A3A3C)
    private let ink = C.label
    private let subInk = C.subLabel
    private let incomeGold = Color(hex: 0xFFC406)
    private let chipBg = Color.dyn(0xF1F2F5, 0x2C2C2E)

    var body: some View {
        VStack(spacing: 0) {
            topBar
            filterRow
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    if q.trimmingCharacters(in: .whitespaces).isEmpty {
                        emptyHint
                    } else if loading {
                        ProgressView().padding(.vertical, 40)
                    } else if groups.isEmpty {
                        notFound
                    } else {
                        HStack {
                            Text(countText)
                                .font(pf(13))
                                .foregroundColor(subInk)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 17)
                        .padding(.top, 14)
                        .padding(.bottom, 6)
                        ForEach(groups, id: \.month) { g in
                            monthLabel(g.month, g.rows)
                            VStack(spacing: 0) {
                                ForEach(Array(g.rows.enumerated()), id: \.element.id) { idx, b in
                                    row(b)
                                    if idx < g.rows.count - 1 { HairLine(inset: 64) }
                                }
                            }
                            .background(C.cardBg)
                        }
                    }
                    Color.clear.frame(height: 24)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .navigationDestination(isPresented: $showDetail) {
            if let b = openBill { billDetail(b) }
        }
        .task {
            history = SearchHistory.all
            if let d = try? await API.shared.bills(limit: 200) { bills = d.bills }
            loading = false
            /* 进来就聚焦，键盘直接弹出来（微信搜索页也是这样） */
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { focused = true }
        }
    }

    /* ---------------------------------------------------------- 顶栏 */

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                SVGIcon(markup: I.searchSmall, size: 14, color: subInk)
                    .frame(width: 14, height: 14)
                TextField(Tr("查找交易"), text: $q)
                    .font(pf(14))
                    .foregroundColor(ink)
                    .textFieldStyle(.plain)
                    .accentColor(C.green)
                    .focused($focused)
                    .submitLabel(.search)
                    .onSubmit { SearchHistory.add(q) }
                    .onChange(of: q) { v in
                        if v.count >= 2 { SearchHistory.add(v); history = SearchHistory.all }
                    }
                if !q.isEmpty {
                    Button { q = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(Color.dyn(0xB8B8BE, 0x6E6E73))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fieldBg))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(fieldEdge, lineWidth: 0.5))

            Button { dismiss() } label: {
                Text(Tr("取消"))
                    .font(pf(15))
                    .foregroundColor(C.green)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    /* ---------------------------------------------------------- 筛选 */

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("全部", kind == 0) { kind = 0 }
                chip("只看支出", kind == 1) { kind = 1 }
                chip("只看收入", kind == 2) { kind = 2 }
                Rectangle().fill(C.hairline).frame(width: 0.5, height: 18).padding(.horizontal, 2)
                chip("全部时间", span == 0) { span = 0 }
                chip("近一月", span == 1) { span = 1 }
                chip("近三月", span == 2) { span = 2 }
                chip("今年", span == 3) { span = 3 }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private func chip(_ title: String, _ on: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(Tr(title))
                .font(pf(13, on ? .medium : .regular))
                .foregroundColor(on ? C.green : ink)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(on ? C.green.opacity(0.12) : chipBg))
        }
        .buttonStyle(.plain)
    }

    /* ---------------------------------------------------------- 没输内容时 */

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !history.isEmpty {
                HStack {
                    Text(Tr("最近搜索")).font(pf(13.5)).foregroundColor(subInk)
                    Spacer(minLength: 0)
                    Button {
                        SearchHistory.clear()
                        history = []
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13))
                            .foregroundColor(subInk)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 10)

                /* 一条条小胶囊，点一条就填进搜索框 */
                FlowChips(items: history) { w in
                    q = w
                    focused = true
                }
                .padding(.horizontal, 16)
            }
            Text(Tr("可以搜好友名字、备注，也可以搜「转账」「红包」「充值」"))
                .font(pf(12.5))
                .foregroundColor(subInk)
                .padding(.horizontal, 16)
                .padding(.top, 22)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var notFound: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26, weight: .light))
                .foregroundColor(subInk.opacity(0.7))
            Text(Tr("没有找到相关账单"))
                .font(pf(14))
                .foregroundColor(subInk)
            Text(Tr("换个关键词，或者把时间范围放宽一点"))
                .font(pf(12.5))
                .foregroundColor(subInk.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    /* ---------------------------------------------------------- 结果 */

    private struct MonthGroup { var month: String; var rows: [BillRecord] }

    private var filtered: [BillRecord] {
        let key = q.trimmingCharacters(in: .whitespaces).lowercased()
        let cal = Calendar.current
        let now = Date()
        return bills.filter { b in
            if kind == 1 && !b.mine { return false }
            if kind == 2 && b.mine { return false }
            if span > 0 {
                guard let d = TimeFmt.date(b.createdAt) else { return false }
                switch span {
                case 1: if !cal.isDate(d, equalTo: now, toGranularity: .month) { return false }
                case 2:
                    guard let from = cal.date(byAdding: .month, value: -3, to: now) else { break }
                    if d < from { return false }
                default:
                    if cal.component(.year, from: d) != cal.component(.year, from: now) { return false }
                }
            }
            if !key.isEmpty {
                let hay = (rowTitle(b) + " " + (b.note ?? "") + " " + (b.stateText) + " " + TimeFmt.bill(b.createdAt)).lowercased()
                if !hay.contains(key) { return false }
            }
            return true
        }
    }

    private var groups: [MonthGroup] {
        var out: [MonthGroup] = []
        for b in filtered {
            let m = String((b.createdAt ?? "").prefix(7))
            if out.last?.month == m { out[out.count - 1].rows.append(b) }
            else { out.append(MonthGroup(month: m, rows: [b])) }
        }
        return out
    }

    private var countText: String {
        Lang.isEnglish ? "\(filtered.count) results" : "找到 \(filtered.count) 笔"
    }

    private func monthLabel(_ m: String, _ rows: [BillRecord]) -> some View {
        let parts = m.split(separator: "-")
        let title = parts.count == 2 ? "\(parts[0])年\(Int(parts[1]) ?? 0)月" : m
        let out = rows.filter { $0.mine }.reduce(0) { $0 + $1.amount }
        return HStack {
            Text(title).font(pf(13)).foregroundColor(subInk)
            Spacer(minLength: 0)
            if out > 0 { Text("支出 ¥" + moneyFmt(out)).font(pfMoney(12)).foregroundColor(subInk) }
        }
        .padding(.horizontal, 17)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private func row(_ b: BillRecord) -> some View {
        Button {
            openBill = b
            showDetail = true
        } label: {
            HStack(spacing: 0) {
                Avatar(path: b.peerAvatar ?? "", size: 44, radius: 11)
                    .padding(.leading, 16)
                VStack(alignment: .leading, spacing: 7) {
                    Text(rowTitle(b)).font(pf(16)).foregroundColor(ink).lineLimit(1)
                    Text((TimeFmt.bill(b.createdAt)) + ((b.status ?? "pending") == "pending" ? (" · " + b.stateText) : ""))
                        .font(pf(12.5))
                        .foregroundColor(subInk)
                        .lineLimit(1)
                }
                .padding(.leading, 16)
                Spacer(minLength: 8)
                MoneyLabel(text: (b.mine ? "-" : "") + moneyFmt(b.amount),
                           size: 16, curSize: 0,
                           color: b.mine ? ink : incomeGold,
                           weight: .regular)
                    .padding(.trailing, 18)
            }
            .frame(height: 72)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func rowTitle(_ b: BillRecord) -> String {
        let kind = b.walletKind ?? ""
        if !kind.isEmpty, let n = b.note, !n.isEmpty { return n }
        return b.mine ? ("转账给" + b.peer) : (b.peer + "转给你")
    }

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
            Text(Tr("这条账单读不出来")).font(pf(14)).foregroundColor(subInk)
        }
    }
}

/// 一排会自动换行的小胶囊（搜索历史那种）
struct FlowChips: View {
    let items: [String]
    var tap: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows(), id: \.self) { line in
                HStack(spacing: 8) {
                    ForEach(line, id: \.self) { w in
                        Button { tap(w) } label: {
                            Text(w)
                                .font(pf(13))
                                .foregroundColor(C.label)
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .frame(height: 30)
                                .background(Capsule().fill(Color.dyn(0xF1F2F5, 0x2C2C2E)))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// 简单换行：一行最多放 3 个（够用了，不做真正的排版计算）
    private func rows() -> [[String]] {
        var out: [[String]] = []
        var cur: [String] = []
        for w in items {
            cur.append(w)
            if cur.count == 3 { out.append(cur); cur = [] }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}
