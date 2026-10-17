import SwiftUI

/* ============================================================
   发红包成功那一下的**全屏红包雨**（质感版）

   · 金红渐变的红包从屏幕上方落下来，带**轻微左右摆动**（像真在下）
   · 每个红包有金盖 + 中间那颗金色「¥」纽（不是一块红方块）
   · 出现时淡入、快落到底时淡出，全程 3 秒左右，不挡操作（不吃手势）
   · 画法用 Canvas + TimelineView：一屏几十个也不掉帧
   ============================================================ */

struct RedPacketRain: View {
    /// 播多久（秒）
    var duration: Double = 3.2
    /// 放完的回调（调用方把开关关掉）
    var onEnd: () -> Void = {}

    @State private var t0 = Date()

    private struct Drop {
        var x: CGFloat      // 横向位置（0~1）
        var delay: Double   // 什么时候开始落
        var speed: Double   // 落多快
        var size: CGFloat   // 多大
        var spin: Double    // 飘一点角度
        var sway: Double    // 摆动幅度
    }

    /// 34 个红包，位置/大小/速度都用固定公式算出来（每次一样，不乱跳）
    private let drops: [Drop] = (0..<34).map { i in
        let r = Double((i * 97) % 100) / 100.0
        let r2 = Double((i * 53) % 100) / 100.0
        return Drop(x: CGFloat(r2),
                    delay: r * 1.15,
                    speed: 0.55 + r * 0.55,
                    size: 34 + CGFloat(r) * 22,
                    spin: (r - 0.5) * 0.9,
                    sway: 8 + r * 16)
    }

    var body: some View {
        TimelineView(.animation) { ctx in
            let e = ctx.date.timeIntervalSince(t0)
            Canvas { g, size in
                for d in drops {
                    let p = (e - d.delay) * d.speed
                    if p < 0 { continue }
                    if p > 1.45 { continue }
                    let y = -0.22 * size.height + CGFloat(p) * size.height * 1.6
                    let x = d.x * size.width + CGFloat(sin(p * 5.5)) * CGFloat(d.sway)
                    /* 出现淡入、落到底淡出 */
                    let fade = p < 0.12 ? p / 0.12 : max(0, 1 - (p - 1.05) / 0.4)
                    if fade <= 0.01 { continue }

                    let w = d.size
                    let h = d.size * 1.32
                    let rect = CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h)
                    var c = g
                    c.opacity = fade          // GraphicsContext.opacity 是属性，不是方法
                    c.translateBy(x: x, y: y)
                    c.rotate(by: .radians(d.spin))
                    c.translateBy(x: -x, y: -y)

                    /* 影子：让红包有一点立体感 */
                    c.fill(Path(roundedRect: rect.offsetBy(dx: 0, dy: 3), cornerRadius: w * 0.24),
                           with: .color(.black.opacity(0.18)))
                    /* 红包本体：金 → 红 的斜向渐变 */
                    c.fill(Path(roundedRect: rect, cornerRadius: w * 0.24),
                           with: .linearGradient(Gradient(colors: [Color(hex: 0xF6A93C),
                                                                  Color(hex: 0xE23B2E),
                                                                  Color(hex: 0xA81212)]),
                                                 startPoint: rect.origin,
                                                 endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
                    /* 上面的金色盖子 */
                    let lid = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.32)
                    c.fill(Path(roundedRect: lid, cornerRadius: w * 0.2),
                           with: .linearGradient(Gradient(colors: [Color(hex: 0xFFE9B0),
                                                                  Color(hex: 0xE7A22A)]),
                                                 startPoint: lid.origin,
                                                 endPoint: CGPoint(x: lid.maxX, y: lid.maxY)))
                    /* 中间那颗金色「¥」纽 */
                    let dot = w * 0.26
                    c.fill(Path(ellipseIn: CGRect(x: rect.midX - dot / 2,
                                                  y: lid.maxY - dot * 0.42,
                                                  width: dot, height: dot)),
                           with: .linearGradient(Gradient(colors: [Color(hex: 0xFFF3C4),
                                                                   Color(hex: 0xD9981F)]),
                                                 startPoint: CGPoint(x: rect.midX, y: lid.maxY),
                                                 endPoint: CGPoint(x: rect.midX, y: lid.maxY + dot)))
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            t0 = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { onEnd() }
        }
    }
}
