import SwiftUI

/* ============================================================
   按住说话时屏幕中间那个浮层 —— Siri 那种高级款

   结构还是微信那套（上：滑到这里转文字 / 中：麦克风 / 下：松手发语音），
   但中间换成一整颗**会呼吸的发光球**（超现实那套）：
     · 球体是蓝 → 红渐变 + 透明玻璃壳（中间是空的，透出暗背景），里面两层反向流动
     · 外层两道弧光绕着球转（赛博光晕），后面是深邃的暗黑空场
     · 音量越大，球越大越亮（跟着 recorder.level 实时变）
     · 球外面一圈环形波形：24 根小胶囊绕着圆心起伏，也在跟着音量动
     · 最外圈是细进度环：走到 60 秒上限时正好满一圈
     · 手指滑到「取消」整颗球变红、滑到「转文字」变绿，字也跟着换
   ============================================================ */

struct VoiceHUD: View {
    let seconds: Int
    let level: CGFloat
    let willCancel: Bool
    var willTranscribe: Bool = false
    var maxSeconds: Int = 60

    /// 球形渐变的三种颜色（Siri 那套蓝紫粉；取消变红、转文字变绿）
    private var colors: [Color] {
        if willCancel {
            return [Color(hex: 0xFF7A6B), Color(hex: 0xFF3B30), Color(hex: 0xFF9F0A)]
        }
        if willTranscribe {
            return [Color(hex: 0x2BD07A), Color(hex: 0x34C7E0), Color(hex: 0xB7F06A)]
        }
        return [Color(hex: 0x5B8CFF), Color(hex: 0xA45BFF), Color(hex: 0xFF5BA8)]
    }

    private var accent: Color {
        if willCancel { return Color(hex: 0xFF5B4D) }
        if willTranscribe { return Color(hex: 0x2BD07A) }
        return Color(hex: 0x7C8CFF)
    }

    /// 0~1：已经到了多少（最外圈进度环）
    private var progress: Double {
        guard maxSeconds > 0 else { return 0 }
        return max(0, min(1, Double(seconds) / Double(maxSeconds)))
    }

    private var nearlyDone: Bool { !willCancel && seconds >= max(1, maxSeconds - 10) }

    private var mainHint: String {
        if willCancel { return "松开手指，取消发送" }
        if willTranscribe { return "松手 转文字" }
        return "松手 发语音"
    }

    var body: some View {
        VStack(spacing: 12) {
            /* ① 上：转文字区（滑到这里高亮） */
            Text("滑到这里 转文字")
                .font(pf(13, willTranscribe ? .semibold : .regular))
                .foregroundColor(willTranscribe ? .white : .white.opacity(0.62))
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(willTranscribe
                                   ? Color(hex: 0x2BD07A).opacity(0.95)
                                   : Color.white.opacity(0.10))
                )

            /* ② 中：Siri 那颗球（波形 + 进度环 + 发光球体） */
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                orb(phase: ctx.date.timeIntervalSinceReferenceDate)
            }
            .frame(width: 258, height: 258)

            /* ③ 下：秒数 + 主提示（最后 10 秒给倒计时） */
            VStack(spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(seconds)″")
                        .font(pfMoney(15, .medium))
                        .foregroundColor(.white)
                        .monospacedDigit()
                    Text(mainHint)
                        .font(pf(13))
                        .foregroundColor(.white.opacity(0.92))
                }
                if nearlyDone {
                    Text("还可以说 \(max(0, maxSeconds - seconds)) 秒")
                        .font(pf(11.5))
                        .foregroundColor(Color(hex: 0xFFB340))
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 18)
        /* 深邃暗黑背景：中间浓、往外化开（没有边界的暗场，球像浮在深空里）。
           深浅后台可调：voiceHudDark（默认 0.78，越小越透）。 */
        .background {
            RadialGradient(colors: [Color.black.opacity(UIConfig.num("voiceHudDark", 0.78)),
                                    Color.black.opacity(0.42),
                                    Color.black.opacity(0.0)],
                           center: .center, startRadius: 20, endRadius: 300)
                .frame(width: 620, height: 620)
                .allowsHitTesting(false)
        }
        .animation(.easeInOut(duration: 0.2), value: willCancel)
        .animation(.easeInOut(duration: 0.2), value: willTranscribe)
    }

    /* ---------------------------------------------------------- Siri 球 */

    /// Siri 那颗球：外面一圈会膨胀的光晕 + 细波形 + 进度环，
    /// 中间是**三层不同转速的角向渐变叠出来的等离子球**（大模糊 + 叠加发光 = 颜色在里面流动）。
    /// 说话越大声 → 球越大、越亮、外面那层光铺得越开（这就是"会互动"）。
    /// 球里面的东西：球心暗底 + 三层流光 + 涡流弧光 + 左上受光，
    /// 外面用径向遮罩收边（是球、但边是化开的）。
    /// 抽成单独一份，是因为下面的"泛光"要用同一份球再叠一遍。
    private func orbInner(_ phase: Double,
                          _ c1: Color, _ c2: Color, _ c3: Color, _ c4: Color) -> some View {
        ZStack {
            /* 球心的暗：里面的光才有对比、才有体积 */
            Circle()
                .fill(RadialGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.17),
                                              Color(red: 0.02, green: 0.02, blue: 0.07)],
                                     center: UnitPoint(x: 0.40, y: 0.34),
                                     startRadius: 2, endRadius: 82))

            /* 球里那三层流光：速度、方向、模糊都不同（压淡一点，这是玻璃球不是彩球） */
            ZStack {
                AngularGradient(colors: [c1, c2, c3, c4, c1],
                                center: .center,
                                angle: .degrees(phase * 46))
                    .blur(radius: 9)
                    .opacity(0.52)
                AngularGradient(colors: [c3, c4, c1, c2, c3], center: .center)
                    .blur(radius: 16)
                    .opacity(0.40)
                    .rotationEffect(.degrees(-phase * 92))
                AngularGradient(colors: [c4, c1, c2, c3, c4], center: .center)
                    .blur(radius: 24)
                    .opacity(0.28)
                    .rotationEffect(.degrees(phase * 138))
            }
            .rotation3DEffect(.degrees(phase * 26), axis: (x: 0, y: 1, z: 0), perspective: 0.30)
            .blendMode(.plusLighter)

            /* 涡流弧光：几道弧在球里绕圈甩 */
            ZStack {
                Circle()
                    .trim(from: 0.02, to: 0.13)
                    .stroke(c4.opacity(0.52), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(phase * 74))
                Circle()
                    .trim(from: 0.34, to: 0.47)
                    .stroke(c3.opacity(0.46), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-phase * 56))
                Circle()
                    .trim(from: 0.68, to: 0.79)
                    .stroke(c1.opacity(0.52), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(phase * 90))
            }
            .frame(width: 122, height: 122)
            .blur(radius: 9)
            .blendMode(.plusLighter)

            /* 球面左上那片受光（不是整个球都亮） */
            Circle()
                .fill(RadialGradient(colors: [Color.white.opacity(0.26), Color.clear],
                                     center: UnitPoint(x: 0.34, y: 0.27),
                                     startRadius: 1, endRadius: 54))
                .blendMode(.plusLighter)
        }
        .frame(width: 158, height: 158)
        /* 径向遮罩：中间实、边缘柔和收进去 —— 看得出是一颗球，但边是"化"的 */
        .mask(
            Circle().fill(RadialGradient(colors: [Color.white,
                                                  Color.white,
                                                  Color.white.opacity(0.0)],
                                         center: .center,
                                         startRadius: 34, endRadius: 79))
        )
    }

    /// 语音球：iOS 17+ 用 **Metal 着色器**按像素算（真正的球面光照 + 流动 + 色散），
    /// 老系统（iOS 16）退回下面这套 SwiftUI 叠出来的近似版（球体 + 泛光 + 色散 + 玻璃壳）。
    private func orb(phase: Double) -> some View {
        let amp = max(0.05, min(1, Double(level)))
        let fit = CGFloat(1 + 0.035 * sin(phase * 1.4))
        let float = CGFloat(sin(phase * 1.0) * 3.5)
        /* 说话越大声球越大 —— 动态范围放宽（0.86→1.28），
           不然只差几个百分点，眼睛看不出来"跟着声音变"。 */
        let scale = (0.86 + CGFloat(amp) * 0.42) * fit
        let glassAmt = UIConfig.num("voiceOrbGlass", 0.65)

        /* Siri 那套虹彩：蓝 → 紫 → 粉 → 青。
           手势状态也跟着换：滑到取消 → 偏红橙；滑到转文字 → 偏青绿。 */
        let c1 = willCancel ? Color(hex: 0xFF4A3C)
                            : (willTranscribe ? Color(hex: 0x2BD07A) : Color(hex: 0x3B7CFF))
        let c2 = willCancel ? Color(hex: 0xFF6A3C)
                            : (willTranscribe ? Color(hex: 0x3FD9C0) : Color(hex: 0x8A5BFF))
        let c3 = willCancel ? Color(hex: 0xFF6B6B)
                            : (willTranscribe ? Color(hex: 0x7CF0B0) : Color(hex: 0xFF5AA8))
        let c4 = willCancel ? Color(hex: 0xFFB03C)
                            : (willTranscribe ? Color(hex: 0xB7F06A) : Color(hex: 0x3AD6FF))
        let inner = orbInner(phase, c1, c2, c3, c4)

        return ZStack {
            if #available(iOS 17.0, *) {
                /* ★ GPU 着色器：球面法线算光照、球面坐标上的噪声算流动、
                     菲涅尔边缘 + 镜面高光 + 边缘色散、球外柔光晕 —— 全按像素算。
                     （老系统没有 ShaderLibrary，走到 else 里那套 SwiftUI 近似版）。
                     ⚠ 底必须是**不透明**的：以前写的是 fill(Color.clear)，
                     完全透明的视图渲染系统会直接跳过 —— 着色器根本没被调用，
                     结果就只剩外面那层玻璃壳，看着"球里什么都没有"。 */
                /* ⚠ 底**不能是矩形**：着色器正常时它整块被覆盖看不见，
                   但着色器万一没跑起来（真机上都遇到过），
                   那块 258×258 的黑矩形就露出来了 —— 用户看到的
                   "球外面有个隐形黑色框"就是它。改成圆形：
                   就算着色器没跑，露出来的也是个黑球，不是黑框。 */
                /* 进一步：连"黑球"的硬边也不要。底改成**径向渐变的黑**
                   （中间实、往外化开），着色器万一没跑起来也只是球外一圈柔和的暗晕，
                   不会出现任何硬边 —— 球外面永远不会有"方框/黑圈"。
                   它照样"不是全透明"，足够让着色器被调用（全透明视图渲染系统会跳过）。 */
                /* Siri 那颗球：**一团会呼吸的虹彩光雾**（没有轮廓、没有高光点）。
                   同一个着色器画三遍 —— 两层大模糊当泛光、一层清晰当本体，
                   叠起来才有 Siri 那种"从里往外透光"的质感（单画一层会显得干）。 */
                let siri = Circle()
                    .fill(RadialGradient(colors: [Color.black,
                                                  Color.black.opacity(0.92),
                                                  Color.black.opacity(0.52),
                                                  Color.black.opacity(0.0)],
                                         center: .center,
                                         startRadius: 0,
                                         endRadius: 129))
                    .frame(width: 258, height: 258)
                    .colorEffect(ShaderLibrary.voiceOrb(
                        /* ⚠ 时间必须传**小**数：以前直接传 timeIntervalSinceReferenceDate（7.8 亿），
                           Metal 的 float 只有 24 位尾数，乘上波速后精度就崩了 ——
                           sin() 算出来是乱的，波纹/旋转/流动全变成噪声，看着就像"没动、没波"。
                           取模到 1000 秒以内即可（每 1000 秒循环一次，肉眼看不出来）。 */
                        .float(phase.truncatingRemainder(dividingBy: 1000)),
                        .float(258), .float(258),
                        .color(c1), .color(c2), .color(c3), .color(c4),
                        .float(amp),
                        .float(glassAmt),
                        .float(0.42)))          // 光团半径（占半宽的 42%，留出外圈泛光的余地）
                ZStack {
                    siri.blur(radius: 52).opacity(0.70).blendMode(.plusLighter)
                    siri.blur(radius: 22).opacity(0.86).blendMode(.plusLighter)
                    siri
                }
                .clipShape(Circle())
                .scaleEffect(scale)
                .offset(y: float)
            } else {
                /* iOS 16：SwiftUI 叠出来的近似版 */
                Circle()
                    .fill(RadialGradient(colors: [c1.opacity(0.26 + amp * 0.22),
                                                  c2.opacity(0.10),
                                                  Color.clear],
                                         center: .center, startRadius: 42, endRadius: 168))
                    .frame(width: 336, height: 336)
                    .scaleEffect((0.90 + CGFloat(amp) * 0.30) * fit)
                    .blur(radius: 22)
                    .blendMode(.plusLighter)

                inner
                    .scaleEffect(scale)
                    .offset(y: float)
                    .shadow(color: c3.opacity(0.42 + CGFloat(amp) * 0.30), radius: 24)
                    .shadow(color: c1.opacity(0.38 + CGFloat(amp) * 0.28), radius: 46)

                inner
                    .scaleEffect(scale * 1.03)
                    .blur(radius: 40)
                    .opacity(0.42)
                    .blendMode(.plusLighter)
                    .offset(y: float)

                Circle()
                    .stroke(c4.opacity(0.55), lineWidth: 3)
                    .frame(width: 152, height: 152)
                    .blur(radius: 5)
                    .scaleEffect(scale)
                    .offset(x: 1.8, y: float)
                    .blendMode(.plusLighter)
                Circle()
                    .stroke(c3.opacity(0.50), lineWidth: 3)
                    .frame(width: 152, height: 152)
                    .blur(radius: 5)
                    .scaleEffect(scale)
                    .offset(x: -1.8, y: float)
                    .blendMode(.plusLighter)
            }

            /* 下面这三层（玻璃壳 / 内暗环 / 球缘亮环）**只给 iOS 16 那套近似版用**。
               iOS 17+ 走的是 Siri 光雾 —— 没有轮廓、没有高光点，
               再叠这三层会把光雾"框"成一颗玻璃球，又回到旧质感了。 */
            if #unavailable(iOS 17.0) {
            /* 液态玻璃球壳：苹果原生 Liquid Glass（真折射 + 镜面回光），
               着色器管球里的光和色散，这一层管"玻璃本身"。
               强度后台可调：voiceOrbGlass（默认 0.65；写 0 就没有壳）。 */
            if glassAmt > 0 {
                /* ⚠ 语音球这层壳**不用原生玻璃**（native: false）：
                   实测 iOS 26 的原生 glassEffect 有时不认 `in: Circle()`，
                   球外面会露出一整块方形玻璃（就是用户说的"球外面有个方框"）。
                   我们自己的那套玻璃是 shape.fill + shape.stroke 画的，一定是正圆。
                   （原生那层现在也补了 clipShape 兜底，但球这里干脆走稳的那条路。） */
                GlassBackground(shape: Circle(),
                                opacity: glassAmt,
                                edgeAlpha: UIConfig.num("voiceOrbEdge", 0.50),
                                shadow: false,
                                seed: 0.50,
                                native: false)
                    .frame(width: 158, height: 158)
                    .scaleEffect(scale)
                    .offset(y: float)
            }

            /* 玻璃球的"厚度"：壳内侧一道很淡的暗环（苹果那颗球的边看着是厚的） */
            Circle()
                .stroke(Color.black.opacity(0.38), lineWidth: 5)
                .frame(width: 146, height: 146)
                .blur(radius: 5)
                .opacity(0.65)
                .scaleEffect(scale)
                .offset(y: float)

            /* 球缘亮环：轮廓更清楚一点（不抢里面的流光） */
            Circle()
                .stroke(LinearGradient(colors: [Color.white.opacity(0.22),
                                                Color.white.opacity(0.02),
                                                c1.opacity(0.16)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1)
                .frame(width: 158, height: 158)
                .blur(radius: 1.2)
                .scaleEffect(scale)
                .offset(y: float)
            }

            /* 60 秒进度：一圈很淡的光慢慢走满 */
            Circle()
                .trim(from: 0, to: CGFloat(progress))
                .stroke(AngularGradient(colors: [c1.opacity(0.50), c4.opacity(0.50)],
                                        center: .center),
                        style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 224, height: 224)
                .opacity(0.70)

            /* 球下面一片极淡的光斑：浮在空中的感觉 */
            Ellipse()
                .fill(RadialGradient(colors: [c3.opacity(0.15 + amp * 0.13), Color.clear],
                                     center: .center, startRadius: 2, endRadius: 84))
                .frame(width: 176, height: 30)
                .offset(y: 112 - float * 0.4)
                .blur(radius: 14)
                .blendMode(.plusLighter)
        }
        .frame(width: 258, height: 258)
        .animation(.easeOut(duration: 0.09), value: level)
    }
}

/* ============================================================
   单独一颗「语音球」（2026-10-16 用户：「通讯录搜索框起来后，把我之前做的
   语音球放到键盘上方居中，键盘消失跟着消失」）

   和聊天里「按住说话」那颗**同一个 Metal 着色器**（voiceOrb）、同一套 Siri 配色
   和泛光叠法 —— 区别只是这里不带"滑到这里转文字"那一圈提示、也没有进度环，
   尺寸随便给（球体按 258 的画布算，缩放放在最外层，比例不会走样）。
   ============================================================ */
struct VoiceOrb: View {
    /// 0~1：说话音量（没在听的时候给个小值，球自己会呼吸）
    var level: CGFloat = 0.16
    /// 显示出来多大
    var diameter: CGFloat = 92
    /// 正在听：整体更亮一点
    var listening: Bool = false

    /// 着色器按这个画布算坐标，外层只做缩放
    private let canvas: CGFloat = 258

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
            let phase = ctx.date.timeIntervalSinceReferenceDate
            let amp = max(0.05, min(1, level))
            let fit = CGFloat(1 + 0.035 * sin(phase * 1.4))
            let float = CGFloat(sin(phase * 1.0) * 3.5)
            let scale = (0.86 + amp * 0.42) * fit
            let c1 = Color(hex: 0x3B7CFF)
            let c2 = Color(hex: 0x8A5BFF)
            let c3 = Color(hex: 0xFF5AA8)
            let c4 = Color(hex: 0x3AD6FF)

            ZStack {
                if #available(iOS 17.0, *) {
                    /* ⚠ 底不能全透明：全透明的视图渲染系统会直接跳过，着色器就不会被调用。
                       这里用"径向渐变的黑"当底 —— 万一着色器没跑起来，露出来的也是
                       一团柔和的暗晕，不会有硬边（和聊天那颗球同一套处理）。 */
                    let siri = Circle()
                        .fill(RadialGradient(colors: [Color.black,
                                                      Color.black.opacity(0.92),
                                                      Color.black.opacity(0.52),
                                                      Color.black.opacity(0.0)],
                                             center: .center, startRadius: 0, endRadius: 129))
                        .frame(width: canvas, height: canvas)
                        .colorEffect(ShaderLibrary.voiceOrb(
                            .float(phase.truncatingRemainder(dividingBy: 1000)),
                            .float(canvas), .float(canvas),
                            .color(c1), .color(c2), .color(c3), .color(c4),
                            .float(amp),
                            .float(UIConfig.num("voiceOrbGlass", 0.65)),
                            .float(0.42)))
                    ZStack {
                        siri.blur(radius: 52).opacity(0.70).blendMode(.plusLighter)
                        siri.blur(radius: 22).opacity(0.86).blendMode(.plusLighter)
                        siri
                    }
                    .clipShape(Circle())
                    .scaleEffect(scale)
                    .offset(y: float)
                } else {
                    /* iOS 16：SwiftUI 叠出来的近似版（和聊天那颗球的老系统分支一个路子） */
                    ZStack {
                        Circle()
                            .fill(RadialGradient(colors: [c1.opacity(0.95), c2.opacity(0.85), c3.opacity(0.55)],
                                                 center: UnitPoint(x: 0.36, y: 0.30),
                                                 startRadius: 2, endRadius: 132))
                        Circle()
                            .fill(RadialGradient(colors: [Color.white.opacity(0.34), Color.clear],
                                                 center: UnitPoint(x: 0.33, y: 0.26),
                                                 startRadius: 0, endRadius: 72))
                    }
                    .frame(width: 168, height: 168)
                    .blur(radius: 6)
                    .scaleEffect(scale)
                    .shadow(color: c3.opacity(0.45), radius: 26)
                    .offset(y: float)
                }
            }
            .frame(width: canvas, height: canvas)
            .scaleEffect(diameter / canvas)
            .frame(width: diameter, height: diameter)
            .opacity(listening ? 1 : 0.94)
        }
    }
}
