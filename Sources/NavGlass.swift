import SwiftUI

/* ============================================================
   三个主页面的顶栏玻璃（会话 / 通讯录 / 视界互联）共用这一套

   · 不滚的时候：顶栏和页面同一个底色（看着是连在一起的，没有分割线）
   · 手指往上一滚：顶栏浮起一层**磨砂玻璃**（底下内容糊着还能看见 + 边缘高光），
     列表从它后面穿过去；分割线也才出现
   · 三个键都在后台：「会话页顶栏玻璃浓度」(chatsNavGlassAlpha，默认 1 = 全玻璃)、
     「会话页顶栏遮罩浓度」(chatsNavMaskAlpha，默认 0.45，压太重就成色板了)、
     「会话页顶栏遮罩颜色」(chatsNavMaskColor，不配就跟页面底色一致)
   ============================================================ */

/// 量「列表滚了多少」的探针键（三个页面共用；挂在整块列表内容上，别挂在第一行上，
/// 否则 LazyVStack 一回收第一行，值就跳回 0、玻璃会「闪一下就没」）
struct TopScrollKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 顶栏那层玻璃。fallback 是"没配遮罩颜色时跟谁一个色"（各页传自己的底色）
struct TopGlassBar: View {
    var scrolled: CGFloat
    /// 没配 chatsNavMaskColor 时用的颜色（会话页 chatsPageBg / 通讯录 pageBg / 视界 discoverBg）
    var fallback: Color
    /// 顶栏总高（算"滚过多少才开始浮出来"的系数用不着，留个口子）
    /// 从"完全没玻璃"到"完全浮出来"要滚多少：给长一点，过程才是**由浅到深**的
    var offset: CGFloat = 80
    /// **常显**：通讯录 / 视界互联这两页的顶栏要一直是那条遮罩（微信就是常显），
    /// 不像会话页那样"不滚就没有、滚起来才浮出来"。
    var always: Bool = false

    var body: some View {
        let mask = UIConfig.num("chatsNavMaskAlpha", 0.92)
        /* 由浅到深的过渡：前段慢、后段快（0.8 次方），拉的时候不会"啪一下"变实 */
        let raw = min(1, max(0, scrolled / max(1, offset)))
        /* always = 常显：直接按 1 算（不受滚动影响）；
           否则跟会话页一样按滚动"由浅到深"。 */
        let t = always ? 1 : pow(raw, 0.8)
        if t > 0.01 {
            /* 用户要求顶部遮罩关闭系统玻璃高光：改成一整块同色遮罩，
               不再使用 `.bar` + vibrancy，因此不会出现白色角光或亮边。 */
            (UIConfig.colorIfSet("chatsNavMaskColor") ?? fallback)
                .opacity(max(0, min(1, mask)) * t)
            .ignoresSafeArea(edges: .top)
            /* 这层只是背景：**绝对不能吃掉手势**（点了/滑了都要原样传给列表） */
            .allowsHitTesting(false)
        }
    }
}

/// 顶栏底下那条细线：**只在滚了以后**才出现（不滚的时候顶栏和列表是一个整体）
struct TopGlassLine: View {
    var scrolled: CGFloat
    var body: some View {
        Rectangle()
            .fill(C.navLine)
            .frame(height: 0.5)
            .opacity(scrolled > 6 ? 1 : 0)
    }
}

/// 探针：贴在列表整块内容上（ScrollView 里 + coordinateSpace(name:)）
struct TopScrollProbe: View {
    var space: String
    var body: some View {
        GeometryReader { g in
            Color.clear.preference(key: TopScrollKey.self,
                                   value: -g.frame(in: .named(space)).minY)
        }
    }
}

/// 把探针报上来的值收成 @State 用（带防抖：万一报 0 也不把已浮起来的玻璃收回去）
extension View {
    func topScrollTracking(_ scrolled: Binding<CGFloat>, space: String) -> some View {
        self
            .coordinateSpace(name: space)
            .onPreferenceChange(TopScrollKey.self) { v in
                let s = max(0, v)
                if s > scrolled.wrappedValue || s < 1 {
                    if abs(s - scrolled.wrappedValue) > 0.5 { scrolled.wrappedValue = s }
                }
            }
    }
}
