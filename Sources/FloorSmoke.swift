import SwiftUI

/* ============================================================
   二楼背后那层**会流动**的烟

   · 三四团很淡的雾，各自用不同的速度和方向慢慢飘（sin/cos 驱动，永远不重复）
   · Canvas + 一次 blur 滤镜画出来，几乎不吃性能；不吃手势
   · 颜色/浓度后台可调：floorSmokeColor / floorSmokeFlow（默认 0.16）
   ============================================================ */

struct FloorSmoke: View {
    /// 烟的颜色（默认偏紫蓝，和参考图那支深紫蓝是一路）
    var color: Color = Color(hex: 0x8E86C8)
    /// 整体浓度
    var intensity: Double = 0.16
    /// 飘的速度倍率（1 = 正常，0 = 不动）
    var speed: Double = 1

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate * max(0, speed)
            Canvas { g, size in
                /* 一次大半径模糊：几团圆就变成了"烟" */
                g.addFilter(.blur(radius: 46))
                for i in 0..<4 {
                    let p = Double(i)
                    let x = size.width * CGFloat(0.18 + 0.64 * (0.5 + 0.5 * sin(t * (0.09 + p * 0.03) + p * 1.7)))
                    let y = size.height * CGFloat(0.12 + 0.76 * (0.5 + 0.5 * cos(t * (0.07 + p * 0.025) + p * 2.3)))
                    let r = size.width * CGFloat(0.40 + 0.14 * sin(t * 0.05 + p))
                    let a = intensity * (0.55 + 0.45 * (0.5 + 0.5 * sin(t * 0.08 + p * 1.3)))
                    let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                    g.fill(Path(ellipseIn: rect),
                           with: .radialGradient(Gradient(colors: [color.opacity(a), color.opacity(0)]),
                                                 center: CGPoint(x: x, y: y),
                                                 startRadius: 0, endRadius: r))
                }
            }
        }
        .allowsHitTesting(false)
    }
}
