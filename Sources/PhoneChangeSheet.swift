import SwiftUI

/* ============================================================
   换手机号（和微信一个流程）：填新号 → 收验证码 → 提交。
   · 手机号一年只能换一次（服务端也拦）
   · 新号不能已经绑了别的账号
   · 没配短信通道时（后台「短信通道」还没填），验证码发不出去，
     所以再给一个「当前登录密码」的方式验证 —— 不然公网用户根本换不了。
   ============================================================ */

struct PhoneChangeSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var phone = ""
    @State private var code = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error = ""
    @State private var note = ""
    @State private var devCode = ""

    private var phoneOK: Bool {
        phone.range(of: "^1[3-9]\\d{9}$", options: .regularExpression) != nil
    }

    var body: some View {
        /* 整页 push：顶栏换成全站 NavBar（不再自带 NavigationStack） */
        VStack(spacing: 0) {
            NavBar(title: Tr("更换手机号"), back: { dismiss() })
            VStack(alignment: .leading, spacing: 14) {
                Text(Tr("新手机号要能收短信验证码；手机号一年只能换一次。"))
                    .font(.system(size: 13)).foregroundColor(C.subLabel)

                HStack(spacing: 10) {
                    TextField(Tr("新手机号"), text: $phone).keyboardType(.numberPad)
                    Button(Tr("获取验证码")) { sendCode() }
                        .font(.system(size: 14)).foregroundColor(C.loginGreen)
                        .disabled(!phoneOK || busy)
                }
                .padding(.horizontal, 14).frame(height: 52)
                .background(Color.dyn(0xFFFFFF, 0x1C1C1E))

                TextField(Tr("验证码"), text: $code).keyboardType(.numberPad)
                    .padding(.horizontal, 14).frame(height: 52)
                    .background(Color.dyn(0xFFFFFF, 0x1C1C1E))

                if !devCode.isEmpty {
                    Text(Tr("本机直接显示验证码：") + devCode)
                        .font(.system(size: 13)).foregroundColor(C.loginGreen)
                }

                SecureField(Tr("当前登录密码（没配短信通道时用）"), text: $password)
                    .padding(.horizontal, 14).frame(height: 52)
                    .background(Color.dyn(0xFFFFFF, 0x1C1C1E))

                if !note.isEmpty { Text(note).font(.system(size: 13)).foregroundColor(C.subLabel) }
                if !error.isEmpty { Text(error).font(.system(size: 13)).foregroundColor(C.red) }

                Button { submit() } label: {
                    Text(busy ? Tr("提交中…") : Tr("确认更换"))
                        .font(.system(size: 17, weight: .medium)).foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background(phoneOK && !busy ? C.loginGreen : C.subLabel)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .disabled(busy || !phoneOK)

                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
    }

    private func sendCode() {
        busy = true; error = ""; note = ""; devCode = ""
        Task {
            do {
                let dev = try await API.shared.phoneChangeCode(phone: phone)
                devCode = dev ?? ""
                note = devCode.isEmpty ? Tr("验证码已发送，5 分钟内有效") : Tr("没配短信通道，验证码直接显示在这里")
            } catch { self.error = (error as? APIError)?.errorDescription ?? "发送失败" }
            busy = false
        }
    }

    private func submit() {
        busy = true; error = ""; note = ""
        Task {
            do {
                let masked = try await API.shared.changePhone(phone: phone, code: code, password: password)
                app.show(Tr("手机号已更换为 ") + (masked.isEmpty ? phone : masked))
                dismiss()
            } catch { self.error = (error as? APIError)?.errorDescription ?? "更换失败" }
            busy = false
        }
    }
}
