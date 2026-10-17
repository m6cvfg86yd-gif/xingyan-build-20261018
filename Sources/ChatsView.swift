import SwiftUI
import UIKit
import Darwin

/* ============================================================
   会话行的触摸层 —— 左滑用它，**不用 SwiftUI 的 DragGesture**。

   为什么（线上实测）：SwiftUI 的 DragGesture 挂在行上会和外面那层 ScrollView
   抢手势。换成 iOS 26 SDK（Xcode 26）构建之后，竖向的上下滑被这个 DragGesture
   吃掉，表现就是「会话页上下滑不动」——而通讯录/发现/我 这些列表页没有这个手势，
   所以只有会话页有问题。

   UIKit 的 pan 可以声明「允许和 UIScrollView 的滚动手势同时识别」
   （delegate 返回 true），所以：
     · 手指竖向滑 → 我们完全不碰，列表照常上下滚
     · 手指横向拖 → 才算左滑，驱动行往左推
   单击也在这里一起处理（这一层盖在行上面，SwiftUI 的 onTapGesture 收不到）。
   ============================================================ */
struct RowSwipeCatcher: UIViewRepresentable {
    /// 单击（点的位置，用来区分「点头像」还是「点整行」）
    var onTap: (CGPoint) -> Void
    /// 这一下确定是横向拖动（方向判完才调）
    var onBegan: () -> Void
    /// 横向拖动的位移（从按下算起）
    var onChanged: (CGFloat) -> Void
    /// 松手：位移 + 横向速度（速度用来判「甩一下」是开还是收）
    var onEnded: (CGFloat, CGFloat) -> Void

    final class Coord: NSObject, UIGestureRecognizerDelegate {
        var onTap: (CGPoint) -> Void = { _ in }
        var onBegan: () -> Void = { }
        var onChanged: (CGFloat) -> Void = { _ in }
        var onEnded: (CGFloat, CGFloat) -> Void = { _, _ in }
        /// 这一下已经判定成横向拖了吗
        private var horizontal = false

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            switch g.state {
            case .began:
                horizontal = false
            case .changed:
                if !horizontal {
                    /* 方向：横着明显多于竖着才算左滑；否则一律交给列表滚 */
                    guard abs(t.x) > abs(t.y) + 4 else { return }
                    horizontal = true
                    onBegan()
                }
                onChanged(t.x)
            case .ended, .cancelled, .failed:
                if horizontal { onEnded(t.x, g.velocity(in: g.view).x) }
                horizontal = false
            default:
                break
            }
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            onTap(g.location(in: g.view))
        }

        /// 关键：和 ScrollView 的滚动**同时识别**，谁也别抢谁的
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }

    func makeCoordinator() -> Coord { Coord() }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = true

        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coord.handlePan(_:)))
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        v.addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coord.handleTap(_:)))
        tap.delegate = context.coordinator
        /* 不要 cancelsTouchesInView：这样这一层只是"看着"，不会把触摸从行里抢走 */
        tap.cancelsTouchesInView = false
        v.addGestureRecognizer(tap)

        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onBegan = onBegan
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
    }
}

struct ChatRow: View {
    let chat: Chat
    /// 点左边那个头像（只有机器人那几行给）：直接弹它自己的名片
    var onTapAvatar: (() -> Void)? = nil

    var body: some View {
        /* 微信的位置是固定的：头像在行高里居中，文字块和右边那列都从离顶 13 的地方开始 */
        HStack(alignment: .top, spacing: 0) {
            avatarBlock
                .padding(.top, avatarTop)
            Spacer().frame(width: L.rowGap)
            textColumn
                .padding(.top, L.rowPadTop)
            Spacer(minLength: 6)
            rightColumn
                .padding(.top, L.rowPadTop)
        }
        .padding(.leading, L.rowPadL)
        .padding(.trailing, L.rowPadR)
        .frame(height: L.rowH)
        .contentShape(Rectangle())
    }

    /// 头像在行高里居中（微信 76 的行、48 的头像 → 上下各 14）
    private var avatarTop: CGFloat { max(0, (L.rowH - L.avatar) / 2) }

    /// 头像：机器人那几行点它能弹名片，普通会话点了进聊天
    private var avatarBlock: some View {
        Group {
            if let tap = onTapAvatar {
                avatar.contentShape(Rectangle()).onTapGesture { tap() }
            } else {
                avatar
            }
        }
    }

    /// 名字在上、预览在下
    private var textColumn: some View {
        VStack(alignment: .leading, spacing: L.rowTextGap) {
            HStack(spacing: 5) {
                Text(chat.name)
                    .font(pf(L.rowNameSize))
                    .foregroundColor(C.name)
                    .lineLimit(1)
                    .layoutPriority(1)
                /* 昵称旁边挂等级图标（QQ 那套）：后台「显示在聊天里」开着才显示 */
                /* 1 级不画等级图标（2026-10-16 用户「每条线上多出来的那个 1 去掉」）——
                   聊天列表和通讯录一个规矩：2 级往上才显示。 */
                if let lv = chat.qqLevel, lv > 1, GrowthFlags.showInChats == true {
                    QQLevelBadge(level: lv, size: L.v(13, 3.6, 15), maxIcons: 3)
                        .fixedSize()
                }
                /* 会员徽章（对方开了会员就挂一个，单聊看对方、群聊看群主） */
                MemberBadge(tier: chat.memberTier,
                            short: chat.memberShort,
                            color: chat.memberColor,
                            color2: chat.memberColor2,
                            height: L.v(11.5, 3.2, 13))
                    .fixedSize()
            }
            Text(chat.lastMessage?.preview ?? "")
                .font(pf(L.rowPreviewSize))
                .foregroundColor(C.preview)
                .lineLimit(1)
        }
    }

    /// 右边一列：时间在上，未读徽标在下（微信就是这样，徽标不在头像上）
    private var rightColumn: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text(TimeFmt.list(chat.lastMessage?.createdAt ?? chat.updatedAt))
                .font(pf(L.rowTimeSize))
                .foregroundColor(C.time)
                .fixedSize()
        }
    }

    /// 未读标记：**压在头像右上角**（微信就是这样 —— 不在行右边）。
    /// 普通会话给数字徽标；免打扰会话只给一个小红点（微信的规则）。
    @ViewBuilder
    private var unreadOnAvatar: some View {
        if chat.unreadCount > 0 {
            /* 免打扰的会话、和「左滑 → 标为未读」的会话：微信都只点一个小红点，
               不给数字（数字留给真正等你看的消息） */
            if chat.muted == true || chat.flagged == true {
                UnreadDot(border: C.chatsRowBg)
                    .offset(x: 5, y: -5)
            } else {
                UnreadBadge(count: chat.unreadCount, border: C.chatsRowBg)
                    .offset(x: 8, y: -8)
            }
        }
    }

    private var avatar: some View {
        Avatar(path: chat.avatar ?? "", size: L.avatar, radius: 4, level: chat.qqLevel ?? 0)
            /* 好友设了状态：头像右下角挂一个小 emoji（微信就是这样） */
            .overlay(alignment: .bottomTrailing) {
                if let icon = chat.moodIcon, !icon.isEmpty {
                    Text(icon)
                        .font(.system(size: 9))
                        .frame(width: 17, height: 17)
                        .background(Circle().fill(C.cardBg))
                        .overlay(Circle().stroke(C.hairline, lineWidth: 0.5))
                        .offset(x: 5, y: 5)
                }
            }
            /* 未读：数字徽标 / 免打扰的小红点压在这个头像的右上角 */
            .overlay(alignment: .topTrailing) {
                unreadOnAvatar
            }
    }
}

/* ============================================================
   会话行 + 左滑三级操作（完全照网页版）：
   ① 左滑露出 标为未读(绿) / 不显示(橙) / 删除(红)，三个各 80 宽，整条 240
   ② 点「不显示」→ 这一条撑满 249 变成「不显示该聊天」（橙），再点一下才执行
   ③ 点「删除」→ 这一条撑满 249 变红「清空记录同时不显示聊天」，再点一下才执行
   拖过一截会预览第二层；点别处整条收回去。

   手感（用户要求「有阻尼感」）：
   · 拖动时**越拉越沉**（超出三格只跟 30%，最多再多 92），拉到头不会硬顶死
   · 松手用**弹簧吸附**（interpolatingSpring），会轻轻回稳一下，不是 easeOut 硬切
   · 甩一下就开/收（看松手时的横向速度），慢拖则看拖过没拖过四成
   · 开、进入第二层各轻震一下（和微信的手感一致）
   长相（2026-10-15 用户：「左滑三个按钮跟微信还差质感」→ 对齐微信）：
   · 三格是**顶天立地的实心方块**：整行高、贴右边缘、不圆角、不描边、不投影、纯色不渐变
   · 灰 / 灰 / 红 = 微信 8.0 的 #C7C7CC + #FA5151（深色下灰 #4C4C4C），格子间一条 1px 白线
   · 每格：图标在上、文字在下（白字）；按下那一格压暗一点、松手才执行
   · 同时只开一行：新滑开一行、或列表一开始滚，别的行自己收回（微信也是这样）
   · 想调就改 ui.json：swipeBtnW / swipeFont / swipeIcon / swipeGray / swipeRed
    ============================================================ */

extension Notification.Name {
    /// 会话行左滑：object = 滑开那一行的 chat.id；object = nil 表示「全部收回去」
    /// （微信同时只开一行：新滑开一行、或者列表一开始滚，别的行就自己收回）
    static let chrisRowSwipe = Notification.Name("chris.rowSwipe")
}

struct SwipeChatRow: View {
    enum Mode { case none, hideConfirm, delConfirm }

    let chat: Chat
    var onOpen: () -> Void
    /// 机器人那几行：点头像弹名片（普通会话传 nil）
    var onTapAvatar: (() -> Void)? = nil
    var onUnread: () -> Void
    var onHide: (Bool) -> Void      // true = 连记录一起清掉
    var onDelete: () -> Void

    @State private var offset: CGFloat = 0
    @State private var startOffset: CGFloat = 0
    @State private var mode: Mode = .none
    @State private var dragging = false

    /* 2026-10-15 对齐微信（用户：「左滑三个按钮跟微信还差质感」）：
       微信那三块是**顶天立地的实心方块** —— 整行高、贴住右边缘、不圆角、不描边、不投影、
       纯色不做渐变；颜色就是微信 8.0 的中性灰 #C7C7CC + 品牌红 #FA5151
       （深色模式下灰换成 #4C4C4C）。按下那一格会压暗一点、松手才执行。
       想退回以前那张「小卡片」：ui.json 里写 swipeInset=5、swipeRadius=13。 */
    private var btnW: CGFloat { UIConfig.num("swipeBtnW", 80) }
    private var btnFont: CGFloat { UIConfig.num("swipeFont", 15) }
    private var fullW: CGFloat { btnW * 3 }
    /// 卡片化的那点装饰（微信 = 0 / 0：不做）
    private var cardInset: CGFloat { UIConfig.num("swipeInset", 0) }
    private var cardRadius: CGFloat { UIConfig.num("swipeRadius", 0) }
    private var iconSize: CGFloat { UIConfig.num("swipeIcon", 17) }
    private var cardH: CGFloat { max(20, L.rowH - cardInset * 2) }
    /* 三块的颜色（2026-10-16 用户：「标为未读蓝色，不显示黄色」）：
       标为未读 = 蓝、不显示 = 黄、删除 = 红。三个都能在后台改，不用出包：
       ui.json 写 swipeBlue / swipeYellow / swipeRed（"#浅色|#深色"）。 */
    /// 标为未读：蓝
    private var blueBg: Color { UIConfig.color("swipeBlue", 0x2E7CF6, 0x0A84FF) }
    /// 不显示：黄（纯黄配白字看不清，这里用偏琥珀的黄，白字照样清楚）
    private var yellowBg: Color { UIConfig.color("swipeYellow", 0xE0A22B, 0xD9932A) }
    /// 删除：微信的品牌红
    private var redBg: Color { UIConfig.color("swipeRed", 0xFA5151, 0xFA5151) }
    /// 正在按下的那一格（按下压暗一点、松手才执行 —— 微信就是这个手感）
    @State private var pressedBar = ""
    /// 松手那一下的横向速度（决定用哪档弹簧）
    /// 拖动过程中有没有越过"算打开"的那条线（用来在刚好越过时震一下）
    @State private var crossedOpen = false
    /// 松手那一下的横向速度（决定用哪档弹簧）
    @State private var dragVelocity: CGFloat = 0
    /// 滑开进度 0…1（按钮的图标/文字按它"张开"）
    private var barReveal: CGFloat {
        min(1, max(0, -offset / max(1, fullW)))
    }

    /// 开 / 换层的时候轻震一下
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    /// 吸附用的弹簧：**轻微过冲再回稳** —— 用户要的「阻尼感」就是它
    private var swipeSpring: Animation {
        /* 2026-10-16 用户：「左滑那个滑动感不够」——
           原来 mass 0.9 / stiffness 250 / damping 25 偏"软"，收放都慢半拍。
           现在默认更紧一点（stiffness 320 / damping 26），并且按松手速度分档：
           甩得越狠，回弹越快（这就是"甩一下"和"慢慢拖"手感不一样的原因）。 */
        swipeSpringFor(velocity: dragVelocity)
    }

    /// 按速度挑弹簧：快甩 → 响应快、带一点过冲；慢拖 → 稳一点
    private func swipeSpringFor(velocity vx: CGFloat) -> Animation {
        let fast = abs(vx) > 700
        return .interpolatingSpring(mass: fast ? 0.75 : 0.9,
                                    stiffness: fast ? 420 : 320,
                                    damping: fast ? 30 : 26)
    }

    /* 会话列表每一行也用「卡片底色」，和通讯录的卡片一个色；
       置顶的仍然用置顶色区分一下 */
    /* 置顶行不再单独一层底色（用户反馈"会话页有几个东西被单独框起来"）：
       置顶只体现在排序上，一行一行的底色和普通会话完全一致。
       想恢复"置顶带灰底"就在后台 ui.json 里写 pinnedBg = "#F2F2F2|#333335"。 */
    private var rowBg: Color { C.chatsRowBg }

    var body: some View {
        ZStack(alignment: .trailing) {
            /* ① 行内容：跟着手指往左推 */
            ChatRow(chat: chat, onTapAvatar: onTapAvatar)
                .frame(width: L.width, height: L.rowH, alignment: .leading)
                .background(rowBg)
                .overlay(alignment: .bottom) { HairLine(inset: L.dividerLeft) }
                .offset(x: offset)
                .contentShape(Rectangle())
                .zIndex(1)

            /* ② 操作按钮：画在最上层，只露出滑开的那一块 —— 这样点一定点得到 */
            actionButtons
                .allowsHitTesting(offset != 0)
                .zIndex(2)
        }
        .frame(width: L.width, height: L.rowH, alignment: .leading)
        /* 底层铺一行底色：卡片上下那 5pt 留白露出来的就是它（和各行的底色完全一样）。
           以前没有这层，第二层撑满时左边会透出页面底色，看着像裂了一条缝。 */
        .background(rowBg)
        .clipped()
        /* ③ 手势层：**上下滑交给列表滚**，只有横向拖才算左滑 ——
           以前这里挂的是 SwiftUI 的 DragGesture，换成 iOS 26 SDK 构建之后
           它会和外面那层 ScrollView 抢手势，竖向上下滑被它吃掉，
           表现就是「会话页上下滑不动」（别的列表页没这个手势，所以只有会话页有问题）。
           UIKit 的 pan 可以声明「和 ScrollView 的滚动同时识别」，两边互不影响。
           宽度跟着 offset 收，滑开后露出来的三个按钮不会被这层挡住。 */
        .overlay(alignment: .leading) {
            RowSwipeCatcher(
                onTap: { p in
                    if offset != 0 {
                        close()
                    } else if p.x < L.rowPadL + L.avatar + 10, let tap = onTapAvatar {
                        tap()                       // 机器人那几行：点头像弹名片
                    } else {
                        onOpen()
                    }
                },
                onBegan: {
                    dragging = true
                    startOffset = offset
                    dragVelocity = 0
                    crossedOpen = (-offset > fullW * 0.42)
                    /* 微信：滑开这一行，别处已经滑开的那一行会自己收回去 */
                    NotificationCenter.default.post(name: .chrisRowSwipe, object: chat.id)
                },
                onChanged: { dx in
                    var x = startOffset + dx
                    if x > 0 {
                        /* 往右拖过头：只跟一点点，最多探出 10 —— 有阻尼才不像硬底 */
                        x = min(10, x * 0.22)
                    } else if x < -fullW {
                        /* 拉过三格之后：越拉越沉（只跟 30%，最多再多 92） */
                        x = -(fullW + min(92, (-x - fullW) * 0.30))
                    }
                    /* ⚠ 不要给 offset 加动画：跟手就得**逐帧直接赋值**。
                       以前这里没动画是对的，但下面 settle 用的弹簧偏软，
                       整体就"拖得动、松手不利索"。 */
                    offset = x
                    /* 刚好越过"算打开"那条线：轻震一下（微信那种"咔"的手感） */
                    let nowCrossed = (-offset > fullW * 0.42)
                    if nowCrossed != crossedOpen {
                        crossedOpen = nowCrossed
                        haptic.impactOccurred(intensity: nowCrossed ? 0.55 : 0.35)
                    }
                    /* 多拉一截就预览第二层（那一条撑满 240，变成「不显示该聊天」） */
                    if -x > fullW + 34 && mode == .none {
                        mode = .hideConfirm
                        haptic.impactOccurred(intensity: 0.7)
                    } else if -x < fullW - 9 && mode == .hideConfirm {
                        mode = .none
                    }
                },
                onEnded: { _, vx in
                    dragging = false
                    dragVelocity = vx
                    settle(velocity: vx)
                }
            )
            .frame(width: max(0, L.width + offset), height: L.rowH)
        }
        /* 别的行滑开了（或者列表开始滚了）→ 把自己收回去（微信就是这样，同时只开一行） */
        .onReceive(NotificationCenter.default.publisher(for: .chrisRowSwipe)) { note in
            if let id = note.object as? String {
                if id != chat.id { collapse() }
            } else {
                collapse()
            }
        }
    }

    /// 悄悄收回去（不带震动的关闭）
    private func collapse() {
        guard offset != 0 || mode != .none else { return }
        pressedBar = ""
        dragVelocity = 0            // 收回去用默认那档弹簧（别拿上一次甩的速度）
        withAnimation(swipeSpring) {
            offset = 0
            mode = .none
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 0) {
            switch mode {
            case .none:
                /* 第一层：标为未读（蓝）/ 不显示（黄）/ 删除（红），各一个按钮宽 */
                bar("标为未读", "envelope.badge.fill", blueBg, btnW) {
                    onUnread()
                    close()
                }
                bar("不显示", "eye.slash.fill", yellowBg, btnW, sep: true) {
                    mode = .hideConfirm
                    haptic.impactOccurred()
                    withAnimation(swipeSpring) { offset = -fullW }
                }
                bar("删除", "trash.fill", redBg, btnW, sep: true) {
                    mode = .delConfirm
                    haptic.impactOccurred()
                    withAnimation(swipeSpring) { offset = -fullW }
                }
            case .hideConfirm:
                /* 第二层：整条撑满，再点一下才真的不显示 */
                bar("不显示该聊天", "eye.slash.fill", yellowBg, fullW) {
                    onHide(false)
                    close()
                }
            case .delConfirm:
                /* 第二层：整条撑满，再点一下才真的删掉 */
                bar("清空记录同时不显示聊天", "trash.fill", redBg, fullW) {
                    onDelete()
                    close()
                }
            }
        }
        .frame(height: cardH)
        .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(cardInset > 0 ? 0.22 : 0),
                              lineWidth: cardInset > 0 ? 0.6 : 0)
        )
        .padding(.vertical, cardInset)
        .frame(width: max(0, -offset), height: L.rowH, alignment: .trailing)
        .clipped()
        /* 卡片浮在行上面那一层投影（.clipped 之后才加，投出来才是卡片自己的形状） */
        .shadow(color: .black.opacity(cardInset > 0 ? 0.16 : 0),
                radius: cardInset > 0 ? 9 : 0, x: 0, y: 3)
    }

    /// 松手吸附：**带阻尼的弹簧**（会轻轻回稳一下，不是硬切过去）
    private func settle(velocity vx: CGFloat) {
        if mode != .none {
            withAnimation(swipeSpring) { offset = -fullW }
            return
        }
        let open: Bool
        if vx <= -420 {
            open = true                     // 往左甩一下：直接开到最大
        } else if vx >= 420 {
            open = false                    // 往右甩一下：直接收回去
        } else {
            open = -offset > fullW * 0.42   // 慢慢拖的：拖过四成就算开
        }
        if open { haptic.impactOccurred() }
        withAnimation(swipeSpring) {
            offset = open ? -fullW : 0
            if !open { mode = .none }
        }
    }

    /// 一个可以点的格子：图标在上、文字在下、白字、**纯色底**（微信那三块就是这么长的）
    /// 不用 Button：Button 在会滑动的行里容易点不到，所以自己用
    /// DragGesture(minimumDistance: 0) 接下按/松手 —— 顺带做「按下压暗」的手感。
    private func bar(_ title: String, _ symbol: String, _ bg: Color, _ width: CGFloat,
                     sep: Bool = false,
                     action: @escaping () -> Void) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundColor(.white)
            Text(title)
                .font(pfExact(btnFont, .medium))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        /* 图标和文字**随滑开程度张开**（88% → 100%、半透明 → 全亮）——
           整块底色不缩放（不然三块之间会露缝），只让里面的内容"长"出来。 */
        .scaleEffect(0.88 + 0.12 * barReveal)
        .opacity(0.62 + 0.38 * barReveal)
        .frame(width: max(0, width), height: cardH)
        .background(bg.opacity(pressedBar == title ? 0.84 : 1))
        /* 两块灰之间那条 1px 白线（微信也有，不然两块灰分不出来）—— 顶天立地不内缩 */
        .overlay(alignment: .leading) {
            if sep {
                Rectangle()
                    .fill(Color.white.opacity(0.36))
                    .frame(width: 0.5)
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if pressedBar != title { pressedBar = title }
                }
                .onEnded { v in
                    pressedBar = ""
                    /* 手指在格子里（没怎么移动）= 点了这一格；拖走就算放弃（微信也是这样） */
                    if abs(v.translation.width) < 14, abs(v.translation.height) < 14 { action() }
                }
        )
    }

    private func close() {
        pressedBar = ""
        dragVelocity = 0            // 点按钮关掉：用默认弹簧
        withAnimation(swipeSpring) {
            offset = 0
            mode = .none
        }
    }
}
/* ============================================================ 微信（会话列表） */

struct ChatsView: View {
    @ObservedObject private var lang = LangStore.shared
    /// 小星档位（关了就不画那双眼睛，让放大镜顶到左边那个位置 —— 2026-10-15 用户要求）
    @ObservedObject private var eyes = EyesStore.shared
    @EnvironmentObject var app: AppState
    /// 二楼顶那一条要按模式给"能看清时间"的底（浅色垫浅、深色垫深）
    @Environment(\.colorScheme) private var scheme

    @State private var keyword = ""
    /// 会话列表滚了多少（顶栏那层磨砂按它淡入淡出）
    @State private var scrolled: CGFloat = 0
    /// 下拉露出来的「二楼」露了多少（微信那个小程序层；由列表自己的下拉量驱动，不挂手势）
    @State private var pullDown: CGFloat = 0
    /// 二楼是不是"拉开停住了"：微信是拉过阈值就停着（不再弹回去），往上滚或点一下才收起
    @State private var floorUp = false
    /// 「二楼」总开关：后台 chatsFloor 写 0 = 整页不做二楼（被误触烦到可以直接关掉）
    private var floorOn: Bool { UIConfig.num("chatsFloor", 1) > 0 }
    /// 「二楼」的下拉阈值（pt）：拉过这么多才算"想开二楼"。
    /// 默认 **120**（原来 70 太浅，用户反馈"二楼一直误触"）。
    private var floorPull: CGFloat { max(40, UIConfig.num("chatsFloorPull", 120)) }
    /// 下拉时三颗"压感点"已经点亮了几颗（每亮一颗震一下；用户要求振动加强）
    @State private var floorTick = 0
    /// 二楼第一组「最近使用的小程序」的数据（进页面从后台拉一次）
    @State private var floorApps: [MiniApp] = []
    /* 2026-10-17 用户：「背景也改成天气系统吧」——
       会话页二楼背景换成**和商城二楼同一套**天气系统（真实天气 × 真实昼夜）。 */
    @ObservedObject private var mallWeather = MallWeather.shared
    @ObservedObject private var floorCity = DDCity.shared
    /// 二楼顶上那颗城市（点了开城市选择页，和商城那颗一样）
    @State private var showFloorCity = false
    /// 二楼里点一个小程序：用内置浏览器整页打开
    @State private var floorAppOpen: MiniApp?
    /// 二楼那个搜索框：**只搜小程序**的那一页（用户 2026-10-16 要求）
    @State private var showAppSearch = false
    /// 「重力感」：手指下拉的距离 → 二楼实际露出的高度
    /// 前 60pt 完全跟手，再往深按 0.82 次方衰减（拉得越深越沉，像拽一个越来越重的东西）。
    /// 后台键 floorGravity：写 0 就是原来那种 1:1 跟手。
    private func heavyPull(_ d: CGFloat) -> CGFloat {
        let g = UIConfig.num("floorGravity", 1)
        if g <= 0 || d <= 60 { return d }
        let tail = max(0, d - 60)
        return 60 + CGFloat(pow(Double(tail), 0.82)) * 0.62 + tail * 0.38
    }
    @State private var path = NavigationPath()
    /// 点公众号那两条会话：直接开公众号页面
    @State private var oaOpenId = ""
    @State private var showOA = false
    @State private var showOAList = false
    @State private var plusMenu = false
    @State private var showScan = false
    /// 「收付款」（会话页右上「＋」→ 收付款；就是我 → 服务 → 收付款 那一页）
    @State private var showPayCode = false
    @State private var openRow: String?
    /// 「搜索」整页
    @State private var showSearch = false
    /// 点会话列表里机器人那几行的头像 → 弹它的名片
    @State private var botCardChat: Chat?
    /// 点左上角那两只眼睛 → 打开「小星」自己的对话页（元宝那种，不是普通聊天页）
    @State private var botChat: Chat?

    /// 顶栏小星那双眼睛的颜色：后台 ui.json 的 eyesColor 优先；
    /// 没配就跟右上角那个 ＋ 同色（navPlusBg）。两个键都在后台能改，不用出包。
    private var eyesTint: Color {
        UIConfig.colorIfSet("eyesColor") ?? UIConfig.color("navPlusBg", 0x0F5A3C, 0x0F5A3C)
    }

    private var list: [Chat] {
        /* 会话列表里点公众号那几条：**直接进公众号页面**，不是进聊天页
           （微信里服务号/订阅号点进去也是它们自己的页面） */
        /* 贾维斯从列表里拿掉（它改成左上角那只小脸，点脸进对话） */
        let base = app.chats.filter { c in
            guard c.botRank != 0,
                  !c.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return false }
            let title = (c.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let avatar = (c.avatar ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            /* 完全空壳的会话：没有名字、没有最后一条、也没有头像 ——
               以前照样按 L.rowH 画一整行，用户看到的就是“莫名其妙空出来一行”。
               只滤掉这种三样全空的；正常新建群哪怕还没消息也会留着头像/标题。 */
            return !title.isEmpty || c.lastMessage != nil || !avatar.isEmpty
        }
        guard !keyword.isEmpty else { return base }
        return base.filter {
            $0.name.contains(keyword) || (($0.lastMessage?.preview ?? "").contains(keyword))
        }
    }

    /// 点一行会话：公众号的服务号 → 那一页；订阅号消息 → 公众号列表；其它 → 聊天页
    private func openRow(_ chat: Chat) {
        if let oa = chat.oaId, !oa.isEmpty {
            oaOpenId = oa
            showOA = true
        } else if chat.oaDigest == true {
            showOAList = true
        } else {
            path.append(chat)
        }
    }

    /// 和网页版一样：有未读时标题变成「微信(3)」
    private var navTitle: String {
        /* 离线：**学微信**——标题直接变成「星言（未连接）」，
          不再另外在页面上挂一条灰色横幅（横幅已经去掉了）。 */
        if app.offline {
            return Lang.isEnglish ? "\(C.tabText0) (No Connection)" : "\(C.tabText0)（未连接）"
        }
        /* 顶栏文字后台可改（tabTitle0），有未读时还是「文字(3)」 */
        return unreadTotal > 0 ? "\(C.tabText0)(\(unreadTotal))" : C.tabText0
    }

    /// 全部未读数（标题旁边那个会滚的数字）
    private var unreadTotal: Int { app.chats.reduce(0) { $0 + ($1.unread ?? 0) } }

    /// 会话页顶栏那层「薄玻璃」（用户要的"透一丢丢"）
    /// 「二楼」露出来的那层（微信那层是"最近使用的小程序"）：先放四个最常用的入口，
    /// 压感提示（微信二楼那种）：1 个点 → 2 个点 → 3 个点，
    /// 每拉够一段点亮一个，颜色跟着由浅（半透明）到深（实心）；
    /// 点到第三个（= 后台 chatsFloorPull，默认 120pt）二楼页面才浮出来。
    private var pullDots: some View {
        let p = floorUp ? 100 : pullDown
        return HStack(spacing: 7) {
            ForEach(0..<3, id: \.self) { i in
                /* 三颗点按**当前阈值**三等分：阈值 120pt 时就是 40 / 80 / 120pt 各亮一个
                   （阈值是后台键 chatsFloorPull，调深了这几颗点也跟着走） */
                let step = floorPull * CGFloat(i + 1) / 3
                let lit = min(1, max(0, p / step))         // 这一颗的亮度（由浅到深）
                Circle()
                    .fill(C.label.opacity(0.18 + 0.72 * lit))
                    .frame(width: 7, height: 7)
                    .scaleEffect(0.72 + 0.28 * lit)
                    .animation(.easeOut(duration: 0.14), value: pullDown)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /* 二楼开 / 收那一下的动画。
       用户反馈「字还是会弹」—— 弹簧一直在这里：松手时用的是 dampingFraction 0.76，
       会过冲，整页（连同里面的字）都会回弹一下。
       后台 floorPopBounce 写 0 就换成**纯缓动**：一点回弹都没有（不是把弹簧调稳）。 */
    /// 后台 floorPopBounce：写 0 = 二楼开/收、以及里面每一块，**都不走弹簧、也不上下滑**，
    /// 只做缩放 + 淡入淡出（用户："关闭的时候文字不要弹 / 不要上下弹一下"）。
    private var floorBounce: Bool { UIConfig.num("floorPopBounce", 1) > 0 }

    /// 二楼下来 / 收上去的动画时长（后台键 floorAnim，默认 0.42 秒）
    private var floorAnimDur: Double { max(0.08, Double(UIConfig.num("floorAnim", 0.42))) }
    /// 下拉振动强度：后台键 floorHaptic，0 关 / 1 轻 / 2 中 / 3 重（默认 3）
    private var floorHaptic: Int { Int(UIConfig.num("floorHaptic", 3)) }

    /// 按后台设的强度震一下（level 是这一下"本来"该多重，最终取 min(level, 设定值)）
    private func floorImpact(_ level: Int) {
        guard floorHaptic > 0 else { return }
        switch min(level, floorHaptic) {
        case 1: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case 2: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        default: UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        }
    }

    /// 二楼内容的**顶部内缩**（状态栏 + 顶栏那一段的位置）—— B30 那版就这么写的。
    private var floorInset: CGFloat { floorUp ? 0 : L.safeTop + L.navH }

    /// 二楼底下那条「折叠页」的高度：**和商城二楼底下那条一模一样**（54 + 安全区）。
    /// 后台 ui.json 写了 floorBottomH 就用它（>0），否则按商城那条算。
    private var floorBottomHNow: CGFloat {
        let v = UIConfig.num("floorBottomH", 0)
        if v > 0 { return v }
        return 54 + L.safeBottom
    }

    /// 图标「由小变大」的进度：过了三个压感点那一刻从 0 开始，再多拉 60pt 长到 1
    private var floorIconProg: CGFloat {
        min(1, max(0, pullDown - floorPull) / 60)
    }

    private var floorAnim: Animation {
        floorBounce
            ? .spring(response: floorAnimDur, dampingFraction: 0.76)
            : .easeOut(duration: floorAnimDur)
    }

    /// 顶栏那一条现在露的是**天色**（二楼下拉出来的那张滑板，见 body）——
    /// 天色深（夜里 / 雷雨）就把状态栏的时间/信号切白，浅色天色保持深字。
    private var skyStatusLight: Bool {
        guard floorUp || pullDown > 8 else { return false }
        let look = MallWeatherLook.current(mallWeather)
        return look.phase.isNight || look.isThunder
    }

    /// 顶栏跟着下拉淡出：不拉 = 1，拉满（chatsFloorPull）= 0。
    /// ⚠ 写成**独立的属性**、类型写死 Double：直接塞进 .opacity 里写
    /// `max(0, 1 - pullDown / max(1, floorPull))` 会撞上 Swift 的
    /// CGFloat/Double 互转，CI 直接报 `ambiguous use of operator '-'`（B1635 那次就是栽在这）。
    private var navFadeForFloor: Double {
        if floorUp { return 0 }
        let p: CGFloat = pullDown / max(1, floorPull)      // 拉的比例（0…1）
        let v: CGFloat = max(0, 1 - p)                     // 越拉越淡
        return Double(min(1, v))
    }

    /// 二楼现在露出多高（下拉跟着手指，箭头展开固定 150）
    private var floorReveal: CGFloat {
        /* 微信的二楼是**整页**：列表整块下去，二楼铺满全屏（不是顶栏下面一条） */
        let full = UIScreen.main.bounds.height
        /* 但**最底下要留一条**：露出会话列表最后一行 + 底栏（微信就是这么做的，
           截图里底上那条「微信（2233）」就是它），点那一条 / 往上滑就收起二楼。 */
        /* 用户要求：二楼下来是**盖住底栏**的（铺满整屏，连底部导航一起盖住）——
           底下只留一点点"两页叠在一起"的露出（在 miniFloor 里画那个小尖）。
           所以：开着的时候高度 = 整屏，底栏由 AppState.floorFull 收起来。 */
        let top = max(240, full)
        if floorUp { return top }
        /* ── B30 那版（用户指定按它改）：手指拉多少就露出多少 ── */
        if pullDown > 0.5 { return min(pullDown, top) }
        return 0
    }

    /// 名字/图标/动作以后都能挪到后台配置（和别的页面一样，改完不用出包）。
    @ViewBuilder private var miniFloor: some View {
        /* 「动感」：拉的这一路每块跟着手指**一块块长出来**（越靠下的越晚），
          松手停住的时候带一点**错开的弹簧**（一层层浮上来），不是整页一起硬切。 */
        let t: CGFloat = floorUp ? 1 : min(1, pullDown / max(1, floorPull))
        /* 这一层现在**自带天色**：明亮的地方用深色字，夜里用白字（和商城二楼一套） */
        let look = MallWeatherLook.current(mallWeather)
        VStack(spacing: 10) {
            /* ⚠ 2026-10-16 用户：「不要遮住时间啊灵动岛」——
               二楼展开时内容**必须**从安全区下面开始（搜索框不许顶到时间/灵动岛底下）。
               以前这里只垫 safeTop+6，加上松手后的弹簧回弹，第一行就压上去了；
               现在垫 safeTop+10，并且下面那条"叠加条"的遮罩只做装饰、不占内容位置。 */
            Color.clear.frame(height: floorUp ? (L.safeTop + 8) : 0)

            /* 2026-10-17 重新设计这一层时加的第一行：
               左边「问候 + 此刻真实天气」，右边「城市」（点了开城市选择页）。
               既然背景是天色，就让天色**有意义**——不只是好看一下。 */
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(floorGreeting).font(pf(17, .medium)).foregroundColor(look.ink)
                    HStack(spacing: 4) {
                        Image(systemName: look.icon).font(.system(size: 11.5, weight: .semibold))
                        Text(floorWeatherLine(look)).font(pf(12.5))
                    }
                    .foregroundColor(look.inkSoft)
                }
                Spacer(minLength: 0)
                Button { showFloorCity = true } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "location.fill").font(.system(size: 11, weight: .semibold))
                        Text(floorCity.display).font(pf(13)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundColor(look.ink)
                    .padding(.horizontal, 11).frame(height: 30)
                    .background(Capsule().fill(look.cardFill))
                    .overlay(Capsule().stroke(look.cardStroke, lineWidth: 0.6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .modifier(FloorPop(up: floorUp, t: t, delay: 0.02))

            Color.clear.frame(height: 12)

            /* 搜索框（居中；底色/描边跟着天色走，白天白玻璃、夜里黑玻璃） */
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Image(systemName: "magnifyingglass").font(.system(size: 13.5, weight: .medium))
                Text(Tr("搜索小程序")).font(pf(14.5))
                Spacer(minLength: 0)
            }
            .foregroundColor(look.inkSoft)
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(look.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(look.cardStroke, lineWidth: 0.6))
            .padding(.horizontal, 22)
            .contentShape(Rectangle())
            /* ⚠ 2026-10-16 用户：「二楼的搜索框单独只搜小程序」——
               以前点了走的是会话搜索整页（搜聊天/联系人），现在开**只搜小程序**那一页。 */
            .onTapGesture { showAppSearch = true }
            .modifier(FloorPop(up: floorUp, t: t, delay: 0.04))

            /* 2026-10-17 用户：「二楼还是2排离的很远」——
               把「搜索框→第一组」「两组之间」这两段留白收掉（原来 40 / 44，
               用户看着像两块离得很远的排），行内间距也跟着紧一档。 */
            Color.clear.frame(height: 18)      // 搜索框 → 第一张卡

            /* ── 第一组：最近使用的小程序（2 排 × 4，带「更多 ›」）── */
            /* ⚠ 小程序清单还没拉回来时**这一组整块不画** ——
               以前 apps 为空会退化成"快捷入口那四格"，于是和下面第二组一模一样地出现两遍，
               看起来就是"有时候正常有时候不正常"（网络一抖清单就是空的）。 */
            if !floorRecentApps.isEmpty {
                floorCard(look: look) {
                    floorGroup(title: Tr("最近使用的小程序"), more: true,
                               apps: floorRecentApps, look: look, t: t, delay: 0.06)
                }
            }

            if !floorActions.isEmpty {
                Color.clear.frame(height: 12)  // 两张卡之间
                /* ── 第二组：快捷入口（扫一扫 / 收付款 / 搜一搜 / 发起群聊）
                       —— 微信那一组是「常用的小程序」且**没有「更多」**，我们用自己这四个动作顶上，
                       排法、尺寸、留白和第一组完全一致。 ── */
                floorCard(look: look) {
                    floorGroup(title: Tr("快捷入口"), more: false,
                               apps: [], actions: floorActions, look: look, t: t, delay: 0.28)
                }
            }

            Spacer(minLength: 0)
            /* 最底那一条：二楼底下露出被它顶下去的**会话列表开头**那一层
               （微信截图里是「微信（2233）」那一行）。
               用户要求：**二楼里不要出现「智信」这个标题**，所以这一条只留"一层页"的样子，
               不再写字；点一下照样收起二楼。 */
            Button {
                withAnimation(floorAnim) { floorUp = false }
            } label: {
                HStack(spacing: 0) {
                    /* ⚠ 2026-10-16 用户：「二楼下面的折叠区域居中标题（数字）」——
                       这一条以前照"二楼里不要出现智信这个标题"做成空的，
                       现在按微信那样：**居中显示当前这一页的标题 + 未读数字**
                       （微信截图里那行就是「微信（2233）」）。 */
                    Text(navTitle)
                        /* 2026-10-17 用户：「星言（）字合适一点」——
                           这一条加高到和商城二楼一样之后，15pt 就显得小了，
                           改成 17pt（和顶栏标题一个字号）。 */
                        .font(pf(17, .medium))
                        .foregroundColor(look.ink)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 16)
                /* 参考图里那一条正好是 **80pt 高、文字居中** ——
                   而且它看着像"被二楼压着一层"：行底再罩一层淡紫（就是二楼那层烟透下来），
                   顶上加一道渐隐，让二楼和这一条连在一起（不是突然断开）。 */
                /* 「两页叠一起一点点」：这一条做成**从二楼底下露出来的一层页**——
                   上面两个角是圆的、比二楼收窄一点，看着就是底下还压着另一页。 */
                /* 底下"两页叠一起"那一条的高度：后台键 floorBottomH（默认 52pt）。
                   高度会在 20 ~ 底栏高度（56pt）之间自适应 —— 太矮看着像一条线，
                   太高就压到底栏的份额了。
                   圆角走苹果那套**连续弧角**（continuous），半径后台键 floorBottomRadius（默认 14）。 */
                /* 2026-10-17 用户：「折叠页的高度和你做的商城二楼高度一致」——
                   商城二楼底下那条是 `54 + 安全区`，这里照同一个数（原来 52 还被底栏高度卡着，
                   比商城那条矮一截）。后台 floorBottomH 写个数就覆盖它。 */
                .frame(height: max(44, floorBottomHNow))
                .frame(maxWidth: .infinity)
                .background(
                    /* 折叠页那条也跟着天色走：白天压一层白、夜里压一层黑，
                       压在天气背景上都看得清（以前是固定的"紫烟"色） */
                    look.darkInk ? Color.white.opacity(0.34) : Color.black.opacity(0.18)
                )
                .clipShape(RoundedRectangle(cornerRadius: max(0, UIConfig.num("floorBottomRadius", 14)),
                                            style: .continuous))
                .padding(.horizontal, 10)
                .shadow(color: .black.opacity(0.25), radius: 8, y: -3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(FloorPop(up: floorUp, t: t, delay: 0.24))
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
        /* 「烟雾感」= 照桌面 安全 文件夹那张参考图**量的颜色**做的三层：
           ① 底：上深下浅的深紫蓝渐变（图里量到 #1B1A2A → #2B283C → 上浅到 #322F44，
              这就是微信二楼背后那层"烟"）
           ② 一层很薄的磨砂：后面的会话列表透上来一点点（烟才像烟，不是一块色板）
           ③ 左上一团极淡的高光：烟在空中散开的那种不均匀 */
        /* 2026-10-17 用户：「背景也改成天气系统吧」——
           会话页二楼背景换成**和商城二楼同一套**天气系统：真实天气 × 真实昼夜。
           晴/少云/多云/阴/雾/小雨/雨/雪/雷雨各不一样（云飘、星星闪、流星、
           雨雪下落都在动），上叠清晨/白天/黄昏/夜里四套色调。
           文字颜色由 look.ink 自动切（白天深字、夜里白字），都看得清。
           （后台 floorBg* / floorSmoke* 那几个键不再用于背景，留着不删，免得老配置读不到。） */
        /* ⚠ 这里**不再自己画天色**（2026-10-17 用户：「顶栏没有下雨的动效」）：
           天色改挂到外面**整块滑板**的背景上（见 body 里那个 .background 的天色）——
           挂在这里只铺得到内容块本身（顶栏那一条还是灰的），
           而且两处各画一张的话，雨丝相位对不上，二楼中间会出现一条"接缝"。 */
    }

    private func floorItem(_ title: String, _ symbol: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(C.label)
                Text(Tr(title))
                    .font(pf(12))
                    .foregroundColor(C.subLabel)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /* ============================================================
       二楼那两组（照用户给的微信二楼截图**量的数**做）

       量到的关键数字（1260×2736 的 3x 图，换算成 pt）：
         · 图标 48pt（圆角方块）· 图标下面的名字 12~13pt、间距 ≈11
         · 4 列中心距 ≈94.6pt（首列中心距左 68，左右对称）
           → 网格左右边距 21（(420-4×94.6)/2 ≈ 21），图标在每列里居中
         · 标题行左右边距 ≈33；标题 → 图标 ≈18；两排之间 ≈18；两组之间 ≈44
       ============================================================ */
    /* 一张玻璃卡（二楼里每一组都装进一张卡里）—— 颜色跟天色走：
       白天白玻璃 + 细黑边，夜里黑玻璃 + 细白边。 */
    @ViewBuilder private func floorCard<V: View>(look: MallWeatherLook,
                                                 @ViewBuilder _ content: () -> V) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(look.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(look.cardStroke, lineWidth: 0.6))
            .padding(.horizontal, 14)
    }

    /// 「早上好 / 中午好 / 下午好 / 晚上好 / 夜深了」——按当前钟点说一句
    private var floorGreeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<11:  return Tr("早上好")
        case 11..<14: return Tr("中午好")
        case 14..<18: return Tr("下午好")
        case 18..<23: return Tr("晚上好")
        default:      return Tr("夜深了")
        }
    }

    /// 「多云 22°」——真实天气（服务器拉的，和背景同一份数据）
    private func floorWeatherLine(_ l: MallWeatherLook) -> String {
        if mallWeather.failed { return Tr("天气暂时拿不到") }
        let name: String
        switch l.cond {
        case "clear":    name = "晴"
        case "partly":   name = "少云"
        case "cloudy":   name = "多云"
        case "overcast": name = "阴"
        case "fog":      name = "雾"
        case "drizzle":  name = "小雨"
        case "rain":     name = "雨"
        case "snow":     name = "雪"
        case "thunder":  name = "雷雨"
        default:         name = "多云"
        }
        return name + " " + String(Int(round(mallWeather.temp))) + "°"
    }

    private func floorGroup(title: String, more: Bool, apps: [MiniApp],
                            actions: [(String, String, String)] = [],
                            look: MallWeatherLook,
                            t: CGFloat, delay: Double) -> some View {
        /* ⚠ 2026-10-16 用户：「二楼改回去把」——
           前面几版试过「排紧一点」「6 个以内一行放完」，用户不要，**改回原来那版**：
           固定 4 个一排、间距 18、左右边距 21、图标 48 ——
           这几个数当初是照微信二楼截图 1:1 量的，原样恢复。 */
        /* ⚠ 只画传进来的东西：apps 为空且 actions 也为空 = 这一组不画。
           以前 apps 为空会自动退回 floorActions → 两组长得一模一样（用户说的
           「小程序有时候正常有时候不正常」就是这个）。 */
        let cells: [AnyView] = apps.isEmpty
            ? actions.map { AnyView(floorActionCell($0, look: look, t: t, delay: delay)) }
            : apps.map { AnyView(floorAppCell($0, look: look, t: t, delay: delay)) }
        let rows = stride(from: 0, to: cells.count, by: 4).map {
            Array(cells[$0..<min($0 + 4, cells.count)])
        }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(title).font(pf(12.5)).foregroundColor(look.inkSoft)
                Spacer(minLength: 0)
                if more {
                    Text(Tr("更多") + " ›")
                        .font(pf(12.5))
                        .foregroundColor(look.inkSoft)
                        .contentShape(Rectangle())
                        .onTapGesture { path.append("miniapps") }
                }
            }
            .padding(.horizontal, 33)
            .modifier(FloorPop(up: floorUp, t: t, delay: delay))

            Color.clear.frame(height: 14)
            VStack(spacing: 14) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: 0) {
                        ForEach(0..<4, id: \.self) { c in
                            if c < rows[r].count {
                                rows[r][c]
                            } else {
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 21)
        }
    }

    /// 二楼里一个小程序：48pt 图标（有封面用封面，没有就用渐变块 + 那个 emoji）+ 12pt 名字
    private func floorAppCell(_ app: MiniApp, look: MallWeatherLook,
                              t: CGFloat, delay: Double) -> some View {
        Button { floorAppOpen = app } label: {
            VStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [Color(hex: 0x2B2F3A), Color(hex: 0x171B22)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text(app.iconText).font(.system(size: 24))
                    if let cv = app.cover, !cv.isEmpty {
                        RemoteImage(path: cv)
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .frame(width: 48, height: 48)
                Text(app.name)
                    .font(pf(12))
                    .foregroundColor(look.inkSoft)
                    .lineLimit(1)
                    .frame(width: 78)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(FloorPop(up: floorUp, t: t, delay: delay))
        .scaleEffect(floorIconScaleNow, anchor: .center)
    }

    /// 二楼里一个快捷动作（扫一扫 / 收付款 / 搜一搜 / 发起群聊）：同尺寸的 48pt 方块 + 符号
    private func floorActionCell(_ it: (String, String, String), look: MallWeatherLook,
                                 t: CGFloat, delay: Double) -> some View {
        Button { runMiniApp(it.0) } label: {
            VStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(look.darkInk ? Color.white.opacity(0.72) : Color.white.opacity(0.14))
                    Image(systemName: it.2)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(look.ink)
                }
                .frame(width: 48, height: 48)
                Text(Tr(it.1))
                    .font(pf(12))
                    .foregroundColor(look.inkSoft)
                    .lineLimit(1)
                    .frame(width: 78)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(FloorPop(up: floorUp, t: t, delay: delay))
        .scaleEffect(floorIconScaleNow, anchor: .center)
    }

    /// 展开时 1，半开时按 floorIconProg 从 floorIconScale 长到 1（微信那种"由小变大"）
    private var floorIconScaleNow: CGFloat {
        let s0 = UIConfig.num("floorIconScale", 0.45)
        return floorUp ? 1 : (s0 + (1 - s0) * floorIconProg)
    }

    /// 第一组：最近用过的小程序（按本机记录的顺序排，最多 8 个）
    private var floorRecentApps: [MiniApp] {
        guard !floorApps.isEmpty else { return [] }
        /* ⚠ 2026-10-16 用户两次反馈：「二楼的小程序被分割两排」「四国军棋和切水果离得很远」。
           以前这里按"本机最近用过"重排 —— 用过的顺序本来就是随机的，
           于是后台明明挨着配的那两个游戏被拆到两排去了（改稳定排序也救不了：
           它们确实是被"最近用过"分开的）。
           现在**完全按后台配的顺序**（和 Discover 里那一组同一个顺序、游戏是连着的）：
           每次进来位置都固定，两个游戏永远挨在一起。想调顺序就改后台 miniapps.json。 */
        return Array(floorApps.prefix(8))
    }

    /// 二楼那几格从后台配（ui.json 的 miniApps 一行一个：动作|名字|图标）；
    /// 没配就用内置这四格。动作支持：scan / pay / search / group（其它动作先忽略）。
    private var miniApps: [(String, String, String)] {
        let raw = UIConfig.text("miniApps", "")
        var out: [(String, String, String)] = []
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }
            if parts.count >= 3, !parts[0].isEmpty {
                out.append((parts[0], parts[1], parts[2]))
            }
        }
        if out.isEmpty {
            return [("scan", "扫一扫", "qrcode.viewfinder"),
                    ("pay", "收付款", "creditcard"),
                    ("search", "搜一搜", "magnifyingglass"),
                    ("group", "发起群聊", "person.2.fill")]
        }
        return Array(out.prefix(4))
    }

    /// 二楼第二组的"快捷入口"就是这四格（和上一版一样，只是换了尺寸/位置）
    private var floorActions: [(String, String, String)] { miniApps }

    private func runMiniApp(_ action: String) {
        switch action {
        case "scan": showScan = true
        case "pay": showPayCode = true
        case "search": showSearch = true
        case "group": path.append("newGroup")
        default: app.show(Tr("这个入口还没接"))
        }
    }

    /// 顶部遮罩（会话页）。**2026-10-11 B146 用户要求「照微信那条改」**：
    /// 以前是「滚多少浮多少」—— 把材质和染色**一起乘滚动量**（t = scrolled/80 的 0.8 次方），
    /// 结果滚到一半时顶栏是块半透色板，正文从它底下露出一截，糊又没糊透，怎么调都不像微信。
    /// 微信那条是**常显材质栏**：它从头到尾一个样，变的是**底下内容被糊掉**，不是栏自己变淡。
    /// 所以现在不跟滚动了，一直在那儿（底色和列表底色是同一个色，不滚的时候本来也看不出边界）。
    /// ⚠ 两个键还在，别删：
    ///   · chatsNavGlassAlpha = **模糊（磨砂）**多强（现在 ui.json 配 0.2）；
    ///   · chatsNavMaskAlpha  = **遮罩底色**多实（现在配 1 = 不透明，跟页面底色一致）；
    ///     想留一点透，把 chatsNavMaskAlpha 往下调（0.7~0.85），不用重新打 App。
    @ViewBuilder private func chatsNavGlass(_ scrolled: CGFloat) -> some View {
        let blur = UIConfig.num("chatsNavGlassAlpha", 1)
        let mask = UIConfig.num("chatsNavMaskAlpha", 0.25)
        /* 微信顶栏的质感 = **iOS 系统栏材质**（`.bar`：模糊 + vibrancy，跟着系统外观自动换）：
             · blur（chatsNavGlassAlpha）= 系统材质多实
             · mask（chatsNavMaskAlpha）= 上面那层染色压多浓
             · 染色 = 后台「会话页顶栏遮罩颜色」，不配就跟页面底色一致（#EDEDED） */
        ZStack {
            Rectangle().fill(.bar)
                .opacity(max(0, min(1, blur)))
            (UIConfig.colorIfSet("chatsNavMaskColor") ?? C.chatsPageBg)
                .opacity(max(0, min(1, mask)))
        }
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)      // 只是背景：绝不吃手势
    }

    var body: some View {
        NavigationStack(path: $path) {
            /* 列表**整页铺满**（含顶栏底下）：滚动时会话会从顶栏那层薄玻璃后面滑过去 ——
               这就是用户要的那点「透」。顶栏最后画，永远压在最上面。
               （以前是 VStack：列表一定从顶栏下面开始，永远滚不到玻璃底下，所以看着像块实色板。） */
            ZStack(alignment: .top) {
                if app.chats.isEmpty {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: L.safeTop + L.navH)
                        emptyView
                        Spacer(minLength: 0)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            /* 顶上留出顶栏的高度：第一条会话还是从顶栏下面开始 */
                            /* 顶上留位：顶栏那一段（固定值）。
                               ⚠ 这里**不能**再跟着 floorReveal 变：以前二楼展开时把列表整体
                               顶下去一整屏，收起来时光是把这一整屏缩回去，
                               滚动视图自己会带一点回弹 —— 用户看到的
                               「收起来的时候会话页会上下弹一下」就是它。
                               底下那条"两页叠一起"是二楼自己画的，不需要真的把列表推下去。 */
                            Color.clear.frame(height: L.safeTop + L.navH)
                            ForEach(list) { chat in
                                SwipeChatRow(
                                    chat: chat,
                                    onOpen: { openRow(chat) },
                                    /* 只有真的机器人（botRank 0/1/2）点头像才弹「官方账号」名片；
                                       好友/群聊点头像跟整行一样进聊天（微信就是这样） */
                                    onTapAvatar: ((chat.botRank ?? 9) < 9) ? { botCardChat = chat } : nil,
                                    onUnread: { markUnread(chat) },
                                    onHide: { clear in hide(chat, clear: clear) },
                                    onDelete: { remove(chat) }
                                )
                            }
                            /* ⚠ 列表最后一条要给**底栏**留出位置（用户反馈：最后一行被底栏挡住、
                               而且滚不上来）。底栏是浮在列表上面的，内容刚好满屏时最后一条就压在
                               它底下 —— 微信这里也是留一段空白，最后一条能完整滚进可视区。 */
                            Color.clear.frame(height: L.tabH + L.safeBottom + 10)
                        }
                        /* 探针：量列表滚了多少（顶栏那层磨砂/遮罩靠它淡入）。
                           ⚠ 以前这个探针挂在**第一行**上，一滚过第一行 LazyVStack 就把那一行回收，
                           探针没了 → 系统报回 0 → 遮罩以为"没滚"就收掉了（用户看到的
                           「过了第二行遮罩就没了」就是这个）。挂在整块内容上就不会被回收。 */
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(
                                    key: ChatsScrollKey.self,
                                    value: -g.frame(in: .named("chatsScroll")).minY)
                            }
                        )
                    }
                    .coordinateSpace(name: "chatsScroll")
                    /* 二楼：直接用**拖动手势**驱动（simultaneous = 只观察、不抢滚动），
                       不再只依赖滚动探针 —— 手指在列表最上面往下拖就一定露出来，
                       而且是**跟着手指连着滑**（不是"空一块"）。 */
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { g in
                                guard scrolled < 8 else { return }      // 只有（基本）回到顶部才认这个下拉
                                let dy = g.translation.height
                                if floorOn, dy > 0 {
                                    pullDown = heavyPull(dy)
                                    /* 每点亮一颗提示点震一下（越往后越重，像压感） */
                                    let step = max(1, floorPull / 3)
                                    let lit = min(3, Int(dy / step))
                                    if lit != floorTick {
                                        floorTick = lit
                                        if lit > 0 {
                                            /* 用户要求"拉下来再加重"：前两颗 medium、第三颗 heavy；
                                               整体轻重走后台键 floorHaptic（0 关 / 1 轻 / 2 中 / 3 重） */
                                            floorImpact(lit >= 3 ? 3 : 2)
                                        }
                                    }
                                } else if !floorUp {
                                    pullDown = 0
                                    floorTick = 0
                                }
                            }
                            .onEnded { g in
                                /* 弹簧 + 阻尼：拉过阈值就"吸"上去停在二楼（会有一点回弹），
                                   没拉够就软软地弹回去（不是硬切）。
                                   阈值由后台 chatsFloorPull 控制，默认 **120pt**
                                   （原来 70pt 太浅，用户反馈"二楼一直误触"）。 */
                                /* 防误触（用户反馈"还是会误触"）：
                                   ① 拉够阈值
                                   ② **松手时速度不快**（快速上滑蹭到顶部时 predictedEnd 冲得很远，
                                      这种是"滑到头弹一下"，不该开二楼）—— 只认慢慢拉过去的。 */
                                let fling = abs(g.predictedEndTranslation.height - g.translation.height)
                                let open = floorOn && pullDown > floorPull && fling < 220
                                /* 二楼下来那一下**振动加强**（用户要求）：heavy + 80ms 后再补一下 medium，
                                   摸着是"咚"的一下，比原来的 light 明显得多。 */
                                if open {
                                    floorImpact(3)
                                    if floorHaptic >= 2 {
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                                        }
                                    }
                                }
                                floorTick = 0
                                withAnimation(floorAnim) {
                                    floorUp = open
                                    pullDown = 0
                                }
                            }
                    )
                    .onPreferenceChange(ChatsScrollKey.self) { v in
                        let s = max(0, v)
                        /* 开始滚列表 → 把滑开的会话行收回去（微信就是这样的） */
                        if s > 8 { NotificationCenter.default.post(name: .chrisRowSwipe, object: nil) }
                        /* 探针万一被回收/报 0，别把已经滚起来的顶栏遮罩又收回去 ——
                           只在「确实回到顶部」或「真的滚得更远」时才改 */
                        if s > scrolled || s < 1 {
                            if abs(s - scrolled) > 0.5 { scrolled = s }
                        }
                        /* 下拉的那一段（v 是负的）就是「二楼」露出来的高度：完全靠列表自己的
                           橡皮筋，不需要我们再挂一层手势，所以不会跟滚动抢手势。 */
                        let p = heavyPull(max(0, -v))
                        if abs(p - pullDown) > 0.5 { pullDown = p }
                        /* 二楼**只在松手那一下判断**（onEnded 里），不再拉到一半就自己弹出来 ——
                           之前"滑到头弹一下"也会被这里判定成开二楼，就是误触的主因。
                           阈值后台键：chatsFloorPull（现在 180pt）。 */
                        if s > 14, floorUp { floorUp = false }     // 往上滚 = 收起二楼
                    }
                    /* 列表不加底色，而且允许它滚到安全区（顶栏）底下 */
                    .ignoresSafeArea(edges: .top)
                    .background(Color.clear)
                    .refreshable { await app.loadChats() }
                }

                /* 顶栏固定不动 —— 画在列表上面（那层薄玻璃就是"透"的来源） */
                /* 「二楼」：往下拉的时候，顶栏下面让出来的那块空档里露出来的这层
                   （微信那层是"最近使用的小程序"）。它完全跟着**列表自己的下拉量**走，
                   不额外挂手势；只有拉出来超过 60pt 才接收点击，所以不会抢滚动/点击手势。 */
                if pullDown > 0.5 || floorUp {
                    ZStack(alignment: .top) {
                        /* ── B30 那版（用户指定按它改）：拉到第三个压感点（chatsFloorPull）
                           之后页面才浮出来，容器高度 = 当前下拉距离，跟着手指走。 ── */
                        if floorUp || pullDown >= floorPull {
                            miniFloor
                                .frame(maxWidth: .infinity, alignment: .top)
                        }

                        /* 压感提示：**1 个点 → 2 个点 → 3 个点**，颜色跟着由浅到深；
                           点到第三个（= chatsFloorPull，默认 180pt）二楼才算真的打开 ——
                           微信二楼就是这种"越拉越实"的力度感。 */
                        VStack(spacing: 0) {
                            Spacer().frame(height: floorUp ? L.safeTop + 10 : 8)
                            pullDots
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                        .opacity(floorUp ? 0 : 1)
                    }
                        .frame(height: floorReveal)
                        .frame(maxWidth: .infinity, alignment: .top)
                        /* ⚠ 内缩必须留在 frame **外面**（B30 就是这样）：
                           铺满时 padding=0，顶上那条遮罩才正好压在时间/信号上；
                           拉到一半时 padding=状态栏+顶栏，页面不会钻到时间底下。
                           （曾经把它挪进 frame 里面，等于把整页往下推 55pt，
                           底下那条就掉到屏幕外了 —— 用户："叠加条改没了"。） */
                        .padding(.top, floorInset)
                        /* ⚠ 2026-10-16 用户：「二楼遮住时间的那段颜色不要拼接的感觉 /
                           就是最早那种二楼连一起的感觉」。
                           上一版在这条上又从**安全区下面**（.padding(.top, safeTop)）
                           单独压了一层 46pt 的黑渐变 —— 于是"时间那一段"和下面
                           **不是同一个面**，看着就是上下两块颜色拼起来的。
                           现在：这一层**整块不压**，二楼自己的那层烟（floorBg1…4 渐变 +
                           一点磨砂 + 左上那团高光）从屏幕最顶上一直连到最底下，是一个面；
                           时间看不清的问题由**状态栏文字切白**解决（见 StatusBarStyle）。 */
                        .frame(maxWidth: .infinity, alignment: .top)
                        .clipped()
                        /* 2026-10-17 用户：「顶栏没有下雨的动效」（会话页）——
                           天色原来只铺在**二楼的内容块**上：内容块自己带着内缩
                           （状态栏 + 顶栏那一段），雨丝/雪花/雷闪就只在下半截动，
                           顶上那一条永远是块灰的 —— 用户看到的就是这个。
                           现在天色挂在**整块滑板**（含顶上那段内缩）当背景：
                           负的 top padding 再往顶上多铺「状态栏 + 顶栏」一整段，
                           所以从屏幕最顶上（时间/信号那一条）一路铺到内容块下边缘，
                           雨丝在顶栏里也看得见；下边缘和内容块**严格同一条线**
                           （背景和外框共用一个 frame，不会差出一截）。
                           顶栏那层玻璃跟着下拉淡出（见 chatsNavGlass 那条的 opacity），
                           天色才透得出来。 */
                        .background {
                            MallSkyBackground(look: MallWeatherLook.current(mallWeather))
                                .padding(.top, -(L.safeTop + L.navH))
                                .ignoresSafeArea()
                        }
                        .allowsHitTesting(floorOn && (pullDown > floorPull * 0.6 || floorUp))
                        /* 二楼本身滑出来那一下：floorPopBounce=0 用纯缓动（一点都不弹），
                           开着的时候才是弹簧（damping 1.0，不带过冲）。 */
                        .animation(floorBounce
                                   ? .spring(response: floorAnimDur, dampingFraction: 1.0)
                                   : .easeOut(duration: floorAnimDur),
                                   value: floorUp)
                }

                VStack(spacing: 0) {
                    NavBar(title: navTitle,
                           /* 2026-10-16 用户：「会话页标题旁边的数字加入数字滚动效果」——
                              未读数单独用 RollingNumber 画（值一变，每位数字往上滚一格）。
                              离线那种「星言（未连接）」还是走原来的纯文字。 */
                           titleView: (!app.offline && unreadTotal > 0) ? AnyView(
                               HStack(spacing: 0) {
                                   Text(C.tabText0)
                                       .font(pf(17, .semibold))
                                       .foregroundColor(C.label)
                                   RollingNumber(value: unreadTotal,
                                                 font: pf(17, .semibold),
                                                 color: C.label, height: 20)
                               }
                           ) : nil,
                           /* 二楼拉开时，**顶栏那两块（小星眼睛 / 放大镜）不在二楼里显示**（用户要求） */
                           leftExtra: floorUp ? nil : AnyView(
                            /* 左边两块独立玻璃：小星眼睛 + 放大镜（放大镜就在眼睛右边） */
                            HStack(spacing: 8) {
                                /* 小星开着才画那双眼睛（档位在「我 → 插件 → 小星」里改）；
                                   关了这格直接不占位 —— 放大镜就顶到眼睛原来的位置 */
                                /* ⚠ 用 navEyesOn（不是 eyesOn）：档位没确定之前先不画 ——
                                   以前默认按"开"画，真档位两秒后才到，关了眼睛的人就会
                                   "先看到眼睛、两秒后没了"（2026-10-16 用户反馈）。 */
                                if eyes.navEyesOn {
                                    Button {
                                        if let bot = app.chats.first(where: { $0.botRank == 0 }) {
                                            botChat = bot
                                        } else {
                                            Task { await app.loadChats()
                                                if let b = app.chats.first(where: { $0.botRank == 0 }) { botChat = b } }
                                        }
                                    } label: {
                                        JarvisEyesAvatar(size: 28, tint: eyesTint)
                                            .frame(width: 36, height: 36)
                                    }
                                    .buttonStyle(.plain)
                                }

                                /* 放大镜：点开「搜索」整页（以前是列表最上面那个搜索框，现在收进这里） */
                                Button {
                                    showSearch = true
                                } label: {
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundColor(C.label)
                                        .frame(width: 36, height: 36)
                                        .background { GlassBackground(shape: Circle(), shadow: true, seed: 0.40) }
                                }
                                .buttonStyle(.plain)

                            }
                            .padding(.leading, 4)
                           ),
                           /* 玻璃胶囊**保留**（标题/左下角那两块还是各自一块玻璃）；
                               「连着下面的会话页」是靠那层只在滚动时才浮起来的薄磨砂做的
                               （见 chatsNavGlass）—— 不滚的时候它和列表同一个底色，看着是一个整体。 */
                           floating: true,
                           leftExtraGlass: false) {
                        Button {
                            /* 弹出的手感：弹簧带动一点回弹（阻尼越小越弹） */
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) { plusMenu = true }
                        } label: {
                            FlexIcon(custom: IconOverrides.custom("nav.plus"),
                                     size: UIConfig.num("navPlusSize", 20),
                                     color: UIConfig.color("navPlusInk", 0xFFFFFF, 0xFFFFFF),
                                     symbol: "plus")
                                .frame(width: UIConfig.num("navPlusW", 44),
                                       height: UIConfig.num("navPlusH", 36))
                                .background(Capsule(style: .continuous)
                                    .fill(UIConfig.color("navPlusBg", 0x0F5A3C, 0x0F5A3C)))
                        }
                        /* 点下去**亮一下 + 轻微缩小**，有"点到了"的手感（用户要求） */
                        .buttonStyle(NavPlusPressStyle())
                    }
                    /* 用户要求：会话页顶栏也要「一点玻璃透」——列表滚到顶栏下面时，
                       透过一层很薄的磨砂能看到一丢丢内容，而不是一块实色板。
                       浓淡后台可调（后台「界面配置 → 界面文字」里的 chatsNavGlassAlpha，
                       默认 0.55；写 0 退回原样）。 */
                    /* 顶栏背景：**先一层"挡点击"的透明层**（属于顶栏自己的背景，
                       所以小星眼睛/放大镜这些按钮永远画在它上面、照常能点），
                       再叠那层会浮出来的玻璃。后台开关 navBarSwallowTouch（默认 1 =
                       点顶栏空白处不会点到下面的会话行；写 0 恢复让路）。 */
                    .background {
                        ZStack {
                            if UIConfig.num("navBarSwallowTouch", 1) > 0 {
                                Color.clear
                                    .frame(height: L.navH)
                                    .contentShape(Rectangle())
                            }
                            chatsNavGlass(scrolled)
                        }
                    }
                    /* 那条细线**只在滚动以后**才出现（不滚时顶栏和列表是一个整体，微信就是这样） */
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(C.navLine).frame(height: 0.5)
                            .opacity(scrolled > 6 ? 1 : 0)
                    }
                    /* 用户要求：二楼里**不要出现「智信」这个标题和右边那个「＋」** ——
                       二楼是盖在列表上的，而顶栏是画在二楼**上面**的，所以这里得自己收掉：
                       二楼拉开时整条顶栏淡出 + 不再吃点击。 */
                    /* 2026-10-17 用户：「顶栏没有下雨的动效」——
                       下拉把二楼那层天色拉出来的时候，顶栏要**跟着下拉一起淡**：
                       淡的过程就是天色（雨丝/雪花/雷闪）从顶栏里露出来的过程，
                       拉满（floorUp）时整条顶栏为 0，和以前一样。 */
                    .opacity(navFadeForFloor)
                    .allowsHitTesting(!floorUp)
                    Spacer(minLength: 0)
                }
            }
            /* 第一页面（会话列表）的底色跟通讯录统一：都用后台的「页面底色」pageBg，
               以前这里用的是 navBg，深色下比通讯录浅一档（#18181A vs #0B0B0D）。 */
            .background(C.chatsPageBg.ignoresSafeArea(edges: .bottom))
            .sheet(isPresented: $showSearch) {
                SearchPage(onOpenChat: { c in path.append(c) })
                    .environmentObject(app)
            }
            .background(C.chatsPageBg.ignoresSafeArea(edges: .top))
            .toolbar(.hidden, for: .navigationBar)
            /* 返回列表这一下：**立刻**把底栏放出来。
               HidesTabBar 恢复底栏是挂在页面 onDisappear 上的，而 onDisappear 要等系统
               退场动画整段走完才触发 —— 底栏就"慢半拍才跳出来"（用户反馈的"返回后
               底部导航跳出来有延迟"）。导航栈回到根 = 一定在列表页，直接把层数清零，
               让底栏跟着返回动画一起滑上来；之后那些迟到的 onDisappear 再扣也只是减到 0。 */
            .onChange(of: path.count) { n in
                if n == 0 { app.tabBarDepth = 0 }
            }
            /* 二楼铺满全屏时**把底栏也盖住**（拉开时收起底栏，收起二楼时底栏自己回来）。
               ⚠ 这条必须挂在**外面这一层**：以前挂在二楼的子树里，二楼一收整棵子树就被移除，
               回调不触发 → floorFull 一直停在 true，底栏再也不回来了（用户反馈「底栏又没了」）。 */
            .onChange(of: floorUp) { v in
                withAnimation(.easeOut(duration: 0.2)) { app.floorFull = v }
                /* 二楼是**深色**的（底色 #121120 起）——顶上整块同色以后，
                   时间/信号要是黑色就看不见了。所以二楼展开时把状态栏文字切白，
                   收起再切回系统默认（微信那套就是这么做的）。
                   ⚠ 必须挂在这一层：二楼子树一收就被移除，挂在里面回调不触发。 */
                StatusBarStyle.shared.set(light: skyStatusLight)
            }
            /* 下拉的时候天色就从顶栏下面钻出来了（见 body 里那张整屏天色滑板）：
               深色天色（夜里/雷雨）把时间/信号切白，浅色天色（白天晴）保持深字。
               不挂这一条的话，下拉到一半顶栏是深色、时间是黑的，看不清。 */
            .onChange(of: pullDown > 8) { _ in
                StatusBarStyle.shared.set(light: skyStatusLight)
            }
            /* 离开会话页（被别的全屏页盖住 / 切到发现页）时把状态栏还给系统，
               不然后面那些浅色页面顶上会留一行白字。 */
            .onDisappear { StatusBarStyle.shared.set(light: false) }
            .navigationDestination(for: Chat.self) { chat in
                chatDest(chat)
            }
            /* 点了推送通知：MainTab 把会话 id 放到 app.pendingPushChatId，
               这里按**列表自己那条导航**把它推进去（和手点一个会话同一条路）。 */
            .onAppear { openPendingPushChat(app.pendingPushChatId) }
            .onChange(of: app.pendingPushChatId) { v in openPendingPushChat(v) }
            /* 公众号那两条会话：点进去是公众号页面（不是聊天页） */
            .navigationDestination(isPresented: $showOA) {
                OfficialAccountPage(accountId: oaOpenId)
            }
            .navigationDestination(isPresented: $showOAList) {
                OfficialAccountsView()
            }
            .navigationDestination(for: String.self) { key in
                if key == "newGroup" {
                    GroupCreateView { chat in
                        /* 建完群直接进这个群：走最外层整页打开，
                           不往导航栈里 push（push 在「刚 pop 掉建群页」那一下容易被系统丢掉，
                           表现就是「建完群没跳进去，要退出来重新点一下」）。 */
                        app.openChatViaList(chat)
                    }
                } else if key == "addFriend" {
                    AddFriendView()
                } else if key == "myQR" {
                    MyQRView()
                } else if key == "miniapps" {
                    /* 二楼第一组右上角那个「更多 ›」→ 小程序列表页（和发现页同一页） */
                    MiniAppsView()
                } else {
                    ComingSoonView(title: key)
                }
            }
        }
        /* 右上角「＋」：下拉小卡片（毛玻璃 + 彩色图标），点别处收起 */
        .navPlusOverlay($plusMenu, items: [
            NavPlusItem(title: Tr("发起群聊"), symbol: "person.2.fill",
                        colors: [C.green, C.green.opacity(0.78)]) { path.append("newGroup") },
            NavPlusItem(title: Tr("添加朋友"), symbol: "person.badge.plus",
                        colors: [Color(hex: 0x64B5F6), Color(hex: 0x2A6BC4)]) { path.append("addFriend") },
            NavPlusItem(title: Tr("扫一扫"), symbol: "qrcode.viewfinder",
                        colors: [Color(hex: 0xFFB627), Color(hex: 0xF08600)]) { showScan = true },
            NavPlusItem(title: Tr("收付款"), symbol: "creditcard.fill",
                        colors: [Color(hex: 0xB98CFF), Color(hex: 0x7A45D6)]) { showPayCode = true }
        ])
        /* 小星对话页：整页打开（点左上角那两只眼睛进来） */
        .fullScreenCover(item: $botChat) { c in
            BotChatView(chat: c).environmentObject(app)
        }
        .fullScreenCover(isPresented: $showScan) {
            ScannerView { text in handleScanned(text, app: app) }
        }
        /* 二楼里点一个小程序：内置浏览器整页打开（和发现页→游戏/小程序同一条路） */
        .fullScreenCover(item: $floorAppOpen) { m in
            GameWebPage(game: m).environmentObject(app)
        }
        /* 二楼那个搜索框：**只搜小程序**（不搜聊天、不搜联系人） */
        .sheet(isPresented: $showAppSearch) {
            MiniAppSearchView(apps: floorApps) { m in
                showAppSearch = false
                floorAppOpen = m
            }
            .environmentObject(app)
        }
        /* 二楼顶上那颗城市（和商城二楼那颗同一页） */
        .sheet(isPresented: $showFloorCity) {
            DDCityPickerView().environmentObject(app)
        }
        /* 二楼一拉开就顺手刷一次天气（背景就是它画的） */
        .onChange(of: floorUp) { up in
            if up { MallWeather.shared.refresh() }
        }
        .sheet(item: $botCardChat) { c in
            BotCardView(chat: c).environmentObject(app)
        }
        .sheet(isPresented: $showPayCode) {
            NavigationStack { PayCodePage() }
                .environmentObject(app)
        }
        .task {
            HitchWatch.shared.start("会话列表")
            /* 二楼第一组要显示「最近使用的小程序」——进页面拉一次后台的小程序清单 */
            /* ⚠ 2026-10-17 用户：「小程序有时候正常有时候不正常」——
               以前这里是 `floorApps = await miniApps()`：网络一抖就拿到空数组，
               直接把列表清空（二楼上那一组就没了/退化成别的东西）。
               现在：**拉到才覆盖，拉不到用本机缓存的那份**，位置永远稳定。 */
            let got = await API.shared.miniApps()
            if !got.isEmpty {
                floorApps = got
                if let d = try? JSONEncoder().encode(got) {
                    UserDefaults.standard.set(d, forKey: "chris.floorApps")
                }
            } else if floorApps.isEmpty,
                      let d = UserDefaults.standard.data(forKey: "chris.floorApps"),
                      let cached = try? JSONDecoder().decode([MiniApp].self, from: d) {
                floorApps = cached
            }
            /* 二楼背景是天气系统：进页面先要一份天气（服务器拉的，10 分钟缓存） */
            MallWeather.shared.refresh()
            // 进页面先拉一次，之后每 4 秒自动刷新一次（这样别人发消息不用切页就能看到）
            while !Task.isCancelled {
                await app.loadChats()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
        /* 点推送通知进聊天：统一交给最外层的 MainTab 处理（它永远在线，
           在别的 tab 上点通知也能进得去；以前挂在会话页，人不在会话页就收不到）。 */
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Spacer()
            Text(app.loadError ?? "正在加载会话…")
                .font(pf(14))
                .foregroundColor(C.subLabel)
            if app.loadError != nil {
                Button(Tr("重试")) { Task { await app.loadChats() } }
                    .font(pf(15))
                    .foregroundColor(C.green)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(C.chatsPageBg)
    }

    private func markUnread(_ chat: Chat) {
        Task {
            await API.shared.markUnread(chatId: chat.id)
            await app.loadChats()
            app.show(Tr("已标为未读"))
        }
    }

    private func hide(_ chat: Chat, clear: Bool) {
        Task {
            let err = clear
                ? await API.shared.deleteChat(chatId: chat.id)
                : await API.shared.hideChat(chatId: chat.id)
            await app.loadChats()
            app.show(err ?? (clear ? "已清空记录并设为不显示" : "已不显示该聊天"))
        }
    }

    private func remove(_ chat: Chat) {
        Task {
            let err = await API.shared.deleteChat(chatId: chat.id)
            await app.loadChats()
            app.show(err ?? "已删除")
        }
    }

    /// 点了推送通知要进的那个会话（app.pendingPushChatId）：
    /// 列表还没加载好就等一会儿（最多 8 秒），加载好了**用列表自己的导航** push 进去。
    /// 2026-10-12 用户：「点推送通知依旧闪退」—— 以前是 MainTab 用最外层 fullScreenCover
    /// 整页压聊天页，冷启动那几帧会打架被系统杀掉；改成走这一条
    /// （和用户手点一个会话**完全同一条路**，那条路日志里一直正常）。
    private func openPendingPushChat(_ id: String?) {
        guard let id, !id.isEmpty else { return }
        Task { @MainActor in
            for _ in 0..<40 {
                if app.chats.contains(where: { $0.id == id }) { break }
                await app.loadChats()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard let c = app.chats.first(where: { $0.id == id }) else {
                app.pendingPushChatId = nil
                app.show(Tr("找不到这个会话"))
                CrashCatcher.note("推送", "列表里没有这个会话 " + id)
                return
            }
            app.pendingPushChatId = nil
            CrashCatcher.note("推送", "交给会话列表打开 " + id)
            /* 让列表先画出来那一帧，再把会话推进去（不然 push 和首次渲染撞一起） */
            try? await Task.sleep(nanoseconds: 350_000_000)
            path.append(c)
        }
    }
}

/// 会话页 / 星联页右上角那个 ＋：按下去亮一下（像灯被按亮），松手回弹
/// 会话列表滚了多少（顶栏那层薄磨砂按它淡入）
private struct ChatsScrollKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct NavPlusPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            /* 用户要求：照 WhatsApp 那颗圆钮的手感 —— 按下去**中间一块特别亮**，
               光往外很快淡掉（不是整块一起泛白），中心再补一点过曝的白点。 */
            .overlay {
                ZStack {
                    RadialGradient(colors: [Color.white.opacity(0.95),
                                            Color.white.opacity(0.30),
                                            Color.white.opacity(0)],
                                   center: .center, startRadius: 0, endRadius: 34)
                    Circle()
                        .fill(Color.white.opacity(0.55))
                        .frame(width: 16, height: 16)
                        .blur(radius: 7)
                }
                .blendMode(.plusLighter)
                .opacity(configuration.isPressed ? 1 : 0)
                .clipShape(Capsule(style: .continuous))
                .allowsHitTesting(false)
            }
            .brightness(configuration.isPressed ? 0.10 : 0)
            .shadow(color: Color.white.opacity(configuration.isPressed ? 0.5 : 0), radius: 10)
            .animation(.easeOut(duration: 0.13), value: configuration.isPressed)
    }
}

/* ------------------------------------------------------------ 二楼的"动感" */

/// 二楼里每一块的入场动画：
/// · 拉的过程中跟着手指长出来（t = 下拉进度，0→1）
/// · 松手停住时（up = true）按 delay 错开弹一下 —— 越靠下的越晚，像一层层浮上来
/// 这样整页不是"一起硬切"，是有一点点层次和阻尼感的。
private struct FloorPop: ViewModifier {
    var up: Bool
    var t: CGFloat
    var delay: Double

    /* 微信那套四楼（下拉二楼）里，二楼的内容是**一直在那儿的**：
       手指往下拉多少，就露出多少 —— 里面每一块从来不单独淡入 / 缩放 / 位移。
       （用户："出来画面的时候不要整个出来，和微信感觉一样的出来"。）
       所以这里什么都不做，只是保留这个修饰器，方便以后想再打开动效。 */
    func body(content: Content) -> some View {
        content
    }
}
    /// 包一层只是为了**进聊天页前先打一条点**（只有这条、没有「9 页面出现」的话，
    /// 说明崩在 ChatDetailView 的构建里，而不是在上面这一层）
    private func chatDest(_ chat: Chat) -> some View {
        /* 顺带把内存也记上（B156 那版就是这么记的）：43MB 那种数字能一眼看出
           到底是不是"内存太大被系统杀掉"。2026-10-12 这次排查又把这条补回来了。 */
        CrashCatcher.note("聊天页", "8 准备打开 " + chat.id + memNote())
        /* ⚠ 2026-10-13：不再直接把那个巨型聊天页塞进 push —— 先渲染一个很轻的占位，
           等 0.4 秒转场过去再把真页面换上来（避免「场景更新看门狗」把进程杀掉，
           见 ChatDeferred.swift 里的说明）。聊天页本身保持 B218 原样。 */
        return DeferredChatView(chat: chat)
    }

    /// 「内存43MB(剩6613MB)」——进会话前记一条，用来判断是不是 jetsam（内存）杀的
    private func memNote() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return " 内存读不到" }
        let used = Int(Double(info.phys_footprint) / 1_048_576.0)
        let left = Int(Double(info.limit_bytes_remaining) / 1_048_576.0)
        return " 内存\(used)MB(剩\(left)MB)"
    }

/* ============================================================
   二楼的搜索页：**只搜小程序**（2026-10-16 用户：「二楼的搜索框单独只搜小程序」）

   以前那个框点了开的是会话搜索整页（搜聊天、搜联系人），
   微信二楼那个框其实只搜小程序 —— 这里单独做一页：一个输入框 + 匹配到的小程序，
   点一条就用内置浏览器整页打开。
   ============================================================ */
struct MiniAppSearchView: View {
    let apps: [MiniApp]
    var onOpen: (MiniApp) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var q = ""

    private var hits: [MiniApp] {
        let key = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return apps }
        return apps.filter { $0.name.contains(key) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundColor(C.subLabel)
                    TextField(Tr("搜索小程序"), text: $q)
                        .font(pf(14.5))
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.search)
                    if !q.isEmpty {
                        Button { q = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15))
                                .foregroundColor(C.subLabel)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.dyn(0xEDEDED, 0x2C2C2E)))

                Button(Tr("取消")) { dismiss() }
                    .font(pf(15))
                    .foregroundColor(C.label)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(hits) { m in
                        Button {
                            dismiss()
                            onOpen(m)
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(LinearGradient(colors: [Color(hex: 0x2B2F3A), Color(hex: 0x171B22)],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                                    Text(m.iconText).font(.system(size: 18))
                                    if let cv = m.cover, !cv.isEmpty {
                                        RemoteImage(path: cv)
                                            .frame(width: 36, height: 36)
                                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    }
                                }
                                .frame(width: 36, height: 36)
                                Text(m.name)
                                    .font(pf(16))
                                    .foregroundColor(C.label)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Chevron(size: 9, line: 1.6)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 56)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        HairLine(inset: 64)
                    }
                    if hits.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 26))
                                .foregroundColor(C.subLabel.opacity(0.6))
                            Text(Tr("没有找到这个小程序"))
                                .font(pf(14))
                                .foregroundColor(C.subLabel)
                        }
                        .padding(.top, 60)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .background(C.pageBg.ignoresSafeArea())
    }
}
