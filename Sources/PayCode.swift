import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/* ============================================================
   收付款（微信那套：我 → 服务 → 收付款）
   · 付款码：18 位数字条码 + 同一串数字的二维码，60 秒一换（微信也是 60 秒）
     —— 别人扫它 = 我付钱给他（商家扫顾客那个逻辑）
   · 收款码：我的一张固定二维码，扫了给我付钱；「设置金额」出来的那张带金额
     （金额由服务器签名，改一个数字就作废）
   · 钱当时到账：不挂「待收款」，和微信商家收款一样即时到账、即时记流水
   ============================================================ */

/* ---------------------------------------------------------- 条形码（Code128） */

/// 系统自带的 Code128 生成器（不用自己抄码表），渲染成图片显示
func code128Image(_ text: String, height: CGFloat) -> UIImage? {
    let data = text.data(using: .ascii) ?? Data()
    let filter = CIFilter.code128BarcodeGenerator()
    filter.message = data
    filter.quietSpace = 2
    guard let out = filter.outputImage else { return nil }
    let scale = 6.0
    let scaled = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let ctx = CIContext()
    guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
    /* 只要黑条，高度我们自己控；中间一片白就裁掉 */
    let img = UIImage(cgImage: cg)
    let drawH = max(40, height)
    let size = CGSize(width: img.size.width, height: drawH)
    let r = UIGraphicsImageRenderer(size: size)
    return r.image { _ in
        UIColor.white.setFill()
        UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        /* 条形码原图是白底黑条，高度不够时非等比拉伸会变形 —— 这里按行取中间那条黑色细带 */
        img.draw(in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
    }
}

struct BarcodeView: View {
    let text: String
    var height: CGFloat = 76

    var body: some View {
        if let img = code128Image(text, height: height) {
            Image(uiImage: img)
                .resizable()
                .interpolation(.none)
                .frame(height: height)
                .frame(maxWidth: .infinity)
        } else {
            Rectangle().fill(Color(hex: 0xEDEDED)).frame(height: height)
        }
    }
}

/* ---------------------------------------------------------- 付款码（收付款首页） */

struct PayCodePage: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var info: PayCodeInfo?
    @State private var left = 0                 // 还剩几秒换码
    @State private var loading = true
    @State private var failed = ""
    @State private var showReceive = false

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("收付款"), back: { dismiss() }) {
                Button { Task { await load(force: true) } } label: {
                    Text(Tr("刷新"))
                        .font(pf(16))
                        .foregroundColor(C.label)
                        .frame(height: L.navH)
                        .padding(.trailing, 16)
                }
                .buttonStyle(.plain)
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    codeCard
                    receiveButton
                    Text(Tr("付款码只用于向商家付款，请勿泄露给陌生人；60 秒自动更换，付过一次就作废。"))
                        .font(pf(12.5))
                        .foregroundColor(C.subLabel)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 34)
                        .padding(.top, 6)
                }
                .padding(.bottom, 26)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        /* 付款码是给收银台扫的：进来渐亮、退出还原 */
        .modifier(BrightenScreen())
        .sheet(isPresented: $showReceive) { ReceiveCodePage().environmentObject(app) }
        .task { await load(force: false) }
        .onReceive(ticker) { _ in
            guard info != nil else { return }
            if left <= 1 { Task { await load(force: true) } }
            else { left -= 1 }
        }
        /* 回到前台：码可能已经过期了，立刻换一张 */
        .onChange(of: scenePhase) { p in
            if p == .active { Task { await load(force: false) } }
        }
    }

    private var codeCard: some View {
        VStack(spacing: 0) {
            if let info = info {
                BarcodeView(text: info.code ?? "", height: 78)
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                Text(info.grouped ?? "")
                    .font(.system(size: 17, weight: .medium, design: .monospaced))
                    .foregroundColor(C.label)
                    .padding(.top, 8)
                if !(info.rows ?? []).isEmpty {
                    QRCanvas(rows: info.rows ?? [])
                        .frame(width: 196, height: 196)
                        .padding(.top, 16)
                }
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                    Text(left > 0 ? Tr("\(left) 秒后自动更换") : Tr("正在更换…"))
                        .font(pf(12))
                }
                .foregroundColor(C.subLabel)
                .padding(.top, 12)
                .padding(.bottom, 20)
            } else if loading {
                ProgressView().padding(.vertical, 60)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 26))
                        .foregroundColor(Color(hex: 0xE5A54D))
                    Text(failed.isEmpty ? Tr("付款码加载失败，点上面「刷新」再来一次") : failed)
                        .font(pf(14))
                        .foregroundColor(C.subLabel)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 46)
            }
        }
        .frame(maxWidth: .infinity)
        .background(C.cardBg)
        .padding(.horizontal, 8)
        .padding(.top, 12)
    }

    private var receiveButton: some View {
        Button { showReceive = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "qrcode")
                    .font(.system(size: 17, weight: .medium))
                Text(Tr("二维码收款"))
                    .font(pf(17, .medium))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.75))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 18)
            .frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(C.green))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    private func load(force: Bool) async {
        if info == nil { loading = true }
        do {
            let got = try await API.shared.payCode()
            info = got
            left = max(1, got.seconds ?? 60)
            failed = ""
        } catch {
            if info == nil { failed = (error as? APIError)?.errorDescription ?? Tr("付款码加载失败") }
        }
        loading = false
    }
}

/* ---------------------------------------------------------- 收款码 */

struct ReceiveCodePage: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var info: PayCodeInfo?
    @State private var amountText = ""
    @State private var showSetAmount = false
    @State private var busy = false

    /// 当前这张收款码带没带金额（0 = 普通收款码）
    private var amt: Double { max(0, info?.amount ?? 0) }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("二维码收款"), back: { dismiss() })

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12).fill(Color.white)
                        if let info = info, let rows = info.rows, !rows.isEmpty {
                            /* 中间不盖头像：这套二维码是纠错 L（只能容忍 7% 破损），
                               盖头像等于让码扫不出来（个人码踩过这个坑）。 */
                            QRCanvas(rows: rows).frame(width: 232, height: 232)
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(width: 260, height: 260)
                    .shadow(color: Color.black.opacity(0.08), radius: 12, y: 4)

                    if let a = info?.amount, a > 0 {
                        VStack(spacing: 2) {
                            Text(money(a))
                                .font(pfMoney(26))
                                .foregroundColor(C.label)
                            Text(Tr("对方扫码后按这个金额付给你，改不了"))
                                .font(pf(12.5))
                                .foregroundColor(C.subLabel)
                        }
                    }

                    HStack(spacing: 12) {
                        Avatar(path: info?.user?.avatar ?? app.me?.avatar ?? "", size: 46, radius: 6)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(info?.user?.nickname ?? app.me?.nickname ?? "")
                                .font(pf(16, .medium)).foregroundColor(C.label).lineLimit(1)
                            Text(Tr("扫这张码就能给我付钱"))
                                .font(pf(12.5)).foregroundColor(C.subLabel)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(C.cardBg)
                    .padding(.horizontal, 8)

                    VStack(spacing: 0) {
                        row(Tr("设置金额"), amt > 0 ? Tr("改一下") : Tr("填一个数，扫码的人直接按这个付")) {
                            amountText = (info?.amount ?? 0) > 0 ? String(format: "%.2f", info?.amount ?? 0) : ""
                            showSetAmount = true
                        }
                        if amt > 0 {
                            HairLine(inset: 16)
                            row(Tr("清除金额"), Tr("回到普通收款码")) {
                                Task { await load(amount: 0) }
                            }
                        }
                    }
                    .background { CardGlassBox(radius: 8) }
                    .padding(.horizontal, 8)

                    Text(Tr("收款码长期有效；带金额的那种 24 小时后失效，重新设置一次就行。"))
                        .font(pf(12.5))
                        .foregroundColor(C.subLabel)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 34)
                        .padding(.top, 4)
                }
                .padding(.top, 14)
                .padding(.bottom, 26)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        /* 收款码也是给人扫的：进来渐亮、退出还原（和「我的二维码」一样） */
        .modifier(BrightenScreen())
        .task { await load(amount: 0) }
        .alert(Tr("设置金额"), isPresented: $showSetAmount) {
            TextField(Tr("金额"), text: $amountText).keyboardType(.decimalPad)
            Button(Tr("确定")) {
                let v = Double(amountText.trimmingCharacters(in: .whitespaces)) ?? 0
                Task { await load(amount: v) }
            }
            Button(Tr("取消"), role: .cancel) { }
        } message: {
            Text(Tr("填了金额以后，对方扫这张码就直接按这个数付给你（24 小时内有效）"))
        }
    }

    private func row(_ title: String, _ sub: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(pf(16)).foregroundColor(C.label)
                    Text(sub).font(pf(12.5)).foregroundColor(C.subLabel)
                }
                Spacer(minLength: 0)
                Chevron(size: 9, line: 1.6)
            }
            .padding(.horizontal, 16)
            .frame(height: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func load(amount: Double) async {
        do {
            info = try await API.shared.receiveCode(amount: amount)
        } catch {
            app.show((error as? APIError)?.errorDescription ?? Tr("收款码加载失败"))
        }
    }
}

/* ---------------------------------------------------------- 扫到码之后：确认付款 */

struct PayConfirmPage: View {
    let target: PayScanInfo
    /// 扫进来的原文（带回服务器，金额和收款人都以服务器解析的为准）
    var scanText: String = ""

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var amountText = ""
    @State private var password = ""
    @State private var hasPwd = true
    @State private var busy = false
    @State private var hint = ""
    @FocusState private var amountFocus: Bool
    @FocusState private var pwdFocus: Bool

    private var fixedAmount: Double { max(0, target.amount ?? 0) }
    private var amount: Double {
        fixedAmount > 0 ? fixedAmount : (Double(amountText.trimmingCharacters(in: .whitespaces)) ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("付款"), back: { dismiss() })

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    VStack(spacing: 8) {
                        Avatar(path: target.user?.avatar ?? "", size: 58, radius: 8)
                        Text(Tr("向 ") + (target.user?.nickname ?? Tr("对方")) + Tr(" 付款"))
                            .font(pf(16, .medium)).foregroundColor(C.label)
                        Text(target.kind == "pay" ? Tr("扫的是对方的付款码") : Tr("扫的是对方的收款码"))
                            .font(pf(12.5)).foregroundColor(C.subLabel)
                    }
                    .padding(.top, 22)

                    if fixedAmount > 0 {
                        Text(money(fixedAmount))
                            .font(pfMoney(34))
                            .foregroundColor(C.label)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("¥").font(pf(22)).foregroundColor(C.label)
                            TextField("0.00", text: $amountText)
                                .keyboardType(.decimalPad)
                                .font(pfMoney(30))
                                .foregroundColor(C.label)
                                .focused($amountFocus)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 62)
                        .background { CardGlassBox(radius: 8) }
                        .padding(.horizontal, 8)
                    }

                    if hasPwd {
                        VStack(spacing: 10) {
                            Text(Tr("请输入支付密码"))
                                .font(pf(13.5)).foregroundColor(C.subLabel)
                            /* 统一用支付页那套 6 格 */
                            PayDotField(count: password.count, height: 46)
                                .contentShape(Rectangle())
                                .onTapGesture { pwdFocus = true }
                            TextField("", text: $password)
                                .keyboardType(.numberPad)
                                .focused($pwdFocus)
                                .frame(width: 1, height: 1)
                                .opacity(0.01)
                                .onChange(of: password) { v in
                                    let clean = String(v.filter { $0.isNumber }.prefix(6))
                                    if clean != v { password = clean }
                                }
                        }
                    } else {
                        /* 没设过支付密码：先去设，别让人不输密码就把钱付出去 */
                        Text(Tr("还没设置支付密码（我 → 设置 → 账号与安全 → 支付密码）"))
                            .font(pf(12.5)).foregroundColor(C.subLabel)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }

                    if !hint.isEmpty {
                        Text(hint)
                            .font(pf(13.5))
                            .foregroundColor(Color(hex: 0xE5484D))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }

                    Button { Task { await pay() } } label: {
                        HStack(spacing: 6) {
                            if busy { ProgressView().tint(.white) }
                            Text(busy ? Tr("付款中…") : Tr("确认付款"))
                                .font(pf(17, .medium))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(amount > 0 ? C.green : C.green.opacity(0.5)))
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .padding(.horizontal, 8)

                    Text(Tr("付出去的钱当时到对方账上，不能撤回。"))
                        .font(pf(12.5))
                        .foregroundColor(C.subLabel)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }
                .padding(.bottom, 26)
            }
            .background(C.pageBg)
        }
        /* 付款中：屏幕正中三个点（微信付款时那一下过渡） */
        .overlay {
            if busy { PayBusyOverlay(text: "正在付款") }
        }
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .task {
            hasPwd = await API.shared.hasPayPassword()
            if fixedAmount <= 0 { amountFocus = true } else if hasPwd { pwdFocus = true }
        }
    }

    private func pay() async {
        hint = ""
        guard amount > 0 else { hint = Tr("请输入金额"); return }
        if hasPwd && password.count < 6 { hint = Tr("请输入 6 位支付密码"); return }
        busy = true
        defer { busy = false }
        do {
            let res = try await API.shared.payCollect(
                text: codeText, amount: amount, password: password, face: false)
            app.show(Tr("已付款 ") + money(res.amount ?? amount) + Tr(" 给 ") + (res.payee?.nickname ?? Tr("对方")))
            app.me = try? await API.shared.me()
            await app.loadChats()
            dismiss()
        } catch {
            hint = (error as? APIError)?.errorDescription ?? Tr("付款失败")
        }
    }

    /// 扫进来的原文再带回服务器（金额、收款人都以服务器解析出来的为准，客户端改不了）
    private var codeText: String { scanText }
}
