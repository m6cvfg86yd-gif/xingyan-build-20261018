import SwiftUI

/* ============================================================
   红包（微信那一套）
   · 聊天里那张卡片：橙色的可以点开，领过/领完/过期都变淡
   · 发红包：金额 + 个数（群聊）+ 祝福语 + 拼手气/普通 → 支付密码
   · 拆红包：点「开」才进零钱，显示抢到多少
   · 详情：谁抢了多少、手气最佳
   ============================================================ */

struct RedPacketInfo: Identifiable {
    var id = ""
    var total: Double = 0
    var count = 1
    var claimedCount = 0
    var claimedIds: [String] = []
    var type = "normal"
    var note = ""
    var status = "pending"
    var expired = false
    var fromId = ""
    var fromName = ""
    var expiresAt: Double = 0
    var refundAmount: Double = 0
    /* 封面（微信那套：发红包时挑一张，卡片和拆红包页都按它画） */
    var coverId = ""
    var coverName = ""
    var cover = ""
    var coverThumb = ""
    var coverColor = "#B3241C"

    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = o["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        total = num(o["total"])
        count = max(1, Int(num(o["count"], 1)))
        claimedCount = Int(num(o["claimedCount"], 0))
        claimedIds = (o["claimedIds"] as? [String]) ?? []
        type = (o["type"] as? String) ?? "normal"
        note = (o["note"] as? String) ?? "恭喜发财，大吉大利"
        status = (o["status"] as? String) ?? "pending"
        /* 老版本那条「一对一红包」的消息（服务器上已经删掉那套逻辑）：
           status 是 received，这里当成已结束画，不要当成还能抢 */
        if status == "received" { status = "done"; expired = true }
        expired = (o["expired"] as? Bool) ?? (status == "refunded")
        fromId = (o["fromId"] as? String) ?? ""
        fromName = (o["fromName"] as? String) ?? ""
        expiresAt = num(o["expiresAt"])
        refundAmount = num(o["refundAmount"])
        coverId = (o["coverId"] as? String) ?? ""
        coverName = (o["coverName"] as? String) ?? ""
        cover = (o["cover"] as? String) ?? ""
        coverThumb = (o["coverThumb"] as? String) ?? ""
        coverColor = (o["coverColor"] as? String) ?? "#B3241C"
    }

    init(raw: API.RedPacketRaw) {
        id = raw.id
        total = raw.total ?? 0
        count = max(1, raw.count ?? 1)
        claimedCount = raw.claimedCount ?? 0
        claimedIds = raw.claimedIds ?? []
        type = raw.type ?? "normal"
        note = raw.note ?? "恭喜发财，大吉大利"
        status = raw.status ?? "pending"
        expired = raw.expired ?? (status == "refunded")
        fromId = raw.fromId ?? ""
        fromName = raw.fromName ?? ""
        expiresAt = raw.expiresAt ?? 0
        refundAmount = raw.refundAmount ?? 0
        coverId = raw.coverId ?? ""
        coverName = raw.coverName ?? ""
        cover = raw.cover ?? ""
        coverThumb = raw.coverThumb ?? ""
        coverColor = raw.coverColor ?? "#B3241C"
    }

    private func num(_ v: Any?, _ fallback: Double = 0) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String, let d = Double(s) { return d }
        return fallback
    }

    var isLucky: Bool { type == "lucky" }
    func claimed(by uid: String) -> Bool { claimedIds.contains(uid) }
    /// 还有没有得抢（群里别人还能抢）
    var stillOpen: Bool { !expired && status == "pending" && claimedCount < count }
    /// 抢完了 / 过期了
    var isOver: Bool { !stillOpen }
    /// 剩下多久过期（小时）
    var hoursLeft: Int {
        guard expiresAt > 0 else { return 0 }
        return max(0, Int((expiresAt / 1000 - Date().timeIntervalSince1970) / 3600))
    }
}

/* ============================================================ 聊天里的红包卡片 */
struct RedPacketCard: View {
    let info: RedPacketInfo
    let mine: Bool
    let myId: String

    private var claimedByMe: Bool { info.claimed(by: myId) }
    /// 领过 / 领完 / 过期 → 淡色（微信就是这样变淡的）
    private var pale: Bool { claimedByMe || info.isOver }

    private var stateText: String {
        if claimedByMe { return "已领取" }
        if info.expired { return "已过期" }
        if info.isOver { return "红包已被领完" }
        return "领取红包"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                RedPacketGlyph(pale: pale)
                    .frame(width: 30, height: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.note.isEmpty ? "恭喜发财，大吉大利" : info.note)
                        .font(pf(15.5, .medium))
                        .foregroundColor(pale ? Color.white.opacity(0.92) : .white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if info.count > 1 {
                        Text("共 \(info.count) 个")
                            .font(pf(11.5))
                            .foregroundColor(Color.white.opacity(0.75))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Rectangle()
                .fill(Color.white.opacity(0.22))
                .frame(height: 0.5)

            HStack(spacing: 6) {
                Text(info.isLucky ? "拼手气红包" : "普通红包")
                    .font(pf(11.5))
                    .foregroundColor(Color.white.opacity(0.8))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(stateText)
                    .font(pf(12.5))
                    .foregroundColor(pale ? Color.white.opacity(0.9) : .white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
        }
        .frame(width: 236, alignment: .leading)
        .background(
            Group {
                if !info.cover.isEmpty {
                    /* 有封面：直接用封面图当底（微信就是这么好看的） */
                    ZStack {
                        RPCoverView(path: info.cover, colorHex: info.coverColor)
                        LinearGradient(colors: [Color.black.opacity(0.02), Color.black.opacity(0.42)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                } else {
                    LinearGradient(colors: pale
                                   ? [Color(hex: 0xF7BE8F), Color(hex: 0xF0AE79)]
                                   : [Color(hex: 0xFA9D3C), Color(hex: 0xF2882A)],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
            .opacity(pale ? 0.86 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/* ============================================================ 封面图（后台配的图，按网址加载） */
struct RPCoverView: View {
    let path: String
    var colorHex: String = "#B3241C"
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hexString: colorHex, fallback: 0xB3241C),
                                    Color(hexString: colorHex, fallback: 0xB3241C).opacity(0.75)],
                           startPoint: .top, endPoint: .bottom)
            if let image = image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            }
        }
        .clipped()
        .task(id: path) {
            guard !path.isEmpty, let url = API.shared.assetURL(path) else { return }
            if let data = try? await API.shared.assetData(url) { image = UIImage(data: data) }
        }
    }
}

/* ============================================================ 选封面（微信那种左右滑着挑） */
struct RedPacketCoverPicker: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    /// 选好之后回调
    var onPick: (API.RedPacketCoverRaw) -> Void

    @State private var covers: [API.RedPacketCoverRaw] = []
    @State private var index = 0
    @State private var loading = true
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("选择红包封面"), back: { dismiss() })
            if loading {
                ProgressView().padding(.top, 60)
                Spacer()
            } else if covers.isEmpty {
                Text(Tr("还没有可选封面，去后台「红包封面」里加几张"))
                    .font(pf(14)).foregroundColor(C.subLabel)
                    .padding(.top, 60)
                Spacer()
            } else {
                TabView(selection: $index) {
                    ForEach(Array(covers.enumerated()), id: \.element.id) { i, c in
                        VStack(spacing: 10) {
                            RPCoverView(path: c.image ?? "", colorHex: c.color ?? "#B3241C")
                                .frame(width: 236, height: 314)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .shadow(color: Color.black.opacity(0.18), radius: 10, y: 4)
                            Text(c.name ?? "")
                                .font(pf(15, .medium))
                                .foregroundColor(C.label)
                        }
                        .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                Button {
                    pick()
                } label: {
                    Text(busy ? Tr("设置中…") : Tr("使用该封面"))
                        .font(pf(17, .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(C.green))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
                .disabled(busy)
            }
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        /* 2026-10-16：选红包封面页补左滑返回 */
        .swipeBack { dismiss() }
        .task {
            if let r = try? await API.shared.redPacketCovers() {
                covers = r.covers
                if let i = covers.firstIndex(where: { $0.id == r.mine }) { index = i }
            }
            loading = false
        }
    }

    private func pick() {
        guard index < covers.count else { return }
        let c = covers[index]
        busy = true
        Task {
            try? await API.shared.chooseRedPacketCover(id: c.id)
            busy = false
            onPick(c)
            dismiss()
        }
    }
}

/// 红包图标：红封套 + 中间一个金色小圆（微信卡片左边那个）
struct RedPacketGlyph: View {
    var pale = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: w * 0.16, style: .continuous)
                    .fill(Color(hex: 0xE95A45))
                    .overlay(
                        RoundedRectangle(cornerRadius: w * 0.16, style: .continuous)
                            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                    )
                    .opacity(pale ? 0.85 : 1)
                /* 封套那一撇 */
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h * 0.34))
                    p.addQuadCurve(to: CGPoint(x: w, y: h * 0.34),
                                   control: CGPoint(x: w / 2, y: h * 0.62))
                }
                .stroke(Color.white.opacity(0.9), lineWidth: 1.4)
                Circle()
                    .fill(Color(hex: 0xF7C948))
                    .frame(width: w * 0.34, height: w * 0.34)
                    .offset(y: h * 0.42)
            }
        }
    }
}

/* ============================================================ 发红包 */
struct RedPacketSendView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    let chat: Chat
    var onSent: ((RedPacketInfo) -> Void)? = nil

    @State private var amountText = ""
    @State private var countText = "1"
    /// 群红包的个数只自动填一次（用户自己改过就不动他了）
    @State private var countInit = false
    @State private var note = "恭喜发财，大吉大利"
    @State private var lucky = true
    @State private var busy = false
    /* 支付步骤直接做在这一页里（微信就是这样：点「塞钱进红包」下面翻出密码键盘）。
       以前是在弹层里再弹一个支付面板，真机上会静默失败 —— 表现就是「按了没反应」。 */
    @State private var paying = false
    @State private var pwd = ""
    /// 密码错了：六格左右抖一下
    @State private var payShakeValue: CGFloat = 0
    @State private var hasPwd = true
    @State private var payTip = ""
    /// 没设过支付密码时弹「去设置」
    @State private var showSetPay = false
    @State private var errorText = ""
    @State private var myBalance: Double = 0
    /// 余额有没有从服务器拿到（没拿到就别用 0 去拦人，交给服务器判断）
    @State private var balanceLoaded = false
    /* 封面：默认用我在服务器上选的那张 */
    @State private var coverId = ""
    @State private var coverImage = ""
    @State private var coverColor = "#B3241C"
    @State private var coverName = ""
    @State private var showCoverPicker = false

    private var isGroup: Bool { chat.type == "group" }
    private var amount: Double { Double(amountText) ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: isGroup ? "发红包" : "发红包", back: { dismiss() }) {
                Text(LuckLabel.text(isLucky: lucky))
                    .font(pf(14))
                    .foregroundColor(C.subLabel)
                    .frame(height: L.navH)
                    .padding(.trailing, 16)
            }

            ScrollView {
                VStack(spacing: 0) {
                    /* 顶部：封面（微信发红包页上面就是封面，点一下能换） */
                    /* 高级版：一整张圆角封面卡（金边 + 投影 + 顶部高光），
                       金额用大号金额字体居中，底下是零钱余额和「选择封面」。 */
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        VStack(spacing: 6) {
                            Text(Tr("恭喜发财 · 大吉大利"))
                                .font(pf(12.5, .medium))
                                .foregroundColor(Color.white.opacity(0.88))
                                .tracking(1.2)
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text("¥").font(pf(24, .semibold)).foregroundColor(Color.white.opacity(0.95))
                                Text(amountText.isEmpty ? "0.00" : amountText)
                                    .font(pfMoney(46, .semibold))
                                    .foregroundColor(.white)
                                    .minimumScaleFactor(0.45)
                                    .lineLimit(1)
                                    .shadow(color: Color.black.opacity(0.22), radius: 6, y: 2)
                            }
                        }
                        Spacer(minLength: 0)
                        HStack(spacing: 6) {
                            Image(systemName: "wallet.pass.fill").font(.system(size: 10.5))
                            Text(Tr("零钱余额") + " ¥\(moneyFmt(myBalance))")
                                .font(pf(12))
                        }
                        .foregroundColor(Color.white.opacity(0.92))
                        .padding(.bottom, 16)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 186)
                    .background(
                        ZStack {
                            if coverImage.isEmpty {
                                LinearGradient(colors: [Color(hex: 0xF45A3C), Color(hex: 0xC91F14)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                            } else {
                                RPCoverView(path: coverImage, colorHex: coverColor)
                                LinearGradient(colors: [Color.black.opacity(0.10), Color.black.opacity(0.42)],
                                               startPoint: .top, endPoint: .bottom)
                            }
                            /* 左上角那一道高光：红卡看着有"皮"的质感 */
                            LinearGradient(colors: [Color.white.opacity(0.28), Color.white.opacity(0)],
                                           startPoint: .topLeading, endPoint: .center)
                        }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(LinearGradient(colors: [Color(hex: 0xF3D08A).opacity(0.95),
                                                        Color(hex: 0xB98A3C).opacity(0.75)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                lineWidth: 1.2))
                    .shadow(color: Color(hex: 0xC91F14).opacity(0.28), radius: 14, y: 8)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .contentShape(Rectangle())
                    .onTapGesture { showCoverPicker = true }
                    .overlay(alignment: .bottomTrailing) {
                        HStack(spacing: 4) {
                            Image(systemName: "rectangle.2.swap").font(.system(size: 11, weight: .semibold))
                            Text(coverName.isEmpty ? Tr("选择封面") : coverName).font(pf(12))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.black.opacity(0.30)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.6))
                        .padding(12)
                    }

                    VStack(spacing: 0) {
                        formRow(icon: "yensign.circle.fill", tint: C.green, title: Tr("金额")) {   // 2026-10-17：跟主色走
                            TextField("0.00", text: $amountText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .font(pfMoney(20, .medium))
                                .foregroundColor(C.label)
                                .frame(maxWidth: 170)
                            Text("元").font(pf(14)).foregroundColor(C.subLabel)
                        }

                        if isGroup {
                            HairLine(inset: 58)
                            formRow(icon: "person.2.fill", tint: Color(hex: 0x3D83E7), title: Tr("个数")) {
                                TextField("1", text: $countText)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .font(pfMoney(20, .medium))
                                    .foregroundColor(C.label)
                                    .frame(maxWidth: 170)
                                Text("个").font(pf(14)).foregroundColor(C.subLabel)
                            }
                        }

                        HairLine(inset: 58)
                        formRow(icon: "text.bubble.fill", tint: Color(hex: 0xF2943B), title: Tr("祝福语")) {
                            TextField("恭喜发财，大吉大利", text: $note)
                                .multilineTextAlignment(.trailing)
                                .font(pf(15))
                                .foregroundColor(C.label)
                        }
                    }
                    .background { CardGlassBox(radius: 16) }
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(C.hairline, lineWidth: 0.6))
                    .padding(.horizontal, 14)
                    .padding(.top, 14)

                    if isGroup {
                        luckyPicker
                            .padding(.horizontal, 14)
                            .padding(.top, 12)
                    }

                    Text(helpText)
                        .font(pf(12.5))
                        .foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.top, 10)

                    Button {
                        self.submit()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "envelope.fill").font(.system(size: 15, weight: .semibold))
                            Text(busy ? "正在发…" : "塞钱进红包").font(pf(17, .semibold))
                        }
                        .foregroundColor(Color(hex: 0x5A1B06))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Capsule().fill(LinearGradient(
                            colors: [Color(hex: 0xFFE49B), Color(hex: 0xF7C84E), Color(hex: 0xDFA02C)],
                            startPoint: .topLeading, endPoint: .bottomTrailing)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.55), lineWidth: 0.8))
                        .shadow(color: Color(hex: 0xDFA02C).opacity(0.45), radius: 12, y: 6)
                        .opacity(busy ? 0.6 : 1)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .disabled(busy)

                    Color.clear.frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if let me = app.me, let b = me.balance { myBalance = b; balanceLoaded = true }
            if let m = try? await API.shared.me() {
                app.me = m
                myBalance = m.balance ?? 0
                balanceLoaded = true
            }
            /* 群里发红包：个数别再默认 1 —— 个数是 1 的话，一个人就把整个红包全抢走了
               （线上真被这么反馈过）。按「除我之外每人一个」给个默认值，微信群红包也是这个习惯。 */
            if isGroup, !countInit {
                countInit = true
                var n = max(1, (chat.memberCount ?? 0) - 1)
                if let r = try? await API.shared.chatMembers(chatId: chat.id) {
                    let others = r.members.filter { $0.id != app.me?.id }.count
                    if others > 0 { n = others }
                }
                if countText == "1" { countText = String(max(1, min(100, n))) }
            }
            /* 我上次选的封面 */
            if let r = try? await API.shared.redPacketCovers() {
                let mine = r.covers.first(where: { $0.id == r.mine }) ?? r.covers.first
                if let mine = mine {
                    coverId = mine.id
                    coverImage = mine.image ?? ""
                    coverColor = mine.color ?? "#B3241C"
                    coverName = mine.name ?? ""
                }
            }
        }
        .sheet(isPresented: $showCoverPicker) {
            RedPacketCoverPicker { c in
                coverId = c.id
                coverImage = c.image ?? ""
                coverColor = c.color ?? "#B3241C"
                coverName = c.name ?? ""
            }
            .environmentObject(app)
        }
        /* 支付键盘：压在这一页上面，不是第二个弹层 */
        .overlay(alignment: .bottom) {
            if paying { payPanel }
        }
        /* 没设过支付密码：先去设一个（微信的规矩：不输密码发不出去） */
        .sheet(isPresented: $showSetPay) {
            PayPasswordView().environmentObject(app)
        }
    }

    /* ---------------------------------------------------------- 支付键盘（当前页内） */
    /* 高级版的小零件：一行表单（左边小色块图标）+ 自己画的胶囊分段 */

    private func formRow<T: View>(icon: String, tint: Color, title: String,
                                  @ViewBuilder content: () -> T) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.opacity(0.15))
                    .frame(width: 30, height: 30)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(tint)
            }
            Text(title).font(pf(16)).foregroundColor(C.label)
            Spacer(minLength: 8)
            content()
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
    }

    private var luckyPicker: some View {
        HStack(spacing: 6) {
            luckyPill(Tr("拼手气红包"), on: lucky) { lucky = true }
            luckyPill(Tr("普通红包"), on: !lucky) { lucky = false }
        }
        .padding(4)
        .background(Capsule().fill(C.label.opacity(0.06)))
        .overlay(Capsule().stroke(C.hairline, lineWidth: 0.6))
    }

    private func luckyPill(_ t: String, on: Bool, _ tap: @escaping () -> Void) -> some View {
        Button { tap() } label: {
            /* ⚠ 用户反馈「拼手气红包点不了」：
               以前选中态是 `.background { if on { 渐变胶囊 } }` —— 没选中的那颗**完全没有背景视图**，
               加上外层还有一层胶囊底 + 描边，点击经常落在那层上、传不进按钮。
               现在：两颗都用**同一个胶囊**（选中的填渐变、没选中的填空），
               再显式给 44pt 高的矩形热区，点击一定吃得到。 */
            Text(t)
                .font(pf(15, on ? .semibold : .regular))
                .foregroundColor(on ? .white : C.label)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Capsule().fill(on
                    ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0xF45A3C), Color(hex: 0xC91F14)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing))
                    : AnyShapeStyle(Color.clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var payPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Button { paying = false; pwd = ""; payTip = "" } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .semibold))
                        .foregroundColor(C.label).frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            Text(Tr("请输入支付密码"))
                .font(pf(14)).foregroundColor(C.subLabel)
            Text("¥" + moneyFmt(amount))
                .font(pfMoney(28, .medium)).foregroundColor(C.label)
                .padding(.top, 4)

            PayDotField(count: pwd.count, shake: payShakeValue, busy: busy)
                .padding(.top, 14)

            PayKeypadView(busy: busy) { tapKey($0) }
                .padding(.top, 14)

            if !payTip.isEmpty {
                Text(payTip).font(pf(13)).foregroundColor(C.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20).padding(.top, 6)
            }
            if Biometrics.available {
                Button { doSend(password: "", face: true) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "faceid").font(.system(size: 15, weight: .semibold))
                        Text(Tr("使用面容"))
                    }
                    .font(pf(15, .medium)).foregroundColor(C.green)
                    .frame(height: 38)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            Color.clear.frame(height: 8)
        }
        .frame(maxWidth: .infinity)
        .background(C.cardBg)
        .transition(.move(edge: .bottom))
    }

    private var keypad: some View {
        let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["", "0", "⌫"]]
        return VStack(spacing: 0) {
            ForEach(0..<rows.count, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { c in
                        let key = rows[r][c]
                        Button { tapKey(key) } label: {
                            Text(key)
                                .font(pf(23, .medium))
                                .foregroundColor(C.label)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(C.cardBg)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(key.isEmpty)
                    }
                }
                .overlay(Rectangle().stroke(C.hairline, lineWidth: 0.5))
            }
        }
        .padding(.horizontal, 12)
    }

    private func tapKey(_ key: String) {
        if busy { return }
        if key == "⌫" {
            if !pwd.isEmpty { pwd.removeLast() }
            payTip = ""
            return
        }
        guard !key.isEmpty, pwd.count < 6 else { return }
        pwd.append(key)
        payTip = ""
        if pwd.count == 6 { doSend(password: pwd, face: false) }
    }

    private var helpText: String {
        if !isGroup { return "单聊红包只能发 1 个；对方点开就进他的零钱。" }
        /* 个数 1 的时候说清楚：这不是「群里一起抢」，是一个人全拿走 */
        if (Int(countText) ?? 1) <= 1 {
            return "⚠️ 个数填 1 = 群里只有一个人能抢，而且整个红包都归他。想让大家都抢到，把个数改成人数。"
        }
        return lucky
            ? "拼手气红包：总金额随机分给每个人，谁抢多少看运气。24 小时没抢完，剩下的自动退回。"
            : "普通红包：每个人抢到的金额一样。24 小时没抢完，剩下的自动退回。"
    }

    private func submit() {
        errorText = ""
        guard amount > 0 else { app.show("先填金额"); return }
        if isGroup {
            let n = Int(countText) ?? 0
            guard n >= 1 && n <= 100 else { app.show("个数填 1~100"); return }
            if amount < Double(n) * 0.01 { app.show("每个红包最少 0.01 元"); return }
            if !lucky {
                let each = (amount / Double(n) * 100).rounded() / 100
                if abs(each * Double(n) - amount) > 0.005 {
                    app.show("普通红包要能平分：\(n) 个 × \(moneyFmt(each)) 元")
                    return
                }
            }
        }
        if balanceLoaded && amount > myBalance {
            app.show("零钱不够：这个红包要 ¥\(moneyFmt(amount))，你只有 ¥\(moneyFmt(myBalance))。去「我 → 服务 → 钱包 → 零钱 → 充值」")
            return
        }
        /* 走到这里说明参数都对：把密码键盘翻出来（没设支付密码就直接发） */
        Task { @MainActor in
            hasPwd = await API.shared.hasPayPassword()
            if hasPwd {
                pwd = ""
                payTip = ""
                withAnimation(.easeOut(duration: 0.2)) { paying = true }
            } else {
                /* 没设过支付密码：先去设。以前这里直接就把红包发出去了 ——
                   用户反馈的「别人发红包怎么不用输密码」就是这条路。 */
                showSetPay = true
            }
        }
    }

    private func doSend(password: String, face: Bool) {
        if busy { return }
        busy = true
        payTip = ""
        let n = isGroup ? max(1, min(100, Int(countText) ?? 1)) : 1
        Task { @MainActor in
            do {
                let r = try await API.shared.sendRedPacket(
                    chatId: chat.id, amount: amount, count: n,
                    type: (isGroup && lucky) ? "lucky" : "normal",
                    note: note.isEmpty ? "恭喜发财，大吉大利" : note,
                    password: password, face: face, coverId: coverId)
                myBalance = r.balance
                if var me = app.me { me.balance = r.balance; app.me = me }
                busy = false
                paying = false
                app.show(Tr("红包已发出"))
                onSent?(RedPacketInfo(raw: r.redpacket))
                dismiss()
            } catch {
                busy = false
                pwd = ""
                payTip = (error as? LocalizedError)?.errorDescription ?? "发红包失败，再试一次"
                payShake($payShakeValue)      // 密码不对 / 发失败：格子抖一下 + 错误震动
            }
        }
    }
}

enum LuckLabel {
    static func text(isLucky: Bool) -> String { isLucky ? "拼手气红包" : "普通红包" }
}

/* ============================================================ 支付密码（发红包前确认） */
struct PayPasswordSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    let amount: Double
    var purpose: String = "支付"
    /// 真正付钱的动作（抛错就是失败）
    let pay: (String, Bool) async throws -> RedPacketInfo
    let onDone: (RedPacketInfo) -> Void

    @State private var password = ""
    @State private var hasPwd = true
    @State private var faceOK = false
    @State private var busy = false
    @State private var tip = ""
    /// 密码错了：六格左右抖一下
    @State private var shake: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(C.label)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }

            Text(purpose)
                .font(pf(15))
                .foregroundColor(C.subLabel)
            Text("¥\(moneyFmt(amount))")
                .font(pfMoney(32, .medium))
                .foregroundColor(C.label)
                .padding(.top, 6)

            if hasPwd {
                /* 6 个格子 + 自带数字键盘：
                   以前用「藏起来的输入框 + 系统键盘」，在真机上经常不弹键盘，
                   表现就是「塞钱进红包」按了没反应 —— 现在不依赖系统键盘。 */
                PayDotField(count: password.count, shake: shake, busy: busy)
                    .padding(.top, 16)

                PayKeypadView(busy: busy) { tap($0) }
                    .padding(.top, 16)
            } else {
                /* 没设过支付密码：微信不会让你「直接付」，先去设一个再说 */
                VStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 22))
                        .foregroundColor(C.green)
                    Text("还没设置支付密码")
                        .font(pf(16, .medium))
                        .foregroundColor(C.label)
                    Text("为了安全，发红包 / 转账 / 付款都要先设一个 6 位支付密码\n（我 → 设置 → 账号与安全 → 支付密码）")
                        .font(pf(13.5))
                        .foregroundColor(C.subLabel)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 26)
                .padding(.top, 22)
            }

            if !tip.isEmpty {
                Text(tip).font(pf(13)).foregroundColor(C.red).padding(.top, 10)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            if faceOK {
                Button { run(face: true) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "faceid").font(.system(size: 15, weight: .semibold))
                        Text("使用面容")
                    }
                    .font(pf(15, .medium))
                    .foregroundColor(C.green)
                    .frame(height: 40)
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }

            Spacer(minLength: 0)
        }
        /* 付钱时盖一层「正在支付」：按钮文字不动，就不会跳（用户反馈的「三个点的跳转」） */
        .overlay {
            if busy { PayBusyOverlay() }
        }
        .animation(.easeOut(duration: 0.15), value: busy)
        .background(C.pageBg.ignoresSafeArea())
        .presentationDetents([.height(hasPwd ? 452 : 300)])
        .task {
            hasPwd = await API.shared.hasPayPassword()
            faceOK = Biometrics.available
        }
    }

    /// 自带数字键盘（1~9 / 0 / 删除），输满 6 位自动付
    private var keypad: some View {
        let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["", "0", "⌫"]]
        return VStack(spacing: 0) {
            ForEach(0..<rows.count, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { c in
                        let key = rows[r][c]
                        Button {
                            tap(key)
                        } label: {
                            Text(key)
                                .font(pf(24, .medium))
                                .foregroundColor(C.label)
                                .frame(maxWidth: .infinity)
                                .frame(height: 54)
                                .background(C.cardBg)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(key.isEmpty)
                    }
                }
                .overlay(Rectangle().stroke(C.hairline, lineWidth: 0.5))
            }
        }
        .padding(.horizontal, 12)
    }

    private func tap(_ key: String) {
        if busy { return }
        if key == "⌫" {
            if !password.isEmpty { password.removeLast() }
            tip = ""
            return
        }
        guard !key.isEmpty, password.count < 6 else { return }
        password.append(key)
        tip = ""
        if password.count == 6 { run(face: false) }
    }

    private func run(face: Bool) {
        if !face && hasPwd && password.count < 6 { return }
        busy = true
        tip = ""
        Task { @MainActor in
            do {
                let info = try await pay(password, face)
                busy = false
                onDone(info)
            } catch {
                busy = false
                password = ""
                tip = (error as? LocalizedError)?.errorDescription ?? "支付失败，再试一次"
                payShake($shake)          // 密码不对 / 付失败：格子抖一下 + 错误震动
            }
        }
    }
}

/* ============================================================ 拆红包 */
struct RedPacketOpenView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    let info: RedPacketInfo
    let myId: String
    var onSeeDetail: ((String) -> Void)? = nil

    @State private var opened = false
    @State private var amount: Double = 0
    @State private var busy = false
    @State private var tip = ""
    @State private var spin = false

    var body: some View {
        ZStack {
            if info.cover.isEmpty {
                LinearGradient(colors: [Color(hex: 0xE4553C), Color(hex: 0xB8381F)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            } else {
                ZStack {
                    RPCoverView(path: info.cover, colorHex: info.coverColor)
                    LinearGradient(colors: [Color.black.opacity(0.18), Color.black.opacity(0.5)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)

                VStack(spacing: 8) {
                    Text(info.fromName.isEmpty ? "好友" : info.fromName)
                        .font(pf(17, .medium))
                        .foregroundColor(Color(hex: 0xF7DFA0))
                    Text("给你发了一个\(info.isLucky ? "拼手气" : "")红包")
                        .font(pf(14))
                        .foregroundColor(Color(hex: 0xF7DFA0).opacity(0.85))
                }

                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [Color(hex: 0xFFE9B0), Color(hex: 0xE9B84C)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 116, height: 116)
                    Circle()
                        .stroke(Color(hex: 0xFFF3CF).opacity(0.7), lineWidth: 2)
                        .frame(width: 132, height: 132)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                    if opened {
                        Text("¥\(moneyFmt(amount))")
                            .font(pfMoney(30, .medium))
                            .foregroundColor(Color(hex: 0x8A3A12))
                    } else {
                        Button { open() } label: {
                            Text(busy ? "…" : "开")
                                .font(pf(30, .semibold))
                                .foregroundColor(Color(hex: 0x8A3A12))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 34)
                .onAppear {
                    withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { spin = true }
                }

                if opened {
                    VStack(spacing: 6) {
                        Text("已存入零钱")
                            .font(pf(13))
                            .foregroundColor(Color(hex: 0xF7DFA0).opacity(0.9))
                        Button {
                            dismiss()
                            onSeeDetail?(info.id)
                        } label: {
                            Text("看看大家的手气")
                                .font(pf(15, .medium))
                                .foregroundColor(Color(hex: 0x8A3A12))
                                .padding(.horizontal, 22)
                                .frame(height: 40)
                                .background(Capsule().fill(Color(hex: 0xF7DFA0)))
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 10)
                    }
                    .padding(.top, 24)
                } else if !tip.isEmpty {
                    Text(tip).font(pf(13.5)).foregroundColor(Color(hex: 0xF7DFA0)).padding(.top, 20)
                }

                Spacer(minLength: 0)
            }
        }
    }

    private func open() {
        if busy { return }
        busy = true
        tip = ""
        Task {
            do {
                let r = try await API.shared.claimRedPacket(id: info.id)
                amount = r.amount
                if var me = app.me { me.balance = r.balance; app.me = me }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { opened = true }
            } catch {
                tip = (error as? LocalizedError)?.errorDescription ?? "没抢到，看看详情"
            }
            busy = false
        }
    }
}

/* ============================================================ 红包详情 */
struct RedPacketDetailView: View {
    @ObservedObject private var lang = LangStore.shared
    @Environment(\.dismiss) private var dismiss

    let id: String
    let myId: String

    @State private var raw: API.RedPacketRaw?
    @State private var loading = true

    private var info: RedPacketInfo? { raw.map { RedPacketInfo(raw: $0) } }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "红包详情", back: { dismiss() })
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    if let info = info {
                        heroCard(info)
                        if let mine = raw?.claims?.first(where: { $0.userId == myId }) {
                            mineCard(mine, info: info)
                        }
                        claimsCard(info)
                        Text(footHint(info))
                            .font(pf(12))
                            .foregroundColor(C.subLabel)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 20)
                            .padding(.top, 2)
                    } else if loading {
                        ProgressView().padding(.top, 60)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "tray")
                                .font(.system(size: 34))
                                .foregroundColor(C.subLabel)
                            Text("红包不存在或者已经删了")
                                .font(pf(14))
                                .foregroundColor(C.subLabel)
                        }
                        .padding(.top, 60)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 26)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task {
            raw = try? await API.shared.redPacketDetail(id: id)
            loading = false
        }
    }

    private var gold: Color { Color(hex: 0xE2A03C) }
    private var goldDeep: Color { Color(hex: 0xC8830C) }

    /* 顶部：深红金渐变头卡（谁发的 + 祝福语 + 共几个/已领几个） */
    private func heroCard(_ info: RedPacketInfo) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "envelope.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(gold)
                Text(Tr("红包")).font(pf(13, .semibold)).foregroundColor(.white.opacity(0.9))
                Spacer(minLength: 0)
                Text(info.isLucky ? Tr("拼手气红包") : Tr("普通红包"))
                    .font(pf(11.5))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(Color.white.opacity(0.16)))
            }
            RPAvatar(path: raw?.fromAvatar ?? "", size: 54)
                .overlay(Circle().stroke(gold.opacity(0.9), lineWidth: 1.5))
                .shadow(color: Color.black.opacity(0.35), radius: 8, y: 3)
                .padding(.top, 2)
            Text(info.fromName.isEmpty ? Tr("好友") : info.fromName)
                .font(pf(17, .semibold))
                .foregroundColor(.white)
            Text(info.note.isEmpty ? Tr("恭喜发财，大吉大利") : info.note)
                .font(pf(13.5))
                .foregroundColor(.white.opacity(0.82))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 18)
            Text(summaryLine(info))
                .font(pf(12.5))
                .foregroundColor(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
        .background(
            ZStack {
                LinearGradient(colors: [Color(hex: 0xB3261A), Color(hex: 0xD8442C), Color(hex: 0x8E1B12)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [gold.opacity(0.28), Color.clear],
                               center: .topTrailing, startRadius: 2, endRadius: 230)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    /* 我抢到的：金色大数字 + 手气最佳 */
    private func mineCard(_ mine: API.RedPacketClaimRaw, info: RedPacketInfo) -> some View {
        let best = (raw?.bestUserId == myId) && ((raw?.claims?.count ?? 0) > 1)
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(gold.opacity(0.14)).frame(width: 44, height: 44)
                QQGlyph(kind: .crown, size: 21)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(Tr("我抢到的")).font(pf(12.5)).foregroundColor(C.subLabel)
                Text("¥" + moneyFmt(mine.amount))
                    .font(.system(size: 25, weight: .heavy, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [gold, goldDeep],
                                                    startPoint: .top, endPoint: .bottom))
            }
            Spacer(minLength: 0)
            if best {
                Text(Tr("手气最佳"))
                    .font(pf(11.5, .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(LinearGradient(colors: [Color(hex: 0xF0C24B), goldDeep],
                                                              startPoint: .top, endPoint: .bottom)))
            }
        }
        .padding(14)
        .background { CardGlassBox(radius: 14) }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(gold.opacity(0.35), lineWidth: 1)
        )
    }

    /* 领取记录：头像 + 名字 + 时间 + 金额（金额右对齐） */
    private func claimsCard(_ info: RedPacketInfo) -> some View {
        let list = raw?.claims ?? []
        let total = max(1, info.count)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(Tr("领取记录")).font(pf(14.5, .semibold)).foregroundColor(C.label)
                Text("\(list.count)/\(total)")
                    .font(pf(12))
                    .foregroundColor(C.subLabel)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if list.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "hourglass")
                        .font(.system(size: 22))
                        .foregroundColor(C.subLabel)
                    Text(Tr("还没有人抢到这个红包"))
                        .font(pf(13))
                        .foregroundColor(C.subLabel)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
            } else {
                ForEach(Array(list.enumerated()), id: \.offset) { idx, c in
                    if idx > 0 { HairLine(inset: 62) }
                    HStack(spacing: 12) {
                        RPAvatar(path: c.avatar ?? "", size: 36)
                            .overlay(Circle().stroke(Color.black.opacity(0.04), lineWidth: 0.5))
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(c.name ?? Tr("好友"))
                                    .font(pf(15))
                                    .foregroundColor(C.label)
                                    .lineLimit(1)
                                if let best = raw?.bestUserId, best == c.userId, list.count > 1 {
                                    HStack(spacing: 3) {
                                        QQGlyph(kind: .crown, size: 10)
                                        Text(Tr("手气最佳")).font(pf(10.5, .medium)).foregroundColor(.white)
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(gold))
                                }
                                if c.userId == myId {
                                    Text(Tr("我"))
                                        .font(pf(10.5, .medium))
                                        .foregroundColor(C.green)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(C.green.opacity(0.13)))
                                }
                            }
                            Text(rpTime(c.at ?? ""))
                                .font(pf(12))
                                .foregroundColor(C.subLabel)
                        }
                        Spacer(minLength: 8)
                        Text("¥" + moneyFmt(c.amount))
                            .font(pfMoney(15.5))
                            .foregroundColor(raw?.bestUserId == c.userId ? goldDeep : C.label)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 58)
                }
            }
        }
        .background { CardGlassBox(radius: 14) }
    }

    private func summaryLine(_ info: RedPacketInfo) -> String {
        let claimed = raw?.claimedCount ?? info.claimedCount
        if info.expired {
            return "共 \(info.count) 个，已领 \(claimed) 个 · 红包已过期"
        }
        if info.isOver {
            return "共 \(info.count) 个，\(info.count) 个已被领完"
        }
        return "共 \(info.count) 个，已领 \(claimed) 个"
    }

    private func footHint(_ info: RedPacketInfo) -> String {
        if info.expired && info.refundAmount > 0 {
            return "24 小时到了，没被抢走的 ¥\(moneyFmt(info.refundAmount)) 已经退回给发红包的人"
        }
        if info.stillOpen {
            return "还有 \(raw?.leftCount ?? 0) 个没被领 · 未领完的钱 24 小时后自动退回"
        }
        return "红包里的钱已经全部领走了"
    }
}

/* ============================================================ 通用：小头像（不要叫 AsyncImage，会盖住系统那个） */
struct RPAvatar: View {
    let path: String
    let size: CGFloat

    var body: some View {
        Group {
            if !path.isEmpty, let url = API.shared.assetURL(path) {
                AsyncImageLoad(url: url)
            } else {
                Circle().fill(Color(hex: 0xE2A03C)).overlay(
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.45))
                        .foregroundColor(.white)
                )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct AsyncImageLoad: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(C.hairline)
            }
        }
        .task {
            if let data = try? await API.shared.assetData(url) { image = UIImage(data: data) }
        }
    }
}

/* 时间：2026-09-23T06:12:33.123Z → 09-23 06:12 */
func rpTime(_ raw: String) -> String {
    let s = raw.replacingOccurrences(of: "T", with: " ")
    guard s.count >= 16 else { return s }
    let a = s.index(s.startIndex, offsetBy: 5)
    let b = s.index(s.startIndex, offsetBy: 16)
    return String(s[a..<b])
}
