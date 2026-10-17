import SwiftUI
import UIKit

/* ============================================================
   状态栏文字颜色的临时开关（会话页「二楼」这种深色页面用）

   2026-10-16 用户：「二楼的顶部要同色，怎么出来时间的位置一条灰的」——
   之前为了让时间在深色二楼上看清，我在状态栏那一条垫了一层浅色磨砂，
   结果那一条和二楼不是一个颜色，看着像"多了一条灰带"。
   微信的做法是：**底色整块一致**，把**状态栏文字改成白色**。

   实现：挂一个只盖住状态栏的透明窗口（windowLevel = .statusBar），
   它的根控制器 preferredStatusBarStyle 返回 .lightContent ——
   iOS 取"最上层窗口"的状态栏样式，所以只在需要的时候把这个窗口显示出来，
   其余时间完全不存在，不动 App 任何其它页面的状态栏。
   ============================================================ */

final class StatusBarStyle: ObservableObject {
    static let shared = StatusBarStyle()

    private var window: UIWindow?
    private var light = false

    /// true = 状态栏白字（深色页面）；false = 跟系统（默认）
    func set(light want: Bool) {
        if want == light && (want == false || window != nil) { return }
        light = want
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if want {
                guard self.window == nil else { return }
                guard let scene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .first(where: { $0.activationState == .foregroundActive })
                    ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
                else { return }
                let w = UIWindow(windowScene: scene)
                w.windowLevel = .statusBar
                w.backgroundColor = .clear
                w.isUserInteractionEnabled = false
                w.rootViewController = LightStatusVC()
                w.isHidden = false
                self.window = w
            } else {
                self.window?.isHidden = true
                self.window = nil
            }
        }
    }

    private final class LightStatusVC: UIViewController {
        override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
        }
    }
}
