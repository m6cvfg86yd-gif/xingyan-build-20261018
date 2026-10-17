import SwiftUI

/* ============================================================
   未成年人模式 / 关怀模式（微信「设置」里那两项）

   未成年人模式（照微信官方帮助中心那套流程）：
     我 → 设置 → 未成年人模式 → **阅读条款** → 「开启」→ **设置独立密码** →
     **邀请家长为监护人**（这三步就是那"两层"：密码 + 监护人）
     · 开了以后：「我」页会挂一把**小雨伞**；完全不可访问的：视频号、直播、游戏、
       附近的人、摇一摇、搜一搜；微信支付可以按需调整
     · 关闭 / 改设置 / 换监护人：都要独立密码
     · 服务端（/api/me/teen）真的会把这些接口挡住，不是只改界面

   关怀模式（照微信）：文字更大、色彩更强、按钮更大；还能开「听文字消息」——
     开启后点一下聊天里的文字消息就念出来。
   ============================================================ */

/* ---------------------------------------------------------- 未成年人模式 */

/// 一把小雨伞（未成年人模式的标志：微信里开了青少年/未成年人模式，
/// 「我」页上就会挂这么一把）。**自己画**，不依赖系统 SF Symbols 里有没有伞，
/// 哪台手机、哪个系统版本都是一样的形状。
struct UmbrellaIcon: View {
    var color: Color
    var size: CGFloat = 24

    var body: some View {
        Canvas { ctx, sz in
            let w = sz.width, h = sz.height
            let domeH = h * 0.56
            /* 伞面：一条弧 + 下沿的波浪 */
            var dome = Path()
            dome.move(to: CGPoint(x: 0, y: domeH))
            dome.addQuadCurve(to: CGPoint(x: w, y: domeH),
                              control: CGPoint(x: w / 2, y: -domeH * 0.75))
            dome.addQuadCurve(to: CGPoint(x: w * 0.75, y: domeH),
                              control: CGPoint(x: w * 0.875, y: domeH + h * 0.10))
            dome.addQuadCurve(to: CGPoint(x: w * 0.50, y: domeH),
                              control: CGPoint(x: w * 0.625, y: domeH + h * 0.10))
            dome.addQuadCurve(to: CGPoint(x: w * 0.25, y: domeH),
                              control: CGPoint(x: w * 0.375, y: domeH + h * 0.10))
            dome.addQuadCurve(to: CGPoint(x: 0, y: domeH),
                              control: CGPoint(x: w * 0.125, y: domeH + h * 0.10))
            dome.closeSubpath()
            ctx.fill(dome, with: .color(color))
            /* 伞柄（底下带个小弯钩） */
            var stick = Path()
            stick.move(to: CGPoint(x: w / 2, y: domeH - h * 0.04))
            stick.addLine(to: CGPoint(x: w / 2, y: h * 0.84))
            stick.addQuadCurve(to: CGPoint(x: w * 0.33, y: h * 0.82),
                               control: CGPoint(x: w * 0.35, y: h * 0.99))
            ctx.stroke(stick, with: .color(color),
                       style: StrokeStyle(lineWidth: max(1.4, w * 0.075), lineCap: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct TeenModeView: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var cfg: API.TeenStatus?
    @State private var loading = true
    /// 要独立密码才能做的事
    @State private var ask: Ask?
    @State private var pin = ""
    @State private var showSetup = false
    @State private var showGuardian = false
    @State private var guardianDraft = ""
    /// 通过密码校验后的那一串（换监护人时保存要用）
    @State private var guardianPin = ""

    private enum Ask: Equatable { case close, guardian, pay(Bool) }

    /// 微信里「启用后完全不可访问」的那几项
    private let blocked: [(String, String)] = [
        ("feed", "视频号"), ("live", "直播"), ("games", "游戏"),
        ("nearby", "附近的人"), ("shake", "摇一摇"), ("search", "搜一搜")
    ]

    private var on: Bool { cfg?.enabled ?? false }
    private var hasPin: Bool { cfg?.hasPin ?? false }
    private var payAllowed: Bool { ((cfg?.scopes ?? [:])["pay"] ?? 0) != 0 }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("未成年人模式"), back: { dismiss() })
            if loading {
                ProgressView().padding(.top, 60)
                Spacer(minLength: 0)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        if on { onPage } else { offPage }
                        Color.clear.frame(height: 30)
                    }
                }
                .background(C.pageBg)
            }
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { await load() }
        /* 开启向导：条款 → 独立密码 → 邀请监护人（微信就是这三步） */
        .fullScreenCover(isPresented: $showSetup) {
            TeenSetupWizard { await load() }
                .environmentObject(app)
        }
        /* 换监护人 */
        .sheet(isPresented: $showGuardian) { guardianSheet }
        .alert(Tr("输入独立密码"), isPresented: Binding(
            get: { ask != nil },
            set: { if !$0 { ask = nil; pin = "" } }
        )) {
            TextField(Tr("4 位数字"), text: $pin).keyboardType(.numberPad)
            Button(Tr("取消"), role: .cancel) { ask = nil; pin = "" }
            Button(Tr("确定")) { confirm() }
        } message: {
            Text(Tr("未成年人模式的开关和设置都要这个密码"))
        }
    }

    /* ---------------- 没开启：说明 + 开启 ---------------- */

    private var offPage: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                UmbrellaIcon(color: Color(hex: 0x3E9BF0), size: 58)
                Text(Tr("未成年人模式"))
                    .font(pf(20, .semibold)).foregroundColor(C.label)
                Text(Tr("开启后，视频号、直播、游戏、附近的人、摇一摇、搜一搜将不可访问；\n微信支付、公众号、小程序可以按需要调整。"))
                    .font(pf(13.5)).foregroundColor(C.subLabel)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.top, 34)
            .padding(.bottom, 26)

            GroupCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Tr("开启流程")).font(pf(15, .medium)).foregroundColor(C.label)
                    Text(Tr("① 阅读并同意使用条款\n② 设置一个 4 位独立密码（之后开关都要它）\n③ 邀请家长账号作为监护人"))
                        .font(pf(13.5)).foregroundColor(C.subLabel)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .padding(.horizontal, 12)

            Button { showSetup = true } label: {
                Text(Tr("开启未成年人模式"))
                    .font(pf(17, .medium)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(C.green))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 22)

            Text(Tr("忘了独立密码：可以让监护人在「监护人」里帮你重置。"))
                .font(pf(12.5)).foregroundColor(C.subLabel)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28).padding(.top, 14)
        }
    }

    /* ---------------- 已开启：管理页 ---------------- */

    private var onPage: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                UmbrellaIcon(color: Color(hex: 0x3E9BF0), size: 44)
                Text(Tr("未成年人模式已开启"))
                    .font(pf(18, .semibold)).foregroundColor(C.label)
                Text(Tr("「我」页会显示一把小雨伞"))
                    .font(pf(12.5)).foregroundColor(C.subLabel)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)

            GroupCard {
                row(Tr("监护人"),
                    (cfg?.guardianPhone?.isEmpty == false) ? (cfg!.guardianPhone!) : Tr("未设置"),
                    chevron: true) {
                    askPin(.guardian)
                }
                HairLine(inset: 16)
                row(Tr("使用时长"), Tr("每天 40 分钟"), chevron: false) { }
                HairLine(inset: 16)
                row(Tr("宵禁"), Tr("22:00 - 次日 6:00 需监护人授权"), chevron: false) { }
            }
            .padding(.horizontal, 12)

            VStack(alignment: .leading, spacing: 0) {
                Text(Tr("不可访问"))
                    .font(pf(13)).foregroundColor(C.subLabel)
                    .padding(.horizontal, 8).padding(.top, 16).padding(.bottom, 6)
                GroupCard {
                    ForEach(Array(blocked.enumerated()), id: \.offset) { idx, it in
                        if idx > 0 { HairLine(inset: 16) }
                        HStack {
                            Text(Tr(it.1)).font(pf(16)).foregroundColor(C.label)
                            Spacer(minLength: 8)
                            Text(Tr("已限制")).font(pf(14)).foregroundColor(C.subLabel)
                        }
                        .padding(.horizontal, 16).frame(height: 50)
                    }
                }
            }
            .padding(.horizontal, 12)

            VStack(alignment: .leading, spacing: 0) {
                Text(Tr("可以按需要调整"))
                    .font(pf(13)).foregroundColor(C.subLabel)
                    .padding(.horizontal, 8).padding(.top, 16).padding(.bottom, 6)
                GroupCard {
                    HStack {
                        Text(Tr("微信支付")).font(pf(16)).foregroundColor(C.label)
                        Spacer(minLength: 8)
                        Toggle("", isOn: Binding(
                            get: { payAllowed },
                            set: { v in askPin(.pay(v)) }
                        )).labelsHidden().tint(C.green)
                    }
                    .padding(.horizontal, 16).frame(height: 54)
                }
            }
            .padding(.horizontal, 12)

            Button { askPin(.close) } label: {
                Text(Tr("关闭未成年人模式"))
                    .font(pf(16)).foregroundColor(C.red)
                    .frame(maxWidth: .infinity).frame(height: 50)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.top, 22)

            Text(Tr("关闭、改设置、换监护人都要独立密码；忘了可以让监护人在后台重置。"))
                .font(pf(12.5)).foregroundColor(C.subLabel)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28).padding(.top, 10)
        }
    }

    private func row(_ title: String, _ value: String, chevron: Bool,
                     _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 8) {
                Text(title).font(pf(16)).foregroundColor(C.label)
                Spacer(minLength: 8)
                Text(value).font(pf(14.5)).foregroundColor(C.subLabel).lineLimit(1)
                if chevron { Chevron(size: 8, line: 1.5) }
            }
            .padding(.horizontal, 16).frame(height: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /* ---------------- 换监护人 ---------------- */

    private var guardianSheet: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("监护人"), back: { showGuardian = false }) {
                Button { Task { await saveGuardian() } } label: {
                    Text(Tr("保存")).font(pf(16)).foregroundColor(C.green).padding(.trailing, 16)
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(Tr("监护人的手机号")).font(pf(15)).foregroundColor(C.label)
                TextField(Tr("填家长手机号"), text: $guardianDraft)
                    .font(pf(16))
                    .keyboardType(.numberPad)
                    .padding(.horizontal, 12).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(C.searchBg))
                Text(Tr("只保存脱敏后的号码（如 138****8888），不会外发。"))
                    .font(pf(12)).foregroundColor(C.subLabel)
            }
            .padding(16)
            .background { CardGlassBox(radius: 14) }
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(C.hairline, lineWidth: 0.6))
            .padding(.horizontal, 14).padding(.top, 10)
            Spacer(minLength: 0)
        }
        .background(C.pageBg.ignoresSafeArea())
        /* 2026-10-16：换监护人这一层补左滑返回 */
        .swipeBack { showGuardian = false }
        .onAppear {
            /* 服务端只回脱敏号码，回填不了；这里就让用户重新填一次 */
            guardianDraft = ""
        }
    }

    /* ---------------- 干活 ---------------- */

    private func load() async {
        cfg = try? await API.shared.teen()
        loading = false
    }

    private func askPin(_ what: Ask) {
        guard hasPin else { app.show(Tr("先开启未成年人模式（会设一个独立密码）")); return }
        pin = ""
        ask = what
    }

    private func confirm() {
        let p = pin.trimmingCharacters(in: .whitespaces)
        guard p.count == 4 else { app.show(Tr("密码要 4 位数字")); ask = nil; return }
        guard let what = ask else { return }
        ask = nil
        pin = ""
        Task {
            do {
                switch what {
                case .close:
                    cfg = try await API.shared.teenSet(pin: p, enabled: false, scopes: nil, guardianPhone: nil)
                    app.show(Tr("已关闭未成年人模式"))
                case .guardian:
                    /* 密码对了才让进去改（错密码服务端会回错误） */
                    _ = try await API.shared.teenSet(pin: p, enabled: nil, scopes: nil, guardianPhone: nil)
                    guardianPin = p
                    guardianDraft = ""
                    showGuardian = true
                case .pay(let v):
                    cfg = try await API.shared.teenSet(pin: p, enabled: nil, scopes: ["pay": v ? 1 : 0],
                                                       guardianPhone: nil)
                    app.show(v ? Tr("微信支付已放开") : Tr("微信支付已限制"))
                }
            } catch {
                app.show((error as? LocalizedError)?.errorDescription ?? Tr("操作失败"))
            }
        }
    }

    private func saveGuardian() async {
        let ph = guardianDraft.trimmingCharacters(in: .whitespaces)
        do {
            cfg = try await API.shared.teenSet(pin: guardianPin, enabled: nil, scopes: nil, guardianPhone: ph)
            app.show(ph.isEmpty ? Tr("已清空监护人") : Tr("监护人已保存"))
            showGuardian = false
        } catch {
            app.show((error as? LocalizedError)?.errorDescription ?? Tr("保存失败"))
        }
    }
}

/* ---------------------------------------------------------- 开启向导（条款 → 独立密码 → 监护人） */

struct TeenSetupWizard: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    /// 全部走完以后回调（父页面重新拉一次状态）
    var onDone: () async -> Void

    @State private var step = 0
    @State private var agreed = false
    @State private var pin = ""
    @State private var pin2 = ""
    @State private var phone = ""
    @State private var busy = false
    @State private var error = ""

    private let terms = """
    未成年人模式使用条款

    1. 未成年人模式用于帮助家长管理青少年的使用范围与时长。
    2. 开启后，视频号、直播、游戏、附近的人、摇一摇、搜一搜将不可访问；
       微信支付、公众号、小程序可以按家长需要调整。
    3. 开启后需要设置一个 4 位独立密码，关闭或修改设置都要输入这个密码。
    4. 独立密码只保存在你自己的服务器上（加盐哈希，服务端也看不到原文）。
    5. 忘记密码时，可以由已绑定的监护人在「监护人」里重置。
    """

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("未成年人模式"), back: { dismiss() }) {
                Button { dismiss() } label: {
                    Text(Tr("取消")).font(pf(16)).foregroundColor(C.label).padding(.trailing, 16)
                }
                .buttonStyle(.plain)
            }
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    switch step {
                    case 0: termsStep
                    case 1: pinStep
                    default: guardianStep
                    }
                    Color.clear.frame(height: 24)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    /* 第 1 层：阅读条款 */
    private var termsStep: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                UmbrellaIcon(color: Color(hex: 0x3E9BF0), size: 48)
                Text(Tr("请先阅读并同意使用条款")).font(pf(16, .medium)).foregroundColor(C.label)
            }
            .padding(.top, 20).padding(.bottom, 14)

            Text(terms)
                .font(pf(13.5)).foregroundColor(C.label)
                .lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background { CardGlassBox(radius: 14) }
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(C.hairline, lineWidth: 0.6))
                .padding(.horizontal, 14)

            Button { agreed.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: agreed ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 19))
                        .foregroundColor(agreed ? C.green : C.subLabel)
                    Text(Tr("我已阅读并同意《未成年人模式使用条款》"))
                        .font(pf(14)).foregroundColor(C.label)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.top, 16)

            bigButton(Tr("下一步"), enabled: agreed) { step = 1 }
                .padding(.horizontal, 16).padding(.top, 18)
        }
    }

    /* 第 2 层：设置独立密码 */
    private var pinStep: some View {
        VStack(spacing: 0) {
            Text(Tr("设置独立密码"))
                .font(pf(16, .medium)).foregroundColor(C.label)
                .padding(.top, 22).padding(.bottom, 4)
            Text(Tr("之后关闭未成年人模式、改设置都要输这个密码"))
                .font(pf(13)).foregroundColor(C.subLabel)
                .padding(.bottom, 14)

            GroupCard {
                HStack {
                    Text(Tr("密码")).font(pf(16)).foregroundColor(C.label)
                    Spacer(minLength: 8)
                    secureField($pin)
                }
                .padding(.horizontal, 16).frame(height: 54)
                HairLine(inset: 16)
                HStack {
                    Text(Tr("确认密码")).font(pf(16)).foregroundColor(C.label)
                    Spacer(minLength: 8)
                    secureField($pin2)
                }
                .padding(.horizontal, 16).frame(height: 54)
            }
            .padding(.horizontal, 12)

            if !error.isEmpty {
                Text(error).font(pf(13)).foregroundColor(C.red)
                    .padding(.top, 10)
            }

            bigButton(Tr("下一步"), enabled: pin.count == 4 && pin2.count == 4) {
                guard pin == pin2 else { error = Tr("两次输入的密码不一样"); return }
                error = ""
                step = 2
            }
            .padding(.horizontal, 16).padding(.top, 18)
        }
    }

    /* 第 3 层：邀请监护人 */
    private var guardianStep: some View {
        VStack(spacing: 0) {
            Text(Tr("邀请家长作为监护人"))
                .font(pf(16, .medium)).foregroundColor(C.label)
                .padding(.top, 22).padding(.bottom, 4)
            Text(Tr("填家长的手机号；家长可以帮你重置独立密码"))
                .font(pf(13)).foregroundColor(C.subLabel)
                .padding(.bottom, 14)

            GroupCard {
                HStack {
                    Text(Tr("监护人手机号")).font(pf(16)).foregroundColor(C.label)
                    Spacer(minLength: 8)
                    TextField(Tr("选填"), text: $phone)
                        .font(pf(16)).multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                }
                .padding(.horizontal, 16).frame(height: 54)
            }
            .padding(.horizontal, 12)

            if !error.isEmpty {
                Text(error).font(pf(13)).foregroundColor(C.red).padding(.top, 10)
            }

            bigButton(busy ? Tr("开启中…") : Tr("完成并开启"), enabled: !busy) {
                Task { await finish() }
            }
            .padding(.horizontal, 16).padding(.top, 18)

            Button { phone = ""; Task { await finish() } } label: {
                Text(Tr("先跳过，稍后再邀请"))
                    .font(pf(14.5)).foregroundColor(C.subLabel)
                    .frame(maxWidth: .infinity).frame(height: 44)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
    }

    private func secureField(_ b: Binding<String>) -> some View {
        SecureField(Tr("4 位数字"), text: b)
            .font(pf(16)).multilineTextAlignment(.trailing)
            .keyboardType(.numberPad)
            .frame(width: 110)
    }

    private func bigButton(_ title: String, enabled: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(title)
                .font(pf(17, .medium)).foregroundColor(.white)
                .frame(maxWidth: .infinity).frame(height: 48)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(enabled ? C.green : C.green.opacity(0.4)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// 真正开工：先设密码（服务端会顺手开启），再把监护人写进去
    private func finish() async {
        busy = true
        error = ""
        do {
            _ = try await API.shared.teenSetup(pin: pin)
            let ph = phone.trimmingCharacters(in: .whitespaces)
            if !ph.isEmpty {
                _ = try await API.shared.teenSet(pin: pin, enabled: nil, scopes: nil, guardianPhone: ph)
            }
            await onDone()
            app.show(Tr("未成年人模式已开启"))
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? Tr("开启失败，再试一次")
        }
        busy = false
    }
}

/* ---------------------------------------------------------- 关怀模式 */
struct CareModeView: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var on = CareMode.on
    /// 「听文字消息」（微信关怀模式里的那一项）
    @State private var speak = CareMode.speakText
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("关怀模式"), back: { dismiss() })
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    /* 顶上那三句就是微信的说法：文字更大、色彩更强、按钮更大 */
                    VStack(spacing: 12) {
                        Image(systemName: "figure.wave")
                            .font(.system(size: 48))
                            .foregroundColor(C.green)
                        Text(Tr("关怀模式"))
                            .font(pf(19, .semibold)).foregroundColor(C.label)
                        HStack(spacing: 14) {
                            perk("textformat.size", Tr("文字更大"))
                            perk("paintpalette.fill", Tr("色彩更强"))
                            perk("hand.tap.fill", Tr("按钮更大"))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)

                    GroupCard {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(Tr("开启关怀模式")).font(pf(16)).foregroundColor(C.label)
                                Text(on ? Tr("已开启") : Tr("未开启"))
                                    .font(pf(12.5)).foregroundColor(C.subLabel)
                            }
                            Spacer(minLength: 8)
                            Toggle("", isOn: Binding(
                                get: { on },
                                set: { v in confirm = true; pending = v }
                            )).labelsHidden().tint(C.green)
                        }
                        .padding(.horizontal, 16).frame(height: 54)
                    }
                    .padding(.horizontal, 12)

                    /* 效果预览：开了以后字真的会大一圈（全站字号都被放大） */
                    VStack(spacing: 10) {
                        Text(Tr("效果预览")).font(pf(13)).foregroundColor(C.subLabel)
                        HStack(spacing: 10) {
                            Avatar(path: app.me?.avatarPath ?? "", size: on ? 34 : 30, radius: 5)
                            Text(Tr("这条消息开了关怀模式会更大")) 
                                .font(on ? .system(size: 19) : .system(size: 16))
                                .foregroundColor(C.label)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(C.bubbleOther))
                            Spacer(minLength: 0)
                        }
                        HStack {
                            Text(Tr("通讯录")) 
                                .font(on ? .system(size: 18) : .system(size: 15))
                                .foregroundColor(C.label)
                            Spacer(minLength: 0)
                            Text(Tr("星标朋友"))
                                .font(on ? .system(size: 14) : .system(size: 12))
                                .foregroundColor(C.subLabel)
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .background { CardGlassBox(radius: 14) }
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(C.hairline, lineWidth: 0.6))
                    .padding(.horizontal, 12).padding(.top, 12)

                    /* 听文字消息：微信关怀模式 8.0.16 之后加的，点一下文字消息就念 */
                    GroupCard {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(Tr("听文字消息")).font(pf(16)).foregroundColor(C.label)
                                Text(Tr("开启后，点一下聊天里的文字消息就会读出来"))
                                    .font(pf(12.5)).foregroundColor(C.subLabel)
                            }
                            Spacer(minLength: 8)
                            Toggle("", isOn: Binding(
                                get: { speak },
                                set: { v in
                                    speak = v
                                    CareMode.setSpeak(v)
                                    if v && !on { app.show(Tr("建议把关怀模式一起打开")) }
                                }
                            )).labelsHidden().tint(C.green)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 64)
                    }
                    .padding(.horizontal, 12).padding(.top, 12)

                    VStack(spacing: 6) {
                        Text(Tr("只改这台手机上的显示，不影响别人；关掉就恢复原来的字号。"))
                        Text(Tr("关怀模式由微信首创的适老化设计：文字更大、色彩更强、按钮更大。"))
                    }
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
        /* 微信开/关都会先问一句（它还要重启微信；我们不用重启，立刻生效） */
        .alert(on ? Tr("关闭关怀模式？") : Tr("开启关怀模式？"), isPresented: $confirm) {
            Button(Tr("取消"), role: .cancel) { pending = on }
            Button(Tr("确定")) {
                on = pending
                CareMode.set(on)
                app.show(on ? Tr("关怀模式已开启") : Tr("关怀模式已关闭"))
            }
        } message: {
            Text(on ? Tr("关闭后文字、图标、按钮会恢复原来的大小。")
                    : Tr("开启后文字更大、色彩更强、按钮更大，立刻生效。"))
        }
    }

    @State private var pending = CareMode.on

    private func perk(_ icon: String, _ title: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(C.green)
            Text(title).font(pf(12)).foregroundColor(C.subLabel)
        }
    }
}
