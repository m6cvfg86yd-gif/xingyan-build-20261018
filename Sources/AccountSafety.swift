import SwiftUI

/* ============================================================
   安全中心（冻结 / 解冻 / 自助解封）—— 2026-10-12 用户要求；2026-10-13 改掉「微信」字样
   「把微信的真实封号和解冻、可以自己冻结做出来对齐」。

   对应用户看到的：
     · 我 → 设置 → 账号与安全 → **安全中心**
         冻结账号（本人操作，冻上以后所有设备下线、登不进来）
         解冻账号（输入账号 + 登录密码，可再补实名身份证号）
         账号被禁用？自助解封（身份证解封，原来登录页那套）
     · 登录页：账号被冻结 / 被禁用时，下面直接给对应的入口
     · 管理页：输入一个星言号 → 冻结 / 解冻 / 封禁 / 解封（带原因）

   服务器接口见 API.swift 里 `冻结 / 解冻` 那一段。
   ============================================================ */

struct AccountSafetyCenterView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var showFreeze = false
    @State private var showUnfreeze = false
    @State private var showUnban = false

    var body: some View {
        VStack(spacing: 0) {
            /* 标题用「安全中心」（2026-10-13 用户要求：不要再写「微信安全中心」） */
            NavBar(title: Tr("安全中心"), back: { dismiss() })
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Text(Tr("账号冻结、解冻、被封后的自助解封都在这一页。冻结/解封只影响登录，聊天记录和好友都保留。"))
                        .font(pf(13))
                        .foregroundColor(C.subLabel)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                    GroupCard {
                        Button { showFreeze = true } label: {
                            safetyRow(Tr("冻结账号"), Tr("立即冻结"), danger: true)
                        }
                        .buttonStyle(.plain)
                        HairLine(inset: 16)
                        Button { showUnfreeze = true } label: {
                            safetyRow(Tr("解冻账号"), Tr("账号 + 登录密码"), danger: false)
                        }
                        .buttonStyle(.plain)
                        HairLine(inset: 16)
                        Button { showUnban = true } label: {
                            safetyRow(Tr("账号被禁用？自助解封"), Tr("需要实名身份证号"), danger: false)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)

                    Spacer().frame(height: 30)
                }
                .padding(.top, 6)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .sheet(isPresented: $showFreeze) { FreezeAccountSheet().environmentObject(app) }
        .sheet(isPresented: $showUnfreeze) { UnfreezeSheet().environmentObject(app) }
        .sheet(isPresented: $showUnban) { UnbanSheet(preUser: "", prePass: "") }
    }

    private func safetyRow(_ title: String, _ right: String, danger: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title).font(pf(16)).foregroundColor(danger ? C.red : C.label)
            Spacer(minLength: 0)
            Text(right).font(pf(13)).foregroundColor(C.subLabel)
            Chevron(size: 9, line: 1.6)
        }
        .padding(.horizontal, 16).frame(height: 54)
        .contentShape(Rectangle())
    }
}

/* ---------------------------------------------------------- 冻结账号（本人） */

struct FreezeAccountSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var error = ""
    @State private var busy = false
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            DDSheetBar(title: Tr("冻结账号"))
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(Tr("冻结后：所有设备立刻下线、别人搜不到你、也登不进来；聊天记录、好友、朋友圈都保留。需要时可以随时在这台设备上自助解冻。"))
                        .font(pf(14))
                        .foregroundColor(C.label)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField(Tr("登录密码（没设过就留空）"), text: $password)
                        .font(pf(15))
                        .padding(.horizontal, 14).frame(height: 50)
                        .background(RoundedRectangle(cornerRadius: 10).fill(C.fieldBg))
                    Toggle(isOn: $confirm) {
                        Text(Tr("我已了解，确定要冻结我的账号")).font(pf(14.5)).foregroundColor(C.label)
                    }
                    .tint(C.red)
                    if !error.isEmpty {
                        Text(error).font(pf(13)).foregroundColor(C.red)
                    }
                    Spacer().frame(height: 6)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            Button { Task { await doFreeze() } } label: {
                Text(busy ? Tr("正在冻结…") : Tr("冻结账号"))
                    .font(pf(16, .medium)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 23)
                        .fill(confirm ? C.red : C.subLabel))
                    .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)
            .disabled(!confirm || busy)
            .padding(.bottom, max(10, L.safeBottom))
        }
        .background(C.pageBg.ignoresSafeArea())
    }

    private func doFreeze() async {
        busy = true
        error = ""
        if let err = await API.shared.freezeSelf(password: password) {
            error = err
            busy = false
            return
        }
        busy = false
        dismiss()
        app.show(Tr("账号已冻结，可在登录页点「解冻账号」随时解开"))
        await app.logout()          // 自己冻的也立刻退出（服务器那边已经全拒了）
    }
}

/* ---------------------------------------------------------- 解冻账号（自助） */

struct UnfreezeSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var password = ""
    @State private var idCard = ""
    @State private var error = ""
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            DDSheetBar(title: Tr("解冻账号"))
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(Tr("输入被冻结的账号和登录密码就能解开（做过实名的再填一下身份证号更稳妥）。解开后自动登录。"))
                        .font(pf(14))
                        .foregroundColor(C.label)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField(Tr("账号（星言号或手机号）"), text: $username)
                        .font(pf(15)).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(.horizontal, 14).frame(height: 50)
                        .background(RoundedRectangle(cornerRadius: 10).fill(C.fieldBg))
                    SecureField(Tr("登录密码"), text: $password)
                        .font(pf(15))
                        .padding(.horizontal, 14).frame(height: 50)
                        .background(RoundedRectangle(cornerRadius: 10).fill(C.fieldBg))
                    TextField(Tr("实名身份证号（可选）"), text: $idCard)
                        .font(pf(15)).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .padding(.horizontal, 14).frame(height: 50)
                        .background(RoundedRectangle(cornerRadius: 10).fill(C.fieldBg))
                    if !error.isEmpty { Text(error).font(pf(13)).foregroundColor(C.red) }
                    Spacer().frame(height: 6)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            Button { Task { await submit() } } label: {
                Text(busy ? Tr("正在解冻…") : Tr("解冻并登录"))
                    .font(pf(16, .medium)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 23).fill(C.green))
                    .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .padding(.bottom, max(10, L.safeBottom))
        }
        .background(C.pageBg.ignoresSafeArea())
    }

    private func submit() async {
        let u = username.trimmingCharacters(in: .whitespaces)
        let idc = idCard.trimmingCharacters(in: .whitespaces).uppercased()
        if u.isEmpty { error = Tr("请填写被冻结的账号"); return }
        if password.isEmpty { error = Tr("请填写登录密码"); return }
        if !idc.isEmpty && idc.count != 18 { error = Tr("身份证要 18 位，最后一位可以是 X"); return }
        busy = true
        error = ""
        do {
            let user = try await API.shared.unfreeze(username: u, password: password, idCard: idc)
            await app.finishLogin(user)
            app.show(Tr("解冻成功，已登录"))
            dismiss()
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? "解冻失败"
        }
        busy = false
    }
}

/* ---------------------------------------------------------- 管理页：账号状态（冻结 / 解冻 / 封禁 / 解封） */

struct AccountOpsSection: View {
    @EnvironmentObject private var app: AppState

    @State private var name = ""
    @State private var reason = ""
    @State private var stateText = ""
    @State private var targetId = ""
    @State private var banned = false
    @State private var frozen = false
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Tr("账号状态（冻结 / 解冻 / 封禁 / 解封）")).font(pf(16)).foregroundColor(C.label)
                Text(Tr("输入星言号或手机号，先查状态再操作；冻结=临时锁（本人可自助解冻），封禁=处罚（要身份证自助解封）"))
                    .font(pf(12)).foregroundColor(C.subLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)

            HStack(spacing: 8) {
                TextField(Tr("星言号 / 手机号"), text: $name)
                    .font(pf(15)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(.horizontal, 12).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 10).fill(C.fieldBg))
                Button { Task { await look() } } label: {
                    Text(Tr("查状态")).font(pf(15)).foregroundColor(.white)
                        .padding(.horizontal, 14).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 10).fill(C.green))
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
            .padding(.horizontal, 16)

            TextField(Tr("原因（封禁/冻结会写在提示里）"), text: $reason)
                .font(pf(14))
                .padding(.horizontal, 12).frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(C.fieldBg))
                .padding(.horizontal, 16).padding(.top, 8)

            if !stateText.isEmpty {
                Text(stateText).font(pf(13)).foregroundColor(C.subLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 10)
            }

            HStack(spacing: 8) {
                actBtn(Tr("冻结"), "freeze", C.orange)
                actBtn(Tr("解冻"), "unfreeze", C.green)
                actBtn(Tr("封禁"), "ban", C.red)
                actBtn(Tr("解封"), "unban", C.green)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func actBtn(_ t: String, _ action: String, _ color: Color) -> some View {
        Button { Task { await act(action) } } label: {
            Text(t).font(pf(14, .medium)).foregroundColor(.white)
                .frame(maxWidth: .infinity).frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 10).fill(color))
        }
        .buttonStyle(.plain)
        .disabled(targetId.isEmpty || busy)
        .opacity(targetId.isEmpty ? 0.45 : 1)
    }

    private func look() async {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { app.show(Tr("先填星言号")); return }
        busy = true
        let s = await API.shared.accountState(n)
        busy = false
        targetId = s.exists ? n : ""
        banned = s.banned
        frozen = s.frozen
        if !s.exists {
            stateText = Tr("没查到这个人")
            return
        }
        stateText = (banned ? Tr("状态：已封禁") : (frozen ? Tr("状态：已冻结") : Tr("状态：正常")))
            + (s.reason.isEmpty ? "" : Tr("｜原因：") + s.reason)
    }

    private func act(_ action: String) async {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        busy = true
        // /api/ops/account 需要 userId：先按星言号查一次（accountState 只回状态），
        // 所以这里用「管理侧搜索」拿 id；拿不到就直接用星言号（服务器也认 userId 里的用户名）
        let uid = await resolveUserId(n) ?? n
        let ok = await API.shared.opsAccount(userId: uid, action: action,
                                             reason: reason.trimmingCharacters(in: .whitespaces))
        busy = false
        app.show(ok ? (Tr("已执行：") + action) : Tr("操作失败（可能没权限或没这个人）"))
        await look()
    }

    /// 星言号 → userId（用管理侧的搜索接口；失败返回 nil）
    private func resolveUserId(_ n: String) async -> String? {
        if n.hasPrefix("u_") { return n }
        /* 管理侧「按用户名/昵称搜人」的接口（发卡那套用的同一个） */
        let hits = (try? await API.shared.opsCardFind(n)) ?? []
        return hits.first(where: { $0.username == n })?.id ?? hits.first?.id
    }
}
