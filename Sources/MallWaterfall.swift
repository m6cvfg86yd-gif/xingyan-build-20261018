import SwiftUI

/* ============================================================
   双列**错落**瀑布流（2026-10-17 用户：「要有点卡片错落的设计感」）

   以前商品列表用 LazyVGrid：同一行两张卡被拉成一样高（行高对齐），
   不管标题长短、有没有标签，看着就是"表格"。
   现在两列各自独立往下堆：每张卡按内容自然高，左右上下都错开 ——
   拼多多/淘宝首页那种"瀑布"感。

   用法：把卡片和"估高"一起丢进来，组件负责决定每张进左列还是右列
   （永远往当前更矮的那一列放，两列高度差最小）。
   ============================================================ */
struct DDWaterfallGrid: View {
    /// (卡片, 估高)：估高只用来"分列"，不影响卡片真实高度
    let cells: [(view: AnyView, h: CGFloat)]
    var spacing: CGFloat = 10
    /// 实测容器宽度后再把两列写死成同一宽度。
    /// 只靠 HStack + maxWidth:.infinity 时，卡片内容的理想宽度仍会参与分配，
    /// 左右两列可能出现几像素宽窄差，整组卡片看起来就会左右偏。
    @State private var availableWidth: CGFloat = 0
    private var columnWidth: CGFloat { max(0, (availableWidth - spacing) / 2) }

    var body: some View {
        var left: [(view: AnyView, h: CGFloat)] = []
        var right: [(view: AnyView, h: CGFloat)] = []
        var hL: CGFloat = 0
        var hR: CGFloat = 0
        for c in cells {
            if hL <= hR { left.append(c); hL += c.h + spacing }
            else { right.append(c); hR += c.h + spacing }
        }
        return Group {
            if availableWidth > 1 {
                HStack(alignment: .top, spacing: spacing) {
                    VStack(spacing: spacing) {
                        ForEach(Array(left.enumerated()), id: \.offset) { item in
                            item.element.view.frame(maxWidth: .infinity, alignment: .top)
                        }
                    }
                    .frame(width: columnWidth, alignment: .top)
                    VStack(spacing: spacing) {
                        ForEach(Array(right.enumerated()), id: \.offset) { item in
                            item.element.view.frame(maxWidth: .infinity, alignment: .top)
                        }
                    }
                    .frame(width: columnWidth, alignment: .top)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity)
        .background {
            GeometryReader { g in
                Color.clear.preference(key: DDWaterfallWidthKey.self, value: g.size.width)
            }
        }
        .onPreferenceChange(DDWaterfallWidthKey.self) { w in
            if abs(w - availableWidth) > 0.5 { availableWidth = w }
        }
    }

    /// 估一张商品卡大概多高（和图一样：方形图 + 标题 1~2 行 + 价格行 + 标签/店铺行）
    /// 只用来决定它进哪一列，稍微有点误差没关系。
    static func estimate(_ p: DDProduct) -> CGFloat {
        var h: CGFloat = 1.0
        /* 标题越长越可能两行 */
        if p.title.count > 18 { h += 0.12 }
        if p.sold.isEmpty == false { h += 0.04 }
        if p.shop.isEmpty == false { h += 0.04 }
        if p.tags.isEmpty == false { h += 0.05 }
        return h
    }
}

private struct DDWaterfallWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
