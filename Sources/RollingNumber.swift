import SwiftUI

/* ============================================================
   会滚的数字（2026-10-16 用户：「会话页标题旁边的数字加入数字滚动效果」）

   每位数字是一个小窗口，值一变：老数字往上滚出去、新数字从下面滚进来
   （老式计数器/老虎机那种手感），比直接"啪"一下换成新数字体面得多。
   ============================================================ */
struct RollingNumber: View {
    let value: Int
    var font: Font = .system(size: 17, weight: .semibold)
    var color: Color = C.label
    /// 一个数字格子的高度（和标题字号对齐）
    var height: CGFloat = 20

    private var digits: [Int] {
        String(max(0, value)).compactMap { $0.wholeNumberValue }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(digits.enumerated()), id: \.offset) { _, d in
                RollingDigit(value: d, font: font, color: color, height: height)
            }
        }
    }
}

private struct RollingDigit: View {
    let value: Int
    let font: Font
    let color: Color
    let height: CGFloat

    @State private var prev = 0
    @State private var cur = 0
    /// true = 停稳了（老数字已经滚上去、新数字在位）
    @State private var settled = true

    var body: some View {
        ZStack {
            Text(String(prev))
                .offset(y: settled ? -height : 0)
            Text(String(cur))
                .offset(y: settled ? 0 : height)
        }
        .font(font)
        .monospacedDigit()
        .foregroundColor(color)
        .frame(height: height)
        .clipped()
        .onAppear { cur = value; prev = value; settled = true }
        .onChange(of: value) { v in
            prev = cur
            cur = v
            settled = false                       // 先摆到"老在上、新在下"
            DispatchQueue.main.async {            // 下一帧再动，动画才吃得上
                withAnimation(.easeOut(duration: 0.30)) { settled = true }
            }
        }
    }
}
