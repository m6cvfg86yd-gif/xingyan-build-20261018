import SwiftUI

/* ============================================================
   钱包 → 身份信息 / 支付设置（微信那两页）
   · 身份信息：实名姓名（打码）、身份证号（打码）、证件有效期、职业、常住地址；
     没实名就给「立即认证」；还能看账户等级和已绑卡数
   · 支付设置：支付密码、小额免密支付（含额度）、首选付款方式、自动续费/免密签约（可解约）
   ============================================================ */

struct IdentityView: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var info: API.IdentityInfo?
    @State private var idValid = ""
    @State private var occupation = ""
    @State private var address = ""
    @State private var busy = false
    @State private var showRealName = false
    @State private var showUpgrade = false
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("身份信息"), back: { dismiss() })
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    /* 实名状态卡片 */
                    VStack(spacing: 6) {
                        Text((info?.verified ?? false) ? Tr("已实名认证") : Tr("未实名认证"))
                            .font(pf(16, .medium))
                            .foregroundColor(.white)
                        if let n = info?.realName, !n.isEmpty {
                            Text(n).font(pf(13)).foregroundColor(Color.white.opacity(0.9))
                        }
                        Text(subtitleLine)
                            .font(pf(12)).foregroundColor(Color.white.opacity(0.85))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    /* 2026-10-17：绿色渐变按钮改成跟全 App 主色走（ui.json: greenColor） */
                    .background(LinearGradient(colors: [C.green, C.green.opacity(0.82)],
                                               startPoint: .top, endPoint: .bottom))

                    GroupCard {
                        row(Tr("姓名"), info?.realName?.isEmpty == false ? info!.realName! : Tr("未认证"))
                        HairLine(inset: 16)
                        row(Tr("身份证号"), info?.idMask?.isEmpty == false ? info!.idMask! : Tr("未认证"))
                        HairLine(inset: 16)
                        row(Tr("认证时间"), (info?.verifiedAt ?? "").isEmpty ? "—" : String((info!.verifiedAt!).prefix(10)))
                    }
                    .padding(.top, 10)

                    GroupCard {
                        editRow(Tr("证件有效期"), $idValid, Tr("比如 2035-08-01"))
                        HairLine(inset: 16)
                        editRow(Tr("职业"), $occupation, Tr("比如 个体经营"))
                        HairLine(inset: 16)
                        editRow(Tr("常住地址"), $address, Tr("省市区 + 详细地址"))
                    }
                    .padding(.top, 10)

                    if !(info?.verified ?? false) {
                        Button { showRealName = true } label: {
                            Text(Tr("立即认证"))
                                .font(pf(17, .medium)).foregroundColor(.white)
                                .frame(maxWidth: .infinity).frame(height: 48)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(C.green))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16).padding(.top, 18)
                    } else {
                        Button { showUpgrade = true } label: {
                            Text(Tr("账户升级服务"))
                                .font(pf(16, .medium)).foregroundColor(C.green)
                                .frame(maxWidth: .infinity).frame(height: 46)
                                .background { CardGlassBox(radius: 8) }
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16).padding(.top, 18)
                    }

                    Button { save() } label: {
                        Text(busy ? Tr("保存中…") : Tr("保存"))
                            .font(pf(16, .medium)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).frame(height: 46)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(C.green))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16).padding(.top, 10)
                    .disabled(busy)

                    Text(Tr("身份证号只保存打码后的，完整号码不留在服务器上。"))
                        .font(pf(12.5)).foregroundColor(C.subLabel)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24).padding(.top, 12)
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
        .sheet(isPresented: $showUpgrade) {
            WalletUpgradeView().environmentObject(app)
        }
    }

    /// 头部那行小字（拆出来，免得编译器算不明白那一串拼接）
    private var subtitleLine: String {
        let lv = info?.levelName ?? ""
        let n = info?.bankCount ?? 0
        if n > 0 { return lv + " · 已绑 " + String(n) + " 张卡" }
        return lv
    }

    private func row(_ t: String, _ v: String) -> some View {
        HStack(spacing: 8) {
            Text(t).font(pf(16)).foregroundColor(C.label)
            Spacer(minLength: 6)
            Text(v).font(pf(15)).foregroundColor(C.subLabel)
        }
        .padding(.horizontal, 16).frame(height: 52)
    }

    private func editRow(_ t: String, _ text: Binding<String>, _ ph: String) -> some View {
        HStack(spacing: 8) {
            Text(t).font(pf(16)).foregroundColor(C.label)
            Spacer(minLength: 6)
            TextField(ph, text: text)
                .font(pf(15)).multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16).frame(height: 52)
    }

    private func load() async {
        if let got = try? await API.shared.identity() {
            info = got
            idValid = got.idValid ?? ""
            occupation = got.occupation ?? ""
            address = got.address ?? ""
        }
        loading = false
    }

    private func save() {
        busy = true
        Task {
            await API.shared.saveIdentity(idValid: idValid, occupation: occupation, address: address)
            app.show(Tr("身份信息已保存"))
            busy = false
            await load()
        }
    }
}

/* ---------------------------------------------------------- 支付设置 */
struct PaySettingsView: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var cfg: API.PaySettings?
    @State private var noPin = false
    @State private var limit: Double = 1000
    @State private var payMethod = "balance"
    @State private var busy = false
    @State private var showChangePwd = false
    @State private var loading = true

    private let limits: [Double] = [0, 200, 500, 1000]

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("支付设置"), back: { dismiss() })
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    GroupCard {
                        Button { showChangePwd = true } label: {
                            HStack(spacing: 8) {
                                Text(Tr("支付密码")).font(pf(16)).foregroundColor(C.label)
                                Spacer(minLength: 6)
                                Text((cfg?.hasPayPassword ?? false) ? Tr("已设置") : Tr("未设置"))
                                    .font(pf(15)).foregroundColor(C.subLabel)
                                Chevron(size: 9, line: 1.6)
                            }
                            .padding(.horizontal, 16).frame(height: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        HairLine(inset: 16)
                        HStack(spacing: 8) {
                            Text(Tr("面容支付")).font(pf(16)).foregroundColor(C.label)
                            Spacer(minLength: 6)
                            Text(Biometrics.available ? Tr("可用（付款时选「使用面容」）") : Tr("这台手机不支持"))
                                .font(pf(13)).foregroundColor(C.subLabel)
                        }
                        .padding(.horizontal, 16).frame(height: 52)
                    }
                    .padding(.top, 10)

                    GroupCard {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(Tr("小额免密支付")).font(pf(16)).foregroundColor(C.label)
                                Spacer(minLength: 8)
                                Toggle("", isOn: $noPin).labelsHidden().tint(C.green)
                                    .onChange(of: noPin) { _ in save() }
                            }
                            Text(Tr("开启后，单笔不超过额度时不用输支付密码")).font(pf(12)).foregroundColor(C.subLabel)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)

                        if noPin {
                            HairLine(inset: 16)
                            HStack(spacing: 8) {
                                Text(Tr("免密额度")).font(pf(16)).foregroundColor(C.label)
                                Spacer(minLength: 6)
                                Picker("", selection: $limit) {
                                    ForEach(limits, id: \.self) { v in
                                        Text(v == 0 ? Tr("不限") : ("¥" + String(format: "%.0f", v))).tag(v)
                                    }
                                }
                                .pickerStyle(.menu)
                                .tint(C.green)
                                .onChange(of: limit) { _ in save() }
                            }
                            .padding(.horizontal, 16).frame(height: 52)
                        }
                    }
                    .padding(.top, 10)

                    GroupCard {
                        HStack(spacing: 8) {
                            Text(Tr("优先付款方式")).font(pf(16)).foregroundColor(C.label)
                            Spacer(minLength: 6)
                            Picker("", selection: $payMethod) {
                                Text(Tr("零钱")).tag("balance")
                                Text(Tr("银行卡")).tag("card")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 170)
                            .onChange(of: payMethod) { _ in save() }
                        }
                        .padding(.horizontal, 16).frame(height: 56)
                    }
                    .padding(.top, 10)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(Tr("自动续费 / 免密签约")).font(pf(13)).foregroundColor(C.subLabel)
                            .padding(.horizontal, 8).padding(.bottom, 6)
                        GroupCard {
                            let list = cfg?.autoDebits ?? []
                            if list.isEmpty {
                                Text(Tr("没有签约中的免密服务"))
                                    .font(pf(14)).foregroundColor(C.subLabel)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 24)
                            } else {
                                ForEach(Array(list.enumerated()), id: \.element.id) { idx, a in
                                    if idx > 0 { HairLine(inset: 16) }
                                    HStack(spacing: 10) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(a.name ?? Tr("免密服务")).font(pf(15.5)).foregroundColor(C.label)
                                            Text((a.cycle ?? "") + ((a.amount ?? 0) > 0 ? (" · ¥" + moneyFmt(a.amount ?? 0)) : ""))
                                                .font(pf(12)).foregroundColor(C.subLabel)
                                        }
                                        Spacer(minLength: 6)
                                        Button { cancel(a.id) } label: {
                                            Text(Tr("解约")).font(pf(13.5)).foregroundColor(C.red)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 16).frame(height: 58)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.top, 14)

                    Text(Tr("支付密码用于转账、发红包、提现；免密支付只对超过额度的那部分生效。"))
                        .font(pf(12.5)).foregroundColor(C.subLabel)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24).padding(.top, 14)
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
        .sheet(isPresented: $showChangePwd) {
            ChangePasswordSheet().environmentObject(app)
        }
    }

    private func load() async {
        if let got = try? await API.shared.paySettings() {
            cfg = got
            noPin = got.noPin ?? false
            limit = got.noPinLimit ?? 1000
            payMethod = got.payMethod ?? "balance"
        }
        loading = false
    }

    private func save() {
        if busy { return }
        busy = true
        Task {
            await API.shared.savePaySettings(noPin: noPin, noPinLimit: limit, payMethod: payMethod)
            busy = false
        }
    }

    private func cancel(_ id: String) {
        Task {
            await API.shared.cancelAutoDebit(id)
            app.show(Tr("已解约"))
            await load()
        }
    }
}
