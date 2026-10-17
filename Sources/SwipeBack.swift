import SwiftUI
import UIKit

/* ============================================================
  左边缘右滑返回（和手机微信 / 系统那一套一样）

   2026-10-16（第二次）用户：「又开始出现左滑返回问题了」。
   这次一口气堵三个会"复发"的洞 —— 前两版都是只治了当场的那个症状：
     A. **手势挂错窗口 / 窗口换了**：整窗手势是"装一次就不管了"，
        一旦主窗口被重建（登录页 ↔ 主界面、状态栏那层窗口、scene 重连），
        手势还留在那个已经不在屏幕上、或者只盖住状态栏的小窗口上 ——
        于是**所有页面左滑全都没反应**。现在每次 push 都核对一遍：
        发现挂的窗口不是当前 key window，就把手势**搬过去**；
     B. **栈顶那一页其实已经不在屏幕上了**：`onDisappear` 偶尔不触发（被别的
        整页盖住 / SwiftUI 复用视图），那一页还占着"栈顶"的位置，
        真正在屏幕上的那一页永远轮不到 —— 也是"没反应"。现在每页都带一份
        自己的 UIView（`SwipeBackHost`），`top` 只认**还在窗口里**的那些页；
     C. **被别人的横滑抢走**：列表/翻页/朋友圈那颗下拉球的横滑先认出来，
        我们这一下就没了。现在只要判定成"边缘返回"，立刻把窗口里
        **已经开始的其他手势**掐掉（只掐 begun/changed 的，不碰没开始的），
        这样既不会两边一起动，也不会顺手点开一行。

   2026-10-16 用户：「多个位置的返回左滑会出现误触到其他界面」。

   上一版是 SwiftUI 的 `.simultaneousGesture`（和内容"同时识别"）：
     · 手指从左边起滑时，**下面的行/列表也收到这一下** —— 滑的距离稍微短一点，
       松手时那一行就把这一下当成"点了一下"，于是推进了别的页面（用户说的"误触"）；
     · 而且每一页都挂了一份，遇到"一页里又盖着一页"的时候会**两边都响应**，
       一次返回退了两层 —— 落在哪一页就不对了。

   现在换成 UIKit 的做法（和系统边缘手势同款）：
     ① 整个窗口只装**一个** `UIPanGestureRecognizer`，由 `SwipeBackCenter` 统一管；
     ② 只有"最后进来的那一页"（栈顶）能响应 —— 不会再一次退两层；
     ③ `cancelsTouchesInView = true`：边缘这一下滑动**不会再传给孩子**，
        所以不会顺带点开一行、也不会把表情面板/翻页那种横滑带着一起动；
     ④ `shouldBegin` 里判方向：竖着滑（想滚列表）或者往左滑，一律不管，交给列表；
     ⑤ 没注册过 `swipeBack` 的页面完全不受影响（手势直接被拒收）。
   ============================================================ */

/// 一页的返回手势（由 `SwipeBackModifier` 创建、`SwipeBackCenter` 统一调度）
final class SwipeBackPage: ObservableObject {
    let id = UUID()
    var onBack: () -> Void = {}
    var enabled = true
    var width: CGFloat = 390
    /// 这一页真正的 UIView（由 `SwipeBackHost` 塞进来）：用来判断它还在不在屏幕上
    weak var host: UIView?
    /// host 有没有被塞过（塞过之后 host 变 nil = 这一页已经被销毁了）
    var hostSet = false
    /// 页面往右移出去的距离（0 = 原位）
    @Published var offset: CGFloat = 0
}

final class SwipeBackCenter: NSObject, UIGestureRecognizerDelegate {
    static let shared = SwipeBackCenter()

    /// 注册进来的页面（**后进的在后面** —— 只有最后那个 = 栈顶能响应）
    private var pages: [SwipeBackPage] = []
    private weak var pan: UIPanGestureRecognizer?
    /// 手势现在挂在哪一扇窗上（窗口换了要跟着搬）
    private weak var hostWindow: UIWindow?
    /// 还没拿到窗口时的重试次数（App 刚起来那一瞬间窗口可能还没建好）
    private var retries = 0
    /// 这一下已经判定成"边缘返回"了吗
    private var tracking = false
    private var tracked: SwipeBackPage?

    /// 边缘判定：手指按在离屏幕左边 20pt 以内才算（和系统一样窄 ——
    /// 宽了会把列表最左边的按钮也吃掉）
    private let edge: CGFloat = 20

    func push(_ p: SwipeBackPage) {
        pages.removeAll { $0 === p }
        pages.append(p)
        /* A：每次进新页面都核对手势挂对窗口没有 —— 这才是"全都没反应"的病根 */
        installIfNeeded()
    }

    func remove(_ p: SwipeBackPage) {
        pages.removeAll { $0 === p }
        if tracked === p { tracked = nil; tracking = false }
        p.offset = 0
    }

    /// 现在该谁响应：最后一个 enabled、而且**还在屏幕上**的页面
    private var top: SwipeBackPage? {
        /* B：离开屏幕的页（host 已经不在任何窗口里）自己出队 ——
           否则它一直占着栈顶，底下那页就永远收不到这一下。 */
        pages.removeAll { p in
            guard p.hostSet else { return false }        // 还没塞进 host 的先留着
            guard let h = p.host else { return true }    // 视图已经销毁 → 这一页没了
            return h.window == nil                       // 视图被摘出窗口 → 也算没了
        }
        for p in pages.reversed() where p.enabled { return p }
        return nil
    }

    private func installIfNeeded() {
        guard let win = Self.keyWindow() else {
            /* 窗口还没建好：隔一会儿再试（只重试有限次，不转圈） */
            if retries < 20 {
                retries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.installIfNeeded() }
            }
            return
        }
        /* 已经挂在"正确的这扇窗"上了，什么都不用做 */
        if let g = pan, g.view === win { hostWindow = win; return }
        /* 挂在别的窗口（老窗口 / 状态栏那层小窗口）上 → 摘下来搬到新窗口 */
        if let old = pan {
            old.view?.removeGestureRecognizer(old)
            pan = nil
        }
        retries = 0
        let g = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
        g.delegate = self
        /* ★ 关键的一条：这一下判定成边缘返回之后，孩子（行、按钮、翻页）
           就收不到这次触摸了 —— "误触到其他界面"就是从这儿堵死的。 */
        g.cancelsTouchesInView = true
        g.delaysTouchesBegan = false
        win.addGestureRecognizer(g)
        pan = g
        hostWindow = win
    }

    static func keyWindow() -> UIWindow? {
        let all = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        /* 优先挑**普通层级**的那个主窗口：状态栏那一层（StatusBarStyle 建的那个
           windowLevel = .statusBar 的小窗口）不该挂手势 —— 挂上去等于手势永远失效。 */
        return all.first { $0.isKeyWindow && $0.windowLevel == .normal }
            ?? all.first { $0.isKeyWindow }
            ?? all.first { $0.windowLevel == .normal && !$0.isHidden }
    }

    /* ---------------- 手势 ---------------- */

    /// 只有"手指按在左边 20pt 以内"这一种触摸才接
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        /* 每次触摸都顺手核对一下窗口（万一刚好错过了 push 那一下） */
        installIfNeeded()
        guard top != nil else { return false }
        guard let v = g.view else { return false }
        return touch.location(in: v).x <= edge
    }

    /// 方向不对就别开始：竖着滑（滚列表）和往左滑都不算返回
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let p = top, let v = g.view, let pan = g as? UIPanGestureRecognizer else { return false }
        let vel = pan.velocity(in: v)
        guard vel.x > 0 else { return false }
        guard abs(vel.x) > abs(vel.y) * 1.1 else { return false }
        tracked = p
        return true
    }

    /* ⚠ 2026-10-16 用户：「朋友圈没有左滑返回」。
       病根就是这一句以前写的 false：朋友圈那一页自己挂了两个**整页级**的
       DragGesture（下拉刷新那颗彩球，minimumDistance 只有 6）—— 它们 6pt 就先认出来了，
       而这里声明"我不跟别人同时识别"，于是我们的边缘手势被判输、这一下根本收不到
       （其它页面没有整页手势，所以只有朋友圈不灵）。
       现在改成 true：允许同时识别 —— 只要我们这边一开始（左边缘 + 横向右滑），
       `cancelsTouchesInView` 会立刻把别人那一下掐掉，不会两边一起动。 */
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func handle(_ g: UIPanGestureRecognizer) {
        guard let v = g.view else { return }
        let t = g.translation(in: v)
        switch g.state {
        case .began:
            /* C：这一下归我们了 —— 把窗口里**已经动起来**的其他手势掐掉
               （列表滚动、图片翻页、朋友圈下拉球…），免得两边一起动。 */
            if let w = v as? UIWindow { cancelCompeting(in: w, except: g) }
            tracking = true
            tracked?.offset = max(0, t.x)
        case .changed:
            guard tracking, let p = tracked else { return }
            /* 跟手：**逐帧直接赋值**，不加动画（和微信一样） */
            p.offset = max(0, t.x)
        case .ended:
            guard tracking, let p = tracked else { return }
            tracking = false
            tracked = nil
            let far = p.offset > p.width * 0.28
            let fast = g.velocity(in: v).x > p.width * 1.1
            if far || fast {
                withAnimation(.easeOut(duration: 0.2)) { p.offset = p.width }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                    if p.offset > 0 { p.onBack() }
                    p.offset = 0
                }
            } else {
                withAnimation(.easeOut(duration: 0.22)) { p.offset = 0 }
            }
        default:
            /* 被取消 / 失败：收回原位，不触发返回 */
            tracking = false
            if let p = tracked { withAnimation(.easeOut(duration: 0.2)) { p.offset = 0 } }
            tracked = nil
        }
    }

    /// 把已经开始（begun / changed）的其它手势取消掉：关一下再开一下就有这个效果。
    /// 只碰"已经开始"的 —— 还没开始的手势（比如行上的点击）保持原样，该点还能点。
    private func cancelCompeting(in view: UIView, except mine: UIGestureRecognizer) {
        if let list = view.gestureRecognizers {
            for r in list where r !== mine {
                guard r.state == .began || r.state == .changed else { continue }
                let was = r.isEnabled
                r.isEnabled = false
                r.isEnabled = was
            }
        }
        for sub in view.subviews { cancelCompeting(in: sub, except: mine) }
    }
}

struct SwipeBackModifier: ViewModifier {
    let enabled: Bool
    let onBack: () -> Void

    @StateObject private var page = SwipeBackPage()

    private var width: CGFloat { max(1, L.width) }

    func body(content: Content) -> some View {
        ZStack {
            content
                .offset(x: page.offset)
                .overlay(
                    Color.black
                        .opacity(0.16 * Double(min(1, page.offset / width)))
                        .allowsHitTesting(false)
                )
                /* B：把这一页真正的 UIView 交给 page —— 手势靠它判断
                   "这一页还在不在屏幕上"，不在的页不会占着栈顶。 */
                .background(SwipeBackHost(page: page).frame(width: 0, height: 0).allowsHitTesting(false))
        }
        .background(C.pageBg)
        .onAppear {
            page.onBack = onBack
            page.width = width
            page.enabled = enabled
            SwipeBackCenter.shared.push(page)
        }
        .onDisappear { SwipeBackCenter.shared.remove(page) }
        .onChange(of: enabled) { v in page.enabled = v }
        .onChange(of: width) { w in page.width = w }
    }
}

/* 把承载这一页的 UIView 报给 page（一行的 UIViewRepresentable，透明、不吃触摸） */
private struct SwipeBackHost: UIViewRepresentable {
    let page: SwipeBackPage

    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        /* 不能在 makeUIView 里直接写 page.host —— 那时视图还没进窗口，
           挂到下一层 runloop 再写，拿到的才是"已经在窗口里"的那一份。 */
        DispatchQueue.main.async { self.page.host = v; self.page.hostSet = true }
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {
        if page.host !== v { DispatchQueue.main.async { self.page.host = v; self.page.hostSet = true } }
    }
}

extension View {
    /// 左边缘右滑返回（和手机微信一样）
    func swipeBack(_ enabled: Bool = true, onBack: @escaping () -> Void) -> some View {
        modifier(SwipeBackModifier(enabled: enabled, onBack: onBack))
    }
}
