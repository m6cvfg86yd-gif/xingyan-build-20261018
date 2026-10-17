import SwiftUI

/* AI 助手的小头像：仿微信「小微」那种 —— 一颗白白圆润的小脸 + 两只大眼睛。
   会眨眼（偶尔连眨两下）、会左右瞟、会微微抬头低头、还会呼吸，
   放在会话页顶栏最左边，点一下进 AI 助手的对话。 */
struct JarvisEyesAvatar: View {
    var size: CGFloat = 28
    /// 眼睛颜色。不传按原来的（浅色深眼珠 / 深色白眼珠）；
    /// 传了就固定用这个色（顶栏那颗传的是「后台 eyesColor，没配就跟 ＋ 同色」）。
    /// 另外后台 ui.json 里也能全局配：eyesColor = "#RRGGBB|#RRGGBB"，改完重开 App 生效。
    var tint: Color? = nil
    /// 「静态小星」那一档用：眼睛照样画出来，但**两段无限循环动画不跑**
    /// （眨眼 / 瞟 / 呼吸 / 点头全停）—— 省电，看着也安静。
    /// 档位在「我 → 设置 → 通用 → 更多 → 显示小星」里选，见 EyesStore。
    var staticOnly: Bool = false
    /* 深色模式下眼睛要用白色，不然黑底上看不见 */
    @Environment(\.colorScheme) private var scheme

    /// 眼睛实际用的颜色：传进来的 → 后台 eyesColor → 原来的自动色
    private var eyeTint: Color {
        if let t = tint { return t }
        if let c = UIConfig.colorIfSet("eyesColor") { return c }
        return scheme == .dark ? Color.white : Color(hexString: "#1B1D22")
    }
    /// 用了自定义色（后台配的或外面传的）→ 高光一律用白点，不管深浅色模式
    private var customTint: Bool { tint != nil || UIConfig.colorIfSet("eyesColor") != nil }

    /// 0 = 睁着，1 = 闭上
    @State private var blink: CGFloat = 0
    /// -1 看左 · 1 看右
    @State private var lookX: CGFloat = 0
    /// -1 看下 · 1 看上
    @State private var lookY: CGFloat = 0.15
    /// 0~1 呼吸
    @State private var breathe: CGFloat = 0
    /// 轻轻点头
    @State private var nod: CGFloat = 0

    @State private var alive = false

    private var eyeW: CGFloat { size * 0.20 }
    private var eyeH: CGFloat { size * 0.30 }

    var body: some View {
        ZStack {
            /* 外面的「小脸」圆去掉了（用户要求）：现在只有两只眼睛，背景透明 */
            HStack(spacing: size * 0.185) {
                eye
                eye
            }
            .offset(y: size * 0.015)
        }
        .frame(width: size, height: size)
        .scaleEffect(1 + breathe * 0.05)
        .offset(y: nod * size * 0.03)
        .task {
            if staticOnly { return }      // 静态档：不启动任何循环动画
            await runLoops()
        }
    }

    private var eye: some View {
        Capsule()
            /* 浅色模式：深色眼珠；深色模式：白色眼睛。指定了颜色就一律用它 */
            .fill(eyeTint)
            .frame(width: eyeW, height: max(size * 0.035, eyeH * (1 - blink * 0.94)))
            /* 眼珠跟着左右瞟、偶尔抬一下眼皮 */
            .offset(x: lookX * size * 0.055, y: -lookY * size * 0.028)
            /* 眼睛里那点高光，看着更像活的 */
            .overlay(alignment: .top) {
                Circle()
                    /* 高光：眼珠是深色时用白点，眼珠是白色时用暗点（颠倒一下才看得见） */
                    .fill(customTint
                          ? Color.white.opacity(0.6)
                          : (scheme == .dark ? Color.black.opacity(0.35) : Color.white.opacity(0.55)))
                    .frame(width: eyeW * 0.36, height: eyeW * 0.36)
                    .offset(x: -eyeW * 0.14, y: eyeH * 0.10)
                    .opacity(blink > 0.6 ? 0 : 1)
            }
            .animation(.easeInOut(duration: 0.42), value: lookX)
            .animation(.easeInOut(duration: 0.42), value: lookY)
    }

    /* 一只「活」的动画循环：眨眼、瞟一瞟、呼吸、轻轻点头各自按自己的节奏来 */
    private func runLoops() async {
        if staticOnly { return }
        guard !alive else { return }
        alive = true

        /* 呼吸 + 点头：慢慢来回 */
        withAnimation(.easeInOut(duration: 2.1).repeatForever(autoreverses: true)) { breathe = 1 }
        withAnimation(.easeInOut(duration: 2.9).repeatForever(autoreverses: true)) { nod = 1 }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await blinkLoop() }
            group.addTask { await glanceLoop() }
        }
    }

    /* 眨眼：2.2~4.6 秒一次，三成概率连眨两下 */
    private func blinkLoop() async {
        while !Task.isCancelled {
            let gap = Double.random(in: 2.2...4.6)
            try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
            if Task.isCancelled { return }
            await blinkOnce()
            if Bool.random() && Double.random(in: 0...1) < 0.3 {
                try? await Task.sleep(nanoseconds: 160_000_000)
                if Task.isCancelled { return }
                await blinkOnce()
            }
        }
    }

    private func blinkOnce() async {
        withAnimation(.easeInOut(duration: 0.085)) { blink = 1 }
        try? await Task.sleep(nanoseconds: 105_000_000)
        withAnimation(.easeInOut(duration: 0.13)) { blink = 0 }
    }

    /* 左右瞟：自己走自己的节奏，和眨眼错开 */
    private func glanceLoop() async {
        while !Task.isCancelled {
            let x: CGFloat = [CGFloat(-1), 1].randomElement() ?? 1
            withAnimation(.easeInOut(duration: 0.7)) {
                lookX = x * CGFloat.random(in: 0.45...1)
                lookY = CGFloat.random(in: -0.35...0.35)
            }
            try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 1.3...2.6) * 1_000_000_000))
        }
    }
}

/* ====================================================================
   AI 助手 / 腾讯新闻 的名片
   在聊天里点它的头像出来的就是这一页：会动的眼睛 + 简介 + 发消息 / 语音通话。
   ==================================================================== */
struct BotCardView: View {
    let chat: Chat

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var calling = false

    /// 会话列表里排第一的（botRank 0）= 会动眼睛那个 AI 助手
    private var isEyesBot: Bool { (chat.botRank ?? 9) == 0 }

    private var sheetBg: Color { scheme == .dark ? Color(hex: 0x1C1C1E) : .white }
    /* 页面底色统一走后台的 pageBg（暗色下就是会话页每行那个 #141419） */
    private var pageBg: Color { C.pageBg }
    private var ink: Color { scheme == .dark ? Color(hex: 0xEDEDED) : Color(hex: 0x1A1A1A) }
    private var gray: Color { scheme == .dark ? Color(hex: 0x8E8E93) : Color(hex: 0x737373) }
    private var link: Color { scheme == .dark ? Color(hex: 0x7D90B8) : Color(hex: 0x576B95) }
    private var lineColor: Color { scheme == .dark ? Color(white: 1, opacity: 0.09) : Color(hex: 0xE5E5E5) }

    private var bio: String {
        if isEyesBot { return "您的私人助理：聊天、提醒、天气、记账、代发消息，随时为您效劳" }
        if chat.name.contains("新闻") { return "热点新闻、时事资讯，想听哪条跟我说" }
        return "有问题随时问我，还能帮你查最新资讯～"
    }

    /// 新版官方号名片（畅聊/HarmonyOS 语言）开关：后台 data/ui.json 里
    /// agentCardStyle = "new" 才走新版；默认 "old" 就是原来这版。
    var body: some View {
        if UIConfig.text("agentCardStyle", "old") == "new" {
            BotCardNew(name: chat.name,
                       bio: bio,
                       avatarPath: chat.avatar ?? "",
                       isEyes: isEyesBot,
                       onClose: { dismiss() },
                       onMessage: { dismiss() },
                       onCall: { calling = true })
        } else {
            cardBody
        }
    }

    private var cardBody: some View {
        VStack(spacing: 0) {
            NavBar(title: "", back: { dismiss() }) { EmptyView() }
                .background(sheetBg)

            ScrollView {
                VStack(spacing: 0) {
                    hero
                    Rectangle().fill(pageBg).frame(height: 10)
                    acts
                    Spacer(minLength: 0)
                }
            }
            .background(pageBg)
        }
        .background(pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .hidesTabBar()
        .fullScreenCover(isPresented: $calling) {
            AICallView(chat: chat).environmentObject(app)
        }
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 14) {
            if isEyesBot {
                JarvisEyesAvatar(size: 74)
                    .frame(width: 88, height: 88)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(sheetBg))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(lineColor, lineWidth: 0.6))
            } else {
                Avatar(path: chat.avatar ?? "", size: 88, radius: 8)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(chat.name)
                    .font(pf(20, .medium))
                    .foregroundColor(ink)
                    .lineLimit(1)
                Text(isEyesBot ? "官方 AI 助理" : "官方账号")
                    .font(pf(14))
                    .foregroundColor(gray)
                    .lineLimit(1)
                Text("简介：" + bio)
                    .font(pf(14))
                    .foregroundColor(gray)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 20)
        .background(sheetBg)
    }

    private var acts: some View {
        VStack(spacing: 0) {
            row("发消息", key: "msg")
            Rectangle().fill(lineColor).frame(height: 0.5).padding(.leading, 18)
            row("语音通话", key: "call")
        }
        .background(sheetBg)
        .overlay(alignment: .top) { Rectangle().fill(lineColor).frame(height: 0.5) }
        .overlay(alignment: .bottom) { Rectangle().fill(lineColor).frame(height: 0.5) }
    }

    private func row(_ title: String, key: String) -> some View {
        Button {
            if key == "msg" { dismiss() } else { calling = true }
        } label: {
            HStack(spacing: 14) {
                SVGIcon(markup: key == "msg" ? I.cardChat : I.cardVideo, size: 20, color: link)
                Text(Tr(title))
                    .font(pf(16))
                    .foregroundColor(link)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
