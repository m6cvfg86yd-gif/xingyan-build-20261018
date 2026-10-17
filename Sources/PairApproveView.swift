import SwiftUI

/* 设备确认登录（确认方）：
   网页版点「微信授权登录 / QQ 授权登录」会出一个 6 位数字，
   在这台已经登录的手机上：我 → 设置 → 设备确认登录，输入那个数字，网页就登上了。 */
struct PairApproveView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    /// 扫码过来的：数字直接带上，不用再手输（微信扫码也是直接出确认页）
    var startCode: String = ""
    /// 确认完以后额外要做的事（比如把扫码那一页关掉）
    var onDone: (() -> Void)? = nil

    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    /// 已经查过这台请求设备的资料 → 出微信那张「登录确认」卡片
    @State private var checked = false
    @State private var device = ""
    @State private var at = ""
    /// 微信这一页主体是「登录设备管理」：进来先列出登录过的设备（型号 + 系统 + 时间 + 本机）
    @State private var devices: [API.LoginDevice] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr(checked ? "登录确认" : "设备确认登录"), back: { dismiss() })
            ScrollView {
                VStack(spacing: 0) {
                    deviceList
                    codeHint
                    if checked {
                        confirmCard
                    } else {
                        codeForm
                    }
                    Color.clear.frame(height: 24)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .onAppear {
            if !startCode.isEmpty {
                code = startCode
                focused = false
                check()
            } else {
                focused = true
            }
            Task { devices = await API.shared.devices() }
        }
    }

    /* ---------------- 上面：登录设备列表（微信那一页的主体） ---------------- */

    @ViewBuilder private var deviceList: some View {
        if !devices.isEmpty {
            HStack {
                Text(Tr("登录设备")).font(pf(13)).foregroundColor(C.subLabel)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 6)

            GroupCard {
                ForEach(Array(devices.enumerated()), id: \.offset) { i, d in
                    if i > 0 { HairLine(inset: 16) }
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(deviceModelText(d)).font(pf(16.5)).foregroundColor(C.label).lineLimit(1)
                            Text(deviceTimeText(d)).font(pf(12.5)).foregroundColor(C.subLabel).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if d.current == true {
                            Text(Tr("本机"))
                                .font(pf(11.5))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(C.green))
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 56)
                    .background(C.cardBg)
                }
            }
        }
    }

    /// 「用已登录的手机扫一扫 / 输 6 位数字」那一句（新版把扫码放前面）
    private var codeHint: some View {
        Text(Tr("新设备上点「微信登录」会出一个二维码和一个 6 位数字：用已登录的手机扫一下，或者把数字输在下面确认。"))
            .font(pf(12.5))
            .foregroundColor(C.subLabel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 14)
    }

    /// 设备型号：服务端存的 model 优先，没有再退回设备名 / UA
    private func deviceModelText(_ d: API.LoginDevice) -> String {
        let model = (d.model ?? "").trimmingCharacters(in: .whitespaces)
        if !model.isEmpty { return model }
        let raw = d.name ?? ""
        let name = raw.isEmpty ? "" : (raw.removingPercentEncoding ?? raw)
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        let dev = (d.device ?? "").trimmingCharacters(in: .whitespaces)
        return dev.isEmpty ? Tr("未知设备") : dev
    }

    private func deviceTimeText(_ d: API.LoginDevice) -> String {
        let os = (d.os ?? "").trimmingCharacters(in: .whitespaces)
        var bits: [String] = []
        if !os.isEmpty { bits.append(os) }
        if let ms = d.at, ms > 0 {
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "M月d日 HH:mm"
            bits.append(f.string(from: Date(timeIntervalSince1970: ms / 1000)))
        }
        return bits.joined(separator: " · ")
    }

    /* ---------------- 第 ① 步：输入新设备上那串数字 ---------------- */

    private var codeForm: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                    Text(Tr("在另一台设备（网页版 / 新手机）上点「微信登录」，会显示一个二维码和一个 6 位数字：最好用这台手机扫那个码确认，扫不了就把数字输在下面。"))
                        .font(pf(13))
                        .foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.top, 14)

                    HStack(spacing: 10) {
                        TextField("6 位数字", text: $code)
                            .font(.system(size: 26, weight: .bold, design: .monospaced))
                            .keyboardType(.numberPad)
                            .tracking(6)
                            .focused($focused)
                            .onChange(of: code) { v in
                                code = String(v.filter { $0.isNumber }.prefix(6))
                            }
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 64)
                    .background(C.cardBg)
                    .padding(.top, 18)

                    if let e = error {
                        Text(e).font(pf(13)).foregroundColor(C.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18)
                            .padding(.top, 10)
                    }

                    Button {
                        check()
                    } label: {
                        Text(busy ? Tr("查询中…") : Tr("下一步"))
                            .font(pf(16, .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(C.green)
                            .cornerRadius(12)
                    }
                    .disabled(busy || code.count != 6)
                    .padding(.horizontal, 20)
                    .padding(.top, 22)
            }
        }
    }

    /* ---------------- 第 ② 步：微信那张「登录确认」卡片 ---------------- */

    private var confirmCard: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(systemName: "iphone")
                    .font(.system(size: 40))
                    .foregroundColor(C.green)
                Text(device).font(pf(17, .semibold)).foregroundColor(C.label)
                    .multilineTextAlignment(.center).lineLimit(2)
                Text(Tr("请求登录你的星言账号"))
                    .font(pf(13.5)).foregroundColor(C.subLabel)
                if !at.isEmpty {
                    Text(at).font(pf(12.5)).foregroundColor(C.subLabel)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 16)

            HairLine(inset: 16)

            Text(Tr("如果这不是你本人的操作，请点「取消」，并尽快修改密码。"))
                .font(pf(12.5))
                .foregroundColor(C.red.opacity(0.92))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.top, 14)

            Button { approve() } label: {
                Text(busy ? Tr("确认中…") : Tr("确认登录"))
                    .font(pf(16, .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(C.green)
                    .cornerRadius(12)
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { checked = false }
            } label: {
                Text(Tr("取消")).font(pf(16)).foregroundColor(C.label)
                    .frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .background(C.cardBg)
        .cornerRadius(14)
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    /// 先看看这是哪台设备在请求登录
    private func check() {
        busy = true
        error = nil
        Task {
            if let info = await API.shared.pairInfo(code: code) {
                device = info.device.isEmpty ? Tr("另一台设备") : info.device
                at = shortTime(info.at)
                withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { checked = true }
            } else {
                error = Tr("这个数字不对，或者已经过期了 —— 让那台设备重新出一个")
            }
            busy = false
        }
    }

    private func approve() {
        busy = true
        error = nil
        Task {
            if let err = await API.shared.pairApprove(code: code) {
                self.error = err
                withAnimation { checked = false }
            } else {
                app.show(Tr("已确认，那台设备登录成功"))
                onDone?()
                dismiss()
            }
            busy = false
        }
    }

    /// 2026-10-09T21:35:00Z → 请求时间：21:35
    private func shortTime(_ s: String) -> String {
        guard s.count >= 16 else { return "" }
        let t = String(s.dropFirst(11).prefix(5))
        return Tr("请求时间：") + t
    }
}
