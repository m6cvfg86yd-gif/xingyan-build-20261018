import SwiftUI

/* ============================================================
   星言支付（2026-10-15 用户：「给软件整体接个星言支付，名字可以后台换，
   用于商城付款转账都可以，跟华为支付逻辑一样」）

   华为支付那套逻辑 = **钱包 + 银行卡式的卡面 + 生物识别/支付密码验证 + 成功回执**，
   这里照着做成一页「收银台」：
     · 上面一张卡（星言钱包，尾号是这台账号算出来的，稳定的）
     · 中间金额 + 收款方
     · 主按钮 = 「使用面容 / 使用指纹」（真的调系统生物识别：Biometrics）
     · 兜底 = 6 位支付密码（走服务器 /api/me/paypassword/verify 真校验）
     · 验过 → 打勾「支付成功」→ 自动关掉并把结果回调给调用方

   名字/文案/开关全走后台 ui.json（「界面文字」里就能改，不用重新出包）：
     payName = 星言支付      paySub = 指纹 / 面容 · 安全支付
     payCard = 星言钱包      payOn  = 1（0 = 整个关掉，回到原来的支付方式）
   ============================================================ */

enum XYPay {
    /// 支付品牌名（后台可换）
    static var name: String { UIConfig.text("payName", "星言支付") }
    static var sub: String { UIConfig.text("paySub", "指纹 / 面容 · 安全支付") }
    static var cardLine: String { UIConfig.text("payCard", "星言钱包") }
    /// 总开关（0 = 关）
    static var on: Bool { UIConfig.num("payOn", 1) > 0 }

    /// 卡号后四位：按账号算一个稳定的数（同一个号每次都一样，不会乱跳）
    static func tail(_ seed: String) -> String {
        var h = 5381
        for b in seed.utf8 { h = (h &* 33) &+ Int(b) }
        return String(format: "%04d", abs(h) % 10000)
    }
}

/// 星言支付收银台（商城付款 / 转账 / 订单付款都用这一页）
struct XYPaySheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    let amount: Double
    /// 收款方 / 商品名（显示在金额下面）
    var target: String = ""
    /// 一句话说明（比如「发起拼单 · 2 人团」）
    var note: String = ""
    /// 验过之后干什么（下单 / 转账 / 推进订单）
    var onSuccess: () -> Void

    /// 0 = 待验证（指纹/面容）· 1 = 输支付密码 · 2 = 成功
    @State private var stage = 0
    @State private var pwd = ""
    @State private var hint = ""
    @State private var busy = false
    @State private var shake = false
    @State private var noPwd = false
    @FocusState private var focusPwd: Bool

    private var tail: String { XYPay.tail(app.me?.id ?? app.me?.username ?? "xingyan") }

    var body: some View {
        VStack(spacing: 0) {
            bar
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    cardFace
                    amountBlock
                    if stage == 2 { successBlock }
                    else if stage == 1 { pwdBlock }
                    else { verifyBlock }
                    Spacer().frame(height: 4)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
        }
        .background(C.pageBg.ignoresSafeArea())
        .task {
            /* 没设过支付密码：主按钮就走生物识别，密码那一行给个提示 */
            noPwd = !(await API.shared.hasPayPassword())
        }
    }

    /* ---------------- 顶栏 ---------------- */

    private var bar: some View {
        HStack(spacing: 8) {
            Text(XYPay.name).font(pf(17, .semibold)).foregroundColor(C.label)
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(C.subLabel)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .overlay(HairLine(), alignment: .bottom)
    }

    /* ---------------- 卡面（华为支付那张卡的感觉） ---------------- */

    private var cardFace: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x1C1E26), Color(hex: 0x30354A)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    /* 星言支付的**品牌图标**：后台「UI 图标」里给 pay.xy 配了图就用那个
                       （SVG / 图片 / emoji 都行），没配就还是原来那颗金色「星」圆章 —— 
                       也就是说这套图标**不用重新出包**，后台写一条就换掉。 */
                    if let brand = IconOverrides.custom("pay.xy"), !brand.isEmpty {
                        FlexIcon(custom: brand, size: 26,
                                 color: Color(hex: 0xFFE7B0), symbol: "creditcard.fill")
                            .frame(width: 26, height: 26)
                    } else {
                        Text("星")
                            .font(pf(13, .bold)).foregroundColor(Color(hex: 0x3A2B12))
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(LinearGradient(
                                colors: [Color(hex: 0xFFE7B0), Color(hex: 0xD9A94A)],
                                startPoint: .top, endPoint: .bottom)))
                    }
                    Text(XYPay.cardLine).font(pf(13.5, .medium)).foregroundColor(.white)
                    Spacer(minLength: 0)
                    Image(systemName: "wave.3.right").font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.65))
                }
                Spacer(minLength: 0)
                Text("••••  ••••  ••••  " + tail)
                    .font(pf(15.5, .medium)).foregroundColor(.white.opacity(0.94))
                HStack(spacing: 6) {
                    Text(app.me?.nickname ?? app.me?.username ?? "")
                        .font(pf(11.5)).foregroundColor(.white.opacity(0.7)).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(XYPay.sub).font(pf(11)).foregroundColor(.white.opacity(0.55)).lineLimit(1)
                }
                .padding(.top, 6)
            }
            .padding(14)
        }
        .frame(height: 138)
        .shadow(color: .black.opacity(0.16), radius: 12, y: 6)
    }

    /* ---------------- 金额 ---------------- */

    private var amountBlock: some View {
        VStack(spacing: 6) {
            Text(Tr("付款金额")).font(pf(12.5)).foregroundColor(C.subLabel)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("¥").font(pf(20, .semibold)).foregroundColor(C.label)
                Text(moneyFmt(amount)).font(pf(38, .bold)).foregroundColor(C.label)
            }
            if !target.isEmpty {
                Text(target).font(pf(13)).foregroundColor(C.subLabel)
                    .multilineTextAlignment(.center).lineLimit(2)
                    .padding(.horizontal, 20)
            }
            if !note.isEmpty {
                Text(note).font(pf(11.5)).foregroundColor(C.subLabel.opacity(0.85))
            }
        }
        .padding(.top, 4)
    }

    /* ---------------- 验证（主：生物识别；兜底：支付密码） ---------------- */

    private var verifyBlock: some View {
        VStack(spacing: 10) {
            Button { facePay() } label: {
                HStack(spacing: 8) {
                    Image(systemName: Biometrics.available ? "faceid" : "lock.shield.fill")
                        .font(.system(size: 17))
                    Text(busy ? Tr("正在验证…") : Tr(Biometrics.label + "支付"))
                        .font(pf(16, .medium))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity).frame(height: 50)
                .background(RoundedRectangle(cornerRadius: 25).fill(LinearGradient(
                    colors: [Color(hex: 0x2B2F3E), Color(hex: 0x171922)],
                    startPoint: .leading, endPoint: .trailing)))
            }
            .buttonStyle(.plain)
            .disabled(busy)

            Button {
                if noPwd { hint = Tr("你还没设支付密码：我 → 设置 → 账号与安全 → 支付密码") ; return }
                withAnimation(.easeOut(duration: 0.18)) { stage = 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { focusPwd = true }
            } label: {
                Text(Tr("用支付密码支付")).font(pf(14.5)).foregroundColor(C.label)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 22).fill(C.cardBg))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(C.hairline, lineWidth: 0.6))
            }
            .buttonStyle(.plain)

            if !hint.isEmpty {
                Text(hint).font(pf(12.5)).foregroundColor(C.red)
                    .multilineTextAlignment(.center).padding(.horizontal, 12)
            }
            Text(Tr("这是演示环境，不会真的扣钱。")).font(pf(11.5)).foregroundColor(C.subLabel)
        }
    }

    private var pwdBlock: some View {
        VStack(spacing: 12) {
            HStack(spacing: 9) {
                ForEach(0..<6, id: \.self) { i in
                    Circle()
                        .fill(i < pwd.count ? C.label : C.subLabel.opacity(0.35))
                        .frame(width: 11, height: 11)
                        .frame(width: 42, height: 46)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(C.cardBg))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(bad ? C.red : C.hairline, lineWidth: 0.6))
                }
            }
            .offset(x: shake ? -8 : 0)
            .animation(.default, value: shake)
            /* 真正吃输入的是这个看不见的输入框（numberPad），上面那 6 个点是画出来的 */
            TextField("", text: $pwd)
                .keyboardType(.numberPad)
                .focused($focusPwd)
                .opacity(0.01)
                .frame(height: 1)
                .onChange(of: pwd) { v in
                    let t = String(v.filter { $0.isNumber }.prefix(6))
                    if t != v { pwd = t }
                    hint = ""
                    if t.count == 6 { checkPwd(t) }
                }
            if !hint.isEmpty {
                Text(hint).font(pf(12.5)).foregroundColor(C.red)
            }
            Button { pwd = ""; withAnimation { stage = 0 } } label: {
                Text(Tr("换指纹/面容支付")).font(pf(13.5)).foregroundColor(C.subLabel)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 2)
    }

    private var bad: Bool { hint.contains("不对") || hint.contains("不正确") }

    /// 验过了：打勾 + 支付成功（0.7 秒后自动关掉）
    private var successBlock: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Color(hex: 0x1CA36B)).frame(width: 62, height: 62)
                Image(systemName: "checkmark")
                    .font(.system(size: 26, weight: .bold)).foregroundColor(.white)
            }
            Text(Tr("支付成功")).font(pf(17, .semibold)).foregroundColor(C.label)
            Text("¥" + moneyFmt(amount)).font(pf(13.5)).foregroundColor(C.subLabel)
        }
        .padding(.top, 8)
    }

    /* ---------------- 验证 / 成功 ---------------- */

    private func facePay() {
        guard !busy else { return }
        busy = true
        hint = ""
        Task {
            let r = await Biometrics.authenticate(reason: "验证身份，支付 ¥" + moneyFmt(amount))
            busy = false
            if r.ok { success() }
            else if !r.message.isEmpty { hint = r.message }
        }
    }

    private func checkPwd(_ code: String) {
        guard !busy else { return }
        busy = true
        Task {
            do {
                try await API.shared.verifyPayPassword(code)
                busy = false
                success()
            } catch {
                busy = false
                shake.toggle()
                hint = (error as? APIError)?.errorDescription ?? Tr("支付密码不正确")
                pwd = ""
            }
        }
    }

    private func success() {
        withAnimation(.easeOut(duration: 0.2)) { stage = 2 }
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            onSuccess()
            dismiss()
        }
    }
}
