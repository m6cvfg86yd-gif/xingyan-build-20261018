import SwiftUI

/* 钱包 → 经营账户（微信那套）
   · 上面：经营账户余额 + 今日/本月/累计收款
   · 四个入口：收款记录 / 经营设置 / 提现到零钱 / 开票信息
   数据都在服务端 data/biz.json，后台「经营账户查账」页能看到每个人的账。 */
struct BizAccountView: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var info: API.BizPayload?
    @State private var page: BizPage?

    enum BizPage: String, Identifiable {
        case records, settings, withdraw, invoice
        var id: String { rawValue }
    }

    private func money(_ v: Double?) -> String { "¥" + moneyFmt(v ?? 0) }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("经营账户"), back: { dismiss() })
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    VStack(spacing: 8) {
                        Text(Tr("经营账户余额"))
                            .font(pf(13.5)).foregroundColor(Color.white.opacity(0.85))
                        Text(money(info?.balance))
                            .font(pfMoney(34, .medium))
                            .foregroundColor(.white)
                        Text((info?.enabled ?? false)
                             ? ((info?.settings?.arrival ?? "balance") == "biz"
                                ? Tr("收款进经营账户，可随时提现到零钱")
                                : Tr("收款直接进零钱（经营账户没开或到账方式选了零钱）"))
                             : Tr("经营账户还没开，开了才能按经营账户收款、开票、对账"))
                            .font(pf(12))
                            .foregroundColor(Color.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                    /* 2026-10-17 用户：「所有带有微信绿的按钮换个颜色」——
                       这种绿色渐变按钮不再写死，跟全 App 的主色走（ui.json: greenColor） */
                    .background(LinearGradient(colors: [C.green, C.green.opacity(0.82)],
                                               startPoint: .top, endPoint: .bottom))

                    GroupCard {
                        HStack(spacing: 0) {
                            totalCell(Tr("今日收款"), info?.totals?.today)
                            Rectangle().fill(C.hairline).frame(width: 0.5, height: 40)
                            totalCell(Tr("本月收款"), info?.totals?.month)
                            Rectangle().fill(C.hairline).frame(width: 0.5, height: 40)
                            totalCell(Tr("累计收款"), info?.totals?.all)
                        }
                        .padding(.vertical, 14)
                    }
                    .padding(.top, 10)

                    GroupCard {
                        entry(Tr("收款记录"), "\(info?.totals?.count ?? 0) " + Tr("笔"), .records)
                        HairLine(inset: 16)
                        entry(Tr("经营设置"),
                              (info?.enabled ?? false) ? Tr("已开启") : Tr("未开启"), .settings)
                        HairLine(inset: 16)
                        entry(Tr("提现到零钱"), money(info?.balance), .withdraw)
                        HairLine(inset: 16)
                        entry(Tr("开票信息"),
                              (info?.invoiceReady ?? false) ? (info?.invoice?.title ?? "") : Tr("未填写"), .invoice)
                    }
                    .padding(.top, 10)

                    Text(Tr("经营账户里的每一笔收款都有订单号，后台「经营账户查账」可以对账。"))
                        .font(pf(12.5)).foregroundColor(C.subLabel)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.top, 14)
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
        .sheet(item: $page) { p in
            Group {
                switch p {
                case .records: BizRecordsView(info: info)
                case .settings: BizSettingsView(onSaved: { Task { await load() } })
                case .withdraw: BizWithdrawView(info: info, onDone: { Task { await load() } })
                case .invoice: BizInvoiceView(info: info, onDone: { Task { await load() } })
                }
            }
            .environmentObject(app)
        }
    }

    private func totalCell(_ title: String, _ v: Double?) -> some View {
        VStack(spacing: 4) {
            Text(money(v)).font(pfMoney(16)).foregroundColor(C.label)
            Text(title).font(pf(12)).foregroundColor(C.subLabel)
        }
        .frame(maxWidth: .infinity)
    }

    private func entry(_ title: String, _ value: String, _ p: BizPage) -> some View {
        Button { page = p } label: {
            HStack(spacing: 8) {
                Text(title).font(pf(16)).foregroundColor(C.label)
                Spacer(minLength: 6)
                Text(value).font(pf(13)).foregroundColor(C.subLabel).lineLimit(1)
                Chevron(size: 9, line: 1.6)
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        info = try? await API.shared.biz()
    }
}

/* ---------------------------------------------------------- 收款记录 */
struct BizRecordsView: View {
    @ObservedObject private var lang = LangStore.shared
    @Environment(\.dismiss) private var dismiss
    let info: API.BizPayload?

    private var records: [API.BizRecordRaw] { info?.records ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("收款记录"), back: { dismiss() })
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    GroupCard {
                        HStack(spacing: 0) {
                            cell(Tr("今日"), info?.totals?.today)
                            Rectangle().fill(C.hairline).frame(width: 0.5, height: 40)
                            cell(Tr("本月"), info?.totals?.month)
                            Rectangle().fill(C.hairline).frame(width: 0.5, height: 40)
                            cell(Tr("累计"), info?.totals?.all)
                        }
                        .padding(.vertical, 14)
                    }
                    .padding(.top, 10)

                    GroupCard {
                        if records.isEmpty {
                            Text(Tr("还没有收款记录。别人给你转钱、你收到红包，都会记在这里。"))
                                .font(pf(14)).foregroundColor(C.subLabel)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 26)
                        } else {
                            ForEach(Array(records.enumerated()), id: \.element.id) { idx, r in
                                if idx > 0 { HairLine(inset: 16) }
                                recordRow(r)
                            }
                        }
                    }
                    .padding(.top, 10)
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
    }

    @ViewBuilder private func recordRow(_ r: API.BizRecordRaw) -> some View {
        let isOut = r.kind == "withdraw"
        let sign = isOut ? "-" : "+"
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title(r)).font(pf(15.5)).foregroundColor(C.label)
                Spacer(minLength: 6)
                Text(sign + "¥" + moneyFmt(r.amount ?? 0))
                    .font(pfMoney(15.5))
                    .foregroundColor(isOut ? C.label : C.green)
            }
            HStack(spacing: 8) {
                Text(subtitle(r)).font(pf(12)).foregroundColor(C.subLabel)
                Spacer(minLength: 6)
                Text(rpTime(r.createdAt ?? "")).font(pf(12)).foregroundColor(C.subLabel)
            }
            if let no = r.orderNo, !no.isEmpty {
                Text(Tr("订单号") + " " + no)
                    .font(pf(11.5)).foregroundColor(C.subLabel)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func title(_ r: API.BizRecordRaw) -> String {
        switch r.kind {
        case "withdraw": return Tr("提现到零钱")
        case "invoice": return Tr("申请开票")
        case "refund": return Tr("退款")
        default:
            return (r.fromName?.isEmpty == false ? (r.fromName! + Tr(" 的付款")) : Tr("收款"))
        }
    }

    private func subtitle(_ r: API.BizRecordRaw) -> String {
        var parts: [String] = []
        if r.kind == "collect" {
            parts.append(r.method == "redpacket" ? Tr("红包") : (r.method == "transfer" ? Tr("转账") : Tr("收款")))
            if let n = r.note, !n.isEmpty { parts.append(n) }
            parts.append(r.settled == true ? Tr("已入零钱") : Tr("已入经营账户"))
        } else if let n = r.note, !n.isEmpty {
            parts.append(n)
        }
        return parts.joined(separator: " · ")
    }

    private func cell(_ t: String, _ v: Double?) -> some View {
        VStack(spacing: 4) {
            Text("¥" + moneyFmt(v ?? 0)).font(pfMoney(15)).foregroundColor(C.label)
            Text(t).font(pf(12)).foregroundColor(C.subLabel)
        }
        .frame(maxWidth: .infinity)
    }
}
/* ---------------------------------------------------------- 经营设置 */
struct BizSettingsView: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    var onSaved: (() -> Void)?

    @State private var enabled = false
    @State private var arrival = "balance"
    @State private var notify = true
    @State private var autoWithdraw = false
    @State private var shopName = ""
    @State private var remark = ""
    @State private var loading = true
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("经营设置"), back: { dismiss() })
            if loading {
                ProgressView().padding(.top, 60)
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        GroupCard {
                            switchRow(Tr("开启经营账户"), isOn: $enabled,
                                      hint: Tr("开了以后才能按经营账户收款、开票、对账"))
                            HairLine(inset: 16)
                            HStack {
                                Text(Tr("到账方式")).font(pf(16)).foregroundColor(C.label)
                                Spacer(minLength: 8)
                                Picker("", selection: $arrival) {
                                    Text(Tr("到零钱")).tag("balance")
                                    Text(Tr("到经营账户")).tag("biz")
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 190)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 56)
                            HairLine(inset: 16)
                            switchRow(Tr("收款提醒"), isOn: $notify,
                                      hint: Tr("有人给你转钱、发红包时提醒你"))
                            HairLine(inset: 16)
                            switchRow(Tr("自动提现到零钱"), isOn: $autoWithdraw,
                                      hint: Tr("经营账户里的钱自动提到零钱（T+1 结算）"))
                        }
                        .padding(.top, 10)

                        GroupCard {
                            field(Tr("店铺名"), $shopName, Tr("比如：小林便利店"))
                            HairLine(inset: 16)
                            field(Tr("备注"), $remark, Tr("收款码上显示的一句话"))
                        }
                        .padding(.top, 10)

                        GroupCard {
                            HStack {
                                Text(Tr("手续费率")).font(pf(16)).foregroundColor(C.label)
                                Spacer(minLength: 6)
                                Text("0.6%").font(pf(15)).foregroundColor(C.subLabel)
                            }
                            .padding(.horizontal, 16).frame(height: 52)
                            HairLine(inset: 16)
                            HStack {
                                Text(Tr("结算周期")).font(pf(16)).foregroundColor(C.label)
                                Spacer(minLength: 6)
                                Text("T+1").font(pf(15)).foregroundColor(C.subLabel)
                            }
                            .padding(.horizontal, 16).frame(height: 52)
                        }
                        .padding(.top, 10)

                        Button { save() } label: {
                            Text(busy ? Tr("保存中…") : Tr("保存"))
                                .font(pf(17, .medium)).foregroundColor(.white)
                                .frame(maxWidth: .infinity).frame(height: 48)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(C.green))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16).padding(.top, 20)
                        .disabled(busy)

                        Text(Tr("到账方式选「经营账户」时，收到的钱先记在经营账户余额里，你随时可以提到零钱。"))
                            .font(pf(12.5)).foregroundColor(C.subLabel)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24).padding(.top, 12)
                        Color.clear.frame(height: 24)
                    }
                }
                .background(C.pageBg)
            }
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task {
            if let b = try? await API.shared.biz() {
                enabled = b.enabled ?? false
                arrival = b.settings?.arrival ?? "balance"
                notify = b.settings?.notify ?? true
                autoWithdraw = b.settings?.autoWithdraw ?? false
                shopName = b.settings?.shopName ?? ""
                remark = b.settings?.remark ?? ""
            }
            loading = false
        }
    }

    private func switchRow(_ title: String, isOn: Binding<Bool>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(pf(16)).foregroundColor(C.label)
                Spacer(minLength: 8)
                Toggle("", isOn: isOn).labelsHidden().tint(C.green)
            }
            Text(hint).font(pf(12)).foregroundColor(C.subLabel)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func field(_ title: String, _ text: Binding<String>, _ ph: String) -> some View {
        HStack(spacing: 10) {
            Text(title).font(pf(16)).foregroundColor(C.label)
            Spacer(minLength: 6)
            TextField(ph, text: text)
                .font(pf(15)).multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16).frame(height: 52)
    }

    private func save() {
        busy = true
        Task {
            do {
                try await API.shared.bizSave(enabled: enabled, arrival: arrival, notify: notify,
                                             autoWithdraw: autoWithdraw, shopName: shopName, remark: remark)
                app.show(Tr("经营设置已保存"))
                onSaved?()
                dismiss()
            } catch {
                app.show((error as? LocalizedError)?.errorDescription ?? Tr("保存失败"))
            }
            busy = false
        }
    }
}

/* ---------------------------------------------------------- 提现到零钱 */
struct BizWithdrawView: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let info: API.BizPayload?
    var onDone: (() -> Void)?

    @State private var amountText = ""
    @State private var busy = false
    @State private var askPwd = false
    @State private var pwd = ""

    private var balance: Double { info?.balance ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("提现到零钱"), back: { dismiss() })
            VStack(spacing: 8) {
                Text(Tr("可提现余额")).font(pf(13)).foregroundColor(C.subLabel)
                Text("¥" + moneyFmt(balance))
                    .font(pfMoney(32, .medium)).foregroundColor(C.label)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .background(C.cardBg)

            GroupCard {
                HStack(spacing: 10) {
                    Text(Tr("提现金额")).font(pf(16)).foregroundColor(C.label)
                    Spacer(minLength: 6)
                    TextField("0.00", text: $amountText)
                        .keyboardType(.decimalPad)
                        .font(pfMoney(17)).multilineTextAlignment(.trailing)
                        .frame(maxWidth: 150)
                    Button { amountText = String(format: "%.2f", balance) } label: {
                        Text(Tr("全部")).font(pf(14)).foregroundColor(C.green)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16).frame(height: 54)
            }
            .padding(.top, 10)

            Button { submit() } label: {
                Text(busy ? Tr("处理中…") : Tr("提现到零钱"))
                    .font(pf(17, .medium)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(balance <= 0 ? C.subLabel : C.green))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.top, 18)
            .disabled(busy || balance <= 0)

            Text(Tr("经营账户提现到零钱是即时到账的，不收费。"))
                .font(pf(12.5)).foregroundColor(C.subLabel)
                .padding(.top, 12)
            Spacer(minLength: 0)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .alert(Tr("请输入支付密码"), isPresented: $askPwd) {
            TextField(Tr("支付密码"), text: $pwd).keyboardType(.numberPad)
            Button(Tr("取消"), role: .cancel) { pwd = "" }
            Button(Tr("确定")) { doWithdraw(password: pwd); pwd = "" }
        }
    }

    private func submit() {
        let v = Double(amountText) ?? 0
        if !(v > 0) { app.show(Tr("先填金额")); return }
        if v > balance + 0.001 { app.show(Tr("超过可提现余额了")); return }
        Task {
            let hasPwd = await API.shared.hasPayPassword()
            if hasPwd {
                askPwd = true
            } else {
                /* 没设过支付密码：钱出不去，先去设一个（微信也是这个规矩） */
                app.show(Tr("还没设置支付密码：我 → 设置 → 账号与安全 → 支付密码"))
            }
        }
    }

    private func doWithdraw(password: String) {
        let v = Double(amountText) ?? 0
        busy = true
        Task {
            do {
                let r = try await API.shared.bizWithdraw(amount: v, all: false, password: password, face: false)
                if var me = app.me { me.balance = r.balance ?? me.balance; app.me = me }
                app.show(Tr("已经提到零钱"))
                onDone?()
                dismiss()
            } catch {
                app.show((error as? LocalizedError)?.errorDescription ?? Tr("提现失败"))
            }
            busy = false
        }
    }
}

/* ---------------------------------------------------------- 开票信息 */
struct BizInvoiceView: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let info: API.BizPayload?
    var onDone: (() -> Void)?

    @State private var title = ""
    @State private var taxNo = ""
    @State private var address = ""
    @State private var phone = ""
    @State private var bankName = ""
    @State private var bankAccount = ""
    @State private var applyAmount = ""
    @State private var note = ""
    @State private var busy = false
    @State private var loaded = false

    private var invoices: [API.BizInvoiceRaw] { info?.invoices ?? [] }
    private var invoiced: Double {
        invoices.filter { ($0.status ?? "pending") != "rejected" }
            .reduce(0) { $0 + ($1.amount ?? 0) }
    }
    private var leftAmount: Double { max(0, (info?.totals?.all ?? 0) - invoiced) }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("开票信息"), back: { dismiss() })
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    GroupCard {
                        field(Tr("发票抬头"), $title, Tr("公司或个人名字"))
                        HairLine(inset: 16)
                        field(Tr("税号"), $taxNo, Tr("企业开票必填"))
                        HairLine(inset: 16)
                        field(Tr("地址"), $address, Tr("选填"))
                        HairLine(inset: 16)
                        field(Tr("电话"), $phone, Tr("选填"))
                        HairLine(inset: 16)
                        field(Tr("开户行"), $bankName, Tr("选填"))
                        HairLine(inset: 16)
                        field(Tr("银行账号"), $bankAccount, Tr("选填"))
                    }
                    .padding(.top, 10)

                    Button { save() } label: {
                        Text(busy ? Tr("保存中…") : Tr("保存开票信息"))
                            .font(pf(16, .medium)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).frame(height: 46)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(C.green))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16).padding(.top, 14)
                    .disabled(busy)

                    GroupCard {
                        HStack {
                            Text(Tr("可开票金额")).font(pf(16)).foregroundColor(C.label)
                            Spacer(minLength: 6)
                            Text("¥" + moneyFmt(leftAmount))
                                .font(pfMoney(16)).foregroundColor(C.green)
                        }
                        .padding(.horizontal, 16).frame(height: 52)
                        HairLine(inset: 16)
                        HStack(spacing: 10) {
                            Text(Tr("开票金额")).font(pf(16)).foregroundColor(C.label)
                            Spacer(minLength: 6)
                            TextField("0.00", text: $applyAmount)
                                .keyboardType(.decimalPad)
                                .font(pfMoney(16)).multilineTextAlignment(.trailing)
                                .frame(maxWidth: 140)
                            Button { applyAmount = String(format: "%.2f", leftAmount) } label: {
                                Text(Tr("全部")).font(pf(14)).foregroundColor(C.green)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16).frame(height: 52)
                        HairLine(inset: 16)
                        HStack(spacing: 10) {
                            Text(Tr("备注")).font(pf(16)).foregroundColor(C.label)
                            Spacer(minLength: 6)
                            TextField(Tr("选填"), text: $note)
                                .font(pf(15)).multilineTextAlignment(.trailing)
                        }
                        .padding(.horizontal, 16).frame(height: 52)
                    }
                    .padding(.top, 12)

                    Button { apply() } label: {
                        Text(busy ? Tr("提交中…") : Tr("申请开票"))
                            .font(pf(17, .medium)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).frame(height: 48)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(leftAmount > 0 ? C.green : C.subLabel))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16).padding(.top, 12)
                    .disabled(busy || leftAmount <= 0)

                    if !invoices.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(Tr("开票记录")).font(pf(13)).foregroundColor(C.subLabel)
                                .padding(.horizontal, 8).padding(.bottom, 6)
                            GroupCard {
                                ForEach(Array(invoices.enumerated()), id: \.element.id) { idx, inv in
                                    if idx > 0 { HairLine(inset: 16) }
                                    HStack(spacing: 8) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("¥" + moneyFmt(inv.amount ?? 0))
                                                .font(pfMoney(15)).foregroundColor(C.label)
                                            Text(rpTime(inv.createdAt ?? ""))
                                                .font(pf(12)).foregroundColor(C.subLabel)
                                        }
                                        Spacer(minLength: 6)
                                        Text(statusText(inv.status ?? "pending"))
                                            .font(pf(13))
                                            .foregroundColor((inv.status ?? "") == "done" ? C.green : C.subLabel)
                                    }
                                    .padding(.horizontal, 16).frame(height: 56)
                                }
                            }
                        }
                        .padding(.horizontal, 8).padding(.top, 14)
                    }

                    Text(Tr("开票申请会进后台，客服开好后状态会变成「已开票」。"))
                        .font(pf(12.5)).foregroundColor(C.subLabel)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24).padding(.top, 12)
                    Color.clear.frame(height: 26)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task {
            if !loaded {
                title = info?.invoice?.title ?? ""
                taxNo = info?.invoice?.taxNo ?? ""
                address = info?.invoice?.address ?? ""
                phone = info?.invoice?.phone ?? ""
                bankName = info?.invoice?.bankName ?? ""
                bankAccount = info?.invoice?.bankAccount ?? ""
                loaded = true
            }
        }
    }

    private func statusText(_ s: String) -> String {
        s == "done" ? Tr("已开票") : (s == "rejected" ? Tr("已驳回") : Tr("处理中"))
    }

    private func field(_ t: String, _ text: Binding<String>, _ ph: String) -> some View {
        HStack(spacing: 10) {
            Text(t).font(pf(16)).foregroundColor(C.label)
            Spacer(minLength: 6)
            TextField(ph, text: text)
                .font(pf(15)).multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16).frame(height: 52)
    }

    private func save() {
        busy = true
        Task {
            do {
                try await API.shared.bizSaveInvoice(title: title, taxNo: taxNo, address: address,
                                                    phone: phone, bankName: bankName, bankAccount: bankAccount)
                app.show(Tr("开票信息已保存"))
                onDone?()
            } catch {
                app.show((error as? LocalizedError)?.errorDescription ?? Tr("保存失败"))
            }
            busy = false
        }
    }

    private func apply() {
        let v = Double(applyAmount) ?? 0
        if !(v > 0) { app.show(Tr("先填开票金额")); return }
        busy = true
        Task {
            do {
                _ = try await API.shared.bizApplyInvoice(amount: v, kind: "company", note: note)
                app.show(Tr("已经提交，客服开好票会在这里显示"))
                applyAmount = ""
                note = ""
                onDone?()
            } catch {
                app.show((error as? LocalizedError)?.errorDescription ?? Tr("申请失败"))
            }
            busy = false
        }
    }
}
