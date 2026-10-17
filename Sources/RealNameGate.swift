import SwiftUI

/* ============================================================
   未实名的全局提示（逻辑和微信一样）

   微信不是「不实名就不能用」：聊天、加好友、朋友圈照常，只有**动钱**的
   功能（转账 / 红包 / 收付款 / 零钱）才要求先实名。
   服务端在这些接口上回 403 + details.needRealName，这里负责弹对话框，
   并给一个「去实名认证」的入口（我 → 设置 → 实名认证 那一页）。
   ============================================================ */

final class RealNameGate: ObservableObject {
    static let shared = RealNameGate()

    /// 弹「根据国家规定…」那个对话框
    @Published var alert = false
    /// 打开实名认证页
    @Published var openPage = false

    private init() { }

    /// 任何请求碰到「需要实名」都调它（可能在后台线程，所以切回主线程）
    func prompt() {
        if Thread.isMainThread { alert = true }
        else { DispatchQueue.main.async { self.alert = true } }
    }
}
