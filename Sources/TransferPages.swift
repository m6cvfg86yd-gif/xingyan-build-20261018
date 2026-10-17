import SwiftUI

/* ============================================================
   转账 4 页（按你给的设计稿实现）
     1) TransferHomeView      填写收款人 / 金额 / 备注
     2) TransferConfirmView   确认信息
     3) TransferPasswordView  6 位支付密码（能真的输入，输满自动提交）
     4) TransferSuccessView   转账成功
   说明：设计稿里两处 iOS 上跑不通，做了等价替换：
     · Color(hex:) → 项目里已有的 Color(hexString:)
     · NavigationStack.popToRoot() / 空 label 的 NavigationLink → 用导航路径 path 跳转
   颜色：默认 #007AFF / #34C759，后台「🎨 登录页」里能改（读同一份配置）
   ============================================================ */

/// 转账流程的入口：套一层导航栈，把 4 页串起来
struct TransferPagesFlow: View {
    let chatId: String
    var peerName: String
    var peerAccount: String
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            TransferHomeView(chatId: chatId, peerName: peerName, peerAccount: peerAccount, onClose: onClose)
        }
    }
}

// MARK: - 1. 转账首页
struct TransferHomeView: View {
    @Environment(\.dismiss) var dismiss

    let chatId: String
    var peerName: String
    var peerAccount: String
    var onClose: () -> Void

    @State private var receiverName = ""
    @State private var receiverAccount = ""
    @State private var amount = ""
    @State private var remark = ""
    @State private var resolveError: String?
    @State private var resolvedChatId = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer(minLength: 20)

                // 收款人
                VStack(spacing: 12) {
                    TextField("收款人姓名", text: $receiverName)
                        .font(.system(size: 16))
                        .padding(16)
                        .background(Color(.systemGray6))
                        .cornerRadius(12)

                    TextField("收款账号/手机号", text: $receiverAccount)
                        .font(.system(size: 16))
                        .padding(16)
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }

                // 转账金额
                VStack(alignment: .leading, spacing: 8) {
                    Text(Tr("转账金额"))
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)

                    HStack {
                        Text("¥")
                            .font(pfMoney(24))
                        TextField("0.00", text: $amount)
                            .font(.system(size: 24, weight: .semibold))
                            .keyboardType(.decimalPad)
                    }
                    .padding(16)
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                }

                // 备注
                TextField("备注（选填）", text: $remark)
                    .font(.system(size: 16))
                    .padding(16)
                    .background(Color(.systemGray6))
                    .cornerRadius(12)

                if let e = resolveError {
                    Text(e).font(.system(size: 13)).foregroundColor(C.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer()

                // 下一步
                NavigationLink {
                    TransferConfirmView(
                        chatId: resolvedChatId.isEmpty ? chatId : resolvedChatId,
                        receiverName: receiverName,
                        receiverAccount: receiverAccount,
                        amount: amount,
                        remark: remark,
                        onClose: onClose
                    )
                } label: {
                    Text(Tr("下一步"))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(canNext ? TransferTheme.accent : Color(.systemGray3))
                        .cornerRadius(16)
                }
                .disabled(!canNext)
                .simultaneousGesture(TapGesture().onEnded { resolveReceiver() })
            }
            .padding(.horizontal, 20)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .navigationTitle(Tr("转账"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { dismiss(); onClose() } label: { Image(systemName: "chevron.left") }
            }
        }
        .onAppear {
            if receiverName.isEmpty { receiverName = peerName }
            if receiverAccount.isEmpty { receiverAccount = peerAccount }
            resolvedChatId = chatId
        }
    }

    var canNext: Bool {
        !receiverName.isEmpty && !receiverAccount.isEmpty && !amount.isEmpty && (Double(amount) ?? 0) > 0
    }

    /// 如果收款账号被改成了别人，就重新找一个会话（必须是好友，和 App 规则一致）
    private func resolveReceiver() {
        resolveError = nil
        let acc = receiverAccount.trimmingCharacters(in: .whitespaces)
        if acc.isEmpty || acc == peerAccount { resolvedChatId = chatId; return }
        Task {
            do {
                guard let u = try await API.shared.findUserByAccount(acc) else {
                    resolveError = "没找到这个账号：\(acc)"
                    return
                }
                let c = try await API.shared.directChat(userId: u.id)
                resolvedChatId = c.id
                receiverName = u.nickname ?? receiverName
            } catch {
                resolveError = (error as? APIError)?.errorDescription ?? "找不到这个收款人"
            }
        }
    }
}

// MARK: - 2. 转账确认页
struct TransferConfirmView: View {
    @Environment(\.dismiss) var dismiss

    let chatId: String
    let receiverName: String
    let receiverAccount: String
    let amount: String
    let remark: String
    var onClose: () -> Void
    let fee = "0.00"

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 20)

                // 收款信息卡片
                VStack(spacing: 16) {
                    Text(Tr("确认转账信息"))
                        .font(.system(size: 18, weight: .semibold))

                    HStack {
                        Text(Tr("收款人")).foregroundColor(.secondary)
                        Spacer()
                        Text(receiverName)
                    }
                    HStack {
                        Text(Tr("收款账号")).foregroundColor(.secondary)
                        Spacer()
                        Text(receiverAccount)
                    }
                    HStack {
                        Text(Tr("转账金额")).foregroundColor(.secondary)
                        Spacer()
                        Text("¥\(amount)").font(pfMoney(16))
                    }
                    HStack {
                        Text(Tr("手续费")).foregroundColor(.secondary)
                        Spacer()
                        Text("¥\(fee)")
                    }
                    if !remark.isEmpty {
                        HStack {
                            Text(Tr("备注")).foregroundColor(.secondary)
                            Spacer()
                            Text(remark)
                        }
                    }

                    Divider()

                    HStack {
                        Text(Tr("合计")).font(.system(size: 16, weight: .semibold))
                        Spacer()
                        Text("¥\(amount)")
                            .font(pfMoney(18))
                            .foregroundColor(TransferTheme.accent)
                    }
                }
                .padding(20)
                .background(Color(.systemGray6))
                .cornerRadius(16)

                Spacer()

                NavigationLink {
                    TransferPasswordView(chatId: chatId, amount: amount, remark: remark, onClose: onClose)
                } label: {
                    Text(Tr("确认转账"))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(TransferTheme.accent)
                        .cornerRadius(16)
                }
            }
            .padding(.horizontal, 20)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .navigationTitle(Tr("确认转账"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { dismiss() } label: { Image(systemName: "chevron.left") }
            }
        }
    }
}

// MARK: - 3. 支付密码页（6 位，能真的输入）
struct TransferPasswordView: View {
    @Environment(\.dismiss) var dismiss

    let chatId: String
    let amount: String
    let remark: String
    var onClose: () -> Void

    @State private var pwd = ""
    @State private var busy = false
    @State private var error: String?
    @State private var done = false
    @State private var showForgot = false
    @FocusState private var focused: Bool
    let pwdLength = 6

    var body: some View {
        VStack(spacing: 30) {
            Spacer(minLength: 30)
            Text(Tr("请输入支付密码"))
                .font(.system(size: 18, weight: .semibold))
            Text("转账金额 ¥\(amount)")
                .font(pfMoney(14))
                .foregroundColor(.secondary)

            // 密码格子
            HStack(spacing: 12) {
                ForEach(0..<pwdLength, id: \.self) { index in
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(index == pwd.count && focused ? TransferTheme.accent : Color(.systemGray4), lineWidth: 1)
                            .frame(width: 44, height: 48)
                        if index < pwd.count {
                            Circle().frame(width: 10, height: 10)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { focused = true }

            // 真正接收输入的框（藏起来但会弹出数字键盘）
            TextField("", text: $pwd)
                .keyboardType(.numberPad)
                .focused($focused)
                .opacity(0)
                .frame(width: 1, height: 1)
                .onChange(of: pwd) { newValue in
                    if newValue.count > pwdLength { pwd = String(newValue.prefix(pwdLength)) }
                    if pwd.count == pwdLength { submit() }
                }

            if busy { ProgressView().padding(.top, 4) }
            if let e = error {
                Text(e).font(.system(size: 13)).foregroundColor(C.red)
            }

            Spacer()

            Button {
                showForgot = true
            } label: {
                Text(Tr("忘记密码？"))
                    .font(.system(size: 14))
                    .foregroundColor(TransferTheme.accent)
            }
        }
        .padding(.horizontal, 20)
        .background(Color(.systemBackground).ignoresSafeArea())
        .navigationTitle(Tr("验证支付密码"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { dismiss() } label: { Image(systemName: "chevron.left") }
            }
        }
        .onAppear { focused = true }
        .alert("忘记支付密码", isPresented: $showForgot) {
            Button(Tr("知道了"), role: .cancel) { }
        } message: {
            Text(Tr("支付密码在「我 → 设置 → 安全中心 → 支付密码」里可以重设；重设后回来继续转账。"))
        }
        .navigationDestination(isPresented: $done) {
            TransferSuccessView(amount: amount, onClose: onClose)
        }
    }

    private func submit() {
        guard !busy else { return }
        busy = true
        error = nil
        focused = false
        Task {
            do {
                try await API.shared.transfer(chatId: chatId,
                                              amount: Double(amount) ?? 0,
                                              note: remark,
                                              method: "balance",
                                              password: pwd)
                done = true
            } catch {
                self.error = (error as? APIError)?.errorDescription ?? "转账失败"
                pwd = ""
                focused = true
            }
            busy = false
        }
    }
}

// MARK: - 4. 转账成功页
struct TransferSuccessView: View {
    let amount: String
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .resizable()
                .frame(width: 72, height: 72)
                .foregroundColor(Color(hexString: "#34C759"))

            Text(Tr("转账成功"))
                .font(.system(size: 22, weight: .semibold))
            Text("¥\(amount)")
                .font(pfMoney(28))
            Text(Tr("预计实时到账"))
                .font(.system(size: 14))
                .foregroundColor(.secondary)

            Spacer()

            VStack(spacing: 16) {
                Button {
                    onClose()          // 关掉转账流程，去看账单
                } label: {
                    Text(Tr("查看账单"))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(TransferTheme.accent)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color(.systemGray6))
                        .cornerRadius(16)
                }

                Button {
                    onClose()          // 返回首页
                } label: {
                    Text(Tr("返回首页"))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(TransferTheme.accent)
                        .cornerRadius(16)
                }
            }
        }
        .padding(.horizontal, 20)
        .background(Color(.systemBackground).ignoresSafeArea())
        .navigationTitle(Tr("转账结果"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden)
    }
}
