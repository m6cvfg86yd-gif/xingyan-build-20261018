import SwiftUI
import UIKit

/* ============================================================
   支付宝（官方接口那条，2026-10-16 用户选「B」）

   资金流：App 下单 → 我们服务器用**自己的应用私钥** RSA2 签名 → 回 orderStr
          → App 打开支付宝 → 用户付款 → 支付宝回调我们服务器（验签 + 标单）
          → App 切回来查单，确认到账。

   两个关键点：
   ① **私钥只在服务器**（data/pay.json），客户端拿不到，泄不了；
   ② 不用引支付宝 SDK：官方 SDK 内部就是打开
      `alipays://platformapi/startapp?appId=20000067&url=<orderStr>`，
      我们直接照做，省一个 framework 和一堆签名配置。

   名字和开关走后台（ui.json 的 alipayName / alipayOn），不用重新出包。
   ============================================================ */
enum AliPay {
    /// 支付方式名字（后台「界面文字」里可改）
    static var name: String { UIConfig.text("alipayName", "支付宝") }
    /// 商城里显不显示支付宝这一项（0 = 藏掉）
    static var on: Bool { UIConfig.num("alipayOn", 1) > 0 }

    /// 调起支付宝。orderStr 是服务端签好的那一串。
    @discardableResult
    static func open(_ orderStr: String) -> Bool {
        guard !orderStr.isEmpty else { return false }
        let enc = orderStr.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        guard !enc.isEmpty else { return false }
        for head in ["alipays://platformapi/startapp?appId=20000067&url=",
                     "alipay://platformapi/startapp?appId=20000067&url="] {
            if let u = URL(string: head + enc) {
                UIApplication.shared.open(u, options: [:], completionHandler: nil)
                return true
            }
        }
        return false
    }

    /// 付完切回来：每 2 秒问一次服务端（支付宝的异步回调也会同时标单）
    static func waitPaid(orderId: String, tryTimes: Int = 30) async -> Bool {
        var left = max(1, tryTimes)
        while left > 0 {
            left -= 1
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { return false }
            if await API.shared.alipayStatus(id: orderId).paid { return true }
        }
        return false
    }
}

/* 付款等待页：调起支付宝之后盖这一层，用户切回来就能看到结果。
   2026-10-16：用户看不到「有没有付上」是最大的坑，所以这一页
   ① 自动查单 ② 也给一颗手动「我已付好，立刻查一下」。 */
struct AliPayWaitingSheet: View {
    @Environment(\.dismiss) private var dismiss

    let amount: Double
    let orderId: String
    /// 调起之前把这一单同步到服务器（服务端要按自己的那份订单签名）
    var sync: (() async -> Void)? = nil
    /// 结果回调：true = 已经收到钱
    var onResult: (Bool) -> Void

    @State private var checking = false
    @State private var tip = ""
    @State private var poll: Task<Void, Never>? = nil

    private let aliBlue = Color(hex: 0x1677FF)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { finish(false) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(C.label)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            Image(systemName: "a.circle.fill")
                .font(.system(size: 44))
                .foregroundColor(aliBlue)
                .padding(.top, 4)
            Text(Tr("支付宝付款"))
                .font(pf(16, .medium)).foregroundColor(C.label).padding(.top, 10)
            Text("¥" + moneyFmt(amount))
                .font(pfMoney(32, .medium)).foregroundColor(C.label).padding(.top, 6)
            Text(orderId)
                .font(pf(12)).foregroundColor(C.subLabel).padding(.top, 4)
            Text(tip.isEmpty ? Tr("付完会自动回到这里，我每 2 秒查一次") : tip)
                .font(pf(13)).foregroundColor(C.subLabel)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24).padding(.top, 14)
            Button { check() } label: {
                Text(checking ? Tr("查询中…") : Tr("我已付好，立刻查一下"))
                    .font(pf(15.5, .medium)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 23, style: .continuous).fill(aliBlue))
            }
            .buttonStyle(.plain)
            .disabled(checking)
            .padding(.horizontal, 24).padding(.top, 18)
            Button { finish(false) } label: {
                Text(Tr("先不付了，去我的订单"))
                    .font(pf(14)).foregroundColor(C.subLabel).frame(height: 40)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            Spacer(minLength: 0)
        }
        .background(C.pageBg)
        .onAppear { startAutoCheck() }
        .onDisappear { poll?.cancel() }
    }

    private func startAutoCheck() {
        poll = Task {
            /* ① 先同步订单 —— 服务端得先有这一单，才签得出来 */
            if let sync { await sync() }
            /* ② 让服务端签名，然后把支付宝调起来 */
            do {
                let r = try await API.shared.alipayCreate(orderId: orderId)
                if r.orderStr.isEmpty {
                    await MainActor.run { tip = Tr("支付宝还没配好：后台「支付配置」里把 APPID 和密钥填上再试。") }
                    return
                }
                _ = await MainActor.run { AliPay.open(r.orderStr) }
            } catch {
                await MainActor.run {
                    tip = Tr("发起支付失败（订单已经留在「待付款」，稍后再点付款）。")
                }
                return
            }
            /* ③ 每 2 秒查一次（支付宝的异步回调也会同时把单标掉） */
            let ok = await AliPay.waitPaid(orderId: orderId, tryTimes: 45)
            if Task.isCancelled { return }
            await MainActor.run {
                if ok { finish(true) }
                else { tip = Tr("还没查到这笔付款。支付宝那边付成功了就先别急，订单在「待付款」里，稍后再点一次。") }
            }
        }
    }

    private func check() {
        guard !checking else { return }
        checking = true
        tip = ""
        Task {
            let r = await API.shared.alipayStatus(id: orderId)
            await MainActor.run {
                checking = false
                if r.paid { finish(true) }
                else { tip = Tr("还没收到这笔钱。付过了的话等 5 秒再点一次；没付就点左上角关掉，订单会留在「待付款」。") }
            }
        }
    }

    private func finish(_ paid: Bool) {
        poll?.cancel()
        onResult(paid)
        dismiss()
    }
}
