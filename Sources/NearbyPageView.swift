import SwiftUI
import CoreLocation
import UIKit

/* ============================================================
   附近的人（发现 → 附近）
   页面照桌面 vx 文件夹那张参考图量的（420×912pt 的截图）：
     · 整页深色：页面 #111111、每一行 #191919、行与行之间没有分割线
     · 行高 65pt；头像 46×46、左边距 8pt（圆角 5）
     · 头像右边 13pt 起是两行字：第一行名字（17pt 白）、第二行距离（14pt 灰「500米以内」）
     · 个性签名灰色，右对齐到右边距 16pt（最多两行）
     · 顶部：‹ 返回 + 居中「附近的人」+ 右侧 ⋯（筛选/刷新/清除位置都在 ⋯ 里）
   功能：进来先定位并上报（半小时有效），按距离排；可筛性别、可打招呼。
   ============================================================ */

/// 雷达的扫描扇（中心在圆心，从 -span 度扫到 0 度；顺着转就是"扫过去"）
/// · span 给大一点 = 更长更淡的拖尾（高级雷达都是"长尾 + 亮前沿"）
struct RadarWedge: Shape {
    var span: Double = 60
    var lead: Double = 0
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        p.move(to: c)
        p.addArc(center: c, radius: max(rect.width, rect.height) / 2,
                 startAngle: .degrees(-span + lead), endAngle: .degrees(lead),
                 clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// 定位：要一次「使用期间」权限，拿到一次坐标就够（不用一直跟）
final class NearbyLocator: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var lat: Double?
    @Published var lng: Double?
    @Published var denied = false
    @Published var asking = false

    private let mgr = CLLocationManager()

    override init() {
        super.init()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func start() {
        switch mgr.authorizationStatus {
        case .denied, .restricted:
            denied = true
        case .notDetermined:
            asking = true
            mgr.requestWhenInUseAuthorization()
        default:
            mgr.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Task { @MainActor in
            switch m.authorizationStatus {
            case .denied, .restricted:
                self.denied = true
                self.asking = false
            case .notDetermined:
                self.asking = true
            default:
                self.asking = false
                self.denied = false
                m.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { return }
        Task { @MainActor in
            self.lat = loc.coordinate.latitude
            self.lng = loc.coordinate.longitude
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) { }
}

struct NearbyPageView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var loc = NearbyLocator()

    @State private var people: [NearbyPerson] = []
    @State private var loading = false
    @State private var tip = ""
    /// all / female / male —— 和微信 ⋯ 里那三个选项一样
    @State private var filter = "all"
    @State private var showMenu = false
    /// 现在看多大的范围（默认 5 公里；5 公里没人可以点「扩大范围」）
    @State private var maxKm: Double = 5
    /// 20 公里内有几个人（用来提示「扩大范围」）
    @State private var wider = 0

    @State private var helloFor: NearbyPerson?
    @State private var helloText = "你好呀，我是在附近的人里看到你的"
    @State private var cardUser: User?

    /* 2026-10-15 用户：「把附近的人改成雷达扫人」——
       默认进雷达：一圈一圈的圈 + 一条转着的扫描扇 + 附近的人按角度摆在圈里，
       扫到谁谁亮（头像）；点亮点看资料/打招呼。列表还留着（右上角那颗切换）。 */
    @State private var mode = 0                 // 0 = 雷达 · 1 = 列表
    @State private var selected: NearbyPerson?
    @State private var sweep: Double = 0
    /* 原来 0.05s（20fps）转起来一顿一顿的；提到 0.02s（50fps）后顺滑，
       角度步长按同样角速度换算（48°/秒 → 每帧 0.96°）。 */
    private let radarTick = Timer.publish(every: 0.02, on: .main, in: .common).autoconnect()
    /// 雷达半径（pt）
    private let radarD: CGFloat = 142

    /* 参考图里的颜色（深色页面，不走全局主题） */
    private let pageBg = Color.dyn(0x111111, 0x141419)
    private let rowBg = Color(hex: 0x191919)
    private let nameInk = Color.white
    private let subInk = Color(hex: 0x929292)

    private var filterTitle: String {
        switch filter {
        case "female": return "只看女生"
        case "male": return "只看男生"
        default: return "全部"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            /* 顶栏：照参考图，深色 + 居中标题 + 右侧 ⋯ */
            ZStack {
                /* 标题读后台：ui.json 里写 nearbyTitle（不写就是「附近的人」） */
                Text(Tr(UIConfig.text("nearbyTitle", "附近的人")))
                    .font(pf(17, .semibold))
                    .foregroundColor(nameInk)
                HStack(spacing: 0) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundColor(nameInk)
                            .frame(width: 44, height: L.navH)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                    /* 雷达 ⇄ 列表 */
                    Button { withAnimation(.easeOut(duration: 0.2)) { mode = (mode == 0 ? 1 : 0) } } label: {
                        Image(systemName: mode == 0 ? "list.bullet" : "dot.radiowaves.left.and.right")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(nameInk)
                            .frame(width: 44, height: L.navH)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button { showMenu = true } label: {
                        WeChatDots(color: nameInk)
                            .frame(width: 44, height: L.navH)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: L.navH)
            .background(pageBg)

            if mode == 0 {
                radarArea
            } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if loc.denied {
                        hint("需要定位权限才能看到附近的人\n去「设置 → CHRIS聊天 → 位置」打开", showSetting: true)
                    } else if loading && people.isEmpty {
                        ProgressView().tint(.white).padding(.top, 70)
                    } else if people.isEmpty {
                        VStack(spacing: 12) {
                            hint(tip.isEmpty
                                 ? "\(Int(maxKm)) 公里内还没有其他人\n（对方也要打开「附近的人」，并且就在你附近）"
                                 : tip, showSetting: false)
                            if tip.isEmpty && maxKm < 20 {
                                if wider > 0 {
                                    Button("扩大到 20 公里（有 \(wider) 人）") {
                                        maxKm = 20
                                        Task { await reload(force: true) }
                                    }
                                    .font(pf(15))
                                    .foregroundColor(C.green)
                                } else {
                                    Text(Tr("20 公里内也没有人"))
                                        .font(pf(13))
                                        .foregroundColor(subInk.opacity(0.7))
                                }
                            }
                        }
                    } else {
                        ForEach(people) { p in
                            personRow(p)
                        }
                    }
                }
                .padding(.bottom, 20)
            }
            .background(pageBg)
            }
        }
        .background(pageBg.ignoresSafeArea(edges: .bottom))
        .background(pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .hidesTabBar()
        /* 和微信一样：从左边缘往右一滑就回上一页（别的二级页都挂了这一个） */
        .swipeBack { dismiss() }
        .navigationDestination(isPresented: Binding(
            get: { cardUser != nil },
            set: { if !$0 { cardUser = nil } }
        )) {
            if let u = cardUser {
                ContactCardView(user: u, onOpenChat: { _ in cardUser = nil }, onOpenMoments: { _ in cardUser = nil })
            }
        }
        .confirmationDialog("", isPresented: $showMenu, titleVisibility: .hidden) {
            Button(Tr("全部")) { setFilter("all") }
            Button(Tr("只看女生")) { setFilter("female") }
            Button(Tr("只看男生")) { setFilter("male") }
            Button(Tr("刷新")) { Task { await reload(force: true) } }
            Button(Tr("清除位置信息并退出"), role: .destructive) { clearLocation() }
            Button(Tr("取消"), role: .cancel) { }
        }
        .alert("打招呼", isPresented: Binding(
            get: { helloFor != nil },
            set: { if !$0 { helloFor = nil } }
        )) {
            TextField("说点什么…", text: $helloText)
            Button(Tr("发送")) { sendHello() }
            Button(Tr("取消"), role: .cancel) { helloFor = nil }
        } message: {
            Text("给 \(helloFor?.name ?? "") 发一条消息")
        }
        .task {
            loc.start()
            await reload(force: true)
        }
        .onChange(of: loc.lat) { _ in Task { await reload(force: true) } }
        .onReceive(radarTick) { _ in
            guard mode == 0 else { return }
            sweep = (sweep + 0.96).truncatingRemainder(dividingBy: 360)
        }
    }

    /* ---------------------------------------------------------- 雷达扫人 */

    private var radarArea: some View {
        VStack(spacing: 0) {
            if loc.denied {
                hint("需要定位权限才能看到附近的人\n去「设置 → CHRIS聊天 → 位置」打开", showSetting: true)
                Spacer(minLength: 0)
            } else {
                ZStack {
                    /* ① 雷达屏：一块很暗的绿黑底 + 外圈描边 + 投影 —— 亮的东西才有"屏幕感" */
                    Circle()
                        .fill(RadialGradient(colors: [Color(hex: 0x0F1D16), Color(hex: 0x07110C)],
                                             center: UnitPoint(x: 0.5, y: 0.42),
                                             startRadius: 6, endRadius: radarD * 1.02))
                        .frame(width: radarD * 2 + 18, height: radarD * 2 + 18)
                        .overlay(Circle().stroke(Color(hex: 0x2E6B52).opacity(0.55), lineWidth: 1))
                        .shadow(color: .black.opacity(0.35), radius: 16, y: 7)
                        .shadow(color: C.green.opacity(0.10), radius: 22)

                    /* ② 十字准线（很淡）+ 12 个刻度（每 3 个长一点） */
                    Rectangle().fill(Color(hex: 0x2E6B52).opacity(0.30))
                        .frame(width: radarD * 2, height: 1)
                    Rectangle().fill(Color(hex: 0x2E6B52).opacity(0.30))
                        .frame(width: 1, height: radarD * 2)
                    ForEach(0..<12, id: \.self) { i in
                        Rectangle()
                            .fill(Color(hex: 0x2E6B52).opacity(0.45))
                            .frame(width: 1, height: i % 3 == 0 ? 9 : 5)
                            .offset(y: -radarD + 5)
                            .rotationEffect(.degrees(Double(i) * 30))
                    }

                    /* ③ 三圈同心圆（由内到外一档比一档淡） */
                    ForEach(1..<4, id: \.self) { i in
                        Circle()
                            .stroke(C.green.opacity(0.30 - Double(i) * 0.07), lineWidth: 1)
                            .frame(width: radarD * 2 * CGFloat(i) / 3,
                                   height: radarD * 2 * CGFloat(i) / 3)
                    }

                    /* ④ 转着的扫描：一条长拖尾 + 一条前沿亮线（跟着 sweep 转） */
                    ZStack {
                        RadarWedge(span: 92)
                            .fill(LinearGradient(colors: [C.green.opacity(0.16), .clear],
                                                 startPoint: .leading, endPoint: .trailing))
                        RadarWedge(span: 52)
                            .fill(LinearGradient(colors: [C.green.opacity(0.42), .clear],
                                                 startPoint: .leading, endPoint: .trailing))
                        /* 前沿那道亮线：从圆心指向外，带外发光 */
                        Rectangle()
                            .fill(LinearGradient(colors: [C.green.opacity(0.95), C.green.opacity(0.25)],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: radarD, height: 1.8)
                            .offset(x: radarD / 2)
                            .shadow(color: C.green.opacity(0.85), radius: 7)
                            .frame(width: radarD * 2, height: radarD * 2)
                    }
                    .frame(width: radarD * 2, height: radarD * 2)
                    .rotationEffect(.degrees(sweep))
                    .clipShape(Circle())
                    .frame(width: radarD * 2, height: radarD * 2)

                    /* ⑤ 自己：呼吸圈（两层错开）+ 中心亮点 */
                    Circle()
                        .stroke(C.green.opacity(0.35), lineWidth: 1.4)
                        .frame(width: 54, height: 54)
                        .scaleEffect(0.9 + 0.5 * CGFloat((sin(sweep * .pi / 90) + 1) / 2))
                        .opacity(0.9 - 0.6 * CGFloat((sin(sweep * .pi / 90) + 1) / 2))
                    Circle()
                        .fill(C.green.opacity(0.18))
                        .frame(width: 44, height: 44)
                        .scaleEffect(1 + 0.22 * CGFloat(sin(sweep * .pi / 180)))
                    Circle().fill(C.green).frame(width: 10, height: 10)
                        .shadow(color: C.green.opacity(0.9), radius: 8)
                    /* 附近的人：角度/半径按 id 算死，扫到就亮 */
                    ForEach(Array(people.prefix(14))) { p in blip(p) }
                }
                .frame(height: radarD * 2 + 40)
                .padding(.top, 6)
                if people.isEmpty {
                    Text(loading ? Tr("正在扫描附近的人…")
                                 : (tip.isEmpty
                                    ? Tr("\(Int(maxKm)) 公里内还没有其他人\n（对方也要打开「附近的人」，并且就在你附近）")
                                    : tip))
                        .font(pf(13.5)).foregroundColor(subInk)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                        .padding(.top, 8)
                } else {
                    Text(Tr("已扫到 ") + String(people.count) + Tr(" 个人 · 点亮着的点看资料"))
                        .font(pf(13)).foregroundColor(subInk)
                        .padding(.top, 8)
                }
                Spacer(minLength: 0)
            }
            bottomCard
        }
    }

    /// 圈里一个亮点（头像）
    private func blip(_ p: NearbyPerson) -> some View {
        let s = spot(p)
        let lit = isLit(s.ang)
        let picked = selected?.id == p.id
        let d = radarD * s.r
        let size: CGFloat = picked ? 46 : 38
        return Button {
            withAnimation(.easeOut(duration: 0.18)) { selected = p }
        } label: {
            ZStack {
                Circle().fill(lit || picked ? C.green.opacity(0.9) : Color(hex: 0x2A2A2A))
                    .frame(width: size, height: size)
                Avatar(path: p.avatar ?? "", size: size - 8, radius: (size - 8) / 2)
            }
            .overlay(Circle().stroke(picked ? C.green : Color.white.opacity(lit ? 0.5 : 0.14),
                                     lineWidth: picked ? 2 : 1))
            .shadow(color: lit ? C.green.opacity(0.45) : .clear, radius: 8)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .offset(x: sin(s.ang * .pi / 180) * d, y: -cos(s.ang * .pi / 180) * d)
        .opacity(lit || picked ? 1 : 0.5)
        .animation(.easeOut(duration: 0.25), value: lit)
    }

    /// 这个人摆在哪：角度按 id 固定；半径按「离得越近越靠中心」（km 是真的数据）
    private func spot(_ p: NearbyPerson) -> (ang: Double, r: Double) {
        var h = 5381
        for b in p.id.utf8 { h = (h &* 33) &+ Int(b) }
        let ang = Double(abs(h) % 360)
        let km = max(0.05, p.km ?? 1)
        let near = max(0.25, min(1.0, 1 - (km / max(1, maxKm))))
        return (ang, 0.30 + 0.66 * near)
    }

    /// 扫描扇现在扫到哪个角度了（±26 度算亮）
    private func isLit(_ ang: Double) -> Bool {
        let d = abs(((ang - sweep + 540).truncatingRemainder(dividingBy: 360)) - 180)
        return d < 26
    }

    /// 底下那张卡：选中了谁 / 没选中就显示扫描状态 + 重新扫描
    private var bottomCard: some View {
        VStack(spacing: 8) {
            if let p = selected {
                HStack(spacing: 12) {
                    Avatar(path: p.avatar ?? "", size: 44, radius: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.name).font(pf(16, .medium)).foregroundColor(nameInk).lineLimit(1)
                        Text(signature(p).isEmpty ? p.distanceText
                                                  : p.distanceText + " · " + signature(p))
                            .font(pf(12.5)).foregroundColor(subInk).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button { openCard(p) } label: {
                        Image(systemName: "person.text.rectangle")
                            .font(.system(size: 16)).foregroundColor(subInk)
                            .frame(width: 36, height: 32).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button { helloFor = p } label: {
                        Text(Tr("打招呼")).font(pf(13.5, .medium)).foregroundColor(.white)
                            .padding(.horizontal, 12).frame(height: 32)
                            .background(Capsule().fill(C.green))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 14)).foregroundColor(C.green)
                    Text(loading ? Tr("正在扫描…") : Tr("点上面亮着的头看看是谁"))
                        .font(pf(13.5)).foregroundColor(subInk)
                    Spacer(minLength: 0)
                    Button { Task { await reload(force: true) } } label: {
                        Text(Tr("重新扫描")).font(pf(13, .medium)).foregroundColor(C.green)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(rowBg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 18)
    }

    /* ---------------------------------------------------------- 一行（照参考图） */

    private func personRow(_ p: NearbyPerson) -> some View {
        Button {
            helloFor = p
        } label: {
            HStack(alignment: .top, spacing: 13) {
                Avatar(path: p.avatar ?? "", size: 46, radius: 5)
                    .padding(.leading, 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name)
                        .font(pf(17))
                        .foregroundColor(nameInk)
                        .lineLimit(1)
                    Text(p.distanceText)
                        .font(pf(14))
                        .foregroundColor(subInk)
                        .lineLimit(1)
                }
                .padding(.top, 1)

                Spacer(minLength: 8)

                if !signature(p).isEmpty {
                    Text(signature(p))
                        .font(pf(13.5))
                        .foregroundColor(subInk)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                        .frame(maxWidth: 150, alignment: .trailing)
                        .padding(.top, 3)
                }
            }
            .padding(.trailing, 16)
            .frame(height: 65, alignment: .top)
            .background(rowBg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { openCard(p) } label: {
                Label(Tr("查看资料"), systemImage: "person.text.rectangle")
            }
        }
    }

    /// 右边那列灰字：优先个性签名，其次简介；好友就直接写「已经是好友」
    private func signature(_ p: NearbyPerson) -> String {
        if let m = p.moodText, !m.isEmpty { return m }
        if let b = p.bio, !b.isEmpty { return b }
        if p.friend == true { return "已经是好友" }
        return ""
    }

    private func hint(_ text: String, showSetting: Bool) -> some View {
        VStack(spacing: 10) {
            Text(text)
                .font(pf(14))
                .foregroundColor(subInk)
                .multilineTextAlignment(.center)
            if showSetting {
                Button(Tr("去设置里打开")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(pf(15))
                .foregroundColor(C.green)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    /* ---------------------------------------------------------- 数据 */

    private func setFilter(_ f: String) {
        filter = f
        Task { await reload(force: true) }
    }

    private func reload(force: Bool) async {
        if loading && !force { return }
        loading = true
        defer { loading = false }
        do {
            /* 有定位就先上报（进这个页面等于「我在附近」） */
            if let la = loc.lat, let ln = loc.lng {
                try? await API.shared.nearbyReport(lat: la, lng: ln)
            }
            let r = try await API.shared.nearby(lat: loc.lat, lng: loc.lng, gender: filter, maxKm: maxKm)
            people = r.people
            wider = r.wider
            tip = ""
        } catch {
            tip = (error as? APIError)?.errorDescription ?? "加载失败"
        }
    }

    private func clearLocation() {
        Task {
            try? await API.shared.nearbyClear()
            people = []
            app.show(Tr("已清除位置信息"))
            dismiss()
        }
    }

    private func sendHello() {
        guard let p = helloFor else { return }
        let text = helloText.trimmingCharacters(in: .whitespacesAndNewlines)
        let say = text.isEmpty ? "你好呀，我是在附近的人里看到你的" : text
        helloFor = nil
        Task {
            do {
                _ = try await API.shared.nearbyHello(userId: p.id, text: say)
                app.show(Tr("已打招呼"))
                await app.loadChats()
            } catch {
                app.show((error as? APIError)?.errorDescription ?? "发送失败")
            }
        }
    }

    private func openCard(_ p: NearbyPerson) {
        Task {
            if let u = try? await API.shared.user(id: p.id) { cardUser = u }
        }
    }
}
