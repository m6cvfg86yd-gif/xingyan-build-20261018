import SwiftUI
import CoreLocation

/* ============================================================
   商城「二楼」（2026-10-16 用户：「沿用二楼的方案，商城也做个二楼出来，
   背景会动的夜晚」→「白天晚上都要有变化」→「背景按照天气来 / 系统天气」）

   · 机制：**首页往下拉过阈值 → 整页二楼浮出来**，往上滑 / 点最底下那条收起
     （和会话页二楼一模一样的手感）
   · 背景：**真实天气 × 真实昼夜**
       天气：服务器去拉（Open-Meteo，免费无密钥，数据来自各国气象局/ECMWF），
             App 只传定位，不存任何密钥
       昼夜：用天气接口回的 isDay（跟系统天气一致：冬天早上 6 点它也是"没天亮"）
     画法按天气分：晴 / 少云 / 多云 / 阴 / 雾 / 小雨 / 雨 / 雪 / 雷雨，
     另外按小时给清晨-白天-黄昏-夜里四套色调（用户：「白天晚上都要有变化」）。
   · 内容（全是真数据，不是假占位）：搜索、我的订单（待付款/待发货/待收货带数字）、
     收藏、按时间+天气换标题的特惠、我的快捷四格、底部收起条。
   ============================================================ */

/// 服务器回的天气（字段名跟 /api/weather 对齐）
struct DDWeatherNow: Decodable {
    var condition: String?
    var code: Int?
    var isDay: Bool?
    var temp: Double?
    var cloud: Int?
    var wind: Double?
    var at: String?
    /// 服务器把这批数据算在哪个城市（顶部定位用）
    var city: String?
    var lat: Double?
    var lon: Double?
}

/// 天气中心：10 分钟缓存 + 用的时候顺手刷一次（定位失败也有服务器默认点兜底）
final class MallWeather: ObservableObject {
    static let shared = MallWeather()

    @Published private(set) var condition: String = "partly"
    @Published private(set) var isDay: Bool = true
    @Published private(set) var temp: Double = 0
    @Published private(set) var updatedAt: Date? = nil
    /// 天气接口拿不到时为 true（背景退回"只按时间画"）
    @Published private(set) var failed = false

    private var loading = false

    func refresh(force: Bool = false) {
        if loading { return }
        if !force, let t = updatedAt, Date().timeIntervalSince(t) < 600 { return }
        loading = true
        Task {
            /* 用户选过城市就按城市查（美团那种"切城市看哪儿的天气"）；
               没选过才用系统定位。 */
            let picked = DDCity.shared.name
            var w: DDWeatherNow? = nil
            if !picked.isEmpty {
                w = await API.shared.weather(city: picked)
            } else {
                var lat: Double? = nil
                var lon: Double? = nil
                if let loc = await OneShotLocation.shared.current() {
                    lat = loc.coordinate.latitude
                    lon = loc.coordinate.longitude
                }
                w = await API.shared.weather(lat: lat, lon: lon)
            }
            await MainActor.run {
                if let w {
                    self.condition = (w.condition ?? "partly")
                    self.isDay = (w.isDay ?? true)
                    self.temp = (w.temp ?? 0)
                    self.updatedAt = Date()
                    self.failed = false
                    /* 服务器知道这是哪个城市 → 顺手把顶部那条填上（不触发二次刷新） */
                    if let c = w.city, !c.isEmpty {
                        DDCity.shared.adopt(name: c, lat: w.lat ?? 0, lon: w.lon ?? 0)
                    }
                } else {
                    self.failed = true
                }
                self.loading = false
            }
        }
    }
}

/// 首页滚动位置（判断"是不是在最上面"，只有最上面往下拉才算开二楼）
struct DDFloorOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/* ---------------------------------------------------------- 天色 / 天气 -> 画什么 */
enum MallSkyPhase {
    case dawn, day, dusk, night

    static func now() -> MallSkyPhase {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<8:   return .dawn
        case 8..<17:  return .day
        case 17..<20: return .dusk
        default:      return .night
        }
    }
    /// 天气说"天还没亮/已经黑了"，就按夜里画（比单纯看钟点准）
    static func from(isDay: Bool) -> MallSkyPhase {
        let byClock = now()
        if isDay { return byClock == .night ? .day : byClock }
        return (byClock == .dawn || byClock == .day) ? .night : byClock
    }

    var isNight: Bool { self == .night }
    var darkInk: Bool { self == .day }
    var ink: Color { darkInk ? Color(hex: 0x16213B) : .white }
    var inkSoft: Color { ink.opacity(darkInk ? 0.62 : 0.55) }
    var cardFill: Color { Color.white.opacity(darkInk ? 0.62 : (self == .night ? 0.08 : 0.14)) }
    var cardStroke: Color { darkInk ? Color.black.opacity(0.06) : Color.white.opacity(0.12) }
    var accent: Color {
        switch self {
        case .night: return Color(hex: 0xFFD166)
        case .dawn:  return Color(hex: 0xFF7A4D)
        case .day:   return Color(hex: 0xE23B2E)
        case .dusk:  return Color(hex: 0xFF9B3C)
        }
    }
    var badgeInk: Color { self == .day ? .white : Color(hex: 0x101A30) }
}

/// 天气分档（服务器已经把 WMO 码归好类，这里只决定加多少云、下不下雨雪）
struct MallWeatherLook {
    var cond: String
    var phase: MallSkyPhase

    /* 2026-10-17 用户：「天气系统下下雨啥的要有动画，就会话页」——
       动画本身在 MallSkyBackground 里（雨丝下落 / 雪花飘 / 雷闪 / 云飘 / 星星闪 / 流星），
       这里再给后台一个**预览开关**：ui.json 写 weatherForce=rain（+ weatherForceNight=1）
       就能强制画成对应的天色，不用等真下雨，验收动画一目了然。
       不写这两个键 = 照旧用真实天气。 */
    static func current(_ w: MallWeather) -> MallWeatherLook {
        let force = UIConfig.text("weatherForce", "").trimmingCharacters(in: .whitespaces)
        let forceNight = UIConfig.num("weatherForceNight", 0) > 0
        guard !force.isEmpty else {
            return MallWeatherLook(cond: w.condition,
                                   phase: MallSkyPhase.from(isDay: w.isDay))
        }
        return MallWeatherLook(cond: force,
                               phase: MallSkyPhase.from(isDay: !forceNight))
    }

    /* 颜色 / 明暗这一类都转发给 phase（二楼的内容层只认 look，不直接碰 phase）——
       一开始漏了这几个转发，CI 直接报 "has no member 'ink'"（B991 那次就是栽在这）。 */
    var darkInk: Bool { phase.darkInk }
    var ink: Color { phase.ink }
    var inkSoft: Color { phase.inkSoft }
    var cardFill: Color { phase.cardFill }
    var cardStroke: Color { phase.cardStroke }
    var accent: Color { phase.accent }
    var badgeInk: Color { phase.badgeInk }

    var isClear: Bool { cond == "clear" }
    var isPartly: Bool { cond == "partly" }
    var isCloudy: Bool { cond == "cloudy" }
    var isOvercast: Bool { cond == "overcast" }
    var isFog: Bool { cond == "fog" }
    var isDrizzle: Bool { cond == "drizzle" }
    var isRain: Bool { cond == "rain" }
    var isSnow: Bool { cond == "snow" }
    var isThunder: Bool { cond == "thunder" }
    var isWet: Bool { isDrizzle || isRain || isThunder }
    /// 天被云压住：太阳/月亮要变淡、云要变厚
    var overcastAmt: Double {
        if isThunder { return 1.0 }
        if isRain { return 0.85 }
        if isSnow { return 0.7 }
        if isOvercast { return 0.8 }
        if isCloudy { return 0.5 }
        if isPartly { return 0.22 }
        if isClear { return 0.02 }
        return 0.3
    }
    /// 标题（内容也跟天气一起变，用户要的"连接这个商城的感觉"）
    var title: String {
        switch phase {
        case .night: return "今夜特惠"
        case .dawn:  return "清晨好价"
        case .dusk:  return "傍晚精选"
        case .day:   return isWet ? "雨天好价" : (isSnow ? "雪天好价" : "今日热卖")
        }
    }
    var subTitle: String {
        if isThunder { return "雷雨天气 · 快递照常" }
        if isRain || isDrizzle { return "下雨天 · 照常发货" }
        if isSnow { return "下雪了 · 照常发货" }
        if isFog || isOvercast { return "阴天 · 当天发货" }
        switch phase {
        case .night: return "夜里也发货"
        case .dawn:  return "早起的人先挑"
        case .dusk:  return "下单明早发货"
        case .day:   return "下单当天发货"
        }
    }
    var icon: String {
        if isThunder { return "cloud.bolt.rain.fill" }
        if isRain || isDrizzle { return "cloud.rain.fill" }
        if isSnow { return "snowflake" }
        if isFog { return "cloud.fog.fill" }
        if isOvercast || isCloudy { return "cloud.fill" }
        if isPartly { return phase.isNight ? "cloud.moon.fill" : "cloud.sun.fill" }
        return phase.isNight ? "moon.stars.fill" : "sun.max.fill"
    }
}

/* ---------------------------------------------------------- 会动的天色背景（按天气） */
struct MallSkyBackground: View {
    let look: MallWeatherLook

    private var phase: MallSkyPhase { look.phase }

    /* ⚠ 2026-10-17 用户：「天气已经有了，但它不动」/「看到不会动的雨丝」——
       以前星星闪、云飘、雨雪下落、日月呼吸、流星、雷闪全靠 `onAppear` 里
       `withAnimation(...repeatForever)` 起动画，真机上**这套不发车**：
       天色画出来了（渐变是静态的），雨丝一条条挂在那儿一动不动。
       现在改成 **TimelineView(.animation)**：每帧拿当前时间，位置/相位全部**按时间算** ——
       只要这一层在屏幕上就一定在动，完全不依赖 SwiftUI 那套动画事务。
       视觉数学（周期、幅度、颜色）和原来保持一致，只是把"动画"换成"算"。
       帧率压在 30fps：天色这种慢动效足够顺，手机上更省电。 */
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack {
                    sky
                    if phase.isNight {
                        stars(w: w, h: h, t: t)
                        moon(w: w, h: h, t: t)
                        if look.isClear { shootingStar(w: w, h: h, t: t) }
                    } else {
                        orb(w: w, h: h, t: t)
                    }
                    clouds(w: w, h: h, t: t)
                    if look.isFog || look.isOvercast { fog(w: w, h: h, t: t) }
                    if look.isWet { rain(w: w, h: h, t: t) }
                    if look.isSnow { snow(w: w, h: h, t: t) }
                    if look.isThunder && thunderOn(t) {
                        Color.white.opacity(0.55)
                    }
                }
            }
            .ignoresSafeArea()
        }
    }

    /* ---------------- 时间 → 数值 的小工具 ---------------- */

    /// 来回晃（原来 withAnimation + autoreverses 的那些）：period 是**单程**时长
    private func wave(_ t: Double, period: Double, mid: Double, amp: Double) -> CGFloat {
        CGFloat(mid + amp * cos(2 * Double.pi * t / (period * 2)))
    }
    /// 云的两条漂移（原来 -0.25↔0.22 / 0.30↔-0.20）
    private func drift(_ t: Double) -> CGFloat { wave(t, period: 9, mid: -0.015, amp: 0.235) }
    private func drift2(_ t: Double) -> CGFloat { wave(t, period: 13, mid: 0.05, amp: 0.25) }
    /// 雨/雪往下落的相位 0…1（duration = 落一整屏要多久）
    private func fallPhase(_ t: Double, duration: Double, speed: Double) -> CGFloat {
        CGFloat(((t * speed) / duration).truncatingRemainder(dividingBy: 1))
    }
    /// 呼吸 0…1（星星闪 / 日月光晕）：period = 来回一趟
    private func breathe(_ t: Double, period: Double) -> Double {
        0.5 + 0.5 * cos(2 * Double.pi * t / period)
    }
    /// 雷闪：每 6.5 秒亮 0.16 秒（原来那个 Timer 的节奏）
    private func thunderOn(_ t: Double) -> Bool {
        t.truncatingRemainder(dividingBy: 6.5) < 0.16
    }

    /* 天幕：先把「天气」压上去，再按时间给色调 */
    @ViewBuilder private var sky: some View {
        let grey = look.overcastAmt
        ZStack {
            switch phase {
            case .dawn:
                LinearGradient(colors: [Color(hex: 0x2A2E63), Color(hex: 0x8A5A86),
                                        Color(hex: 0xF09A6A), Color(hex: 0xFFD9A8)],
                               startPoint: .top, endPoint: .bottom)
            case .day:
                LinearGradient(colors: [Color(hex: 0x2E86E0), Color(hex: 0x63B4F2),
                                        Color(hex: 0xBFE3FF), Color(hex: 0xEAF6FF)],
                               startPoint: .top, endPoint: .bottom)
            case .dusk:
                LinearGradient(colors: [Color(hex: 0x1E2A5A), Color(hex: 0x6B3A78),
                                        Color(hex: 0xE2603A), Color(hex: 0xFFC178)],
                               startPoint: .top, endPoint: .bottom)
            case .night:
                LinearGradient(colors: [Color(hex: 0x070B1E), Color(hex: 0x141C46),
                                        Color(hex: 0x2A2159), Color(hex: 0x120E2A)],
                               startPoint: .top, endPoint: .bottom)
            }
            /* 阴/雨/雪/雾：整体压一层灰，太阳月亮也就淡了 */
            if grey > 0.05 {
                LinearGradient(colors: [Color(hex: 0x39435A).opacity(grey * 0.85),
                                        Color(hex: 0x6A7488).opacity(grey * 0.55),
                                        Color(hex: 0x9AA3B4).opacity(grey * 0.35)],
                               startPoint: .top, endPoint: .bottom)
            }
            if look.isSnow {
                LinearGradient(colors: [Color(hex: 0xAEBBD0).opacity(0.5),
                                        Color(hex: 0xE6EDF7).opacity(0.4)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
    }

    @ViewBuilder private func stars(w: CGFloat, h: CGFloat, t: Double) -> some View {
        /* 阴雨天星星自然要少 */
        ForEach(0..<70, id: \.self) { i in
            let fx = CGFloat((i * 37 + 11) % 100) / 100
            let fy = CGFloat((i * 61 + 7) % 100) / 100
            let size = CGFloat(1.2 + Double(i % 4) * 0.7)
            /* 原来是一颗颗 .animation(repeatForever) 闪 —— 现在按时间算，每颗错开相位 */
            let lo = 0.25 + Double(i % 6) * 0.12
            let k = breathe(t + Double(i) * 0.37, period: 2 * (1.6 + Double(i % 5) * 0.5))
            Circle().fill(Color.white)
                .frame(width: size, height: size)
                .position(x: fx * w, y: fy * h * 0.72)
                .opacity((lo + (0.95 - lo) * k) * (1 - look.overcastAmt * 0.85))
        }
    }

    @ViewBuilder private func moon(w: CGFloat, h: CGFloat, t: Double) -> some View {
        let k = breathe(t, period: 6.4)
        ZStack {
            Circle().fill(Color(hex: 0xF7EFC6).opacity(0.12 + 0.10 * k))
                .frame(width: 132, height: 132).blur(radius: 14)
            Circle()
                .fill(LinearGradient(colors: [Color(hex: 0xFFF9E2), Color(hex: 0xE8DCB0)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 62, height: 62)
                .overlay(
                    ZStack {
                        Circle().fill(Color(hex: 0xD9CDA2).opacity(0.55)).frame(width: 14, height: 14).offset(x: -9, y: -7)
                        Circle().fill(Color(hex: 0xD9CDA2).opacity(0.45)).frame(width: 9, height: 9).offset(x: 10, y: 8)
                    }
                )
                .shadow(color: Color(hex: 0xFFF1C0).opacity(0.3 + 0.25 * k), radius: 18)
        }
        .position(x: w * 0.78, y: h * 0.15)
        .opacity(1 - look.overcastAmt * 0.8)
    }

    @ViewBuilder private func orb(w: CGFloat, h: CGFloat, t: Double) -> some View {
        let y: CGFloat = phase == .dawn ? 0.30 : (phase == .day ? 0.14 : 0.34)
        let core: Color = phase == .dusk ? Color(hex: 0xFF9A3C)
                       : (phase == .dawn ? Color(hex: 0xFFC46B) : Color(hex: 0xFFF3B0))
        let k = breathe(t, period: 8)
        ZStack {
            Circle().fill(core.opacity(0.2 + 0.14 * k)).frame(width: 168, height: 168).blur(radius: 26)
            Circle().fill(core.opacity(0.35)).frame(width: 104, height: 104).blur(radius: 12)
            Circle().fill(core).frame(width: 58, height: 58).shadow(color: core.opacity(0.6), radius: 20)
        }
        .position(x: w * 0.76, y: h * y)
        .opacity(1 - look.overcastAmt * 0.85)
    }

    @ViewBuilder private func clouds(w: CGFloat, h: CGFloat, t: Double) -> some View {
        let amt = look.overcastAmt
        let d1 = drift(t)
        let d2 = drift2(t)
        /* 云色：白天白、阴雨灰、夜里暗蓝灰 */
        let base: Color = look.isWet || look.isOvercast
            ? Color(hex: 0x5B6478)
            : (phase.isNight ? Color(hex: 0x2A3252) : Color.white)
        ZStack {
            cloud(ink: base.opacity(0.30 + amt * 0.55), w: w * 0.44, h: 34)
                .position(x: w * (0.55 + d1), y: h * 0.24)
            cloud(ink: base.opacity(0.22 + amt * 0.45), w: w * 0.32, h: 26)
                .position(x: w * (0.34 + d2), y: h * 0.38)
            if amt > 0.35 {
                cloud(ink: base.opacity(0.18 + amt * 0.40), w: w * 0.52, h: 22)
                    .position(x: w * (0.72 + d2 * 0.6), y: h * 0.52)
            }
            if amt > 0.6 {
                cloud(ink: base.opacity(0.16 + amt * 0.35), w: w * 0.60, h: 20)
                    .position(x: w * (0.42 + d1), y: h * 0.64)
            }
        }
        .blur(radius: 6)
    }

    private func cloud(ink: Color, w: CGFloat, h: CGFloat) -> some View {
        ZStack {
            Capsule().fill(ink).frame(width: w, height: h)
            Circle().fill(ink).frame(width: h * 1.35, height: h * 1.35).offset(x: -w * 0.16, y: -h * 0.28)
            Circle().fill(ink).frame(width: h * 1.05, height: h * 1.05).offset(x: w * 0.14, y: -h * 0.18)
        }
    }

    /* 雾 / 阴天：两条横向的雾带慢慢挪 */
    @ViewBuilder private func fog(w: CGFloat, h: CGFloat, t: Double) -> some View {
        let d1 = drift(t)
        let d2 = drift2(t)
        ZStack {
            Capsule().fill(Color.white.opacity(0.10))
                .frame(width: w * 1.1, height: 90).blur(radius: 26)
                .position(x: w * (0.5 + d1 * 0.5), y: h * 0.62)
            Capsule().fill(Color.white.opacity(0.08))
                .frame(width: w * 1.1, height: 70).blur(radius: 22)
                .position(x: w * (0.5 + d2 * 0.6), y: h * 0.80)
        }
    }

    /* 雨：两排不同速度的雨丝（用相位让它一直往下落） */
    @ViewBuilder private func rain(w: CGFloat, h: CGFloat, t: Double) -> some View {
        ZStack {
            ForEach(0..<26, id: \.self) { i in
                let fx = CGFloat((i * 41 + 5) % 100) / 100
                let speed = 1.0 + Double(i % 3) * 0.25
                Capsule()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 1.4, height: 16 + CGFloat(i % 4) * 5)
                    .rotationEffect(.degrees(12))
                    .position(x: fx * w, y: ((fallPhase(t, duration: 1.1, speed: speed) + CGFloat(i) * 0.07)
                                             .truncatingRemainder(dividingBy: 1)) * (h + 40) - 20)
            }
        }
    }

    /* 雪：慢一点、大一点的小白点 */
    @ViewBuilder private func snow(w: CGFloat, h: CGFloat, t: Double) -> some View {
        ForEach(0..<34, id: \.self) { i in
            let fx = CGFloat((i * 29 + 13) % 100) / 100
            let size = CGFloat(2 + Double(i % 4))
            Circle().fill(Color.white.opacity(0.85))
                .frame(width: size, height: size)
                .position(x: fx * w + drift2(t) * 12, y: ((fallPhase(t, duration: 1.1, speed: 0.5 + Double(i % 3) * 0.12)
                                                        + CGFloat(i) * 0.031).truncatingRemainder(dividingBy: 1)) * (h + 30) - 15)
        }
    }

    @ViewBuilder private func shootingStar(w: CGFloat, h: CGFloat, t: Double) -> some View {
        /* 每 7 秒一颗：0 ~ 1.1 秒划过，前 0.25 秒淡入、0.9 秒后淡出（原来那个 Timer 的节奏） */
        let m = t.truncatingRemainder(dividingBy: 7)
        let p = min(1, m / 1.1)
        let x = -0.2 + 1.4 * p
        let op: Double = m > 1.35 ? 0
            : (m < 0.25 ? m / 0.25 : (m < 0.9 ? 1 : max(0, 1 - (m - 0.9) / 0.45)))
        Capsule()
            .fill(LinearGradient(colors: [Color.white.opacity(0), Color.white.opacity(0.9)],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(width: 120, height: 1.6)
            .rotationEffect(.degrees(20))
            .position(x: w * CGFloat(x), y: h * CGFloat(0.10 + x * 0.06))
            .opacity(op)
    }
}

/* ---------------------------------------------------------- 二楼本体（内容布局） */
struct DDMallFloor: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var store = DDStore.shared
    @ObservedObject private var weather = MallWeather.shared

    var onClose: () -> Void
    var onSearch: () -> Void
    /// 0 全部 / 1 待付款 / 2 待发货 / 3 待收货
    var onOrders: (Int) -> Void
    var onFav: () -> Void
    var onViews: () -> Void
    var onCart: () -> Void
    var onOpen: (DDProduct) -> Void
    /// 点顶部的城市（美团那颗「📍上海 ▾」）
    var onCity: () -> Void

    @State private var rise: CGFloat = 0
    @ObservedObject private var city = DDCity.shared

    private var look: MallWeatherLook {
        MallWeatherLook.current(weather)
    }
    private var pendingPay: Int { store.orders.filter { $0.status == "paying" }.count }
    private var shipping: Int { store.orders.filter { $0.status == "wait" }.count }
    private var receiving: Int { store.orders.filter { $0.status == "shipped" }.count }
    private var tonight: [DDProduct] { Array(store.feed(store.live).prefix(6)) }

    var body: some View {
        let L2 = look
        ZStack {
            MallSkyBackground(look: L2)

            VStack(spacing: 0) {
                Spacer().frame(height: L.safeTop + 6)

                /* 顶部城市定位（和商城首页那颗一模一样，美团那种位置） */
                Button { onCity() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "location.fill").font(.system(size: 11, weight: .semibold))
                        Text(city.display).font(pf(13.5, .medium)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundColor(L2.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 33)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .offset(y: (1 - rise) * 14).opacity(Double(rise))

                Color.clear.frame(height: 10)

                /* ① 搜索框 */
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Image(systemName: "magnifyingglass").font(.system(size: 13.5, weight: .medium))
                    Text(Tr("搜索商品")).font(pf(14.5))
                    Spacer(minLength: 0)
                }
                .foregroundColor(L2.inkSoft)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(L2.cardFill))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(L2.cardStroke, lineWidth: 0.6))
                .padding(.horizontal, 33)
                .contentShape(Rectangle())
                .onTapGesture { onSearch() }
                .offset(y: (1 - rise) * 16).opacity(Double(rise))

                Color.clear.frame(height: 22)

                /* 天气那一行：告诉你背景为什么长这样 */
                HStack(spacing: 6) {
                    Image(systemName: L2.icon).font(.system(size: 13, weight: .semibold))
                    Text(weatherTitle(L2)).font(pf(12.5))
                    Spacer(minLength: 0)
                }
                .foregroundColor(L2.inkSoft)
                .padding(.horizontal, 22)
                .offset(y: (1 - rise) * 18).opacity(Double(rise))

                Color.clear.frame(height: 12)

                /* ② 我的订单 */
                floorCard(L2) {
                    HStack {
                        Text(Tr("我的订单")).font(pf(15, .medium)).foregroundColor(L2.ink)
                        Spacer(minLength: 0)
                        Button { onOrders(0) } label: {
                            HStack(spacing: 2) {
                                Text(Tr("全部订单")).font(pf(12.5))
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundColor(L2.inkSoft)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14).frame(height: 40)
                    HairLine(inset: 14, color: L2.cardStroke)
                    HStack(spacing: 0) {
                        orderCell(L2, Tr("待付款"), pendingPay, "yensign.circle") { onOrders(1) }
                        orderCell(L2, Tr("待发货"), shipping, "shippingbox") { onOrders(2) }
                        orderCell(L2, Tr("待收货"), receiving, "truck.box") { onOrders(3) }
                        orderCell(L2, Tr("我的收藏"), store.favs.count, "heart") { onFav() }
                    }
                    .padding(.vertical, 12)
                }
                .offset(y: (1 - rise) * 26).opacity(Double(rise))

                Color.clear.frame(height: 14)

                /* ③ 特惠（标题跟时间和天气一起变） */
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: L2.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(L2.accent)
                        Text(Tr(L2.title)).font(pf(15, .medium)).foregroundColor(L2.ink)
                        Text(Tr(L2.subTitle)).font(pf(11)).foregroundColor(L2.inkSoft)
                        Spacer(minLength: 0)
                        Button { onViews() } label: {
                            Text(Tr("看足迹")).font(pf(12)).foregroundColor(L2.inkSoft)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(tonight) { p in
                                Button { onOpen(p) } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        DDThumb(em: p.em, size: 84, img: p.img)
                                        Text(p.title)
                                            .font(pf(12)).foregroundColor(L2.ink.opacity(0.9))
                                            .lineLimit(2).frame(width: 84, alignment: .leading)
                                        Text("¥" + moneyFmt(p.price))
                                            .font(pfMoney(13.5, .medium)).foregroundColor(L2.accent)
                                    }
                                    .frame(width: 84, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                }
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(L2.cardFill))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(L2.cardStroke, lineWidth: 0.6))
                .padding(.horizontal, 14)
                .offset(y: (1 - rise) * 34).opacity(Double(rise))

                Color.clear.frame(height: 14)

                /* ④ 我的快捷四格 */
                floorCard(L2) {
                    HStack(spacing: 0) {
                        orderCell(L2, Tr("收藏"), store.favs.count, "heart") { onFav() }
                        orderCell(L2, Tr("足迹"), 0, "clock.arrow.circlepath") { onViews() }
                        orderCell(L2, Tr("购物车"), store.cart.count, "cart") { onCart() }
                        orderCell(L2, Tr("全部订单"), 0, "list.bullet.rectangle") { onOrders(0) }
                    }
                    .padding(.vertical, 12)
                }
                .offset(y: (1 - rise) * 40).opacity(Double(rise))

                Spacer(minLength: 0)

                /* ⑤ 底部收起条 */
                Button { onClose() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.up").font(.system(size: 12, weight: .semibold))
                        Text(Tr("星言商城")).font(pf(15, .medium))
                        if pendingPay + shipping + receiving > 0 {
                            Text(String(pendingPay + shipping + receiving))
                                .font(pf(12.5, .medium))
                                .foregroundColor(L2.badgeInk)
                                .padding(.horizontal, 6).frame(height: 18)
                                .background(Capsule().fill(L2.accent))
                        }
                    }
                    .foregroundColor(L2.ink.opacity(0.92))
                    .frame(maxWidth: .infinity).frame(height: 54 + L.safeBottom)
                    .background(L2.darkInk ? Color.white.opacity(0.35) : Color.black.opacity(0.18))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .gesture(DragGesture(minimumDistance: 18)
            .onEnded { v in if v.translation.height < -40 { onClose() } })
        .onAppear {
            rise = 0
            MallWeather.shared.refresh()
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82).delay(0.05)) { rise = 1 }
        }
    }

    /// 「多云 22° · 夜里」这句
    private func weatherTitle(_ l: MallWeatherLook) -> String {
        if weather.failed { return Tr("天气暂时拿不到") }
        var name = "多云"
        switch l.cond {
        case "clear": name = "晴"
        case "partly": name = "少云"
        case "cloudy": name = "多云"
        case "overcast": name = "阴"
        case "fog": name = "雾"
        case "drizzle": name = "小雨"
        case "rain": name = "雨"
        case "snow": name = "雪"
        case "thunder": name = "雷雨"
        default: name = "多云"
        }
        let t = Int(round(weather.temp))
        let dayPart = l.phase.isNight ? "夜里" : (l.phase == .dawn ? "清晨"
                        : (l.phase == .dusk ? "傍晚" : "白天"))
        return "\(name) \(t)° · \(dayPart)"
    }

    /* ⚠ 泛型参数不能叫 C —— 项目里的颜色类就叫 `C`（C.label / C.pageBg），
       一撞就把它遮住（UserManage.swift 踩过一次、CI 报 "has no member"）。 */
    @ViewBuilder private func floorCard<V: View>(_ l: MallWeatherLook,
                                                 @ViewBuilder _ content: () -> V) -> some View {
        VStack(spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(l.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(l.cardStroke, lineWidth: 0.6))
            .padding(.horizontal, 14)
    }

    private func orderCell(_ l: MallWeatherLook, _ title: String, _ n: Int, _ icon: String,
                           _ tap: @escaping () -> Void) -> some View {
        Button { tap() } label: {
            VStack(spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundColor(l.ink.opacity(0.86))
                        .frame(width: 28, height: 24)
                    if n > 0 {
                        Text(n > 99 ? "99+" : String(n))
                            .font(pf(10.5, .medium))
                            .foregroundColor(l.badgeInk)
                            .padding(.horizontal, 4).frame(height: 15)
                            .background(Capsule().fill(l.accent))
                            .offset(x: 8, y: -4)
                    }
                }
                Text(title).font(pf(12.5)).foregroundColor(l.ink.opacity(0.78))
            }
            .frame(maxWidth: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
