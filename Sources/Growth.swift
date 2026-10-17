import SwiftUI
import UIKit

/* ============================================================
   成长体系（照 QQ 等级那套做）
   · 升级看「活跃天」：升到 L 级要 L²+4L 个活跃天
     （Lv1=5 天、Lv4=32、Lv16=320、Lv32=1152、Lv64=4352 —— 和 QQ 的表一致）
   · 活跃天按当天使用时长记：满 2 小时 1 天、满 30 分钟 0.5 天，每天上限 1 天
     （阈值和加速倍数后台能改，服务端结算，客户端只负责上报用了多久）
   · 图标：4 星 = 1 月亮、4 月亮 = 1 太阳、4 太阳 = 1 皇冠
     也就是 1 月亮 = 4 级、1 太阳 = 16 级、1 皇冠 = 64 级
   ============================================================ */

struct GrowthIcons: Codable, Hashable {
    var crowns: Int = 0
    var suns: Int = 0
    var moons: Int = 0
    var stars: Int = 0

    /// 一共几个图标（用来判断要不要显示「+N」）
    var count: Int { crowns + suns + moons + stars }
}

struct GrowthCfg: Codable, Hashable {
    var enabled: Bool?
    var fullSeconds: Int?
    var halfSeconds: Int?
    var maxPerDay: Double?
    var boost: Double?
    var showInContacts: Bool?
    var showInChats: Bool?
    var showInProfile: Bool?
    var avatarFrame: Bool?
    var tip: String?
}

struct GrowthMe: Codable, Hashable {
    var enabled: Bool?
    var total: Double?
    var level: Int?
    /// 显示用的等级（和 QQ 一样最少 1 级：新号也有 1 颗星）
    var levelShown: Int?
    var icons: GrowthIcons?
    var levelStartDays: Double?
    var nextDays: Double?
    var needDays: Double?
    var todaySeconds: Int?
    var todayEarned: Double?
    var cfg: GrowthCfg?
}

struct GrowthRankRow: Codable, Identifiable, Hashable {
    var id: String
    var name: String?
    var avatar: String?
    var total: Double?
    var level: Int?
    var icons: GrowthIcons?
}

/// 等级换算（和服务端一模一样的公式，离线也算得对）
enum QQLevel {
    /// 升到 L 级需要多少个活跃天
    static func days(for level: Int) -> Int { level * level + 4 * level }
    /// 有多少活跃天 = 几级
    static func level(forDays d: Double) -> Int {
        max(0, Int((max(0, d) + 4).squareRoot() - 2))
    }
    static func icons(_ level: Int) -> GrowthIcons {
        var n = max(0, level)
        let crowns = n / 64; n %= 64
        let suns = n / 16; n %= 16
        let moons = n / 4; n %= 4
        return GrowthIcons(crowns: crowns, suns: suns, moons: moons, stars: n)
    }
}

/* 后台配的三个「显示位置」开关。
   单独放一份非隔离的静态量：视图里（包括普通计算属性）读它不会碰到
   MainActor 隔离的限制 —— 之前直接在视图里读 GrowthStore.shared.cfg 会编译不过。 */
enum GrowthFlags {
    static var showInContacts = true
    static var showInProfile = true
    static var showInChats = true
    /// 头像框（月亮细银圈 / 太阳金环 / 皇冠金框）：后台能一键关掉
    static var avatarFrame = true
}

/* ------------------------------------------------------------ 记账 */

/// 等级与活跃天：登录后开着，回前台继续；每分钟把「这段用了多久」报给服务器
@MainActor
final class GrowthStore: ObservableObject {
    static let shared = GrowthStore()

    @Published var me: GrowthMe?
    @Published var rank: [GrowthRankRow] = []
    @Published var rankMine: GrowthRankRow?

    private var timer: Timer?
    private var lastTick = Date()
    private var running = false

    var level: Int { me?.level ?? 0 }
    /// 展示用的等级：最少 1（新号 1 颗星）
    var shownLevel: Int { me?.levelShown ?? max(1, level) }
    var icons: GrowthIcons { me?.icons ?? QQLevel.icons(shownLevel) }
    var cfg: GrowthCfg { me?.cfg ?? GrowthCfg() }
    var totalDays: Double { me?.total ?? 0 }

    func start() {
        guard !running else { return }
        running = true
        lastTick = Date()
        Task { await refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in await GrowthStore.shared.tick() }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        Task { await tick() }        // 把最后不足一分钟的也补上
    }

    /// 把「距上次上报过了多久」报上去（最多认 1 小时，服务端也会再夹一次）
    func tick() async {
        let now = Date()
        let secs = Int(now.timeIntervalSince(lastTick))
        lastTick = now
        guard secs > 0 else { return }
        if let g = try? await API.shared.growthPing(seconds: min(3600, secs)) { apply(g) }
    }

    func refresh() async {
        if let g = try? await API.shared.growthMe() { apply(g) }
    }

    /// 拿到新配置：存一份给我页看，同时把三个「显示位置」开关同步给 GrowthFlags（视图直接读那个）
    private func apply(_ g: GrowthMe) {
        me = g
        let c = g.cfg
        GrowthFlags.showInContacts = c?.showInContacts ?? true
        GrowthFlags.showInProfile = c?.showInProfile ?? true
        GrowthFlags.showInChats = c?.showInChats ?? true
        GrowthFlags.avatarFrame = c?.avatarFrame ?? true
    }

    func loadRank() async {
        if let r = try? await API.shared.growthRank() {
            rank = r.rows
            rankMine = r.me
        }
    }
}

/* ------------------------------------------------------------ 等级图标（自绘质感） */

enum QQGlyphKind { case crown, sun, moon, star }

/// 图标形状自己画：星星 / 月亮 / 太阳 / 皇冠。
/// （之前用「渐变 + 系统符号遮罩」画，真机上会退化成几个小点 —— 看着像一串省略号，
///   所以改成纯 Path，任何系统版本都长得一模一样。）
struct QQGlyphShape: Shape {
    var kind: QQGlyphKind

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        let cx = rect.midX, cy = rect.midY
        switch kind {
        case .star:
            let R = min(w, h) / 2
            let r = R * 0.42
            for i in 0..<10 {
                let ang = -Double.pi / 2 + Double(i) * Double.pi / 5
                let rad = (i % 2 == 0) ? R : r
                let pt = CGPoint(x: cx + CGFloat(cos(ang)) * rad, y: cy + CGFloat(sin(ang)) * rad)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()

        case .moon:
            /* 两个圆叠着挖（偶奇填充）→ 月牙 */
            p.addEllipse(in: rect.insetBy(dx: w * 0.04, dy: h * 0.04))
            let d = min(w, h) * 0.98
            p.addEllipse(in: CGRect(x: rect.minX + w * 0.36,
                                    y: rect.minY - h * 0.04,
                                    width: d, height: d))

        case .sun:
            let R = min(w, h) / 2
            p.addEllipse(in: CGRect(x: cx - R * 0.50, y: cy - R * 0.50, width: R, height: R))
            for i in 0..<8 {
                let a = Double(i) * Double.pi / 4
                let inner = R * 0.72, outer = R * 0.99, half = R * 0.15
                let p1 = CGPoint(x: cx + CGFloat(cos(a)) * inner, y: cy + CGFloat(sin(a)) * inner)
                let p2 = CGPoint(x: cx + CGFloat(cos(a)) * outer, y: cy + CGFloat(sin(a)) * outer)
                let pa = CGPoint(x: p1.x + CGFloat(cos(a + .pi / 2)) * half,
                                 y: p1.y + CGFloat(sin(a + .pi / 2)) * half)
                let pb = CGPoint(x: p1.x + CGFloat(cos(a - .pi / 2)) * half,
                                 y: p1.y + CGFloat(sin(a - .pi / 2)) * half)
                p.move(to: pa); p.addLine(to: p2); p.addLine(to: pb); p.closeSubpath()
            }

        case .crown:
            /* 圆润的三尖皇冠：左尖 → 中间最高 → 右尖，谷底用二次曲线收圆。
               （以前是尖角折线，放大看着很糙 —— 用户说"皇冠太丑"就是这个形状） */
            p.move(to: CGPoint(x: rect.minX + w * 0.07, y: rect.minY + h * 0.90))
            p.addLine(to: CGPoint(x: rect.minX + w * 0.07, y: rect.minY + h * 0.36))
            p.addQuadCurve(to: CGPoint(x: rect.minX + w * 0.26, y: rect.minY + h * 0.52),
                           control: CGPoint(x: rect.minX + w * 0.12, y: rect.minY + h * 0.24))
            p.addQuadCurve(to: CGPoint(x: rect.minX + w * 0.50, y: rect.minY + h * 0.22),
                           control: CGPoint(x: rect.minX + w * 0.35, y: rect.minY + h * 0.42))
            p.addQuadCurve(to: CGPoint(x: rect.minX + w * 0.74, y: rect.minY + h * 0.52),
                           control: CGPoint(x: rect.minX + w * 0.65, y: rect.minY + h * 0.42))
            p.addQuadCurve(to: CGPoint(x: rect.minX + w * 0.93, y: rect.minY + h * 0.36),
                           control: CGPoint(x: rect.minX + w * 0.88, y: rect.minY + h * 0.24))
            p.addLine(to: CGPoint(x: rect.minX + w * 0.93, y: rect.minY + h * 0.90))
            p.closeSubpath()
        }
        return p
    }
}

/// 等级图标（最终用的那个）：优先显示包里渲好的 3D 图 ——
/// 那四张是 Blender + Cycles 渲的真三维（真金属材质、影棚布光、皇冠上还有一颗红宝石）。
/// 万一图没打进包（老包 / 资源丢了），自动退回下面自绘那套 Glyph3D，界面不会开天窗。
struct LevelIcon: View {
    var kind: QQGlyphKind
    var size: CGFloat

    var body: some View {
        /* 回退：Blender 渲的那版 3D 图用户觉得太难看，先用回自绘的精简图标（QQ 那种干净样子）。
           图还在包里（levelicons/），想换回去改这一行就行。 */
        QQGlyph(kind: kind, size: size)
    }

    /// 包里的 3D 图（levelicons/*.png，打包时拷进 App 根目录）——目前不用
    static func image(_ kind: QQGlyphKind) -> UIImage? {
        nil
    }
}

/// 一颗等级图标：金/银渐变 + 顶部高光 + 柔和投影。
/// 太阳和皇冠会「闪闪发光」：一层呼吸的金色光晕 + 太阳慢慢转 + 时不时冒一颗小闪光。
/// （星星/月亮不动 —— 它们出现得最多，全都在动会显得乱、也费电。）
struct QQGlyph: View {
    var kind: QQGlyphKind
    var size: CGFloat

    /// 会发光的：太阳、皇冠
    private var shines: Bool { kind == .sun || kind == .crown }
    private var glowColor: Color { kind == .sun ? Color(hex: 0xFFB01F) : Color(hex: 0xF2C64B) }

    @State private var pulse = false
    @State private var spin = false
    @State private var glint = false

    private var gradient: LinearGradient {
        switch kind {
        case .crown:
            return LinearGradient(colors: [Color(hex: 0xFFF7CF), Color(hex: 0xF2C64B), Color(hex: 0xC8890C)],
                                  startPoint: .top, endPoint: .bottom)
        case .sun:
            return LinearGradient(colors: [Color(hex: 0xFFEBAE), Color(hex: 0xFFB01F), Color(hex: 0xEE7A00)],
                                  startPoint: .top, endPoint: .bottom)
        case .moon:
            return LinearGradient(colors: [Color(hex: 0xF6FAFF), Color(hex: 0xB6CCEC), Color(hex: 0x7696C4)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .star:
            return LinearGradient(colors: [Color(hex: 0xFFF3C0), Color(hex: 0xFFC93C)],
                                  startPoint: .top, endPoint: .bottom)
        }
    }

    var body: some View {
        ZStack {
            /* 呼吸的光晕（只给太阳/皇冠） */
            if shines {
                Circle()
                    .fill(RadialGradient(colors: [glowColor.opacity(pulse ? 0.45 : 0.14), Color.clear],
                                         center: .center, startRadius: 0, endRadius: size * 0.9))
                    .frame(width: size * 1.6, height: size * 1.6)
                    .scaleEffect(pulse ? 1.05 : 0.86)
                    .allowsHitTesting(false)
            }

            /* 图标本体：渐变 + 顶部高光 */
            ZStack {
                QQGlyphShape(kind: kind)
                    .fill(gradient, style: FillStyle(eoFill: true))
                QQGlyphShape(kind: kind)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.0)],
                                         startPoint: .top, endPoint: .center),
                          style: FillStyle(eoFill: true))
            }
            /* 太阳：射线慢慢转（圆本身看不出来，转的是那圈光） */
            .rotationEffect(.degrees(kind == .sun && spin ? 360 : 0))

            /* 小闪光：隔一会儿在右上角闪一下 */
            if shines {
                QQGlyphShape(kind: .star)
                    .fill(Color.white)
                    .frame(width: size * 0.36, height: size * 0.36)
                    .offset(x: size * 0.32, y: -size * 0.32)
                    .opacity(glint ? 0.95 : 0)
                    .scaleEffect(glint ? 1 : 0.35)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: Color.black.opacity(0.18), radius: size * 0.12, y: size * 0.06)
        .onAppear { startShine() }
    }

    private func startShine() {
        guard shines else { return }
        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { pulse = true }
        if kind == .sun {
            withAnimation(.linear(duration: 24).repeatForever(autoreverses: false)) { spin = true }
        }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true).delay(0.7)) { glint = true }
    }
}

/// 一排等级图标：皇冠 > 太阳 > 月亮 > 星星（QQ 的排法）
struct QQLevelBadge: View {
    var level: Int
    var size: CGFloat = 14
    var maxIcons: Int = 4

    private func kinds() -> [QQGlyphKind] {
        /* 和 QQ 一样：新号也有 1 颗星（所以最少按 1 级画） */
        let ic = QQLevel.icons(max(1, level))
        var out: [QQGlyphKind] = []
        for _ in 0..<min(3, ic.crowns) { out.append(.crown) }
        for _ in 0..<min(3, ic.suns) { out.append(.sun) }
        for _ in 0..<min(3, ic.moons) { out.append(.moon) }
        for _ in 0..<min(3, ic.stars) { out.append(.star) }
        return out
    }

    var body: some View {
        let all = kinds()
        let shown = Array(all.prefix(max(1, maxIcons)))
        let more = all.count - shown.count
        HStack(spacing: size * 0.14) {
            ForEach(shown.indices, id: \.self) { i in
                /* Blender 渲的 3D 图（没有图时自动退回自绘那套） */
                LevelIcon(kind: shown[i], size: size)
            }
            if more > 0 {
                Text("+" + String(more))
                    .font(.system(size: size * 0.62, weight: .semibold))
                    .foregroundColor(C.subLabel)
            }
        }
    }
}

/* ------------------------------------------------------------ 我的等级 */

/// 我 → 我的等级（QQ 那套：等级图标 + 活跃天 + 距离下一级 + 活跃榜）
struct MyLevelView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = GrowthStore.shared
    @State private var loadingRank = true

    private func num(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return abs(r - r.rounded()) < 0.001 ? String(Int(r)) : String(format: "%.1f", r)
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("我的等级"), back: { dismiss() })
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    heroCard
                    todayCard
                    ruleCard
                    rankCard
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 30)
            }
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task {
            await store.refresh()
            await store.loadRank()
            loadingRank = false
        }
    }

    /* 顶部那张深色金边卡：等级图标 + Lv + 活跃天 + 到下一级的进度 */
    private var heroCard: some View {
        let total = store.totalDays
        let level = store.shownLevel
        let start = Double(store.me?.levelStartDays ?? Double(QQLevel.days(for: level)))
        let next = Double(store.me?.nextDays ?? Double(QQLevel.days(for: level + 1)))
        let prog = next > start ? max(0, min(1, (total - start) / (next - start))) : 0
        let need = max(0, next - total)

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                QQLevelBadge(level: level, size: 26, maxIcons: 6)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 3) {
                    Text("Lv." + String(level))
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(LinearGradient(colors: [Color(hex: 0xFFF6D2), Color(hex: 0xF0C24B)],
                                                        startPoint: .top, endPoint: .bottom))
                    Text(Tr("活跃天") + " " + num(total))
                        .font(pf(12.5))
                        .foregroundColor(.white.opacity(0.72))
                }
            }

            VStack(spacing: 7) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.15))
                        Capsule()
                            .fill(LinearGradient(colors: [Color(hex: 0xFFE9A6), Color(hex: 0xF3B529)],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(8, g.size.width * prog))
                    }
                }
                .frame(height: 8)
                HStack {
                    Text("Lv." + String(level)).font(pf(11.5)).foregroundColor(.white.opacity(0.55))
                    Spacer(minLength: 6)
                    Text(Tr("距 Lv.") + String(level + 1) + Tr(" 还需 ") + num(need) + Tr(" 个活跃天"))
                        .font(pf(11.5))
                        .foregroundColor(.white.opacity(0.8))
                }
            }
        }
        .padding(16)
        .background(
            ZStack {
                LinearGradient(colors: [Color(hex: 0x1C2130), Color(hex: 0x2B2233), Color(hex: 0x14111A)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Color(hex: 0xF3C74B).opacity(0.22), Color.clear],
                               center: .topTrailing, startRadius: 2, endRadius: 230)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    /* 今天活跃了多少 + 还差多久能记满 */
    private var todayCard: some View {
        let secs = store.me?.todaySeconds ?? 0
        let mins = secs / 60
        let full = store.cfg.fullSeconds ?? 7200
        let half = store.cfg.halfSeconds ?? 1800
        let tip: String = {
            if secs >= full { return Tr("今天的活跃天已经记满（1 个）") }
            if secs >= half { return Tr("再坚持 ") + String(max(1, (full - secs) / 60)) + Tr(" 分钟，今天能记满 1 个活跃天") }
            return Tr("再活跃 ") + String(max(1, (half - secs) / 60)) + Tr(" 分钟，今天记 0.5 个活跃天")
        }()
        return VStack(alignment: .leading, spacing: 10) {
            Text(Tr("今日活跃")).font(pf(15, .medium)).foregroundColor(C.label)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(mins)).font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundColor(C.label)
                Text(Tr("分钟")).font(pf(13)).foregroundColor(C.subLabel)
                Spacer(minLength: 0)
                Text(Tr("今日已记 ") + num(store.me?.todayEarned ?? 0) + Tr(" 个活跃天"))
                    .font(pf(12.5)).foregroundColor(C.subLabel)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(C.hairline)
                    Capsule().fill(LinearGradient(colors: [Color(hex: 0xFFD98A), Color(hex: 0xF3B529)],
                                                  startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, g.size.width * min(1, Double(secs) / Double(max(1, full)))))
                }
            }
            .frame(height: 6)
            Text(tip).font(pf(12)).foregroundColor(C.subLabel)
        }
        .padding(14)
        .background { CardGlassBox(radius: 12) }
    }

    /* 规则说明（后台可改文案） */
    private var ruleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Tr("等级怎么算")).font(pf(15, .medium)).foregroundColor(C.label)
            Text(store.cfg.tip ?? Tr("每天使用满 2 小时记 1 个活跃天，满 30 分钟记 0.5 个。"))
                .font(pf(13)).foregroundColor(C.subLabel).lineSpacing(4)
            HairLine(inset: 0)
            HStack(spacing: 14) {
                HStack(spacing: 5) {
                    LevelIcon(kind: .star, size: 16)
                    Text(Tr("1 星 = 1 级")).font(pf(12)).foregroundColor(C.subLabel)
                }
                HStack(spacing: 5) {
                    LevelIcon(kind: .moon, size: 16)
                    Text(Tr("1 月亮 = 4 级")).font(pf(12)).foregroundColor(C.subLabel)
                }
            }
            HStack(spacing: 14) {
                HStack(spacing: 5) {
                    LevelIcon(kind: .sun, size: 16)
                    Text(Tr("1 太阳 = 16 级")).font(pf(12)).foregroundColor(C.subLabel)
                }
                HStack(spacing: 5) {
                    LevelIcon(kind: .crown, size: 16)
                    Text(Tr("1 皇冠 = 64 级")).font(pf(12)).foregroundColor(C.subLabel)
                }
            }
            Text(Tr("升到 L 级需要 L²+4L 个活跃天：Lv.4 = 32 天 · Lv.16 = 320 天 · Lv.64 = 4352 天"))
                .font(pf(11.5)).foregroundColor(C.subLabel)
        }
        .padding(14)
        .background { CardGlassBox(radius: 12) }
    }

    /* 活跃榜（谁攒的活跃天多） */
    private var rankCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Tr("活跃榜")).font(pf(15, .medium)).foregroundColor(C.label)
                .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)
            if let mine = store.rankMine {
                HStack(spacing: 10) {
                    Avatar(path: mine.avatar ?? "", size: 34, radius: 17, circle: true)
                    Text(Tr("我")).font(pf(14, .medium)).foregroundColor(C.label)
                    QQLevelBadge(level: max(1, mine.level ?? 0), size: 13, maxIcons: 4)
                    Spacer(minLength: 0)
                    Text("Lv." + String(max(1, mine.level ?? 0))).font(pf(13, .semibold)).foregroundColor(C.subLabel)
                    Text(num(mine.total ?? 0) + Tr(" 天")).font(pf(13)).foregroundColor(C.subLabel)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            HairLine(inset: 14)
            if loadingRank && store.rank.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 18)
            } else if store.rank.isEmpty {
                Text(Tr("还没有人上榜，多用几天就有了"))
                    .font(pf(13)).foregroundColor(C.subLabel)
                    .padding(.horizontal, 14).padding(.vertical, 16)
            } else {
                ForEach(Array(store.rank.prefix(20).enumerated()), id: \.element.id) { idx, row in
                    HStack(spacing: 10) {
                        Text(String(idx + 1))
                            .font(pf(13, .semibold))
                            .foregroundColor(idx < 3 ? Color(hex: 0xE0A21B) : C.subLabel)
                            .frame(width: 22, alignment: .center)
                        Avatar(path: row.avatar ?? "", size: 32, radius: 16, circle: true)
                        Text(row.name ?? "")
                            .font(pf(14)).foregroundColor(C.label).lineLimit(1)
                        QQLevelBadge(level: max(1, row.level ?? 0), size: 12, maxIcons: 3)
                        Spacer(minLength: 0)
                        Text("Lv." + String(max(1, row.level ?? 0))).font(pf(12.5)).foregroundColor(C.subLabel)
                        Text(num(row.total ?? 0) + Tr(" 天")).font(pf(12.5)).foregroundColor(C.subLabel)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    if idx < min(19, store.rank.count - 1) { HairLine(inset: 60) }
                }
            }
        }
        .background { CardGlassBox(radius: 12) }
    }
}

