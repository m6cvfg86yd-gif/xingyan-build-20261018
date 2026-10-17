import SwiftUI
import UIKit

/* ============================================================
   会员系统（我们自己的一套，逻辑照 QQ 会员那套）

   · 档位：普通用户 / 会员(VIP) / 超级会员(SVIP)，后台能改名字、价格、倍数
   · 开通：走零钱扣款（要支付密码），也支持后台发的兑换码
   · 权益：升级加速（服务端真生效）、昵称挂会员徽章、名字用会员配色、群人数上限放宽
   · 到期：服务端按到期时间算，过期自动变回普通用户

   这个文件放三样东西：数据模型、MemberStore（拉/开通/续费/兑换）、
   以及到处要用的 MemberBadge（昵称后面那个小徽章）和付钱用的 MemberPaySheet。
   ============================================================ */

struct MemberTier: Decodable, Hashable, Identifiable {
    var id: String
    var name: String
    var short: String?
    var color: String?
    var color2: String?
    var boost: Double?
    var groupMax: Int?
    var price: Price?

    struct Price: Decodable, Hashable {
        var month: Double?
        var quarter: Double?
        var year: Double?
    }

    /// 买 N 个月要多少钱（月/季/年三档单价里挑最划算的，和服务器一个算法）
    func priceOf(_ months: Int) -> Double {
        let p = price ?? Price()
        let unit: Double
        if months >= 12 { unit = (p.year ?? 0) / 12 }
        else if months >= 3 { unit = (p.quarter ?? 0) / 3 }
        else { unit = (p.month ?? 0) }
        return (unit * Double(months) * 100).rounded() / 100
    }
}

struct MemberBenefit: Decodable, Hashable {
    var icon: String?
    var title: String?
    var desc: String?
}

struct MemberMe: Decodable, Hashable {
    var tier: String?
    var name: String?
    var short: String?
    var color: String?
    var color2: String?
    var expireAt: Double?
    var active: Bool?
    var daysLeft: Int?
    var autoRenew: Bool?
    var boost: Double?
    var groupMax: Int?

    var isActive: Bool { active == true && !(tier ?? "").isEmpty }
}

struct MemberHistoryRow: Decodable, Hashable, Identifiable {
    var at: String?
    var tier: String?
    var days: Int?
    var months: Int?
    var price: Double?
    var note: String?
    var id: String { (at ?? "") + "|" + (tier ?? "") + "|" + String(price ?? 0) }
}

struct MemberInfo: Decodable {
    var enabled: Bool?
    var title: String?
    var sub: String?
    var tiers: [MemberTier]?
    var benefits: [MemberBenefit]?
    var me: MemberMe?
    var balance: Double?
    var history: [MemberHistoryRow]?
}

/* ------------------------------------------------------------ 商店 */

@MainActor
final class MemberStore: ObservableObject {
    static let shared = MemberStore()

    @Published var info: MemberInfo?
    @Published var loading = false
    @Published var lastError = ""

    var tiers: [MemberTier] { info?.tiers ?? [] }
    var benefits: [MemberBenefit] { info?.benefits ?? [] }
    var me: MemberMe? { info?.me }
    var active: Bool { info?.me?.isActive == true }
    var balance: Double { info?.balance ?? 0 }

    func refresh() async {
        if loading { return }
        loading = true
        defer { loading = false }
        if let m = try? await API.shared.memberInfo() { info = m }
    }

    /// 开通 / 续费：成功返回 nil，失败返回错误文案
    @discardableResult
    func open(tierId: String, months: Int, payPassword: String) async -> String? {
        let (me, balance, err) = await API.shared.memberOpen(tierId: tierId, months: months, payPassword: payPassword)
        if let err = err { return err }
        if var cur = info {
            if let me = me { cur.me = me }
            if let balance = balance { cur.balance = balance }
            info = cur
        }
        await refresh()
        return nil
    }

    func setAuto(_ on: Bool) async {
        await API.shared.memberAuto(on)
        await refresh()
    }

    @discardableResult
    func redeem(_ code: String) async -> String {
        let (_, msg) = await API.shared.memberRedeem(code)
        await refresh()
        return msg
    }
}

/* ------------------------------------------------------------ 徽章 */

/// 昵称后面那个会员小徽章（普通用户不显示）
struct MemberBadge: View {
    var tier: String?
    var short: String?
    var color: String?
    var color2: String?
    var height: CGFloat = 13

    private var body1: some View {
        let c1 = Color(hexString: (color?.isEmpty == false ? color! : "#E0B44A"))
        let c2 = Color(hexString: (color2?.isEmpty == false ? color2! : "#B8862A"))
        return Text((short?.isEmpty == false) ? short! : "VIP")
            .font(pf(max(7.5, height * 0.58), .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, height * 0.28)
            .frame(height: height)
            .background(Capsule().fill(LinearGradient(colors: [c1, c2],
                                                      startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 0.6))
            .shadow(color: c2.opacity(0.35), radius: 2, y: 1)
            .fixedSize()
    }

    var body: some View {
        if let t = tier, !t.isEmpty { body1 }
    }
}

/* ------------------------------------------------------------ 付钱（6 格 + 自带键盘） */

/// 开通会员时输支付密码那一屏：和红包那套一样，不依赖系统键盘
struct MemberPaySheet: View {
    let amount: Double
    var purpose: String = "开通会员"
    var hasPassword: Bool = true
    /// 真正的付款动作：返回 nil 表示成功，返回文案表示失败
    let pay: (String) async -> String?
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pwd = ""
    @State private var busy = false
    @State private var tip = ""
    /// 密码错了：6 个格子左右抖一下
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
            /* 支付方式那一行（微信付款页也有）：让人知道钱是从零钱扣的 */
            HStack(spacing: 6) {
                Text(Tr("支付方式"))
                Text(Tr("零钱")).foregroundColor(C.label)
            }
            .font(pf(12.5))
            .foregroundColor(C.subLabel)
            .padding(.top, 8)

            if hasPassword {
                PayDotField(count: pwd.count, shake: shake, busy: busy)
                    .padding(.top, 16)

                PayKeypadView(busy: busy) { tapKey($0) }
                    .padding(.top, 16)
            } else {
                /* 没设过支付密码：先去设（服务器也会拦） */
                VStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 22))
                        .foregroundColor(C.green)
                    Text("还没设置支付密码")
                        .font(pf(16, .medium))
                        .foregroundColor(C.label)
                    Text("为了安全，付款前要先设一个 6 位支付密码\n（我 → 设置 → 账号与安全 → 支付密码）")
                        .font(pf(13.5))
                        .foregroundColor(C.subLabel)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 26)
                .padding(.top, 22)
            }

            if !tip.isEmpty {
                Text(tip)
                    .font(pf(13))
                    .foregroundColor(C.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
            }
            Spacer(minLength: 0)
        }
        /* 付钱的时候盖一层「正在开通会员」，不要把按钮文字改来改去（那样会跳一下） */
        .overlay {
            if busy { PayBusyOverlay(text: "正在开通会员") }
        }
        .animation(.easeOut(duration: 0.15), value: busy)
        .background(C.pageBg.ignoresSafeArea())
    }

    private func tapKey(_ key: String) {
        if busy { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()   // 每按一下轻震一下
        if key == "⌫" {
            if !pwd.isEmpty { pwd.removeLast() }
            tip = ""
            return
        }
        guard !key.isEmpty, pwd.count < 6 else { return }
        pwd.append(key)
        tip = ""
        if pwd.count == 6 { submit() }
    }

    private func submit() {
        guard !busy else { return }
        busy = true
        /* @MainActor：震动反馈这类 UIKit 接口是 MainActor 隔离的，在 Task 里必须显式标注 */
        Task { @MainActor in
            let err = await pay(pwd)
            busy = false
            if let err = err {
                tip = err
                pwd = ""
                /* 密码不对：震动 + 六个格子左右抖一下（高级支付页都这么反馈） */
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                withAnimation(.easeOut(duration: 0.06)) { shake = -12 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.35)) { shake = 0 }
                }
                return
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
            onDone()
        }
    }
}

/* ------------------------------------------------------------ 支付成功那一页 */

struct MemberPayResult: Identifiable {
    let id = UUID()
    var title: String          // 「超级会员 · 3 个月」
    var amount: Double         // 付了多少钱
    var expireText: String     // 到期时间
    var isRenew: Bool          // 是开通还是续费
}

/// 付完钱弹的那一屏（微信支付成功页那种）：大对勾 + 金额 + 明细 + 完成
struct MemberPayDoneView: View {
    let result: MemberPayResult
    var onClose: () -> Void
    /* 支付成功那几个动画：对勾弹出来 + 一圈扩散的涟漪 + 明细卡跟着浮上来 */
    @State private var pop = false
    @State private var ripple = false
    @State private var showRows = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 34)
            ZStack {
                Circle()
                    .stroke(C.green.opacity(ripple ? 0 : 0.45), lineWidth: 2)
                    .frame(width: ripple ? 136 : 66, height: ripple ? 136 : 66)
                Circle()
                    .fill(LinearGradient(colors: [C.green, C.green.opacity(0.78)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 66, height: 66)
                    .scaleEffect(pop ? 1 : 0.5)
                    .shadow(color: C.green.opacity(0.35), radius: 12, y: 4)
                Image(systemName: "checkmark")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.white)
                    .scaleEffect(pop ? 1 : 0.4)
                    .opacity(pop ? 1 : 0)
            }
            .onAppear {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.58)) { pop = true }
                withAnimation(.easeOut(duration: 1.1).delay(0.1)) { ripple = true }
                withAnimation(.easeOut(duration: 0.42).delay(0.22)) { showRows = true }
            }
            Text(Tr("支付成功"))
                .font(pf(20, .semibold))
                .foregroundColor(C.label)
                .padding(.top, 16)
                .opacity(showRows ? 1 : 0)
            Text("¥" + moneyFmt(result.amount))
                .font(pfMoney(30, .medium))
                .foregroundColor(C.label)
                .padding(.top, 6)
                .opacity(showRows ? 1 : 0)

            PanelCard {
                row(Tr("商品"), result.title)
                PanelDivider()
                row(Tr("支付方式"), Tr("零钱"))
                PanelDivider()
                row(Tr("到期时间"), result.expireText)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .opacity(showRows ? 1 : 0)
            .offset(y: showRows ? 0 : 12)

            Button { onClose() } label: {
                Text(Tr("完成"))
                    .font(pf(17, .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [C.green, C.green.opacity(0.78)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18)
            .padding(.top, 22)

            Spacer(minLength: 0)
        }
        .background(C.pageBg.ignoresSafeArea())
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Text(title).font(pf(14.5)).foregroundColor(C.subLabel)
            Spacer(minLength: 8)
            Text(value).font(pf(14.5)).foregroundColor(C.label).lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }
}
