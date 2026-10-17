import SwiftUI

/* ============================================================
   客服中心（腾讯/微信那套）
   · 上面一个搜索框：直接搜问题，命中的问答立刻列出来
   · 在线客服：点「联系客服」＝和「在线客服」开一个会话（转人工）
   · 常见问题：后台「客服中心」里配的分类 + 问答，点开看答案
   · 提交问题：生成一张工单，处理进度在「我的工单」里看，后台回复会直接进聊天
   所有文案、分类、问答、开关都在后台配，改完 App 里立刻生效（不用装包）
   ============================================================ */
struct SupportView: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var cfg: API.SupportPayload?
    @State private var loading = true
    @State private var q = ""
    @State private var nextChat: Chat?
    @State private var openCat: API.SupportCategory?
    @State private var showTicket = false
    @State private var busyHuman = false
    /// 「联系客服」直接开独立客服页（不再跳普通聊天）
    @State private var showKefu = false

    private var cats: [API.SupportCategory] { cfg?.categories ?? [] }
    private var tickets: [API.SupportTicket] { cfg?.tickets ?? [] }
    private var isOpenHuman: Bool { (cfg?.human ?? 1) != 0 }
    private var isTicketOn: Bool { (cfg?.ticketOn ?? 1) != 0 }

    /// 搜索命中的问答：问题或答案里有这个词就算
    private var hits: [(cat: String, item: API.SupportItem)] {
        let key = q.trimmingCharacters(in: .whitespaces)
        if key.isEmpty { return [] }
        var out: [(String, API.SupportItem)] = []
        for c in cats {
            for it in (c.items ?? []) {
                if it.q.localizedCaseInsensitiveContains(key) || it.a.localizedCaseInsensitiveContains(key) {
                    out.append((c.title, it))
                }
            }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: cfg?.title ?? Tr("客服中心"), back: { dismiss() })

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    searchBar

                    if !q.trimmingCharacters(in: .whitespaces).isEmpty {
                        hitList
                    } else {
                        if isOpenHuman { humanCard }
                        faqCard
                        if isTicketOn { ticketCard }
                        if !tickets.isEmpty { myTickets }
                        contactCard
                        footNote
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
        .task { await load() }
        .navigationDestination(isPresented: Binding(
            get: { nextChat != nil },
            set: { if !$0 { nextChat = nil } }
        )) {
            if let c = nextChat { ChatDetailView(chat: c) }
        }
        .navigationDestination(isPresented: Binding(
            get: { openCat != nil },
            set: { if !$0 { openCat = nil } }
        )) {
            if let c = openCat { SupportCategoryView(cat: c, keyword: q) }
        }
        .sheet(isPresented: $showTicket) {
            SupportTicketSheet(hint: cfg?.ticketHint ?? "",
                               categories: cats.map { $0.title }) { cat, text in
                let list = try await API.shared.supportTicket(category: cat, content: text)
                await MainActor.run {
                    if var c = cfg {
                        c.tickets = list
                        cfg = c
                    }
                    app.show(Tr("已经提交，客服处理完会回到这里"))
                }
            }
            .environmentObject(app)
        }
        /* 「联系客服」：开独立的在线客服页面 */
        .sheet(isPresented: $showKefu) {
            KefuPage().environmentObject(app)
        }
    }

    /* ---------------------------------------------------------- 搜索 */
    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(C.searchIcon)
            TextField(cfg?.searchHint?.isEmpty == false ? (cfg!.searchHint!) : Tr("描述你遇到的问题"), text: $q)
                .font(pf(14.5))
                .foregroundColor(C.label)
                .submitLabel(.search)
            if !q.isEmpty {
                Button { q = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(C.searchIcon)
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

    private var hitList: some View {
        Group {
            if hits.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 34, weight: .light))
                        .foregroundColor(C.subLabel)
                    Text(Tr("没找到相关的，换个说法试试"))
                        .font(pf(14))
                        .foregroundColor(C.subLabel)
                    if isOpenHuman {
                        Button { openHuman() } label: {
                            Text(busyHuman ? Tr("正在接通…") : Tr("联系在线客服"))
                                .font(pf(15, .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 22)
                                .frame(height: 40)
                                .background(Capsule().fill(C.green))
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
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
    }

    /* ---------------------------------------------------------- 在线客服 */
    private var humanCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AsyncAvatar(path: cfg?.agent?.avatar ?? "", size: 46, corner: 23)
                VStack(alignment: .leading, spacing: 4) {
                    Text(cfg?.agent?.nickname ?? Tr("在线客服"))
                        .font(pf(16.5, .medium))
                        .foregroundColor(C.label)
                    Text((cfg?.workTime?.isEmpty == false) ? cfg!.workTime! : Tr("人工在线时间 09:00 - 22:00"))
                        .font(pf(12.5))
                        .foregroundColor(C.subLabel)
                }
                Spacer(minLength: 8)
                Button { openHuman() } label: {
                    Text(busyHuman ? Tr("接通中…") : Tr("联系客服"))
                        .font(pf(14.5, .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 34)
                        .background(Capsule().fill(C.green))
                }
                .buttonStyle(.plain)
                .disabled(busyHuman)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
        .background { CardGlassBox(radius: 8) }
        .padding(.horizontal, 8)
        .padding(.top, 10)
    }

    /* ---------------------------------------------------------- 常见问题 */
    private var faqCard: some View {
        Group {
            if !cats.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Tr("常见问题"))
                        .font(pf(13))
                        .foregroundColor(C.subLabel)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                    GroupCard {
                        ForEach(Array(cats.enumerated()), id: \.element.id) { idx, c in
                            if idx > 0 { HairLine(inset: 58) }
                            Button { openCat = c } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: catSymbol(c.title))
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundColor(.white)
                                        .frame(width: 30, height: 30)
                                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(catColor(idx)))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(c.title)
                                            .font(pf(16.5))
                                            .foregroundColor(C.label)
                                        Text(Tr("共") + " \((c.items ?? []).count) " + Tr("个问题"))
                                            .font(pf(12))
                                            .foregroundColor(C.subLabel)
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
                .padding(.top, 14)
            }
        }
    }

    /* ---------------------------------------------------------- 提交问题 */
    private var ticketCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupCard {
                Button { showTicket = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.white)
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(hexString: "#1180E0", fallback: 0x1180E0)))
                        Text(Tr("提交问题"))
                            .font(pf(16.5))
                            .foregroundColor(C.label)
                        Spacer(minLength: 8)
                        Text(Tr("写清楚一点，我们尽快处理"))
                            .font(pf(12.5))
                            .foregroundColor(C.subLabel)
                        Chevron(size: 9, line: 1.6)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 14)
    }

    /* ---------------------------------------------------------- 我的工单 */
    private var myTickets: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Tr("我的工单"))
                .font(pf(13))
                .foregroundColor(C.subLabel)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            GroupCard {
                ForEach(Array(tickets.enumerated()), id: \.element.id) { idx, t in
                    if idx > 0 { HairLine(inset: 14) }
                    ticketRow(t)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 14)
    }

    private func ticketRow(_ t: API.SupportTicket) -> some View {
        let done = (t.status ?? "") == "done"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(t.category ?? Tr("其它问题"))
                    .font(pf(15, .medium))
                    .foregroundColor(C.label)
                Spacer(minLength: 8)
                Text(done ? Tr("已处理") : ((t.status ?? "") == "replied" ? Tr("已回复") : Tr("待处理")))
                    .font(pf(12.5))
                    .foregroundColor(done ? C.subLabel : C.green)
                Text(shortTime(t.createdAt ?? ""))
                    .font(pf(12))
                    .foregroundColor(C.subLabel)
            }
            if let c = t.content, !c.isEmpty {
                Text(c)
                    .font(pf(14))
                    .foregroundColor(C.subLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let r = t.reply, !r.isEmpty {
                Text(Tr("客服回复") + "：" + r)
                    .font(pf(14))
                    .foregroundColor(C.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /* ---------------------------------------------------------- 联系方式 */
    @ViewBuilder private var contactCard: some View {
        let phone = cfg?.phone ?? ""
        let mail = cfg?.email ?? ""
        if !phone.isEmpty || !mail.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(Tr("其他联系方式"))
                    .font(pf(13))
                    .foregroundColor(C.subLabel)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                GroupCard {
                    if !phone.isEmpty {
                        Button {
                            if let url = URL(string: "tel://" + phone.filter { $0.isNumber }) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            contactRow(Tr("客服电话"), phone)
                        }
                        .buttonStyle(.plain)
                    }
                    if !phone.isEmpty && !mail.isEmpty { HairLine(inset: 14) }
                    if !mail.isEmpty {
                        Button {
                            let body = (cfg?.title ?? Tr("客服中心")) + " " + (app.me?.username ?? "")
                            if let url = URL(string: "mailto:" + mail + "?subject=Feedback&body="
                                             + (body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            contactRow(Tr("客服邮箱"), mail)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 14)
        }
    }

    private func contactRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(title).font(pf(16.5)).foregroundColor(C.label)
            Spacer(minLength: 8)
            Text(value).font(pf(14)).foregroundColor(C.subLabel)
            Chevron(size: 9, line: 1.6)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .contentShape(Rectangle())
    }

    private var footNote: some View {
        Text(Tr("客服不会向你索要密码、验证码，也不会让你转账。遇到这种都是骗子。"))
            .font(pf(12.5))
            .foregroundColor(C.subLabel)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 22)
            .padding(.top, 16)
    }

    /* ---------------------------------------------------------- 动作 */
    private func load() async {
        if let got = try? await API.shared.support() {
            cfg = got
        }
        loading = false
    }

    /// 转人工：开一个和「在线客服」的会话，直接进聊天页
    private func openHuman() {
        /* 直接开「在线客服」独立页面（页面里自己会建会话、拉消息），不再跳普通聊天 */
        if busyHuman { return }
        showKefu = true
    }

    private func catSymbol(_ title: String) -> String {
        if title.contains("账号") || title.contains("登录") || title.contains("注册") { return "person.crop.circle" }
        if title.contains("支付") || title.contains("钱包") || title.contains("钱") || title.contains("转账") { return "creditcard" }
        if title.contains("聊天") || title.contains("通话") || title.contains("消息") || title.contains("群") { return "bubble.left.and.bubble.right" }
        if title.contains("安全") || title.contains("隐私") || title.contains("锁") || title.contains("实名") { return "lock.shield" }
        if title.contains("功能") || title.contains("使用") || title.contains("怎么") { return "hand.raised" }
        return "questionmark.circle"
    }

    private func catColor(_ idx: Int) -> Color {
        let list: [Color] = [C.green, Color(hexString: "#1180E0", fallback: 0x1180E0),
                             Color(hexString: "#FA9D3B", fallback: 0xFA9D3B), C.red]
        return list[idx % list.count]
    }
}

/* ============================================================ 一个分类里的问答 */
struct SupportCategoryView: View {
    @ObservedObject private var lang = LangStore.shared
    @Environment(\.dismiss) private var dismiss

    let cat: API.SupportCategory
    var keyword: String = ""

    @State private var open: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: cat.title, back: { dismiss() })

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    GroupCard {
                        ForEach(Array((cat.items ?? []).enumerated()), id: \.offset) { idx, it in
                            if idx > 0 { HairLine(inset: 14) }
                            QAItem(category: cat.title, item: it,
                                   forceOpen: open.contains(it.q) || !keyword.isEmpty)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if open.contains(it.q) { open.remove(it.q) } else { open.insert(it.q) }
                                }
                        }
                    }
                    .padding(.top, 10)

                    Text(Tr("还有问题？联系在线客服"))
                        .font(pf(13))
                        .foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 18)
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
        .onAppear {
            /* 搜索进来的：默认把答案展开，省得再点一下 */
            if !keyword.isEmpty, let first = (cat.items ?? []).first { open.insert(first.q) }
        }
    }
}

/* ============================================================ 一条问答（点一下展开答案） */
struct QAItem: View {
    let category: String
    let item: API.SupportItem
    var forceOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(C.green.opacity(0.16)).frame(width: 6, height: 6).padding(.top, 7)
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.q)
                        .font(pf(15.5, forceOpen ? .medium : .regular))
                        .foregroundColor(C.label)
                        .fixedSize(horizontal: false, vertical: true)
                    if forceOpen && !item.a.isEmpty {
                        Text(item.a)
                            .font(pf(14.5))
                            .foregroundColor(C.subLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 6)
                if !forceOpen {
                    Chevron(size: 8, line: 1.5, color: C.searchIcon)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/* ============================================================ 提交问题（工单） */
struct SupportTicketSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    var hint: String = ""
    var categories: [String] = []
    var onSubmit: (String, String) async throws -> Void

    @State private var category = ""
    @State private var text = ""
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("提交问题"), back: { dismiss() }) {
                Button {
                    send()
                } label: {
                    Text(busy ? Tr("提交中…") : Tr("提交"))
                        .font(pf(16, .medium))
                        .foregroundColor(text.isEmpty ? C.subLabel : C.green)
                        .frame(height: L.navH)
                        .padding(.trailing, 16)
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                VStack(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(Tr("把遇到的问题写清楚：什么时候、在哪个页面、点了什么、出现什么"))
                                .font(pf(15))
                                .foregroundColor(C.subLabel)
                                .padding(.horizontal, 16)
                                .padding(.top, 14)
                        }
                        TextEditor(text: $text)
                            .font(pf(15))
                            .scrollContentBackground(.hidden)
                            .frame(height: 180)
                            .padding(.horizontal, 11)
                            .padding(.top, 6)
                    }
                    .background(C.cardBg)

                    if !categories.isEmpty {
                        GroupCard {
                            HStack(spacing: 10) {
                                Text(Tr("问题分类")).font(pf(16)).foregroundColor(C.label)
                                Spacer(minLength: 8)
                                Menu {
                                    ForEach(categories, id: \.self) { c in
                                        Button(c) { category = c }
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(category.isEmpty ? Tr("请选择") : category)
                                            .font(pf(15))
                                            .foregroundColor(category.isEmpty ? C.subLabel : C.label)
                                        Chevron(size: 8, line: 1.5)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 52)
                        }
                        .padding(.top, 8)
                    }

                    if !hint.isEmpty {
                        Text(hint)
                            .font(pf(12.5))
                            .foregroundColor(C.subLabel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 22)
                            .padding(.top, 10)
                    }
                    Color.clear.frame(height: 20)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        /* 2026-10-16：客服「提交问题」补左滑返回 */
        .swipeBack { dismiss() }
    }

    private func send() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { app.show(Tr("先把问题写一句")); return }
        busy = true
        Task {
            do {
                try await onSubmit(category.isEmpty ? (categories.first ?? Tr("其它问题")) : category, body)
                busy = false
                dismiss()
            } catch {
                busy = false
                app.show((error as? LocalizedError)?.errorDescription ?? Tr("提交失败，再试一次"))
            }
        }
    }
}

/* ============================================================ 头像（后台给的地址，可能是 /uploads/xxx） */
struct AsyncAvatar: View {
    let path: String
    let size: CGFloat
    var corner: CGFloat = 0

    var body: some View {
        Group {
            if !path.isEmpty, let url = API.shared.assetURL(path) {
                AsyncImage(url: url) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner > 0 ? corner : 6, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            C.green
            Image(systemName: "headphones")
                .font(.system(size: size * 0.45, weight: .medium))
                .foregroundColor(.white)
        }
    }
}

/* 时间：10-08 14:22 → 10-08 14:22（截短一点，工单列表够用） */
func shortTime(_ raw: String) -> String {
    let s = raw.replacingOccurrences(of: "T", with: " ")
    guard s.count >= 16 else { return s }
    let a = s.index(s.startIndex, offsetBy: 5)
    let b = s.index(s.startIndex, offsetBy: 16)
    return String(s[a..<b])
}
