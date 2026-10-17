import SwiftUI
import UIKit

/* ============================================================
   亮屏（扫一扫 / 我的二维码 / 收款码那一类页面）
   2026-10-13 用户：「点开二维码页面微信有一个突然调亮的过程的」。

   微信进「我的二维码」会把屏幕调亮（对方手机/扫码枪才扫得出来），
   退出时恢复原来亮度。这里复刻那一下：0.3 秒内渐亮到 100%，退出时还原。

   用法：`.modifier(BrightenScreen())` 挂在那一页的根视图上。
   ============================================================ */

struct BrightenScreen: ViewModifier {
    /*
     用户最新要求：二维码页面保持系统当前亮度，不再突然拉满。
     保留这个 modifier 供已有页面引用，但不再修改 UIScreen.brightness。
     */
    func body(content: Content) -> some View {
        content
    }

    /*
     下面是旧版渐亮逻辑，暂时保留作参考：
    /// 进页面之前的亮度（退出时要还原成这个）
    @State private var saved: CGFloat?
    /// 目标亮度：微信也是直接拉满
    private let target: CGFloat = 1.0
    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        content
            .onAppear { brighten() }
            .onDisappear { restore() }
            /* 从后台回来（比如切出去给对方扫完再回来）还是这一页：再亮一次 */
            .onChange(of: phase) { p in if p == .active { brighten() } }
    }

    private var screen: UIScreen? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let s = scenes.first?.screen { return s }
        return scenes.first?.windows.first?.screen
    }

    private func brighten() {
        guard let screen = screen else { return }
        let from = screen.brightness
        if saved == nil { saved = from }
        guard target > from else { return }
        /* 0.3 秒分 10 步渐亮 —— 那一下「突然亮起来」的感觉 */
        let steps = 10
        for i in 1...steps {
            let d = Double(i) / Double(steps)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 * d) {
                /* 用户中途手动调过亮度就别抢（以当前值为准继续往上走） */
                let now = screen.brightness
                screen.brightness = max(now, from + (target - from) * CGFloat(d))
            }
        }
    }

    private func restore() {
        guard let screen = screen, let s = saved else { saved = nil; return }
        screen.brightness = s
        saved = nil
    }
    */
}
