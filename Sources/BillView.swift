import SwiftUI
import UIKit

/// 转账单（从聊天里那条转账消息的 JSON 解析出来）
struct TransferInfo {
    var id = ""
    var amount: Double = 0
    var note = ""
    var status = "pending"
    var method = "balance"
    var fromId = ""
    var toId = ""
    var createdAt = ""
    var expiresAt: Double = 0
    var receivedAt = ""
    var refundedAt = ""
    var refundedBy = ""

    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        id = (o["id"] as? String) ?? ""
        amount = (o["amount"] as? Double) ?? 0
        note = (o["note"] as? String) ?? ""
        status = (o["status"] as? String) ?? "pending"
        method = (o["method"] as? String) ?? "balance"
        fromId = (o["fromId"] as? String) ?? ""
        toId = (o["toId"] as? String) ?? ""
        createdAt = (o["createdAt"] as? String) ?? ""
        if let e = o["expiresAt"] as? Double { expiresAt = e }
        else if let e = o["expiresAt"] as? Int { expiresAt = Double(e) }
        receivedAt = (o["receivedAt"] as? String) ?? ""
        refundedAt = (o["refundedAt"] as? String) ?? ""
        refundedBy = (o["refundedBy"] as? String) ?? ""
    }

    var methodName: String { method == "card" ? "建设银行储蓄卡(2125)" : "零钱" }

    /// 收款后**5 小时内**才能退还（用户规则）：超过 5 小时就不再给「退还」按钮了。
    /// 注意这和「24 小时没收自动退回」不是一回事 —— 那个是**还没收**的情况。
    var refundClosed: Bool {
        guard !receivedAt.isEmpty, let d = TimeFmt.date(receivedAt) else { return false }
        return Date().timeIntervalSince(d) > 5 * 60 * 60
    }

    func statusText(mine: Bool) -> String {
        if status == "pending" { return mine ? "等待对方确认收钱" : "等待你确认收钱" }
        if status == "received" { return "已收款" }
        /* 退回：收款方自己点「退还」的，和 24 小时自动退回，文案不一样 */
        if !refundedBy.isEmpty, refundedBy == toId { return mine ? "已退还" : "对方已退还" }
        return "已退回"
    }

    /// 还剩多久自动退回（网页版 leftText）
    var leftText: String {
        let ms = expiresAt - Date().timeIntervalSince1970 * 1000
        if !(ms > 0) { return "已到期" }
        let h = Int(ms / 3_600_000)
        let m = Int((ms.truncatingRemainder(dividingBy: 3_600_000)) / 60_000)
        if h >= 24 { return "1天内" }
        if h >= 1 { return "\(h)小时" + (m > 0 ? "\(m)分" : "") }
        return "\(m)分钟"
    }

    /// 参考图的单号格式：1000050001 + 年月日时分秒 + 单号
    var billNo: String {
        let d = TimeFmt.date(createdAt)
        var stamp = "00000000000000"
        if let d = d {
            let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
            func p(_ v: Int?) -> String { String(format: "%02d", v ?? 0) }
            stamp = "\(c.year ?? 0)" + p(c.month) + p(c.day) + p(c.hour) + p(c.minute) + p(c.second)
        }
        return "1000050001" + stamp + id.replacingOccurrences(of: "tr_", with: "").uppercased()
    }
}

/* ============================================================
   账单详情（照网页版 bl-screen）：
   头像 + 转账-转给XX + -¥金额 + 当前状态/说明/时间/方式/单号 + 账单服务
   ============================================================ */

struct BillDetailView: View {
    let chat: Chat
    let info: TransferInfo

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var live: TransferInfo?
    @State private var showMore = false
    @State private var showReceipt = false
    @State private var askRefund = false
    @State private var showKefu = false
    /// 正在收款 / 退还：点了先锁住，免得连点两次（异常路径也会复位）
    @State private var busy = false

    private var mine: Bool { info.fromId == (app.me?.id ?? "") }
    private var who: String { mine ? chat.name : (chat.lastMessage?.senderName ?? chat.name) }
    private var t: TransferInfo { live ?? info }
    /// 这一页顶上那颗头像用对方的（微信转账详情就是对方头像）
    private var peerAvatar: String { chat.avatar ?? "" }

    /* 参考图（微信转账详情）量出来的文字：标题 17 / 金额数字 50、¥ 35 / 提示·明细 15 */
    private var faint: Color { Color.dyn(0x737373, 0x9A9A9A) }

    private var titleText: String {
        if t.status == "pending" { return mine ? "待\(who)收款" : "\(who)向你转账" }
        if t.status == "received" { return mine ? "对方已收款" : "已收款" }
        return mine ? "已退回你的余额" : "已退回对方"
    }

    private var hintText: String {
        if t.status == "pending" {
            /* leftText 在满 24 小时时返回的是「1天内」，已经带「内」了，别再加一个 */
            let left = t.leftText.hasSuffix("内") ? String(t.leftText.dropLast()) : t.leftText
            return mine ? "\(left)内对方未收款，将退还给你。" : "\(left)内未收款，将退还对方。"
        }
        if t.status == "received" { return "钱已存入" + (mine ? "对方" : "你的") + "零钱余额。" }
        return "超过 24 小时未收款，钱已原路退回。"
    }

    var body: some View {
        VStack(spacing: 0) {
            /* 顶栏：和参考图一样，右边是「···」（菜单里放账单服务） */
            NavBar(title: "", back: { dismiss() }) {
                Button {
                    showMore = true
                } label: {
                    WeChatDots(size: 4.6, gap: 3.2)
                        .frame(width: 60, height: L.navH)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                VStack(spacing: 0) {
                    /* 对方头像（微信这一页上面就是对方的头像，不是抽象图标） */
                    Avatar(path: peerAvatar, size: 56, radius: 8)
                        .padding(.top, 40)

                    /* 「转账给 XX」/「XX 转账给你」 */
                    Text(mine ? "转账给 \(who)" : "\(who) 转账给你")
                        .font(pfExact(15))
                        .foregroundColor(faint)
                        .padding(.top, 14)

                    /* 金额 */
                    MoneyLabel(text: "¥" + money(t.amount), size: 50, curSize: 34,
                               topAlign: true, color: C.label, exact: true)
                        .padding(.top, 10)

                    /* 状态：待对方确认收款 / 已收款 / 已退回 */
                    Text(t.statusText(mine: mine))
                        .font(pfExact(16))
                        .foregroundColor(C.label)
                        .padding(.top, 14)

                    /* 提示语（微信也是灰字一行） */
                    Text(hintText)
                        .font(pfExact(14))
                        .foregroundColor(faint)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 34)
                        .padding(.top, 8)

                    /* 发钱方：微信这儿是「提醒对方收款」这种链接，不是一整颗大按钮 */
                    if t.status == "pending", mine {
                        Button { billAction() } label: {
                            Text(Tr("提醒对方收款"))
                                .font(pfExact(14.5))
                                .foregroundColor(C.link)
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                        .padding(.top, 12)
                    }

                    /* 明细：参考图是先一条细线，再一行行 15pt 的「左灰右黑」 */
                    Rectangle()
                        .fill(C.hairline)
                        .frame(height: 0.5)
                        .padding(.horizontal, 32)
                        .padding(.top, 31)

                    detailRow("转账时间", TimeFmt.bill(t.createdAt))
                    if !t.note.isEmpty { detailRow("转账说明", t.note) }
                    detailRow("支付方式", t.methodName)
                    detailRow("转账单号", t.billNo)
                    if t.status == "received" { detailRow("收款时间", TimeFmt.bill(t.receivedAt)) }
                    if t.status == "refunded" { detailRow("退回时间", TimeFmt.bill(t.refundedAt)) }

                    Spacer(minLength: 40)
                }
            }
            .background(C.cardBg)

            /* 收钱方：微信是**底部固定**一整颗绿色「确认收款」——不跟着内容滚走 */
            if t.status == "pending", !mine {
                VStack(spacing: 0) {
                    Rectangle().fill(C.hairline).frame(height: 0.5)
                    Button { billAction() } label: {
                        Text(Tr("确认收款"))
                            .font(pf(17, .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(C.green))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                }
                .background(C.cardBg)
            }

            /* 收钱方、已经收到钱之后：微信底下是一颗「退还」——
               点了把钱原路退回给对方（和 24 小时自动退回不是一回事）。
               ⚠ 用户规则：**收款后 5 小时内才能退**，超过 5 小时就不给退了，改显示一行灰字。 */
            if t.status == "received", !mine, t.refundClosed {
                VStack(spacing: 0) {
                    Rectangle().fill(C.hairline).frame(height: 0.5)
                    Text(Tr("收款超过 5 小时，不能再退回了"))
                        .font(pf(13.5))
                        .foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .background(C.cardBg)
            }
            if t.status == "received", !mine, !t.refundClosed {
                VStack(spacing: 0) {
                    Rectangle().fill(C.hairline).frame(height: 0.5)
                    Button { askRefund = true } label: {
                        Text(Tr("退还"))
                            .font(pf(16.5, .medium))
                            .foregroundColor(C.label)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background { CardGlassBox(radius: 6) }
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(C.hairline, lineWidth: 0.9))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                }
                .background(C.cardBg)
            }

            /* 最下面那颗「账单详情」（参考图在最底下、链接色） */
            Button {
                showReceipt = true
            } label: {
                Text(Tr("账单详情"))
                    .font(pfExact(14.5))
                    .foregroundColor(C.link)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 18)
            .background(C.cardBg)
        }
        .background(C.cardBg.ignoresSafeArea(edges: .bottom))
        .background(C.cardBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        /* 进这一页先按单号把状态拉一次：别人已经收了 / 24 小时退回了，
           这一页还显示着「确认收款」的话，点了当然没反应。 */
        .task { await refreshTransfer() }
        /* 账单详情（微信支付那种「交易详情」页）：从最底下那个链接点进来 */
        .sheet(isPresented: $showReceipt) {
            BillReceiptView(chat: chat, info: t)
        }
        /* 对订单有疑问 → 真的进在线客服（微信也是转到客服），不再只弹一句提示 */
        .sheet(isPresented: $showKefu) {
            KefuPage().environmentObject(app)
        }
        /* 退还：微信会先问一句「退还 ¥x 给对方？」 */
        .confirmationDialog("退还 ¥" + money(t.amount) + " 给" + who + "？",
                            isPresented: $askRefund, titleVisibility: .visible) {
            Button(Tr("退还"), role: .destructive) { doRefund() }
            Button(Tr("取消"), role: .cancel) { }
        } message: {
            Text(Tr("退还后这笔钱会原路退回到对方零钱，你和对方的转账卡片都会变成「已退还」。"))
        }
        .confirmationDialog(Tr("账单详情"), isPresented: $showMore, titleVisibility: .visible) {
            Button(Tr("刷新状态")) {
                Task {
                    if let list = try? await API.shared.messages(chatId: chat.id, limit: 30),
                       let msg = list.messages.last(where: { $0.kindName == "transfer" }),
                       let updated = TransferInfo(json: msg.body) {
                        live = updated
                    }
                    app.show(Tr("已经是最新状态"))
                }
            }
            Button(Tr("对订单有疑惑")) {
                showKefu = true
            }
            Button(Tr("定位到聊天位置")) { dismiss() }
            Button(Tr("取消"), role: .cancel) { }
        }
    }

    /// 明细行：左灰右黑，参考图里一行 49 高、左右各留 32
    private func detailRow(_ k: String, _ v: String) -> some View {
        HStack(spacing: 12) {
            Text(k)
                .font(pfExact(14.5))
                .foregroundColor(faint)
            Spacer(minLength: 0)
            Text(v)
                .font(pfExact(14.5))
                .foregroundColor(C.label)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 32)
        .frame(height: 49)
    }

    /// 退还：把钱原路退给付款方（服务端从我的零钱/经营账户扣，加回对方余额）
    private func doRefund() {
        Task {
            if let err = await API.shared.refundTransfer(t.id) {
                app.show(err)
                return
            }
            /* 退还成功：这一页立刻刷成最新状态，余额也跟着刷 */
            if let list = try? await API.shared.messages(chatId: chat.id, limit: 30),
               let msg = list.messages.last(where: { $0.kindName == "transfer" }),
               let updated = TransferInfo(json: msg.body) {
                live = updated
            }
            app.me = try? await API.shared.me()
            app.show(Tr("已退还"))
        }
    }

    private func billAction() {
        if mine {
            /* 真发提醒：服务端会把「XX 提醒你确认收款」推给对方手机（1 分钟只能提醒一次）。
               以前这里只在自己这边弹一句假的「已提醒对方收款」—— 用户一下就发现是摆设。 */
            guard !busy else { return }
            busy = true
            Task {
                let err = await API.shared.remindTransfer(t.id)
                busy = false
                app.show(err ?? Tr("已提醒对方收款"))
            }
            return
        }
        guard !busy else { return }
        busy = true
        Task {
            /* 收款：成功 → 刷新成「已收款」；失败 → **把原因弹出来**（过期 / 不是给你的 / 已经收过了…）。
               以前这里没有错误分支，服务端拒绝时页面上什么都不变，用户看到的就是「点了没反应」。 */
            let err = await API.shared.claimTransfer(t.id)
            await refreshTransfer()
            app.me = try? await API.shared.me()
            busy = false
            app.show(err ?? Tr("已收款"))
        }
    }

    /// 按单号把这一页的转账拉成最新的（收/退/过期以后状态才对得上）
    private func refreshTransfer() async {
        guard let list = try? await API.shared.messages(chatId: chat.id, limit: 50) else { return }
        let hit = list.messages
            .filter { $0.kindName == "transfer" }
            .compactMap { TransferInfo(json: $0.body) }
            .first { $0.id == info.id }
        if let hit { live = hit }
    }
}

/* ============================================================
   转账详情页顶上那个大图标。
   参考图里是：50pt 的蓝色实心圆（#10AEFF）+ 一笔白色的折线。
   白色那笔是照着参考图逐像素量出来的（不是字体渲染的）：
   竖笔在圆心偏左 0.35pt，从圆顶往下 10pt 处起笔，到 23.6pt 处折向右下 33°，
   笔宽 5.4pt、两头圆头。
   ============================================================ */
struct TransferDetailIcon: View {
    var size: CGFloat = 50

    var body: some View {
        let s = size / 50
        ZStack {
            Circle().fill(Color(hex: 0x10AEFF))
            Path { p in
                p.move(to: CGPoint(x: 25.35 * s, y: 12.7 * s))
                p.addLine(to: CGPoint(x: 25.35 * s, y: 23.6 * s))
                p.addLine(to: CGPoint(x: 31.7 * s, y: 33.4 * s))
            }
            .stroke(Color.white, style: StrokeStyle(lineWidth: 5.4 * s,
                                                    lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
    }
}

/* ============================================================
   账单详情 —— 微信支付那种「交易详情」页

   入口：转账详情页最底下那个「账单详情」。
   以前那颗按钮只是弹一个系统小菜单（用户反馈「打不开」），
   现在按微信做成一个真正的页面：
     交易状态 + 大字金额
     明细卡：转账说明 / 收款方 / 转账时间 / 支付方式 / 交易单号 / 商户单号
     底部：对订单有疑问
   ============================================================ */

struct BillReceiptView: View {
    let chat: Chat
    let info: TransferInfo

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showKefu = false

    private var mine: Bool { info.fromId == (app.me?.id ?? "") }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("账单详情"), back: { dismiss() })

            ScrollView {
                VStack(spacing: 0) {
                    Text(info.statusText(mine: mine))
                        .font(pfExact(17))
                        .foregroundColor(C.label)
                        .padding(.top, 26)

                    MoneyLabel(text: "¥" + money(info.amount), size: 40, curSize: 27,
                               topAlign: true, color: C.label, exact: true)
                        .padding(.top, 8)

                    VStack(spacing: 0) {
                        row(Tr("转账说明"), info.note.isEmpty ? "—" : info.note)
                        HairLine(inset: 16)
                        row(mine ? Tr("收款方") : Tr("付款方"), chat.name)
                        HairLine(inset: 16)
                        row(Tr("转账时间"), TimeFmt.bill(info.createdAt))
                        HairLine(inset: 16)
                        row(Tr("支付方式"), info.methodName)
                        HairLine(inset: 16)
                        row(Tr("交易单号"), info.billNo)
                            /* 点一下复制单号：找客服的时候直接粘过去（微信也是给单号） */
                            .contentShape(Rectangle())
                            .onTapGesture {
                                UIPasteboard.general.string = info.billNo
                                app.show(Tr("单号已复制，粘给客服就行"))
                            }
                        HairLine(inset: 16)
                        row(Tr("商户单号"), "1000" + String(info.billNo.suffix(16)))
                        if info.status == "received" {
                            HairLine(inset: 16)
                            row(Tr("收款时间"), TimeFmt.bill(info.receivedAt))
                        }
                        if info.status == "refunded" {
                            HairLine(inset: 16)
                            row(Tr("退回时间"), TimeFmt.bill(info.refundedAt))
                        }
                    }
                    .background(C.cardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.top, 24)

                    Button {
                        showKefu = true
                    } label: {
                        Text(Tr("对订单有疑问"))
                            .font(pf(15.5))
                            .foregroundColor(C.link)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background { CardGlassBox(radius: 10) }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        /* 真进客服页（微信里也是转到客服），带上这一笔的上下文 */
        .sheet(isPresented: $showKefu) {
            KefuPage().environmentObject(app)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(spacing: 14) {
            Text(k).font(pfExact(14.5)).foregroundColor(C.subLabel)
            Spacer(minLength: 8)
            Text(v).font(pfExact(14.5)).foregroundColor(C.label)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
    }
}
