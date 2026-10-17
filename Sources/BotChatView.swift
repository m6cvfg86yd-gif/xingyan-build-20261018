import SwiftUI
import AVFoundation

/* ============================================================
   小星（机器人）自己的对话页 —— 点会话页左上角那两只眼睛进来。
   和普通聊天页是两套：AI 回复不用气泡、旁边就是那两只眼睛；用户消息才是绿色气泡。
   回复逻辑完全沿用现有的（同一套接口、同一套消息），这里只换呈现方式。
   ============================================================ */

struct BotChatView: View {
    let chat: Chat

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    /* 服务器一推消息就立刻拉一次（不然机器人回复要等你下一次动作才显示，看着就是「回复慢」） */
    @ObservedObject private var realtime = Realtime.shared
    @AppStorage("bot.autoRead") private var autoRead = false
    @AppStorage("bot.voice") private var voiceID = ""
    @AppStorage("bot.rate") private var rate = 0.5

    @State private var messages: [Message] = []
    @State private var input = ""
    @State private var sending = false
    @State private var showVoice = false
    /// App 内打开的网页（消息里的链接）
    @State private var web: WebURL?
    @State private var spoken = Set<String>()
    /// 已经发出、还在等机器人回复（这期间显示「正在输入…」）
    @State private var waitingReply = false
    @FocusState private var focused: Bool

    /* 小星的档位（我 → 设置 → 更多 → 显示小星）：
       开启=会动 · 静态=画但不动 · 关闭=不画。会话页顶栏那颗按用户要求删掉了，
       所以这三档现在就作用在**这一页**的那颗眼睛上。
       ⚠ 只换参数值（size / tint / staticOnly），不加修饰器、不加分支 ——
       这台测试机对"视图结构变化"极其敏感（顶栏那颗就是这么被系统杀掉的）。 */
    @ObservedObject private var eyes = EyesStore.shared
    private func eyesSize(_ base: CGFloat) -> CGFloat { eyes.eyesOn ? base : 0.5 }
    private var eyesTintOrClear: Color? { eyes.eyesOn ? nil : Color.clear }
    private var eyesStill: Bool { !eyes.animated }

    private var myId: String { app.me?.id ?? "" }
    private var name: String { (chat.title?.isEmpty == false) ? (chat.title ?? "小星") : "小星" }

    var body: some View {
        VStack(spacing: 0) {
            navBar
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(messages) { m in
                            bubble(m).id(m.id)
                        }
                        if waitingReply { typingRow.id("botTyping") }
                        Color.clear.frame(height: 1).id("botBottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.count) { _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("botBottom", anchor: .bottom) }
                }
                .onChange(of: waitingReply) { _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("botBottom", anchor: .bottom) }
                }
            }
            composer
        }
        .background(C.pageBg.ignoresSafeArea())
        /* 进页面先拉一次；之后靠**实时事件**（服务器一推就拉），只在 8 秒没有任何事件时
           兜底轮询一次 —— 之前是 2.5 秒无条件轮询，翻聊天时会一直重绘、发烫又费电。 */
        .task {
            await load()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if Task.isCancelled { return }
                await load()
            }
        }
        .onChange(of: realtime.event) { _ in
            Task { await load() }
        }
        .sheet(isPresented: $showVoice) { BotVoiceSettingsView() }
        /* 链接用 App 内置浏览器打开（和聊天页一个规矩，不跳出 App） */
        .sheet(item: $web) { SafariSheet(url: $0.url) }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "http" || url.scheme == "https" {
                web = WebURL(url: url)
                return .handled
            }
            return .systemAction
        })
    }

    /// 「正在输入…」：机器人还没回的时候给个动静，别让页面看着像卡住
    private var typingRow: some View {
        HStack(alignment: .top, spacing: 10) {
            JarvisEyesAvatar(size: eyesSize(26), tint: eyesTintOrClear, staticOnly: eyesStill).padding(.top, 2)
            Text(Tr("正在输入…"))
                .font(.system(size: 15))
                .foregroundColor(C.subLabel)
            Spacer(minLength: 16)
        }
        .padding(.bottom, 16)
    }

    /* ---------------------------------------------------------- 顶栏 */

    private var navBar: some View {
        ZStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(C.label)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                Spacer()
                Button { showVoice = true } label: {
                    WeChatDots().frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                JarvisEyesAvatar(size: eyesSize(22), tint: eyesTintOrClear, staticOnly: eyesStill)
                Text(name).font(.system(size: 17, weight: .semibold)).foregroundColor(C.label)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 52)
        .background(Color.dyn(0xFFFFFF, 0x1C1C1E).opacity(0.96))
    }

    /* ---------------------------------------------------------- 消息 */

    @ViewBuilder
    private func bubble(_ m: Message) -> some View {
        let mine = (m.senderId == myId)
        if mine {
            HStack {
                Spacer(minLength: 44)
                Text(RichText.lines(shownText(m), size: 15.5))
                    .font(pf(15.5))
                    .lineSpacing(3)
                    .foregroundColor(Color(hex: 0x1A1A1A))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color(hex: 0xD7F3C6))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding(.bottom, 14)
        } else {
            HStack(alignment: .top, spacing: 10) {
                JarvisEyesAvatar(size: eyesSize(26), tint: eyesTintOrClear, staticOnly: eyesStill).padding(.top, 2)
                Text(RichText.lines(shownText(m), size: 15.5))
                    .font(pf(15.5))
                    .lineSpacing(3)
                    .foregroundColor(C.label)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 16)
            }
            .padding(.bottom, 16)
        }
    }

    /// 机器人回复里那些卡片（JSON）也先按文本显示出来 —— 呈现方式换了，内容还是原来那份
    private func shownText(_ m: Message) -> String {
        let b = m.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if b.isEmpty { return "[" + m.kindName + "]" }
        return b
    }

    /* ---------------------------------------------------------- 输入区 */

    private var composer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("发消息给" + name + "…", text: $input, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($focused)
                    .font(.system(size: 15.5))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.dyn(0xFFFFFF, 0x2C2C2E)))
                Button { sendText() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(canSend ? C.green : C.subLabel))
                }
                .buttonStyle(.plain)
                .disabled(!canSend || sending)
            }
            HStack(spacing: 8) {
                quickChip("帮我…") { input = "帮我" }
                quickChip("今天的天气") { send("今天天气怎么样？") }
                quickChip("记一笔账") { send("帮我记一笔：") }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color.dyn(0xF7F7F7, 0x141416).opacity(0.97))
    }

    private var canSend: Bool { !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func quickChip(_ t: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(t)
                .font(.system(size: 12.5))
                .foregroundColor(C.subLabel)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.dyn(0xF2F2F4, 0x2C2C2E)))
        }
        .buttonStyle(.plain)
    }

    /* ---------------------------------------------------------- 收发 */

    private func load() async {
        if let r = try? await API.shared.messages(chatId: chat.id, limit: 60) {
            messages = r.messages
            /* 机器人已经回了（最后一条不是我发的）→ 收起「正在输入…」 */
            if let last = messages.last, last.senderId != myId { waitingReply = false }
            autoReadLatestIfNeeded()
        }
    }

    private func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        input = ""
        sending = true
        waitingReply = true
        Task {
            _ = try? await API.shared.send(chatId: chat.id, kind: "text", content: t)
            await load()
            sending = false
        }
    }

    private func sendText() { send(input) }

    /// 自动朗读：新来的那条机器人回复念一遍（每条只念一次）
    private func autoReadLatestIfNeeded() {
        Speaker.chosenVoice = voiceID
        Speaker.chosenRate = Float(rate)
        guard autoRead, let last = messages.last, last.senderId != myId else { return }
        guard !spoken.contains(last.id) else { return }
        spoken.insert(last.id)
        let t = shownText(last)
        if !t.isEmpty { Speaker.shared.speak(t) }
    }
}
