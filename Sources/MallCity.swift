import SwiftUI

/* ============================================================
   商城顶部「城市定位」（2026-10-16 用户：「顶部位置做个像美团一样的城市定位」）

   美团那套：首页顶上一行「📍上海 ▾」，点开是城市选择页
     · 当前定位（用系统定位反查城市，旁边一颗「重新定位」）
     · 热门城市（网格，一点就换）
     · 搜索城市（输入即时查）
   选定后存本地；天气接口按这个城市查 —— 所以**天气和二楼背景跟着城市变**。
   ============================================================ */

struct DDCityItem: Decodable, Equatable {
    var name: String
    var admin: String?
    var country: String?
    var lat: Double
    var lon: Double
}

final class DDCity: ObservableObject {
    static let shared = DDCity()

    @Published private(set) var name: String = ""
    @Published private(set) var lat: Double = 0
    @Published private(set) var lon: Double = 0
    @Published private(set) var locating = false
    /// 定位失败（美团那页会显示「定位失败，请点击重试」）
    @Published private(set) var locateFailed = false
    /// 最近访问过的城市（美团有这一栏）
    @Published private(set) var recents: [String] = []
    /* 2026-10-17 用户：「商城的定位有点不太准」——
       ① 用户**手选**过的城市，别再被自动定位覆盖（以前只要进商城就会重新定位）；
       ② 自动定位最多 6 小时刷一次（老定位别一直用着，出差/换城市也能跟上）；
       ③ 反查失败/只拿到"区县"时服务器会纠正成城市名（见 /api/city/here）。 */
    @Published private(set) var manual = false

    private let kN = "chris.city.name"
    private let kA = "chris.city.lat"
    private let kO = "chris.city.lon"
    private let kR = "chris.city.recents"
    private let kM = "chris.city.manual"
    private let kT = "chris.city.at"

    init() {
        name = UserDefaults.standard.string(forKey: kN) ?? ""
        lat = UserDefaults.standard.double(forKey: kA)
        lon = UserDefaults.standard.double(forKey: kO)
        recents = (UserDefaults.standard.array(forKey: kR) as? [String]) ?? []
        manual = UserDefaults.standard.bool(forKey: kM)
    }

    var isSet: Bool { !name.isEmpty }
    /// 顶部那行显示什么：没定过就先显示「定位中」
    var display: String { isSet ? name : (locating ? "定位中…" : "选择城市") }

    func set(_ item: DDCityItem, manual byUser: Bool = false) {
        name = item.name
        lat = item.lat
        lon = item.lon
        manual = byUser
        UserDefaults.standard.set(name, forKey: kN)
        UserDefaults.standard.set(lat, forKey: kA)
        UserDefaults.standard.set(lon, forKey: kO)
        UserDefaults.standard.set(byUser, forKey: kM)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: kT)
        /* 最近访问：新的排前面，留 4 个（美团那栏就是几个常用城市） */
        var r = recents.filter { $0 != item.name }
        r.insert(item.name, at: 0)
        recents = Array(r.prefix(4))
        UserDefaults.standard.set(recents, forKey: kR)
        MallWeather.shared.refresh(force: true)     // 换城市 → 天气和背景跟着换
    }

    /// 服务器回的"这批天气算在哪个城市" —— 只填名字，**不触发刷新**
    /// （不然刷新→回城市名→再刷新，来回死循环）
    func adopt(name n: String, lat la: Double, lon lo: Double) {
        guard !n.isEmpty, name != n else { return }
        name = n
        if la != 0 { lat = la }
        if lo != 0 { lon = lo }
        UserDefaults.standard.set(name, forKey: kN)
        UserDefaults.standard.set(lat, forKey: kA)
        UserDefaults.standard.set(lon, forKey: kO)
    }

    /// 用系统定位反查城市（第一次进商城会自动来一次）
    func locate() {
        guard !locating else { return }
        locating = true
        locateFailed = false
        Task {
            let loc = await OneShotLocation.shared.current()
            var got: DDCityItem? = nil
            if let loc {
                got = await API.shared.cityHere(lat: loc.coordinate.latitude,
                                                lon: loc.coordinate.longitude)
            }
            await MainActor.run {
                self.locating = false
                if let got { self.set(got) }
                else { self.locateFailed = true }
            }
        }
    }

    /// 顺手定位一次：没定过就定；定过是**自动定位来的**、且超过 6 小时没更新，也再定一次。
    /// 用户自己选过的城市（manual）永远不动。
    func locateIfNeeded() {
        guard !manual else { return }
        if isSet {
            let at = UserDefaults.standard.double(forKey: kT)
            if at > 0, Date().timeIntervalSince1970 - at < 6 * 3600 { return }
        }
        locate()
    }

    /// 回到「自动定位」（用户点「当前定位」那一行）：以后跟着手机走
    func useAuto() {
        manual = false
        UserDefaults.standard.set(false, forKey: kM)
        locate()
    }
}

/* ---------------------------------------------------------- 城市选择页（美团那种） */
struct DDCityPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var city = DDCity.shared

    @State private var q = ""
    @State private var hot: [DDCityItem] = []
    @State private var found: [DDCityItem] = []
    @State private var searching = false

    var body: some View {
        VStack(spacing: 0) {
            /* 顶栏：取消 / 标题 / 占位 */
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DDColor.ink)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                Text(Tr("选择城市")).font(pf(16.5, .semibold)).foregroundColor(DDColor.ink)
                Spacer(minLength: 0)
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 6)

            /* 搜索框 */
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DDColor.sub)
                TextField(Tr("搜索城市"), text: $q)
                    .font(pf(14.5))
                    .submitLabel(.search)
                    .onSubmit { runSearch() }
                    .onChange(of: q) { v in
                        if v.trimmingCharacters(in: .whitespaces).isEmpty { found = [] }
                    }
                if !q.isEmpty {
                    Button { q = ""; found = [] } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15)).foregroundColor(DDColor.sub.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(Color.dyn(0xF2F2F5, 0x2A2A2E)))
            .padding(.horizontal, 14)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if !found.isEmpty {
                        groupTitle(Tr("搜索结果"))
                        cityGrid(found)
                    }

                    groupTitle(Tr("当前定位"))
                    HStack(spacing: 8) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 13)).foregroundColor(DDColor.red)
                        if city.locating {
                            Text(Tr("定位中…")).font(pf(16)).foregroundColor(DDColor.sub)
                        } else if city.isSet {
                            Text(city.name).font(pf(17, .medium)).foregroundColor(DDColor.red)
                        } else {
                            Text(city.locateFailed ? Tr("定位失败，请点击重试") : Tr("还没定位"))
                                .font(pf(15)).foregroundColor(DDColor.sub)
                        }
                        Spacer(minLength: 0)
                        Button {
                            city.locate()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise").font(.system(size: 11.5, weight: .semibold))
                                Text(Tr("重新定位")).font(pf(12.5))
                            }
                            .foregroundColor(DDColor.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16).frame(height: 52)
                    .contentShape(Rectangle())
                    /* 点这一行 = 用"当前定位"（以后跟着手机走，不再锁定手选的城市） */
                    .onTapGesture { city.useAuto(); dismiss() }
                    HairLine(inset: 16)

                    if !city.recents.isEmpty {
                        groupTitle(Tr("最近访问"))
                        cityGrid(city.recents.map { n in
                            hot.first(where: { $0.name == n }) ?? DDCityItem(name: n, admin: nil, country: nil, lat: 0, lon: 0)
                        })
                        HairLine(inset: 16)
                    }

                    if hot.isEmpty {
                        groupTitle(Tr("热门城市"))
                        ProgressView().padding(.horizontal, 16).padding(.vertical, 20)
                    } else {
                        groupTitle(Tr("热门城市"))
                        cityGrid(hot)
                    }

                    Color.clear.frame(height: 30)
                }
            }
            .background(DDColor.page)
        }
        .background(DDColor.page)
        .task {
            if hot.isEmpty { hot = await API.shared.cityHot() }
        }
    }

    private func groupTitle(_ t: String) -> some View {
        Text(t)
            .font(pf(13, .medium)).foregroundColor(DDColor.sub)
            .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 8)
    }

    /// 城市网格：**美团那套 —— 纯文字、不带色块、每行 4 个、选中变红**
    private func cityGrid(_ list: [DDCityItem]) -> some View {
        let cols = Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4)
        return LazyVGrid(columns: cols, spacing: 0) {
            ForEach(list, id: \.name) { c in
                Button {
                    /* 用户自己点的城市 = 手选：以后进商城不再被自动定位覆盖 */
                    city.set(c, manual: true)
                    dismiss()
                } label: {
                    Text(c.name)
                        .font(pf(15, city.name == c.name ? .medium : .regular))
                        .foregroundColor(city.name == c.name ? DDColor.red : DDColor.ink)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    private func runSearch() {
        let s = q.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        searching = true
        Task {
            let r = await API.shared.citySearch(s)
            await MainActor.run { found = r; searching = false }
        }
    }
}
