import SwiftUI

/* ============================================================
   「阅后即焚」的焚烧动画 —— 2026-10-13 用户要求「要有动画效果」

   为什么要单独放这个文件：
     ChatDetailView 是个巨型视图，**往里加任何视图层都会被那台机器的看门狗杀掉**
     （B224/B231/B240 都栽在这上面）。所以焚烧动画不放在聊天页里，而是放在
     聊天页**外面那层** DeferredChatView（我们自己的文件）里，
     由聊天页只用一行**代码**通知「该烧了」。

   画法：Canvas 一层画完（不建子视图），1.1 秒：
     · 一层从下往上扫的暖光（橙 → 金，边扫边淡）
     · 十几粒火星往上飘、越飘越淡
     · 起点和随机数都是**按序号算死的**（不用随机数，避免每帧重建）
   ============================================================ */

@MainActor
final class BurnFX: ObservableObject {
    static let shared = BurnFX()
    /// 正在烧（外层按它决定铺不铺那层动画）
    @Published var firing = false
    private var task: Task<Void, Never>?

    func fire() {
        firing = true
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)   // 与动画的 1.4 秒对齐
            if Task.isCancelled { return }
            await MainActor.run { self?.firing = false }
        }
    }
}

struct FlameSweepOverlay: View {
    /// 动画总时长（秒）
    private let dur: Double = 1.4
    @State private var t0 = Date()

    var body: some View {
        TimelineView(.animation) { ctx in
            Canvas { g, size in
                let t = ctx.date.timeIntervalSince(t0)
                guard t >= 0, t <= dur else { return }
                let p = t / dur                       // 0 → 1
                let fade = 1 - p                     // 越烧越淡
                /* 燃烧线：从屏幕底下爬到顶上（像一张纸从底边开始烧） */
                let edgeY = size.height * (1 - p)

                /* ① 烧过的地方是焦黑的（越靠上烧得越早、越淡，最后随整段一起淡出） */
                if edgeY > 0 {
                    let burnt = CGRect(x: 0, y: 0, width: size.width, height: edgeY)
                    g.fill(Path(burnt), with: .linearGradient(
                        Gradient(colors: [
                            Color.black.opacity(0.34 * fade),
                            Color(hex: 0x1A0E06).opacity(0.52 * fade),
                            Color(hex: 0x2A1206).opacity(0.30 * fade)
                        ]),
                        startPoint: CGPoint(x: 0, y: burnt.minY),
                        endPoint: CGPoint(x: 0, y: burnt.maxY)))
                }

                /* ② 燃烧线本身：一条起伏的亮边（橙黄→红），有呼吸感 */
                let flick = 1 + 0.18 * sin(t * 26)
                for i in 0..<64 {
                    let fi = Double(i)
                    let x = size.width * fi / 63
                    let wob = sin(fi * 0.9 + t * 7) * 5 + sin(fi * 2.3 + t * 3) * 2.5
                    let y = edgeY + wob
                    let r = (5.2 + 3.4 * (0.5 + 0.5 * sin(fi * 1.7 + t * 9))) * flick
                    let core = CGRect(x: x - r, y: y - r * 0.8, width: r * 2, height: r * 1.6)
                    g.fill(Path(ellipseIn: core), with: .radialGradient(
                        Gradient(colors: [Color(hex: 0xFFF3C4).opacity(0.95),
                                          Color(hex: 0xFFB024).opacity(0.75),
                                          Color(hex: 0xFF4D00).opacity(0.0)]),
                        center: CGPoint(x: core.midX, y: core.midY),
                        startRadius: 0, endRadius: r * 1.6))
                }

                /* ③ 燃烧线**上方**再压一层热光（把刚烧过的内容染暖），下方留一点余温 */
                if edgeY > 0 {
                    let hot = CGRect(x: 0, y: max(0, edgeY - 90), width: size.width, height: min(90, edgeY))
                    g.fill(Path(hot), with: .linearGradient(
                        Gradient(colors: [Color(hex: 0xFF6A00).opacity(0.0),
                                          Color(hex: 0xFF8A1E).opacity(0.34 * fade)]),
                        startPoint: CGPoint(x: 0, y: hot.minY),
                        endPoint: CGPoint(x: 0, y: hot.maxY)))
                }

                /* ④ 火星：从燃烧线往上飘、越飘越淡越小 */
                for i in 0..<26 {
                    let fi = Double(i)
                    let delay = fi * 0.028
                    let tt = max(0, t - delay) / dur
                    guard tt > 0, tt < 1 else { continue }
                    let baseX = size.width * ((fi * 0.618).truncatingRemainder(dividingBy: 1))
                    let rise = tt * (70 + 240 * ((fi * 0.37).truncatingRemainder(dividingBy: 1)))
                    let x = baseX + sin((tt + fi) * 6.28) * 16
                    let y = edgeY - rise
                    let r = (2.8 - 1.9 * tt) * (0.7 + 0.6 * ((fi * 0.73).truncatingRemainder(dividingBy: 1)))
                    let a = (1 - tt) * 0.95
                    g.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                           with: .color(Color(hex: tt < 0.45 ? 0xFFE08A : 0xFF7A1E).opacity(a)))
                }

                /* ⑤ 烟：几团半透明的灰往上飘（燃烧线上面那一段） */
                for i in 0..<9 {
                    let fi = Double(i)
                    let delay = fi * 0.06
                    let tt = max(0, t - delay) / dur
                    guard tt > 0, tt < 1 else { continue }
                    let baseX = size.width * ((fi * 0.41 + 0.12).truncatingRemainder(dividingBy: 1))
                    let x = baseX + sin((tt + fi) * 3.14) * 26
                    let y = edgeY - 30 - tt * 200
                    let r = 26 + 60 * tt
                    let a = (1 - tt) * 0.16 * fade
                    g.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                           with: .radialGradient(
                            Gradient(colors: [Color(hex: 0x9A9A9A).opacity(a),
                                              Color(hex: 0x6E6E6E).opacity(0.0)]),
                            center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r))
                }
            }
        }
        .onAppear { t0 = Date() }
        .allowsHitTesting(false)
    }
}
