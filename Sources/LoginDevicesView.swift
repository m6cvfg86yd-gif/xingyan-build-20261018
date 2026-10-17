import SwiftUI

/* ============================================================
   登录设备管理（照微信那一页做的 —— 桌面 安全 文件夹那张参考图）：
     · 顶栏：返回 + 「登录设备管理」+ 右上「编辑 / 完成」
     · 说明：你的账号在以下设备中登录过，你可以删除设备，
             删除后在该设备登录时需进行安全验证。
     · 「已登录的设备」：这台（右侧写「当前设备」）
     · 「已退出登录的设备」：很久没登录过的那些（右侧写时间，微信那样：
       「7月29日 晚上11:09」「2025年9月22日 上午9:05」）
     · 底下一张卡：「确认新设备登录」+「常见问题」
   点「编辑」每一行左边出现红「删除」，删的是服务端的登录设备记录
   （POST /api/devices/remove），当前这台不给删。
   ============================================================ */
struct LoginDevicesView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var list: [API.LoginDevice] = []
    @State private var loading = true
    @State private var editing = false
    @State private var askDelete: API.LoginDevice?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("登录设备管理"), back: { dismiss() }) {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { editing.toggle() }
                } label: {
                    Text(editing ? Tr("完成") : Tr("编辑"))
                        .font(pf(17))
                        .foregroundColor(C.label)
                        .frame(height: L.navH)
                        .padding(.trailing, 16)
                }
                .buttonStyle(.plain)
                .disabled(list.isEmpty)
            }

            ScrollView {
                VStack(spacing: 0) {
                    Text(Tr("你的账号在以下设备中登录过，你可以删除设备，删除后在该设备登录时需进行安全验证。"))
                        .font(pf(13))
                        .foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.top, 14)

                    if loading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(Tr("正在加载…")).font(pf(15)).foregroundColor(C.subLabel)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 22)
                        .frame(height: 60)
                    } else if list.isEmpty {
                        Text(Tr("还没有设备记录"))
                            .font(pf(15)).foregroundColor(C.subLabel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 22)
                            .frame(height: 60)
                    }

                    if !living.isEmpty {
                        header(Tr("已登录的设备"))
                        GroupCard {
                            ForEach(Array(living.enumerated()), id: \.offset) { i, d in
                                if i > 0 { HairLine(inset: 16) }
                                row(d, right: d.current == true ? Tr("当前设备") : "")
                            }
                        }
                    }

                    if !dead.isEmpty {
                        header(Tr("已退出登录的设备"))
                        GroupCard {
                            ForEach(Array(dead.enumerated()), id: \.offset) { i, d in
                                if i > 0 { HairLine(inset: 16) }
                                row(d, right: wxTime(d.at))
                            }
                        }
                    }

                    Spacer().frame(height: 14)

                    GroupCard {
                        NavigationLink(value: "pair") {
                            HStack(spacing: 12) {
                                Text(Tr("确认新设备登录")).font(pf(17)).foregroundColor(C.label)
                                Spacer(minLength: 8)
                                Chevron(size: 9, line: 1.6).padding(.trailing, 3)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 54)
                            .background(C.cardBg)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        HairLine(inset: 16)
                        NavigationLink(value: "devices.faq") {
                            HStack(spacing: 12) {
                                Text(Tr("常见问题")).font(pf(17)).foregroundColor(C.label)
                                Spacer(minLength: 8)
                                Chevron(size: 9, line: 1.6).padding(.trailing, 3)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 54)
                            .background(C.cardBg)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { await load() }
        .confirmationDialog(Tr("删除这台设备？"),
                            isPresented: Binding(get: { askDelete != nil },
                                                 set: { if !$0 { askDelete = nil } }),
                            titleVisibility: .visible) {
            Button(Tr("删除"), role: .destructive) {
                if let d = askDelete { Task { await remove(d) } }
            }
            Button(Tr("取消"), role: .cancel) { askDelete = nil }
        }
    }

    /* ---------------------------------------------------------- 分组 / 一行 */

    private func header(_ t: String) -> some View {
        Text(t)
            .font(pf(13))
            .foregroundColor(C.subLabel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 6)
    }

    private func row(_ d: API.LoginDevice, right: String) -> some View {
        HStack(spacing: 12) {
            /* 编辑模式：这一行左边冒出一个红「删除」（当前这台不给删，微信也是这样） */
            if editing, d.current != true {
                Button { askDelete = d } label: {
                    Text(Tr("删除"))
                        .font(pf(14))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Capsule().fill(C.red))
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            /* 左边两行：上面**型号**（iPhone 16 Pro）、下面系统版本 —— 微信就是这样 */
            VStack(alignment: .leading, spacing: 3) {
                Text(title(d))
                    .font(pf(17))
                    .foregroundColor(C.label)
                    .lineLimit(1)
                if !deviceSub(d).isEmpty {
                    Text(deviceSub(d))
                        .font(pf(13))
                        .foregroundColor(C.subLabel)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if !right.isEmpty {
                Text(right)
                    .font(pf(15))
                    .foregroundColor(C.subLabel)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 60)
        .background(C.cardBg)
    }

    /* ---------------------------------------------------------- 数据 */

    /// 已登录的设备：当前这台 + 最近 30 天登录过的
    private var living: [API.LoginDevice] {
        list.filter { $0.current == true || recent($0.at) }
    }
    /// 已退出登录的设备：很久没登录过的记录
    private var dead: [API.LoginDevice] {
        list.filter { $0.current != true && !recent($0.at) }
    }
    private func recent(_ ms: Double?) -> Bool {
        guard let ms = ms, ms > 0 else { return false }
        return Date().timeIntervalSince1970 - ms / 1000 < 30 * 24 * 3600
    }

    /// 一行设备的主标题：**型号优先**（用户要求：微信这一页要能看到设备型号）——
    /// 「iPhone 16 Pro」这种；老记录没有型号再用设备名 / UA 那行，最后兜底「未知设备」。
    private func title(_ d: API.LoginDevice) -> String {
        let model = (d.model ?? "").trimmingCharacters(in: .whitespaces)
        if !model.isEmpty { return model }
        let raw = d.name ?? ""
        let name = raw.isEmpty ? "" : (raw.removingPercentEncoding ?? raw)
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        let dev = (d.device ?? "").trimmingCharacters(in: .whitespaces)
        return dev.isEmpty ? Tr("未知设备") : dev
    }

    /// 型号下面那行：**系统版本** + 设备名（有就带上）。
    private func deviceSub(_ d: API.LoginDevice) -> String {
        let os = (d.os ?? "").trimmingCharacters(in: .whitespaces)
        let raw = d.name ?? ""
        let name = (raw.isEmpty ? "" : (raw.removingPercentEncoding ?? raw))
            .trimmingCharacters(in: .whitespaces)
        var bits: [String] = []
        if !os.isEmpty { bits.append(os) }
        if !name.isEmpty, name != title(d) { bits.append(name) }
        if bits.isEmpty { bits.append((d.device ?? "").trimmingCharacters(in: .whitespaces)) }
        return bits.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// 微信那种时间：「7月29日 晚上11:09」「2025年9月22日 上午9:05」
    private func wxTime(_ ms: Double?) -> String {
        guard let ms = ms, ms > 0 else { return "" }
        let d = Date(timeIntervalSince1970: ms / 1000)
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        let y = c.year ?? 0, mo = c.month ?? 1, da = c.day ?? 1
        let h24 = c.hour ?? 0, mi = c.minute ?? 0
        let part = h24 < 12 ? Tr("上午") : (h24 < 18 ? Tr("下午") : Tr("晚上"))
        var h = h24 % 12
        if h == 0 { h = 12 }
        let t = part + "\(h):" + String(format: "%02d", mi)
        let thisYear = cal.component(.year, from: Date())
        return y == thisYear ? "\(mo)月\(da)日 \(t)" : "\(y)年\(mo)月\(da)日 \(t)"
    }

    private func load() async {
        list = await API.shared.devices()
        loading = false
    }

    private func remove(_ d: API.LoginDevice) async {
        busy = true
        askDelete = nil
        if let err = await API.shared.removeDevice(id: d.id) {
            app.show(err)
        } else {
            app.show(Tr("已删除这台设备"))
            await load()
        }
        busy = false
    }
}

/* ============================================================
   登录设备管理 → 常见问题（微信那一页底下就是这三条）
   ============================================================ */
struct DevicesFaqView: View {
    @Environment(\.dismiss) private var dismiss

    private let qa: [(String, String)] = [
        ("怎么知道有没有别人登录我的账号？",
         "这一页会列出所有登录过的设备。不是你自己的设备，点右上「编辑」把它删掉，"
         + "并且尽快改一次登录密码。"),
        ("删掉设备以后，对方还能用吗？",
         "删掉记录以后，那台设备下次登录要重新做安全验证。想让它立刻下线，"
         + "最稳的办法是改一次登录密码。"),
        ("为什么同一个手机出现好几条？",
         "App 卸了重装、或者换了登录方式，都会算成一台新设备 —— 设备名同一个，"
         + "但底下那条记录是新的。")
    ]

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("常见问题"), back: { dismiss() })
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(qa.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(Tr(qa[i].0))
                                .font(pf(16, .medium))
                                .foregroundColor(C.label)
                            Text(Tr(qa[i].1))
                                .font(pf(14))
                                .foregroundColor(C.subLabel)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                        .background(C.cardBg)
                        if i < qa.count - 1 { HairLine(inset: 18) }
                    }
                    Spacer().frame(height: 30)
                }
                .padding(.top, 8)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
    }
}
