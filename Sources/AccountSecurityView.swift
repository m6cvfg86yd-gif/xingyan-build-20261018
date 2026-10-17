import SwiftUI

/* ============================================================
   账号与安全（微信「设置 → 账号与安全」那一页）
   · 个人信息 / 微信号（星言号）/ 手机号
   · 修改登录密码
   · 实名认证、支付密码、安全锁（手势）、安全分 —— 原来散在设置页，现在归到这一页
   · 登录设备确认 + 退出其他设备
   ============================================================ */
struct AccountSecurityView: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var realNameText = ""
    @State private var hasPay = false
    @State private var showChangePwd = false
    @State private var confirmLogoutOthers = false
    /// 安全中心（冻结 / 解冻 / 自助解封）
    @State private var showSafety = false

    private var me: User? { app.me }
    private var phoneText: String {
        let p = (me?.phone ?? "").trimmingCharacters(in: .whitespaces)
        return p.isEmpty ? Tr("未绑定") : maskPhone(p)      // 中间打码：138****8888
    }
    private var usernameText: String {
        let u = (me?.username ?? "").trimmingCharacters(in: .whitespaces)
        return u.isEmpty ? "—" : u
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("账号与安全"), back: { dismiss() })

            ScrollView {
                VStack(spacing: 0) {
                    GroupCard {
                        NavigationLink(value: "profile") {
                            row(Tr("个人信息"), me?.name ?? "", chevron: true)
                        }
                        .buttonStyle(.plain)
                        HairLine(inset: 16)
                        Button { app.show(Tr("账号一年只能改一次，需要的话联系客服")) } label: {
                            row(Tr("账号"), usernameText, chevron: true)
                        }
                        .buttonStyle(.plain)
                        HairLine(inset: 16)
                        Button { app.show(Tr("手机号在注册或找回密码时绑定，需要换号联系客服")) } label: {
                            row(Tr("手机号"), phoneText, chevron: true)
                        }
                        .buttonStyle(.plain)
                        HairLine(inset: 16)
                        /* 2026-10-12 用户要求「微信的真实封号和解冻、可以自己冻结做出来对齐」：
                           名字用「安全中心」（2026-10-13 用户要求：不要写「微信安全中心」） */
                        Button { showSafety = true } label: {
                            row(Tr("安全中心"), Tr("冻结 / 解冻 / 自助解封"), chevron: true)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 8)

                    Spacer().frame(height: 8)

                    GroupCard {
                        /* 二级菜单整页进（以前是 sheet 从底下冒出来） */
                        NavigationLink(value: "changepwd") {
                            row(Tr("修改登录密码"), "", chevron: true)
                        }
                        .buttonStyle(.plain)
                        HairLine(inset: 16)
                        NavigationLink(value: "realname") {
                            row(Tr("实名认证"), realNameText, chevron: true)
                        }
                        .buttonStyle(.plain)
                        HairLine(inset: 16)
                        NavigationLink(value: "paypwd") {
                            row(Tr("支付密码"), hasPay ? Tr("已设置") : Tr("未设置"), chevron: true)
                        }
                        .buttonStyle(.plain)
                        HairLine(inset: 16)
                        NavigationLink(value: "gesture") {
                            row(Tr("安全锁（手势密码）"),
                                GestureStore.enabled ? Tr("已开启") : Tr("未开启"), chevron: true)
                        }
                        .buttonStyle(.plain)
                        HairLine(inset: 16)
                        /* 声音锁（微信同一个位置：账号与安全 → 声音锁） */
                        NavigationLink(value: "voicelock") {
                            row(Tr("声音锁"),
                                VoiceLockStore.enabled ? Tr("已开启") : Tr("未开启"), chevron: true)
                        }
                        .buttonStyle(.plain)
                        HairLine(inset: 16)
                        NavigationLink(value: "score") {
                            row(Tr("安全分"), "", chevron: true)
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer().frame(height: 8)

                    GroupCard {
                        /* 微信这一页就是「登录设备管理」：列出所有登录过的手机
                           （真设备名 + 系统 + 最后登录时间 + 本机）。
                           以前这里还有一行「登录设备确认」——点进去是一串 6 位数字，
                           用户看着跟微信对不上，现在把它收进「登录设备管理」页里了。 */
                        NavigationLink(value: "devices") {
                            row(Tr("登录设备管理"), "", chevron: true)
                        }
                        .buttonStyle(.plain)
                        HairLine(inset: 16)
                        Button { confirmLogoutOthers = true } label: {
                            row(Tr("退出其他设备"), "", chevron: true)
                        }
                        .buttonStyle(.plain)
                    }

                    Text(Tr("退出其他设备以后，别的手机上登录的这个账号会被踢下线，需要重新登录。"))
                        .font(pf(12.5))
                        .foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.top, 10)
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
        /* 安全中心：冻结 / 解冻 / 自助解封（AccountSafety.swift） */
        .sheet(isPresented: $showSafety) {
            AccountSafetyCenterView().environmentObject(app)
        }
        .task {
            if let m = try? await API.shared.me() {
                app.me = m
            }
            let rn = await API.shared.realNameStatus()
            realNameText = rn.verified ? Tr("已实名") : Tr("未实名")
            hasPay = await API.shared.hasPayPassword()
        }
        .confirmationDialog(Tr("退出其他设备？"), isPresented: $confirmLogoutOthers, titleVisibility: .visible) {
            Button(Tr("退出"), role: .destructive) {
                Task {
                    if let err = await API.shared.logoutOtherDevices() {
                        app.show(err)
                    } else {
                        app.show(Tr("已退出其他设备"))
                    }
                }
            }
            Button(Tr("取消"), role: .cancel) { }
        }
    }

    private func row(_ title: String, _ value: String, chevron: Bool) -> some View {
        HStack(spacing: 12) {
            Text(title).font(pf(17)).foregroundColor(C.label)
            Spacer(minLength: 8)
            if !value.isEmpty {
                Text(value).font(pf(15)).foregroundColor(C.subLabel).lineLimit(1)
            }
            if chevron { Chevron(size: 9, line: 1.6).padding(.trailing, 3) }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(C.cardBg)
        .contentShape(Rectangle())
    }
}

/* ============================================================
   修改登录密码（微信「账号与安全 → 修改密码」）
   ============================================================ */
struct ChangePasswordSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var current = ""
    @State private var next = ""
    @State private var again = ""
    @State private var busy = false
    @State private var errorText = ""

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("修改登录密码"), back: { dismiss() }) {
                Button { save() } label: {
                    Text(busy ? Tr("保存中…") : Tr("完成"))
                        .font(pf(17))
                        .foregroundColor(canSave ? C.green : C.subLabel)
                        .frame(height: L.navH)
                        .padding(.trailing, 16)
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
            }

            GroupCard {
                field(Tr("当前密码"), $current)
                HairLine(inset: 16)
                field(Tr("新密码（至少 6 位）"), $next)
                HairLine(inset: 16)
                field(Tr("再输一遍新密码"), $again)
            }
            .padding(.top, 12)

            if !errorText.isEmpty {
                Text(errorText)
                    .font(pf(13))
                    .foregroundColor(C.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.top, 10)
            }

            Text(Tr("改完密码以后，其他手机上登录的这个账号会被踢下线。"))
                .font(pf(12.5))
                .foregroundColor(C.subLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 12)
            Spacer()
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .hidesTabBar()
        /* 2026-10-16：改密码页补左滑返回（同一个 App 里别有的能滑有的不能） */
        .swipeBack { dismiss() }
    }

    private var canSave: Bool { !busy && !current.isEmpty && next.count >= 6 && next == again }

    private func field(_ title: String, _ text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(title).font(pf(16)).foregroundColor(C.label)
            Spacer(minLength: 8)
            SecureField("", text: text)
                .font(pf(16))
                .foregroundColor(C.label)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 170)
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
    }

    private func save() {
        errorText = ""
        if next != again { errorText = Tr("两次输入的新密码不一样"); return }
        if next.count < 6 { errorText = Tr("新密码至少 6 位"); return }
        busy = true
        Task {
            do {
                try await API.shared.changePassword(current: current, new: next)
                busy = false
                dismiss()
                app.show(Tr("密码已修改"))
            } catch {
                busy = false
                errorText = (error as? APIError)?.errorDescription ?? Tr("修改失败")
            }
        }
    }
}
