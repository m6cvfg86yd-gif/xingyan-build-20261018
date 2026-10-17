import SwiftUI

/* ============================================================
   支付密码（我 → 设置 → 支付密码）
   设过密码的：先验原密码 → 输新密码 → 再输一遍确认
   没设过的：输新密码 → 再输一遍确认
   键盘用 iOS 原生的数字键盘。
   ============================================================ */

struct PayPasswordView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    private enum Step { case old, new1, new2 }

    @State private var hasPwd = false          // 之前设过没有
    @State private var loaded = false
    @State private var step: Step = .new1
    @State private var input = ""
    @State private var firstNew = ""           // 第一次输的新密码
    @State private var oldPwd = ""             // 验过的原密码（改密码时要带给服务器）
    @State private var hint: String?
    @State private var shake = false
    @State private var busy = false
    @FocusState private var focus: Bool

    private var pwdW: CGFloat { L.payPwdW }
    private var pwdH: CGFloat { L.payPwdH }

    private var title: String {
        switch step {
        case .old:  return "请输入原支付密码"
        case .new1: return hasPwd ? "请输入新的支付密码" : "请设置 6 位支付密码"
        case .new2: return "请再次输入确认"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("支付密码"), back: { dismiss() })

            VStack(spacing: 0) {
                Text(title)
                    .font(pf(16))
                    .foregroundColor(C.label)
                    .padding(.top, 34)

                cells
                    .padding(.top, 22)

                if let hint = hint {
                    Text(hint)
                        .font(pf(13.5))
                        .foregroundColor(Color(hex: 0xE5484D))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                        .padding(.top, 14)
                } else {
                    Text(Tr("支付密码是 6 位数字，转账付款时要输它确认"))
                        .font(pf(13))
                        .foregroundColor(C.subLabel)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                        .padding(.top, 14)
                }

                /* 收字的输入框：1×1 藏起来，靠它弹原生数字键盘 */
                TextField("", text: $input)
                    .keyboardType(.numberPad)
                    .focused($focus)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .onChange(of: input) { v in
                        let clean = String(v.filter { $0 >= "0" && $0 <= "9" }.prefix(6))
                        if clean != v { input = clean; return }
                        hint = nil
                        if clean.count == 6 { advance() }
                    }
                    .onAppear { focusSoon() }

                Spacer(minLength: 0)

                GroupCard {
                    infoRow(hasPwd ? "当前状态" : "当前状态", hasPwd ? "已设置支付密码" : "还没有设置支付密码")
                }
                .padding(.bottom, 26)
            }
            .frame(maxWidth: .infinity)
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .overlay {
            if busy {
                ZStack {
                    Color.black.opacity(0.12).ignoresSafeArea()
                    ProgressView().padding(18)
                        .background { CardGlassBox(radius: 10) }
                }
            }
        }
        .task {
            guard !loaded else { return }
            hasPwd = await API.shared.hasPayPassword()
            step = hasPwd ? .old : .new1
            loaded = true
        }
    }

    /* ---------------------------------------------------------- 6 个格子 */

    private var cells: some View {
        /* 统一用支付页那套 6 格（圆角卡片 + 当前格绿边；错了整排抖） */
        PayDotField(count: input.count, shake: shake ? -6 : 0,
                    busy: busy, height: 48)
            .contentShape(Rectangle())
            .onTapGesture { focus = true }
    }

    private func infoRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(pf(15)).foregroundColor(C.subLabel)
            Spacer(minLength: 0)
            Text(v).font(pf(15)).foregroundColor(C.label)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    /* ---------------------------------------------------------- 流程 */

    /// 半屏/整页刚进来时抢焦点偶尔会被系统吞掉，隔几拍补两次
    private func focusSoon() {
        Task {
            focus = true
            for delay in [280_000_000, 480_000_000] {
                try? await Task.sleep(nanoseconds: UInt64(delay))
                if Task.isCancelled { return }
                if !focus && input.isEmpty { focus = true }
            }
        }
    }

    private func advance() {
        switch step {
        case .old:
            checkOld()
        case .new1:
            firstNew = input
            input = ""
            step = .new2
            focusSoon()
        case .new2:
            finish()
        }
    }

    private func checkOld() {
        let code = input
        busy = true
        Task {
            do {
                try await API.shared.verifyPayPassword(code)
                oldPwd = code
                input = ""
                step = .new1
                hint = nil
                busy = false
                focusSoon()
            } catch {
                busy = false
                fail((error as? APIError)?.errorDescription ?? "原支付密码不正确")
            }
        }
    }

    private func finish() {
        guard input == firstNew else {
            fail("两次输入不一样，重新输一遍")
            firstNew = ""
            step = .new1
            return
        }
        let code = input
        busy = true
        Task {
            do {
                try await API.shared.setPayPassword(code, current: oldPwd)
                busy = false
                app.show(hasPwd ? "支付密码改好了" : "支付密码设好了")
                dismiss()
            } catch {
                busy = false
                fail((error as? APIError)?.errorDescription ?? "设置失败，再试一次")
            }
        }
    }

    private func fail(_ message: String) {
        hint = message
        input = ""
        shake = true
        focus = true
        Task {
            try? await Task.sleep(nanoseconds: 420_000_000)
            shake = false
        }
    }
}
