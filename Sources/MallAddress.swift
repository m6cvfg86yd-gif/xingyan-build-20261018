import SwiftUI
import CoreLocation

/* ============================================================
   收货地址簿（2026-10-14 用户：「收货地址啥的单独开个页面存储，学京东逻辑」）

   京东那套：
     · 「我的 → 收货地址」进一个**独立的地址列表页**：一条地址一行卡片，
       姓名 + 手机号 + 省市区详细地址，默认那条有「默认」小标签
     · 每行右边一支铅笔 → 编辑；编辑页里能删
     · 底部固定一颗「新增收货地址」
     · 下单页顶部显示默认地址，点一下进同一个列表页**挑一条**，选完自动回下单页
   数据存在 DDStore 的地址簿里（跟购物车/收藏一样落本机 dd_mall.json）。
   ============================================================ */

struct DDAddress: Identifiable, Codable, Hashable {
    var id: String
    /// 收货人
    var name: String
    var phone: String
    /// 省市区
    var region: String
    /// 详细地址（街道门牌）
    var detail: String
    var isDefault: Bool

    /// 一行里显示的那串字：省市区 + 详细地址
    var full: String { region + detail }
    /// 信息齐全没（老数据迁移上来可能只有地址）
    var complete: Bool { !name.isEmpty && phone.count >= 6 && (!region.isEmpty || !detail.isEmpty) }
}

/* ---------------------------------------------------------- 地址列表 */

struct DDAddressListView: View {
    @ObservedObject private var store = DDStore.shared
    @Environment(\.dismiss) private var dismiss

    /// 下单页进来时传：点一行就选中它、回上一页（不传就是纯管理）
    private let pick: ((DDAddress) -> Void)?

    /* 显式 init：这个页面在**别的文件**里用（我的 → 收货地址 / 下单页挑地址） */
    init(pick: ((DDAddress) -> Void)? = nil) { self.pick = pick }

    @State private var editing: DDAddress? = nil
    @State private var adding = false

    var body: some View {
        VStack(spacing: 0) {
            DDSheetBar(title: Tr("收货地址"))
            if store.addresses.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 40, weight: .light))
                        .foregroundColor(DDColor.sub.opacity(0.7))
                    Text(Tr("还没有收货地址")).font(pf(15)).foregroundColor(DDColor.sub)
                    Text(Tr("加一条，下单时就不用再填了")).font(pf(12.5)).foregroundColor(DDColor.sub.opacity(0.8))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(store.addresses) { a in
                            card(a)
                        }
                    }
                    .padding(10)
                }
            }
            Button { adding = true } label: {
                Text(Tr("新增收货地址"))
                    .font(pf(16, .medium)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 23).fill(DDColor.gradBtn))
                    .padding(.horizontal, 14)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            .padding(.bottom, max(10, L.safeBottom * 0.6))
        }
        .background(DDColor.page.ignoresSafeArea())
        .ddLight()
        .sheet(isPresented: $adding) {
            DDAddressEditView(address: nil).ddLight()
        }
        .sheet(item: $editing) { a in
            DDAddressEditView(address: a).ddLight()
        }
    }

    private func card(_ a: DDAddress) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(a.name.isEmpty ? Tr("未填收货人") : a.name)
                        .font(pf(15.5, .medium)).foregroundColor(DDColor.ink)
                    if !a.phone.isEmpty {
                        Text(a.phone).font(pf(13.5)).foregroundColor(DDColor.sub)
                    }
                    if a.isDefault {
                        Text(Tr("默认"))
                            .font(pf(10.5, .semibold)).foregroundColor(.white)
                            .padding(.horizontal, 5).frame(height: 16)
                            .background(RoundedRectangle(cornerRadius: 3).fill(DDColor.red))
                    }
                }
                Text(a.full.isEmpty ? Tr("还没填详细地址") : a.full)
                    .font(pf(13.5)).foregroundColor(DDColor.sub)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !a.complete {
                    Text(Tr("这条还没填全，点右边铅笔补一下"))
                        .font(pf(11.5)).foregroundColor(DDColor.red)
                }
            }
            Spacer(minLength: 0)
            Button { editing = a } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 17))
                    .foregroundColor(DDColor.sub)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(DDColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            if let p = pick {
                p(a)
                dismiss()
            } else {
                editing = a
            }
        }
    }
}

/* ---------------------------------------------------------- 新增 / 编辑 */

struct DDAddressEditView: View {
    @ObservedObject private var store = DDStore.shared
    @Environment(\.dismiss) private var dismiss

    /// nil = 新增
    private let address: DDAddress?

    init(address: DDAddress?) { self.address = address }

    @State private var name = ""
    @State private var phone = ""
    @State private var region = ""
    @State private var detail = ""
    @State private var isDefault = false
    @FocusState private var focus: Int?
    /* 定位（2026-10-16 用户：「所在地区要直接可以定位的，真实的定位输入地址的地方」）：
       点了就真定位一次 → 反查地址 → 自动把省市区填进「所在地区」、街道门牌填进「详细地址」，
       用户还能接着改。定位用的是一次性的 OneShotLocation（不会后台跟踪）。 */
    @State private var locating = false
    @State private var locMsg: String?

    private var isNew: Bool { address == nil }

    /// 定位到的地址（省 市 区 / 街道门牌）
    private struct LocAddr { var region = ""; var detail = "" }

    var body: some View {
        VStack(spacing: 0) {
            DDSheetBar(title: isNew ? Tr("新增收货地址") : Tr("编辑收货地址"))
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    VStack(spacing: 0) {
                        field(Tr("收货人"), $name, 0, keyboard: .default)
                        HairLine(inset: 14)
                        field(Tr("手机号"), $phone, 1, keyboard: .numberPad)
                        HairLine(inset: 14)
                        field(Tr("所在地区（省 市 区）"), $region, 2, keyboard: .default)
                        HairLine(inset: 14)
                        /* 定位那一条：和上面几行同一个卡片里，一眼就知道地址能自动填 */
                        Button { locateMe() } label: {
                            HStack(spacing: 9) {
                                Image(systemName: locating ? "location.fill" : "location")
                                    .font(pf(15, .medium))
                                    .foregroundColor(DDColor.red)
                                Text(locating ? Tr("正在定位…") : Tr("定位当前位置，自动填地址"))
                                    .font(pf(15))
                                    .foregroundColor(DDColor.ink)
                                Spacer(minLength: 0)
                                if locating {
                                    ProgressView().scaleEffect(0.78)
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(pf(13))
                                        .foregroundColor(DDColor.sub)
                                }
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 50)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(locating)
                        HairLine(inset: 14)
                        field(Tr("详细地址（街道 门牌）"), $detail, 3, keyboard: .default)
                    }
                    .background(DDColor.card)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    if let m = locMsg {
                        HStack(spacing: 6) {
                            Image(systemName: "location.circle")
                                .font(pf(13))
                                .foregroundColor(DDColor.sub)
                            Text(m).font(pf(12.5)).foregroundColor(DDColor.sub)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 4)
                    }

                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Tr("设为默认地址")).font(pf(15)).foregroundColor(DDColor.ink)
                            Text(Tr("下单时优先用这一条")).font(pf(12)).foregroundColor(DDColor.sub)
                        }
                        Spacer(minLength: 0)
                        Toggle("", isOn: $isDefault)
                            .labelsHidden()
                            .tint(DDColor.red)
                    }
                    .padding(14)
                    .background(DDColor.card)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    if !isNew {
                        Button {
                            if let a = address { store.removeAddress(a.id) }
                            dismiss()
                        } label: {
                            Text(Tr("删除这条地址"))
                                .font(pf(15)).foregroundColor(Color(hex: 0xFA5151))
                                .frame(maxWidth: .infinity).frame(height: 46)
                                .background(RoundedRectangle(cornerRadius: 14).fill(DDColor.card))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer().frame(height: 10)
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
            }
            Button { save() } label: {
                Text(Tr("保存"))
                    .font(pf(16, .medium)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 23).fill(canSave ? DDColor.gradBtn : LinearGradient(
                        colors: [Color(hex: 0xF0C9BE), Color(hex: 0xE7B7AA)],
                        startPoint: .leading, endPoint: .trailing)))
                    .padding(.horizontal, 14)
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            .padding(.top, 6)
            .padding(.bottom, max(10, L.safeBottom * 0.6))
        }
        .background(DDColor.page.ignoresSafeArea())
        .ddLight()
        .onAppear {
            guard let a = address else {
                isDefault = store.addresses.isEmpty     // 第一条默认设成默认地址
                return
            }
            name = a.name; phone = a.phone; region = a.region; detail = a.detail; isDefault = a.isDefault
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && phone.trimmingCharacters(in: .whitespaces).count >= 6
            && !(region + detail).trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func field(_ label: String, _ text: Binding<String>, _ idx: Int,
                       keyboard: UIKeyboardType) -> some View {
        HStack(spacing: 12) {
            Text(label).font(pf(15)).foregroundColor(DDColor.ink)
                .frame(width: 132, alignment: .leading)
            TextField("", text: text)
                .font(pf(15))
                .keyboardType(keyboard)
                .focused($focus, equals: idx)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
    }

    /* 真定位：拿一次坐标 → 反查地址 → 填进表单。权限 / 失败都用人话提示，
       不给用户看 Apple 那串英文。 */
    private func locateMe() {
        guard !locating else { return }
        locating = true
        locMsg = nil
        focus = nil
        Task {
            let loc = await OneShotLocation.shared.current()
            guard let loc = loc else {
                locating = false
                locMsg = Tr("定位没成功：到「设置 → 隐私与安全性 → 定位服务」里允许本 App 用位置，再点一次")
                return
            }
            let a = await Self.reverse(loc)
            if !a.region.isEmpty { region = a.region }
            /* 详细地址：用户自己填过就别覆盖，只补空的 */
            if detail.trimmingCharacters(in: .whitespaces).isEmpty && !a.detail.isEmpty {
                detail = a.detail
            }
            locating = false
            locMsg = a.region.isEmpty
                ? Tr("定位到了，但没解析出地址，稍后再试或手动填写")
                : Tr("已按当前位置填好，门牌号可以自己再改一下")
        }
    }

    /// 坐标 → 省 市 区 + 街道门牌
    private static func reverse(_ loc: CLLocation) async -> LocAddr {
        var out = LocAddr()
        guard let marks = try? await CLGeocoder().reverseGeocodeLocation(loc),
              let m = marks.first else { return out }
        var parts: [String] = []
        func add(_ v: String?) {
            guard let v = v?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return }
            if parts.last != v { parts.append(v) }
        }
        add(m.administrativeArea)      // 省 / 直辖市
        add(m.locality)                // 市
        add(m.subLocality)             // 区
        out.region = parts.joined(separator: " ")
        var d: [String] = []
        if let v = m.thoroughfare, !v.isEmpty { d.append(v) }
        if let v = m.subThoroughfare, !v.isEmpty { d.append(v) }
        if d.isEmpty, let v = m.name, !v.isEmpty { d.append(v) }
        out.detail = d.joined()
        return out
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        let p = phone.trimmingCharacters(in: .whitespaces)
        let r = region.trimmingCharacters(in: .whitespaces)
        let d = detail.trimmingCharacters(in: .whitespaces)
        if var a = address {
            a.name = n; a.phone = p; a.region = r; a.detail = d; a.isDefault = isDefault
            store.updateAddress(a)
        } else {
            store.addAddress(DDAddress(id: "", name: n, phone: p, region: r, detail: d, isDefault: isDefault))
        }
        dismiss()
    }
}
