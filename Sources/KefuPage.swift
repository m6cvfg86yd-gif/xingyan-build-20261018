import SwiftUI

/* ============================================================
   在线客服（独立一页，像微信那种客服页，不是普通聊天）
   · 顶部：客服头像 + 名字 + 值班时间，右边「转人工」
   · 中间：对话（自己在右、客服在左）
   · 下面：快捷问题 + 输入框（发出去的消息和后台工单是同一套）
   ============================================================ */
struct KefuPage: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var chatId = ""
    @State private var messages: [Message] = []
    @State private var input = ""
    @State private var loading = true
    @State private var sending = false
    @State private var quick: [API.SupportItem] = []
    @State private var greet = ""
    @State private var workTime = ""
    @State private var agentName = "在线客服"
    @State private var agentAvatar = ""
    @State private var showFAQ = false
    @State private var humanAsked = false
    @State private var connectTip = ""

    private var myId: String { app.me?.id ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: agentName, back: { dismiss() }) {
                Button {
                    askHuman()
                } label: {
                    Text(Tr("转人工"))
                        .font(pf(15, .medium))
                        .foregroundColor(C.green)
                        .frame(height: L.navH)
                        .padding(.trailing, 16)
                }
                .buttonStyle(.plain)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        header
                        if !connectTip.isEmpty {
                            VStack(spacing: 10) {
                                Text(connectTip).font(pf(13.5)).foregroundColor(C.subLabel)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 30)
                                Button { 
                                    connectTip = ""
                                    Task { await start() }
                                } label: {
                                    Text(Tr("重试"))
                                        .font(pf(15, .medium)).foregroundColor(.white)
                                        .padding(.horizontal, 24).frame(height: 40)
                                        .background(Capsule().fill(C.green))
                                }
                                .buttonStyle(.plain)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                        }
                        ForEach(messages) { m in
                            kefuBubble(m)
                        }
                        Color.clear.frame(height: 12).id("bottom")
                    }
                }
                .background(C.pageBg)
                .onChange(of: messages.count) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }

            quickRow
            inputBar
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { await start() }
        .sheet(isPresented: $showFAQ) { FAQView().environmentObject(app) }
    }

    /* ---------------------------------------------------------- 头部 */
    private var header: some View {
        VStack(spacing: 8) {
            RPAvatar(path: agentAvatar, size: 52)
            Text(agentName).font(pf(15, .medium)).foregroundColor(C.label)
            Text(workTime.isEmpty ? Tr("人工在线时间 09:00 - 22:00") : workTime)
                .font(pf(12)).foregroundColor(C.subLabel)
            if !greet.isEmpty {
                Text(greet)
                    .font(pf(13.5))
                    .foregroundColor(C.label)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background { CardGlassBox(radius: 8) }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
            }
            HStack(spacing: 14) {
                Button { showFAQ = true } label: {
                    Text(Tr("看常见问题")).font(pf(13)).foregroundColor(C.green)
                }
                .buttonStyle(.plain)
                Button { askHuman() } label: {
                    Text(Tr("转人工客服")).font(pf(13)).foregroundColor(C.green)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(C.cardBg)
        .padding(.bottom, 10)
    }

    /* ---------------------------------------------------------- 气泡 */
    @ViewBuilder private func kefuBubble(_ m: Message) -> some View {
        let mine = (m.senderId == myId)
        HStack(alignment: .top, spacing: 8) {
            if mine { Spacer(minLength: 50) }
            if !mine { RPAvatar(path: agentAvatar, size: 34) }
            Text(m.body)
                .font(pf(15))
                /* 客服中心这个小聊天也用后台配的气泡色（以前这里写死成绿色） */
                .foregroundColor(mine ? C.bubbleText : C.label)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(mine ? C.bubbleMine : C.cardBg)
                )
                .fixedSize(horizontal: false, vertical: true)
            if mine { RPAvatar(path: app.me?.avatar ?? "", size: 34) }
            if !mine { Spacer(minLength: 50) }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    /* ---------------------------------------------------------- 快捷问题 */
    @ViewBuilder private var quickRow: some View {
        if !quick.isEmpty && messages.count <= 3 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(quick.enumerated()), id: \.offset) { _, it in
                        Button { sendMessage(it.q) } label: {
                            Text(it.q)
                                .font(pf(13))
                                .foregroundColor(C.green)
                                .padding(.horizontal, 12)
                                .frame(height: 32)
                                .background { CardGlassBox(radius: 999) }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(C.pageBg)
        }
    }

    /* ---------------------------------------------------------- 输入栏 */
    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(Tr("说说你遇到的问题…"), text: $input, axis: .vertical)
                .font(pf(15))
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background { CardGlassBox(radius: 8) }
            Button {
                sendMessage(input)
            } label: {
                Text(sending ? "…" : Tr("发送"))
                    .font(pf(15, .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(Capsule().fill(input.trimmingCharacters(in: .whitespaces).isEmpty ? C.subLabel : C.green))
            }
            .buttonStyle(.plain)
            .disabled(sending || input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(C.pageBg)
    }

    /* ---------------------------------------------------------- 逻辑 */
    private func start() async {
        /* 先拿客服配置（头像/名字/值班时间/快捷问题），拿不到也不影响后面开会话 */
        if let cfg = try? await API.shared.support() {
            greet = cfg.greet ?? ""
            workTime = cfg.workTime ?? ""
            agentName = cfg.agent?.nickname ?? "在线客服"
            agentAvatar = cfg.agent?.avatar ?? ""
            var seen = Set<String>()
            quick = (cfg.categories ?? []).compactMap { c in
                (c.items ?? []).first.flatMap { seen.insert($0.q).inserted ? $0 : nil }
            }
        }
        if let r = try? await API.shared.supportHuman() {
            chatId = r.chatId
        }
        await loadMessages()
        /* 万一服务器没建出会话（网络问题），给个能重试的提示，别只留一个空页面 */
        if chatId.isEmpty { connectTip = "客服暂时接不上，点下面重试一次" }
        loading = false
    }

    private func loadMessages() async {
        guard !chatId.isEmpty else { return }
        if let r = try? await API.shared.messages(chatId: chatId, limit: 50) {
            messages = r.messages.filter { $0.kindName != "system" }
        }
    }

    private func sendMessage(_ text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !chatId.isEmpty, !sending else { return }
        sending = true
        input = ""
        Task {
            if let m = try? await API.shared.send(chatId: chatId, kind: "text", content: body) {
                messages.append(m)
            }
            sending = false
            /* 客服（AI 或人工）回消息一般 1~3 秒，等几轮把回复拉回来 */
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await loadMessages()
                if let last = messages.last, last.senderId != myId { break }
            }
        }
    }

    /// 点「转人工」：给客服发一句「人工」，后台会生成工单，值班时间外会提示明天跟进
    private func askHuman() {
        if humanAsked {
            app.show(Tr("已经帮你转人工了，客服看到会在这里回复"))
            return
        }
        humanAsked = true
        sendMessage("人工")
    }
}
