import SwiftUI

/* ============================================================
   零钱：充值 / 提现（照微信那一套）
   · 充值：银行卡 → 零钱。大号金额 + 快捷金额 + 到账银行卡 + 绿色「充值」
   · 提现：零钱 → 银行卡。可提现余额 + 全部提现 + 手续费（0.1%，最低 0.1）+ 支付密码
   · 银行卡只存「银行名 + 末四位」
   ============================================================ */

struct RechargeView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var amountText = ""
    @State private var banks: [API.WalletBankCard] = []
    @State private var bankId = ""
    @State private var busy = false
    @State private var showAddBank = false
    @State private var showPay = false
    @State private var done = false

    private var amount: Double { Double(amountText) ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("充值"), back: { dismiss() })

            ScrollView {
                VStack(spacing: 0) {
                    Text(Tr("充值金额"))
                        .font(pf(13)).foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.top, 18)

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("¥").font(pfMoney(28))
                        TextField("0.00", text: $amountText)
                            .font(pfMoney(44))
                            .keyboardType(.decimalPad)
                            .foregroundColor(C.label)
                    }
                    .padding(.horizontal, 20)
                    .frame(height: 66)

                    /* 快捷金额（微信也有这几个档） */
                    HStack(spacing: 10) {
                        ForEach([50, 100, 200, 500], id: \.self) { v in
                            Button {
                                amountText = "\(v)"
                            } label: {
                                Text("¥\(v)")
                                    .font(pf(15, .medium))
                                    .foregroundColor(amount == Double(v) ? .white : C.label)
                                    .frame(maxWidth: .infinity).frame(height: 40)
                                    .background(RoundedRectangle(cornerRadius: 7)
                                        .fill(amount == Double(v) ? C.green : C.cardBg))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)

                    Spacer().frame(height: 18)

                    GroupCard {
                        Button {
                            if banks.isEmpty { showAddBank = true }
                        } label: {
                            HStack(spacing: 12) {
                                Text(Tr("到账银行卡")).font(pf(16)).foregroundColor(C.label)
                                Spacer(minLength: 8)
                                Text(bankLabel).font(pf(15)).foregroundColor(C.subLabel).lineLimit(1)
                                Chevron(size: 9, line: 1.6).padding(.trailing, 3)
                            }
                            .padding(.horizontal, 16).frame(height: 54)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    Text(Tr("充值是从银行卡转入零钱（本 App 内记账），到账立刻可用。"))
                        .font(pf(12.5)).foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22).padding(.top, 10)

                    Spacer().frame(height: 26)

                    Button { showPay = true } label: {
                        Text(busy ? Tr("处理中…") : Tr("充值"))
                            .font(pf(17, .medium)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).frame(height: 46)
                            .background(RoundedRectangle(cornerRadius: 8).fill(amount > 0 ? C.green : C.subLabel))
                            .padding(.horizontal, 20)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy || amount <= 0)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { await loadBanks() }
        .sheet(isPresented: $showAddBank) {
            BankAddSheet { list in banks = list; bankId = list.first(where: { $0.isDefault == true })?.id ?? list.first?.id ?? "" }
                .environmentObject(app)
        }
        .sheet(isPresented: $showPay) {
            PayConfirmSheet(title: Tr("充值") + " ¥" + money(amount)) { pwd, face in
                doRecharge(password: pwd, face: face)
            }
            .environmentObject(app)
        }
        /* 充值中：屏幕正中三个点（微信付款时那一下过渡） */
        .overlay {
            if busy { PayBusyOverlay(text: "正在充值") }
        }
    }

    private var bankLabel: String {
        if let b = banks.first(where: { $0.id == bankId }) { return b.label }
        if let b = banks.first { return b.label }
        return Tr("添加银行卡")
    }

    private func loadBanks() async {
        banks = (try? await API.shared.walletBanks()) ?? []
        if bankId.isEmpty { bankId = banks.first(where: { $0.isDefault == true })?.id ?? banks.first?.id ?? "" }
    }

    private func doRecharge(password: String, face: Bool) {
        busy = true
        Task {
            do {
                let r = try await API.shared.walletRecharge(amount: amount, bankId: bankId)
                await app.refreshAll()
                busy = false
                dismiss()
                app.show(Tr("充值成功") + " ¥" + money(amount) + "，" + Tr("零钱") + " ¥" + money(r.balance ?? 0))
            } catch {
                busy = false
                app.show((error as? APIError)?.errorDescription ?? Tr("充值失败"))
            }
        }
    }
}

struct WithdrawView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var amountText = ""
    @State private var banks: [API.WalletBankCard] = []
    @State private var bankId = ""
    @State private var busy = false
    @State private var showAddBank = false
    /// 选到账银行卡（微信：点「提现到」那一行走一整页/半屏列表挑）
    @State private var showPickBank = false
    @State private var showPay = false
    @State private var ops: [API.WalletOp] = []
    /// 底部那两条常见问题点开看答案
    @State private var faq: (String, String)?
    @FocusState private var amountFocused: Bool

    private var amount: Double { Double(amountText) ?? 0 }
    private var balance: Double { app.me?.balance ?? 0 }
    /* 微信：每笔 0.1%，最低 0.1 元 */
    private var fee: Double { amount <= 0 ? 0 : max(0.1, (amount * 0.001 * 100).rounded() / 100) }
    /// 本次实际到账（微信在服务费那行写「实际到账 ¥x」）
    private var net: Double { max(0, amount - fee) }
    private var picked: API.WalletBankCard? { banks.first(where: { $0.id == bankId }) }

    var body: some View {
        VStack(spacing: 0) {
            /* 微信这一页的标题就叫「零钱提现」（不是「提现」） */
            NavBar(title: Tr("零钱提现"), back: { dismiss() })

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    /* ① 提现到哪张卡（微信：一张白卡，上面是银行 + 尾号，下面小字「2小时内到账」） */
                    GroupCard {
                        Button {
                            if banks.isEmpty { showAddBank = true } else { showPickBank = true }
                        } label: {
                            HStack(spacing: 12) {
                                Text(Tr("提现到")).font(pf(16)).foregroundColor(C.label)
                                Spacer(minLength: 6)
                                HStack(spacing: 7) {
                                    bankBadge(picked?.bank ?? "")
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(picked.map { ($0.bank ?? Tr("银行卡")) + Tr("储蓄卡") }
                                             ?? Tr("添加银行卡"))
                                            .font(pf(15.5)).foregroundColor(C.label).lineLimit(1)
                                        Text(picked.map { Tr("尾号 ") + ($0.tail ?? "****") } ?? "")
                                            .font(pf(12.5)).foregroundColor(C.subLabel)
                                    }
                                }
                                Chevron(size: 9, line: 1.6).padding(.leading, 2)
                            }
                            .padding(.horizontal, 16).frame(height: 68)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        HairLine(inset: 16)
                        HStack(spacing: 6) {
                            Image(systemName: "clock")
                                .font(.system(size: 12))
                                .foregroundColor(C.subLabel)
                            Text(Tr("预计 2 小时内到账（以银行处理时间为准）"))
                                .font(pf(12.5)).foregroundColor(C.subLabel)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16).padding(.bottom, 12)
                    }
                    .padding(.top, 10)

                    Spacer().frame(height: 8)

                    /* ② 金额（微信：大号 ¥ + 金额，右边「全部提现」；下面一行「可用余额」） */
                    GroupCard {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("¥").font(pfMoney(22)).foregroundColor(C.label)
                            TextField("0.00", text: $amountText)
                                .font(pfMoney(34))
                                .keyboardType(.decimalPad)
                                .foregroundColor(C.label)
                                .focused($amountFocused)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                amountText = String(format: "%.2f", max(0, balance))
                                amountFocused = false
                            } label: {
                                Text(Tr("全部提现")).font(pf(14.5)).foregroundColor(C.link)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16).frame(height: 74)
                        HairLine(inset: 16)
                        HStack {
                            Text(Tr("可用余额")).font(pf(13)).foregroundColor(C.subLabel)
                            Spacer()
                            Text("¥" + money(balance)).font(pf(13)).foregroundColor(C.subLabel)
                        }
                        .padding(.horizontal, 16).frame(height: 40)
                    }

                    /* ③ 服务费 / 实际到账（微信在按钮上面这几行灰字） */
                    VStack(alignment: .leading, spacing: 6) {
                        if amount > 0 {
                            HStack {
                                Text(Tr("服务费（0.1%，最低 ¥0.1）")).font(pf(13)).foregroundColor(C.subLabel)
                                Spacer()
                                Text("¥" + money(fee)).font(pf(13)).foregroundColor(C.subLabel)
                            }
                            HStack {
                                Text(Tr("实际到账")).font(pf(13)).foregroundColor(C.subLabel)
                                Spacer()
                                Text("¥" + money(net)).font(pf(13)).foregroundColor(C.subLabel)
                            }
                        }
                        HStack {
                            Text(Tr("单笔限额")).font(pf(13)).foregroundColor(C.subLabel)
                            Spacer()
                            Text("¥50,000.00").font(pf(13)).foregroundColor(C.subLabel)
                        }
                    }
                    .padding(.horizontal, 22).padding(.top, 10)

                    Spacer().frame(height: 22)

                    Button { showPay = true } label: {
                        Text(busy ? Tr("处理中…") : Tr("提现"))
                            .font(pf(17, .medium)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).frame(height: 46)
                            .background(RoundedRectangle(cornerRadius: 8).fill(canWithdraw ? C.green : C.subLabel))
                            .padding(.horizontal, 20)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy || !canWithdraw)

                    /* ④ 常见问题（微信这一页底部就是这两条链接） */
                    VStack(spacing: 0) {
                        faqRow(Tr("提现多久能到账？"),
                               Tr("一般 2 小时内到账，具体以银行处理时间为准。遇到节假日可能稍慢。")) {
                            faq = (Tr("提现多久能到账？"),
                                   Tr("一般 2 小时内到账，具体以银行处理时间为准。遇到节假日可能慢一些。\n如果超过 24 小时还没到账，把提现记录截图发给管理员查。"))
                        }
                        HairLine(inset: 16)
                        faqRow(Tr("提现要手续费吗？"),
                               Tr("按提现金额的 0.1% 收取，最低 ¥0.1。")) {
                            faq = (Tr("提现要手续费吗？"),
                                   Tr("按提现金额的 0.1% 收取，最低 ¥0.1，从提现金额里直接扣。\n（这也是微信零钱提现的规则。）"))
                        }
                    }
                    .padding(.top, 18)

                    /* 提现记录（微信在这一页下面就有） */
                    if !ops.isEmpty {
                        HStack {
                            Text(Tr("提现记录")).font(pf(13)).foregroundColor(C.subLabel)
                            Spacer()
                        }
                        .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 6)
                        GroupCard {
                            ForEach(ops.indices, id: \.self) { i in
                                let o = ops[i]
                                if i > 0 { HairLine(inset: 16) }
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("¥" + money(o.amount ?? 0)).font(pf(16)).foregroundColor(C.label)
                                        Text((o.bankText ?? "") + " · " + (o.createdAt ?? "").prefix(16))
                                            .font(pf(12)).foregroundColor(C.subLabel).lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    Text(statusText(o.status))
                                        .font(pf(13))
                                        .foregroundColor(o.status == "pending" ? C.orange : C.green)
                                }
                                .padding(.horizontal, 16).frame(height: 60)
                            }
                        }
                    }
                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task {
            banks = (try? await API.shared.walletBanks()) ?? []
            bankId = banks.first(where: { $0.isDefault == true })?.id ?? banks.first?.id ?? ""
            ops = (try? await API.shared.walletOps()) ?? []
        }
        .sheet(isPresented: $showAddBank) {
            BankAddSheet { list in banks = list; bankId = list.first?.id ?? "" }
                .environmentObject(app)
        }
        /* 选到账银行卡（微信是一整页列表，这里用半屏列表，点一下就换） */
        .sheet(isPresented: $showPickBank) { bankPicker }
        .sheet(isPresented: $showPay) {
            PayConfirmSheet(title: Tr("提现") + " ¥" + money(amount)) { pwd, face in
                doWithdraw(password: pwd, face: face)
            }
            .environmentObject(app)
        }
        /* 提现中：屏幕正中三个点（和微信一样） */
        .overlay {
            if busy { PayBusyOverlay(text: "正在提现") }
        }
        .alert(faq?.0 ?? "", isPresented: Binding(get: { faq != nil }, set: { if !$0 { faq = nil } })) {
            Button(Tr("知道了"), role: .cancel) { faq = nil }
        } message: {
            Text(faq?.1 ?? "")
        }
        .onAppear {
            /* 进页面就把光标放金额上（微信也是进来就能输） */
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { amountFocused = true }
        }
    }

    /// 银行小图标：一个圆 + 银行名第一个字（微信到账卡那一行左边就是这种）
    private func bankBadge(_ bank: String) -> some View {
        let ch = bank.isEmpty ? "卡" : String(bank.prefix(1))
        return Text(ch)
            .font(pf(14, .medium))
            .foregroundColor(.white)
            .frame(width: 28, height: 28)
            .background(Circle().fill(bankColor(bank)))
    }

    private func bankColor(_ bank: String) -> Color {
        if bank.contains("工商") { return Color(hex: 0xC0392B) }
        if bank.contains("建设") { return Color(hex: 0x1F5FBF) }
        if bank.contains("农业") { return Color(hex: 0x2E9B5B) }
        if bank.contains("中国银行") { return Color(hex: 0xB3282E) }
        if bank.contains("招商") { return Color(hex: 0xC7302C) }
        if bank.contains("交通") { return Color(hex: 0x1D4E9B) }
        if bank.contains("邮储") || bank.contains("邮政") { return Color(hex: 0x2B7A3D) }
        return Color(hex: 0x8A8A8E)
    }

    private func faqRow(_ q: String, _ a: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 8) {
                Text(q).font(pf(13.5)).foregroundColor(C.link)
                Spacer(minLength: 8)
                Chevron(size: 8, line: 1.4)
            }
            .padding(.horizontal, 20).frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 选到账银行卡
    private var bankPicker: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("选择到账银行卡"), back: { showPickBank = false })
            ScrollView {
                VStack(spacing: 0) {
                    GroupCard {
                        ForEach(banks) { b in
                            Button {
                                bankId = b.id
                                showPickBank = false
                            } label: {
                                HStack(spacing: 12) {
                                    bankBadge(b.bank ?? "")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text((b.bank ?? Tr("银行卡")) + Tr("储蓄卡"))
                                            .font(pf(16)).foregroundColor(C.label)
                                        Text(Tr("尾号 ") + (b.tail ?? "****"))
                                            .font(pf(12.5)).foregroundColor(C.subLabel)
                                    }
                                    Spacer(minLength: 8)
                                    if b.id == bankId {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundColor(C.green)
                                    }
                                }
                                .padding(.horizontal, 16).frame(height: 64)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            HairLine(inset: 16)
                        }
                        Button {
                            showPickBank = false
                            showAddBank = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 17)).foregroundColor(C.green)
                                Text(Tr("添加银行卡")).font(pf(16)).foregroundColor(C.label)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16).frame(height: 56)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 10)
                    Text(Tr("到账时间：预计 2 小时内（以银行处理时间为准）"))
                        .font(pf(12.5)).foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22).padding(.top, 10)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        /* 2026-10-16：选到账银行卡这一层也补左滑返回（滑一下 = 不收卡片，回上一页） */
        .swipeBack { showPickBank = false }
    }

    private var canWithdraw: Bool { amount >= 1 && amount + fee <= balance && !bankId.isEmpty }

    private func statusText(_ s: String?) -> String {
        switch s {
        case "done": return Tr("已到账")
        case "failed": return Tr("提现失败")
        default: return Tr("处理中")
        }
    }

    private func doWithdraw(password: String, face: Bool) {
        busy = true
        Task {
            do {
                let r = try await API.shared.walletWithdraw(amount: amount, bankId: bankId,
                                                            password: password, face: face)
                await app.refreshAll()
                ops = (try? await API.shared.walletOps()) ?? ops
                amountText = ""
                busy = false
                app.show(Tr("提现申请已提交") + "：" + (r.expect ?? "") + "（" + Tr("服务费") + " ¥" + money(r.fee ?? 0) + "）")
            } catch {
                busy = false
                app.show((error as? APIError)?.errorDescription ?? Tr("提现失败"))
            }
        }
    }
}

/* 添加银行卡：只存银行名 + 末四位 */
struct BankAddSheet: View {
    var onAdded: ([API.WalletBankCard]) -> Void

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var bank = ""
    @State private var cardNo = ""
    @State private var holder = ""
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("添加银行卡"), back: { dismiss() }) {
                Button { save() } label: {
                    Text(busy ? Tr("保存中…") : Tr("完成"))
                        .font(pf(17)).foregroundColor(cardNo.count >= 12 ? C.green : C.subLabel)
                        .frame(height: L.navH).padding(.trailing, 16)
                }
                .buttonStyle(.plain)
                .disabled(busy || cardNo.count < 12)
            }
            GroupCard {
                field(Tr("开户银行"), $bank, "招商银行")
                HairLine(inset: 16)
                field(Tr("卡号"), $cardNo, "6225 8801 2345 6789")
                HairLine(inset: 16)
                field(Tr("姓名"), $holder, "")
            }
            .padding(.top, 12)
            Text(Tr("出于安全考虑，服务器只保存银行名和卡号后四位，完整卡号不落盘。"))
                .font(pf(12.5)).foregroundColor(C.subLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22).padding(.top, 10)
            Spacer()
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .hidesTabBar()
        /* 2026-10-16：添加银行卡页补左滑返回 */
        .swipeBack { dismiss() }
    }

    private func field(_ title: String, _ text: Binding<String>, _ ph: String) -> some View {
        HStack(spacing: 12) {
            Text(title).font(pf(16)).foregroundColor(C.label).frame(width: 84, alignment: .leading)
            TextField(ph, text: text)
                .font(pf(16)).foregroundColor(C.label)
                .keyboardType(title == Tr("卡号") ? .numberPad : .default)
        }
        .padding(.horizontal, 16).frame(height: 54)
    }

    private func save() {
        busy = true
        Task {
            do {
                let list = try await API.shared.addBank(bank: bank, cardNo: cardNo, holder: holder)
                onAdded(list)
                busy = false
                dismiss()
                app.show(Tr("银行卡已添加"))
            } catch {
                busy = false
                app.show((error as? APIError)?.errorDescription ?? Tr("添加失败"))
            }
        }
    }
}

/* 支付确认：6 位支付密码（有面容的话可以点「使用面容」） */
struct PayConfirmSheet: View {
    var title: String
    var onConfirm: (String, Bool) -> Void

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var pwd = ""
    @State private var hasPay = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                        .foregroundColor(C.label).frame(width: 44, height: L.navH)
                }
                .buttonStyle(.plain)
                Spacer()
                Text(title).font(pf(16, .medium)).foregroundColor(C.label)
                Spacer()
                Spacer().frame(width: 44)
            }
            .frame(height: L.navH)

            Text(Tr("请输入支付密码"))
                .font(pf(15)).foregroundColor(C.subLabel)
                .padding(.top, 18)

            HStack(spacing: 0) {
                PayDotField(count: pwd.count)
            }
            .padding(.top, 16)

            TextField("", text: $pwd)
                .keyboardType(.numberPad)
                .frame(height: 1).opacity(0.01)

            if Biometrics.available {
                Button {
                    dismiss()
                    onConfirm("", true)      // 面容已通过
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "faceid")
                        Text(Tr("使用面容"))
                    }
                    .font(pf(15)).foregroundColor(C.link)
                }
                .buttonStyle(.plain)
                .padding(.top, 18)
            }

            Button {
                dismiss()
                onConfirm(pwd, false)
            } label: {
                Text(Tr("确认支付"))
                    .font(pf(16, .medium)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 8).fill(pwd.count >= 6 ? C.green : C.subLabel))
                    .padding(.horizontal, 20)
            }
            .buttonStyle(.plain)
            .disabled(pwd.count < 6)
            .padding(.top, 20)
            Spacer()
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .hidesTabBar()
    }
}
