import SwiftUI
import UIKit

/* ============================================================
   聊天页「贴底」用它：直接命令底层的 UIScrollView 滚到**最大偏移**。

   为什么不用 SwiftUI 的 scrollTo(anchor: .bottom)：
   锚点对齐是按滚动视图的框算的，不一定会把安全区（输入框那一条）算进去，
   结果最后一行气泡会落在输入框下面 —— 用户反馈的「字掉到聊天框下面」。
   而「滚到最大偏移」用的是 UIKit 自己算出来的边界（contentInset / 安全区都算过），
   贴到底时最后一条一定停在输入框上方那条线上。
   ============================================================ */
final class ChatScrollHandle {
    static let shared = ChatScrollHandle()
    weak var scroll: UIScrollView?

    /// 滚到真正的底部。滚到了返回 true（拿不到滚动视图时返回 false，调用方再退回 SwiftUI 那套）
    @discardableResult
    func pinToBottom(animated: Bool) -> Bool {
        guard let sv = scroll, sv.window != nil else { return false }
        let bottom = sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom
        let y = max(bottom, -sv.adjustedContentInset.top)
        sv.setContentOffset(CGPoint(x: 0, y: y), animated: animated)
        return true
    }

    /// 现在离底部还有多远（pt，<=0 就是已经贴到底了）。
    /// ⚠ 四个数全从 UIScrollView 自己身上取，不和 SwiftUI 量的高度混着算 ——
    /// 混着算会差出两三百点（一边算进安全区一边没算进），「跟不跟新消息」就会被判错。
    /// 拿不到滚动视图时返回 nil（调用方就保持原状，别乱改）。
    var gap: CGFloat? {
        guard let sv = scroll, sv.window != nil else { return nil }
        let maxY = sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom
        return maxY - sv.contentOffset.y
    }

    /// 手指还在拖 或者 松手后惯性还没停 —— 这时候位置才是"用户定的"
    var moving: Bool {
        guard let sv = scroll else { return false }
        return sv.isDragging || sv.isDecelerating || sv.isTracking
    }
}

/* ============================================================
   聊天页「自己上下滚」的诊断（诊断版专用）

   每一次会动到滚动位置的调用都记一行：**时间 + 是谁触发的 + 当时离底部多远 + 手指在不在滑**。
   屏幕上直接显示最近十几条 —— 用户截图给我，就能一眼看出是"哨兵误判"、"键盘事件"、
   "图片解码补底" 还是"上翻钉位"在把列表推来推去。

   开关：后台 data/ui.json 里写 chatScrollDiag = 1（默认 0，正式版用户看不见）。
   ============================================================ */
final class ChatScrollDiag: ObservableObject {
    static let shared = ChatScrollDiag()
    @Published private(set) var lines: [String] = []

    private let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func note(_ reason: String) {
        let gap = ChatScrollHandle.shared.gap
        let g = gap.map { String(Int($0)) } ?? "?"
        let hand = ChatScrollHandle.shared.moving ? "指" : "-"
        let line = fmt.string(from: Date()) + " " + hand + " 离底" + g + "  " + reason
        if Thread.isMainThread {
            push(line)
        } else {
            DispatchQueue.main.async { self.push(line) }
        }
    }

    private func push(_ line: String) {
        lines.append(line)
        if lines.count > 14 { lines.removeFirst(lines.count - 14) }
    }

    func clear() { lines.removeAll() }
}

/// 诊断面板：半透明黑底 + 最近十几条记录（点一下清空）
struct ChatScrollDiagView: View {
    @ObservedObject private var diag = ChatScrollDiag.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text("滚动诊断 · 点一下清空")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                Spacer(minLength: 0)
                Text(diag.lines.isEmpty ? "（还没有记录）" : "\(diag.lines.count) 条")
                    .font(.system(size: 9.5))
                    .foregroundColor(.white.opacity(0.7))
            }
            ForEach(diag.lines.indices, id: \.self) { i in
                Text(diag.lines[i])
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.72))
        .contentShape(Rectangle())
        .onTapGesture { diag.clear() }
        .allowsHitTesting(true)
    }
}

/* ============================================================
   实时读 ScrollView 的 contentOffset（用 UIKit 订阅，比 SwiftUI 的
   PreferenceKey 稳得多）—— 会话页「下拉二楼」要靠它判断「是不是已经
   在最上面」，以前用 GeometryReader 读偏移经常读不到，导致拉不下来。
   ============================================================ */
struct ScrollOffsetProbe: UIViewRepresentable {
    final class Coordinator {
        var obsOffset: NSKeyValueObservation?
        var obsDrag: NSKeyValueObservation?
        var obsBounds: NSKeyValueObservation?
        var obsSize: NSKeyValueObservation?
        var scroll: UIScrollView?
        var report: (CGFloat) -> Void = { _ in }
        var reportDrag: (Bool) -> Void = { _ in }
        var reportBounds: () -> Void = { }
        var reportSize: () -> Void = { }

        /// 挂到外层那个 UIScrollView 上，开始报「偏移」和「手指在不在滑」
        func attach(_ sv: UIScrollView) {
            scroll = sv
            ChatScrollHandle.shared.scroll = sv
            /* 列表很短（没几条会话）时默认不会回弹，下拉二楼就拉不出来 —— 强制打开 */
            sv.alwaysBounceVertical = true
            obsOffset = sv.observe(\.contentOffset, options: [.new]) { [weak self] s, _ in
                self?.report(s.contentOffset.y)
            }
            obsDrag = sv.observe(\.isDragging, options: [.new]) { [weak self] s, _ in
                self?.reportDrag(s.isDragging)
            }
            /* 可视区大小变了（键盘弹起/收起、表情面板开关、转屏）：
               聊天区高度一变，原来贴在底部的位置就不对了 —— 得让调用方重新贴一次 */
            obsBounds = sv.observe(\.bounds, options: [.new]) { [weak self] _, _ in
                self?.reportBounds()
            }
            /* 内容尺寸变了（消息变多、长文排完版、图片解码完）：
               这是「贴底要不要再补一次」最硬的信号 —— 不用等 SwiftUI 的偏好值。 */
            obsSize = sv.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                self?.reportSize()
            }
        }
    }

    var onChange: (CGFloat) -> Void
    /// 手指是不是正按着拖（微信那套「下拉二楼」要在松手那一下做判断，光有偏移不够）
    var onDragChange: (Bool) -> Void = { _ in }
    /// 可视区大小变了（键盘/面板/转屏）：聊天页靠它把最后一条重新贴到输入框上方
    var onBoundsChange: () -> Void = { }
    /// 内容尺寸变了：聊天页靠它补底（长文/大图专用）
    var onSizeChange: () -> Void = { }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.report = onChange
        context.coordinator.reportDrag = onDragChange
        context.coordinator.reportBounds = onBoundsChange
        context.coordinator.reportSize = onSizeChange
        Self.bind(uiView, context.coordinator, attempt: 0)
    }

    /// 把探针接到它外面那层 UIScrollView 上。
    /// 视图刚建出来的那一两帧还挂在视图树外面（找不到 UIScrollView），
    /// 所以失败就等 80ms 再来一次，最多 20 次 —— 不然「手指在滑」这个信号永远收不到。
    private static func bind(_ uiView: UIView, _ c: Coordinator, attempt: Int) {
        if let sv = findScroll(uiView) {
            if c.scroll !== sv { c.attach(sv) }
            c.report(sv.contentOffset.y)
            c.reportDrag(sv.isDragging)
            return
        }
        guard attempt < 20 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            bind(uiView, c, attempt: attempt + 1)
        }
    }

    static func findScroll(_ view: UIView) -> UIScrollView? {
        var cur: UIView? = view
        while let v = cur {
            if let s = v as? UIScrollView { return s }
            cur = v.superview
        }
        return nil
    }
}
