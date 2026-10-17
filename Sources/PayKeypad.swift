import SwiftUI
import UIKit
import AudioToolbox

/* ============================================================
   统一的支付密码键盘

   App 里所有要输支付密码的地方（转账 / 红包 / 充值提现 / 付款码 /
   开会员 / 设支付密码）都用这一套：
     · 六个格子：一张卡里分 6 格（细分割线），输入的点是实心黑点 ——
       银行 App / 微信支付都是这个样子，比 6 张圆角小卡片"正规"
     · 键盘：**安全键盘** —— 每次弹出来 0~9 的位置都重新打乱（防偷看、
       防记位置），按键是平的细网格（银行那套），按下去整格变灰
     · 手感：每按一下轻震；密码错了整排左右抖 + 错误震动
   ============================================================ */

struct PayKeypadView: View {
    var busy: Bool = false
    var keyHeight: CGFloat = 54
    /// 安全键盘：数字位置随机（银行的做法）。后台/调用方想固定顺序传 false 就行
    var secure: Bool = true
    /// 左下角那颗键换成小数点「.」（微信转账页输金额的键盘就是这样）
    var dot: Bool = false
    var onKey: (String) -> Void

    /// 10 个数字的位置（每次出现都重新打乱）
    @State private var digits: [String] = (0...9).map { String($0) }

    static func shuffledDigits() -> [String] {
        var d = (0...9).map { String($0) }
        d.shuffle()
        return d
    }

    /// 第 r 行第 c 列那个键：3×3 放前 9 个数字，最后一行是「空 · 第 10 个数字 · 删除」
    private func key(_ r: Int, _ c: Int) -> String {
        if r == 3 {
            /* 左下角：金额键盘放小数点，密码键盘留白（那儿放「安全键盘」小字） */
            if c == 0 { return dot ? "." : "" }
            if c == 1 { return digits.count > 9 ? digits[9] : "0" }
            return "⌫"
        }
        let i = r * 3 + c
        return i < digits.count ? digits[i] : ""
    }

    var body: some View {
        VStack(spacing: 0.5) {
            /* 四行写死（新 SDK 下带捕获的嵌套 ForEach 会把类型推崩，B631 那次编译
               就是栽在这儿），12 个格子没必要动态生成 */
            keyRow(0)
            keyRow(1)
            keyRow(2)
            keyRow(3)
        }
        /* 缝隙露出来的就是分割线：整体铺一层"线色"，每格自己盖一层"底色" */
        .background(C.hairline)
        /* ⚠ 真实感的关键：支付键盘是**通屏**的 —— 左右不留边、外面不套圆角卡片，
           只有键与键之间的细线。以前是"带圆角边框、左右各缩进 14"的一张小卡片，
           看着就不像系统/微信那种支付键盘。 */
        .overlay(alignment: .top) {
            Rectangle().fill(C.hairline).frame(height: 0.5)   // 和上面输入区之间那条分割线
        }
        .onAppear {
            /* 安全键盘才打乱；金额键盘用 1…9、0 的正常顺序 */
            digits = secure ? Self.shuffledDigits() : (0...9).map { String($0) }
        }
    }

    private func keyRow(_ r: Int) -> some View {
        HStack(spacing: 0.5) {
            keyCell(key(r, 0))
            keyCell(key(r, 1))
            keyCell(key(r, 2))
        }
    }

    /// 一个按键：空格子放「安全键盘」标识（左下角），其余是数字/删除
    @ViewBuilder
    private func keyCell(_ key: String) -> some View {
        if key.isEmpty {
            /* 左下角那格：一枚小盾牌 + 「安全键盘」（银行 App 都在这儿标一下） */
            VStack(spacing: 2) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 11))
                Text(Tr("安全键盘"))
                    .font(pf(9.5))
            }
            .foregroundColor(C.subLabel.opacity(0.75))
            .frame(maxWidth: .infinity)
            .frame(height: keyHeight)
            .background(C.cardBg)
            .allowsHitTesting(false)
        } else {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                /* 真键盘那一下"嗒"：iOS 的键盘点击音（跟静音开关走，静音时不响）。
                   不想要就把后台 ui.json 里的 payKeySound 写成 0。 */
                if UIConfig.num("payKeySound", 1) > 0 { AudioServicesPlaySystemSound(1104) }
                onKey(key)
            } label: {
                Group {
                    if key == "⌫" {
                        Image(systemName: "delete.left")
                            .font(.system(size: 22, weight: .regular))
                    } else {
                        Text(key).font(.system(size: 26, weight: .regular))
                    }
                }
                .foregroundColor(C.label)
                .frame(maxWidth: .infinity)
                .frame(height: keyHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(BankKeyStyle())
            .disabled(busy)
        }
    }
}

/// 六个密码格：一整张卡分 6 格 + 实心圆点（微信支付 / 银行 App 都是这个样式）
struct PayDotField: View {
    var count: Int
    var total: Int = 6
    var shake: CGFloat = 0
    var busy: Bool = false
    var height: CGFloat = 54

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<total, id: \.self) { i in
                ZStack {
                    if count > i {
                        Circle()
                            .fill(C.label)
                            .frame(width: 11, height: 11)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: height)
                if i < total - 1 {
                    Rectangle().fill(C.hairline).frame(width: 0.7, height: height)
                }
            }
        }
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .stroke(C.hairline, lineWidth: 0.8))
        /* 输错密码时整排左右抖（和微信一样） */
        .padding(.horizontal, 20)
        .offset(x: shake)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: count)
    }
}

/// 密码错了：错误震动 + 六个格子左右抖一下（所有支付页共用这一下）
@MainActor
func payShake(_ shake: Binding<CGFloat>) {
    UINotificationFeedbackGenerator().notificationOccurred(.error)
    withAnimation(.easeOut(duration: 0.06)) { shake.wrappedValue = -12 }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.35)) { shake.wrappedValue = 0 }
    }
}

/// 支付键盘按键的手感：按下去轻微缩小 + 变淡
struct KeyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// 安全键盘那套按键手感（银行 App）：按下去整格变灰，不缩放、不加阴影
struct BankKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.dyn(0xD1D1D6, 0x3A3A3C) : C.cardBg)
    }
}

/// 支付中那三个点：一个接一个亮起来（微信付款时屏幕中间就是这一下）
struct PayDots: View {
    var color: Color = .white
    var size: CGFloat = 9
    @State private var phase = 0
    private let tick = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
                    .opacity(phase == i ? 1 : 0.32)
                    .scaleEffect(phase == i ? 1.12 : 0.85)
            }
        }
        .onReceive(tick) { _ in
            withAnimation(.easeInOut(duration: 0.18)) { phase = (phase + 1) % 3 }
        }
    }
}

/// 付钱的时候屏幕正中盖一层：三个点 + 文案（微信那种"跳一下"的过渡）。
/// 以前是把按钮文字改成「正在付…」，字一变整排就跳，所以改成盖这层；按钮文案不动。
struct PayBusyOverlay: View {
    var text: String = "正在支付"

    var body: some View {
        ZStack {
            Color.black.opacity(0.12).ignoresSafeArea()
            VStack(spacing: 14) {
                PayDots()
                Text(text)
                    .font(pf(13.5, .medium))
                    .foregroundColor(.white)
            }
            .frame(width: 118, height: 118)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.76)))
            .shadow(color: Color.black.opacity(0.22), radius: 20, y: 8)
        }
        .transition(.opacity)
    }
}
