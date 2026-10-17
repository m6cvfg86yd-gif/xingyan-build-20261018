import SwiftUI
import WebRTC

/* ============================================================
   通话界面 —— 照微信参考图做的（420×912pt 量的）：

     · 背景：聊天背景图「糊掉 + 压暗」（不是纯黑）。参考图实测是深橄榄色渐变，
       说明背后是一张被虚化的照片。没设背景图就退化成深灰。
     · 头像 96 居中，顶在 y≈251（安全区下面约 156）
     · 名字 22pt 白色（y≈367）、状态 15pt 白 70%（y≈404）
     · 提示（比如"暂时无法接通…"）15pt 白 55%（y≈559）
     · 底部三个 72pt 圆按钮 + 各自标签（y≈726 圆、y≈812 标签）：
         麦克风已开/已关      取消（红，视频/语音通话中）      扬声器已开/已关
       来电时换成：拒接（红） / 接听（绿）
   两个后台参数：callBackdropBlur（模糊，默认 40）、callGlassTint（压暗，默认 0.45）
   ============================================================ */

struct CallOverlay: View {
    @ObservedObject private var call = CallCenter.shared

    var body: some View {
        if call.phase != .idle {
            if call.minimized {
                /* 挂起（左上那个画中画按钮）：**回到上一页**，只在页面上飘一个小浮窗
                   —— 微信就是这样：聊天、看朋友圈都照用，通话本身一直在跑。
                   以前这里是「整屏还是通话页的模糊背景 + 里面有个小窗」，
                   等于没回到上一页，用户点它跟没点一样。 */
                CallMiniWindow()
                    .zIndex(999)
            } else {
                CallView()
                    .zIndex(999)
            }
        }
    }
}

/// 接通 / 挂断弹的对话框：居中的卡片 + 「确定」，颜色/圆角取后台那套
/// （和聊天页那行时间同一个配置：底色 chatTimeBg、文字色 chatTimeColor、圆角 chatTimeRadius），
/// 所以看着就是「聊天的框框」。通话页收起来以后它还在，所以挂断也一定看得到。
struct CallDialogOverlay: View {
    @ObservedObject private var call = CallCenter.shared

    var body: some View {
        ZStack {
            if let d = call.dialog {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { call.dismissDialog() }

                VStack(spacing: 0) {
                    VStack(spacing: 6) {
                        Text(d.title)
                            .font(pf(16, .medium))
                            .foregroundColor(C.chatTimeInk)
                            .multilineTextAlignment(.center)
                        if !d.detail.isEmpty {
                            Text(d.detail)
                                .font(pf(13))
                                .foregroundColor(C.chatTimeInk.opacity(0.75))
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 22)
                    .padding(.bottom, 18)

                    Rectangle()
                        .fill(C.chatTimeInk.opacity(0.18))
                        .frame(height: 0.5)

                    Button {
                        call.dismissDialog()
                    } label: {
                        Text(d.okText)
                            .font(pf(16, .medium))
                            .foregroundColor(C.chatTimeInk)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: 268)
                .background(
                    RoundedRectangle(cornerRadius: max(12, L.o("chatTimeRadius", 4) + 8), style: .continuous)
                        .fill(C.chatTimeBg)
                )
                .transition(.scale(scale: 0.94).combined(with: .opacity))
                .zIndex(1000)
            }
        }
        .zIndex(1000)
        .animation(.easeOut(duration: 0.16), value: call.dialog)
    }
}

struct CallView: View {
    @ObservedObject private var call = CallCenter.shared
    /// 腾讯云 TRTC 的画面从它自己的 view 里来
    @ObservedObject private var trtc = TRTCBridge.shared
    @EnvironmentObject var app: AppState
    /// 通话中收到的新消息（微信会在通话页顶上弹一行「XX：内容」，点一下进那个会话）
    private struct CallMsgBanner: Equatable {
        var chatId: String
        var name: String
        var text: String
    }
    @State private var msgBanner: CallMsgBanner? = nil
    @State private var bannerTask: Task<Void, Never>? = nil
    /// 每条会话上次看到的最后一条消息 id（第一次只记、不弹）
    @State private var lastMsgSeen: [String: String] = [:]
    @State private var showInvite = false
    /* 通话页里「自己那个小画面」（画中画）：默认贴右下角，可以拖着走，松手吸附到左右边 */
    @State private var pipX: CGFloat? = nil
    @State private var pipY: CGFloat? = nil
    @State private var pipDrag: CGSize = .zero
    /// 「拒绝并回复」那个菜单（2026-10-13 用户要求，对齐微信）
    @State private var showReplies = false
    /// 音频出口（微信那个「听筒 / 扬声器 / 蓝牙」菜单）：长按扬声器那颗弹出来
    @State private var audioDevices: [CallAudioRoute] = []
    @State private var showAudioDevices = false

    private var blurRadius: CGFloat { UIConfig.num("callBackdropBlur", 60) }
    private var tint: CGFloat { UIConfig.num("callGlassTint", 0.45) }

    /// 通话背景用的聊天背景图（自己设的 → 服务器默认 → 没有）
    private var bgPath: String {
        let v = app.me?.chatBackground ?? "auto"
        if v.isEmpty || v == "auto" {
            let def = app.defaultChatBackground
            return (def == "auto") ? "" : def
        }
        return v
    }

    var body: some View {
        ZStack {
            backdrop

            if call.isGroupCall {
                /* 群视频：每人一路画面（宫格）；群语音：头像墙 */
                if call.isVideo { groupVideoLayer } else { groupLayer }
            } else if call.isVideo && call.phase == .active {
                videoLayer
            } else {
                avatarLayer
            }

            VStack(spacing: 0) {
                topBar
                if let b = msgBanner { msgBannerView(b) }
                Spacer(minLength: 0)
                /* 麦克风没开 / 没起来：明说「对方听不到你」并给自助入口 ——
                   以前这种情况界面一切正常，用户根本不知道是哪儿的问题。 */
                if call.micBlocked { micBanner }
                bottomBar
            }
        }
        .sheet(isPresented: $showInvite) {
            inviteSheet
        }
        /* 拒绝并回复：微信那几句常用话（2026-10-13 用户要求） */
        .confirmationDialog(Tr("拒绝并回复"), isPresented: $showReplies, titleVisibility: .visible) {
            Button(Tr("在忙，稍后联系你")) { call.reject(withReply: "在忙，稍后联系你") }
            Button(Tr("不方便接听，稍后回你")) { call.reject(withReply: "不方便接听，稍后回你") }
            Button(Tr("在开车，晚点回你")) { call.reject(withReply: "在开车，晚点回你") }
            Button(Tr("取消"), role: .cancel) { }
        }
        /* 声音输出（微信「听筒 / 扬声器 / 蓝牙耳机」那个菜单）：长按扬声器那颗弹出来。
           现在是哪一个在上面打钩。 */
        .confirmationDialog(Tr("声音输出") + "（" + call.currentAudioDeviceName + "）",
                            isPresented: $showAudioDevices, titleVisibility: .visible) {
            ForEach(audioDevices) { d in
                Button((d.name == call.currentAudioDeviceName ? "✓ " : "") + d.name) {
                    call.selectAudioDevice(d)
                }
            }
            Button(Tr("取消"), role: .cancel) { }
        }
        /* 通话中收到的新消息：每 2 秒扫一遍会话列表（微信也这么做） */
        .task(id: call.callId) {
            /* 模糊背景扛不住的时候自己关掉了：把原因说给用户听（别一声不响） */
            VideoBlur.shared.onAutoOff = { msg in app.show(msg) }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { break }
                scanNewMessages()
            }
        }
    }

    /// 通话中收到的新消息 → 顶上弹一条（点了就缩成小窗、进那个会话，通话不中断）
    private func scanNewMessages() {
        switch call.phase {
        case .idle: return
        default: break
        }
        let mine = app.me?.id ?? ""
        for c in app.chats {
            guard let lm = c.lastMessage, let mid = lm.id, !mid.isEmpty else { continue }
            let sender = lm.senderId ?? ""
            if sender == mine || sender.isEmpty { lastMsgSeen[c.id] = mid; continue }
            let old = lastMsgSeen[c.id]
            lastMsgSeen[c.id] = mid
            guard let old = old, old != mid else { continue }        // 第一次进来只记，不弹旧的
            if c.muted == true { continue }                          // 免打扰的不弹
            let t = (lm.preview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            showBanner(chatId: c.id, name: c.title ?? Tr("新消息"),
                       text: t.isEmpty ? Tr("[新消息]") : t)
            return
        }
    }

    private func showBanner(chatId: String, name: String, text: String) {
        withAnimation(.easeOut(duration: 0.18)) {
            msgBanner = CallMsgBanner(chatId: chatId, name: name, text: String(text.prefix(30)))
        }
        bannerTask?.cancel()
        bannerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.18)) { msgBanner = nil } }
        }
    }

    private func msgBannerView(_ b: CallMsgBanner) -> some View {
        Button {
            msgBanner = nil
            call.minimize()                     // 通话缩成小窗，继续通
            if let c = app.chats.first(where: { $0.id == b.chatId }) { app.openChatViaList(c) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "message.fill").font(.system(size: 12, weight: .semibold))
                Text(b.name).font(pf(13, .medium)).lineLimit(1)
                Text(b.text).font(pf(13)).lineLimit(1).foregroundColor(.white.opacity(0.82))
                Spacer(minLength: 0)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Capsule().fill(Color.black.opacity(0.55)))
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /* ---------------------------------------------------------- 背景 */

    private var backdrop: some View {
        ZStack {
            Color(red: 0.10, green: 0.11, blue: 0.10)
            /* 和微信一样：糊的是「对方的头像」那张图（放大糊狠一点），
               所以背景会带出这个人头像的色调。对方没头像才退回聊天背景图。 */
            if !call.peerAvatar.isEmpty {
                RemoteImage(path: call.peerAvatar)
                    .blur(radius: blurRadius)
                    .scaleEffect(1.35)
            } else if !bgPath.isEmpty {
                RemoteImage(path: bgPath)
                    .blur(radius: blurRadius)
                    .scaleEffect(1.25)                  // 糊完边缘不留白
            }
            Color.black.opacity(tint)                   // 压暗，保证白字看得清
        }
        .ignoresSafeArea()
    }

    /* ---------------------------------------------------------- 语音/呼叫中：头像 + 名字 */

    private var avatarLayer: some View {
        VStack(spacing: 0) {
            /* 位置是照着 vx 里那张「未接通」参考图量的：
               头像 70pt、中心在 y≈167；名字 17pt 紧贴下面（y≈199） */
            Spacer().frame(height: max(30, 132 - L.safeTop))
            Avatar(path: call.peerAvatar, size: 70, radius: 10)
            Text(call.peerName)
                .font(pfExact(17, .medium))
                .foregroundColor(.white)
                .padding(.top, 12)
            Text(statusText)
                .font(pfExact(13.5))
                .foregroundColor(.white.opacity(0.7))
                .padding(.top, 5)
                .opacity(call.phase == .outgoing ? 0 : 1)
            if call.phase == .outgoing {
                /* 打不通就别再滚「正在等待…」了，直接把原因写在屏幕上
                   （服务器回了不在线/忙线以后，通话页会停 8 秒让用户看清） */
                if let err = call.errorText, !err.isEmpty {
                    Text(err)
                        .font(pfExact(15, .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .padding(.top, 6)
                } else {
                    // 等对方接的时候：状态文字像滚动屏一样滚（同时放回铃音）
                    MarqueeText(text: "正在等待对方接受邀请…")
                        .padding(.top, 6)
                }
            }
            if !hintText.isEmpty {
                Text(hintText)
                    .font(pfExact(15))
                    .foregroundColor(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.top, 142)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    /* ---------------------------------------------------------- 视频通话：远端铺满 + 本地小窗 */

    private var videoLayer: some View {
        ZStack {
            /* 走了腾讯云就用腾讯云的画面；没走（或还没进房）还是老样子 */
            if call.usingTRTC {
                TRTCVideoView(view: trtc.remoteView)
                    .ignoresSafeArea()
            } else {
                VideoSurface(track: call.remoteVideo)
                    .ignoresSafeArea()
            }
            if call.usingTRTC ? (trtc.remoteView == nil) : (call.remoteVideo == nil) {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text(Tr("正在连接画面…"))
                        .font(pfExact(14))
                        .foregroundColor(.white.opacity(0.75))
                }
            }
            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(call.peerName)
                            .font(pfExact(17, .medium))
                            .foregroundColor(.white)
                        Text(statusText)
                            .font(pfExact(13))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                Spacer()
                /* 自己那个小画面（画中画）：默认贴右下角，**可以拖着走**，松手吸附到左右边。
                   点一下还是切前后摄像头（拖动要移动超过 5pt 才算拖，不会误触）。 */
                GeometryReader { geo in
                    let w: CGFloat = 104
                    let h: CGFloat = 148
                    let maxX = max(8, geo.size.width - w - 12)
                    let minY: CGFloat = 74                       // 别压住顶上的名字和按钮
                    let maxY = max(minY, geo.size.height - h - 150)
                    let homeX = geo.size.width - w - 16
                    let homeY = geo.size.height - h - 150
                    let x = min(max((pipX ?? homeX) + pipDrag.width, 8), maxX)
                    let y = min(max((pipY ?? homeY) + pipDrag.height, minY), maxY)
                    pipBody(w: w, h: h)
                        .position(x: x + w / 2, y: y + h / 2)
                        .gesture(
                            DragGesture(minimumDistance: 5)
                                .onChanged { v in pipDrag = v.translation }
                                .onEnded { v in
                                    let nx = (pipX ?? homeX) + v.translation.width
                                    let ny = (pipY ?? homeY) + v.translation.height
                                    /* 松手吸附：靠近哪边就贴哪边（和微信一样的手感） */
                                    pipX = nx + w / 2 < geo.size.width / 2 ? 8 : maxX
                                    pipY = min(max(ny, minY), maxY)
                                    pipDrag = .zero
                                }
                        )
                }
            }

            /* 微信视频通话右上角那组：两个**竖向小圆角钮**并排（左：翻转，右：摄像头开/关）。
               位置是照着参考图量的：贴在名字下面一点、靠右，右边距和底部小窗对齐。 */
            VStack {
                HStack {
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        topPill(symbol: "arrow.triangle.2.circlepath.camera",
                                on: false,
                                hint: "翻转") { call.flipCamera() }
                        topPill(symbol: call.cameraOff ? "video.slash.fill" : "video.fill",
                                on: call.cameraOff,
                                hint: call.cameraOff ? "摄像头已关" : "摄像头已开") { call.toggleCamera() }
                    }
                    .padding(.trailing, 14)
                }
                .padding(.top, L.navH + 52)
                Spacer(minLength: 0)
            }
        }
    }

    /// 画中画里的内容（自己的画面）：TRTC 或 Webrtc 两种来源；点一下切前后摄像头
    private func pipBody(w: CGFloat, h: CGFloat) -> some View {
        Group {
            if call.usingTRTC {
                TRTCVideoView(view: trtc.localView)
            } else {
                VideoSurface(track: call.localVideo)
            }
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color.white.opacity(0.22), lineWidth: 1))
        /* 摄像头关了：本地小窗盖一层深色 + 一个斜杠图标（微信的「遮挡摄像头」） */
        .overlay {
            if call.cameraOff {
                ZStack {
                    Color.black.opacity(0.72)
                    Image(systemName: "video.slash.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.9))
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { call.flipCamera() }
    }

    /// 右上角那种竖向小钮：宽 30、高 52、圆角 12，半透明白（开着是白底深图标）
    private func topPill(symbol: String, on: Bool, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(on ? .black : .white)
                .frame(width: 30, height: 52)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(on ? Color.white : Color.black.opacity(0.28)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(hint))
    }

    /* ---------------------------------------------------------- 文字 */

    /// 群视频：**每人一路画面**排成两列宫格（自己的画面缩在右下角小窗里）。
    /// 画面是 TRTC 直接画进 UIView 的（meetingView(for:) 按 userId 分派，见 TRTCBridge）。
    private var groupVideoLayer: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                    GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(call.roster.filter { $0.userId != app.me?.id }) { m in
                        VStack(spacing: 4) {
                            TRTCVideoView(view: TRTCBridge.shared.meetingView(for: m.userId))
                                .frame(height: 152)
                                .background(Color.black)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            HStack(spacing: 4) {
                                if m.muted {
                                    Image(systemName: "mic.slash.fill")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.8))
                                }
                                Text(m.name.isEmpty ? Tr("成员") : m.name)
                                    .font(pf(12.5))
                                    .foregroundColor(.white.opacity(0.88))
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 140)
            }
            /* 自己的画面（小窗） */
            TRTCVideoView(view: TRTCBridge.shared.localView)
                .frame(width: 96, height: 130)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.22), lineWidth: 1))
                .padding(.trailing, 14)
                .padding(.bottom, 96)
        }
    }

    /// 群语音：中间一面「头像墙」（微信的群语音就是一堆头像排着 + 谁在静音）
    private var groupLayer: some View {
        VStack(spacing: 14) {
            Text(call.groupTitle.isEmpty ? Tr("群语音通话") : call.groupTitle)
                .font(pf(17, .semibold))
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(1)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3),
                      spacing: 16) {
                ForEach(call.roster) { m in
                    VStack(spacing: 6) {
                        ZStack {
                            Avatar(path: m.avatar, size: 62, radius: 12)
                            /* ③ 「谁在说话」（2026-10-13 对标微信）：音量最大的那个人套一圈绿光边 */
                            if speakOn(m) {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(C.green, lineWidth: 2.5)
                                    .frame(width: 68, height: 68)
                                    .shadow(color: C.green.opacity(0.65), radius: 8)
                            }
                            if m.muted {
                                Image(systemName: "mic.slash.fill")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(4)
                                    .background(Circle().fill(Color.black.opacity(0.55)))
                                    .offset(x: 23, y: 23)
                            }
                        }
                        Text(m.name.isEmpty ? Tr("成员") : m.name)
                            .font(pf(12.5))
                            .foregroundColor(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 34)
            Text("\(call.roster.count) " + Tr("人在通话中"))
                .font(pf(12.5))
                .foregroundColor(.white.opacity(0.6))
        }
    }

    /// ③ 这个人现在是不是「在说话」：他报上来的音量是全场最大的、而且过了小门槛
    /// （服务端每 250ms 汇总一次整屋音量，见 CallCenter.speakerLevels）
    private func speakOn(_ m: GroupCallMember) -> Bool {
        let lv = call.speakerLevels[m.userId] ?? 0
        guard lv > 0.10 else { return false }
        let top = call.speakerLevels.values.max() ?? 0
        return lv >= top
    }

    private var statusText: String {
        if call.isGroupCall {
            switch call.phase {
            case .incoming:   return "邀请你加入群语音通话…"
            case .outgoing:   return "正在邀请群成员…"
            case .connecting: return "正在接通…"
            case .active:     return timeText
            case .idle:       return ""
            }
        }
        switch call.phase {
        case .incoming:   return call.isVideo ? "邀请你视频通话…" : "邀请你语音通话…"
        case .outgoing:   return "正在等待对方接受邀请…"
        case .connecting: return "正在接通…"
        case .active:     return timeText
        case .idle:       return ""
        }
    }

    /// 参考图里"暂时无法接通，建议稍后尝试…"那一行：只在有话说的时候显示
    private var hintText: String {
        let t = call.tip
        if call.phase == .idle { return "" }
        if t == "未接听" || t == "对方已拒绝" || t == "对方不在线" { return t + "，建议稍后尝试" }
        if t.contains("失败") || t.contains("断开") { return t }
        /* 弱网（微信也会写一行）：先于"对方状态"显示，因为这时候最要紧 */
        if call.weakNet { return "网络不太稳定，正在重连…" }
        /* 对方那边的状态（微信视频通话里对方关了摄像头会写这么一行小字）——
           以前对面关摄像头，我们这边只有一片黑，看不出是关了还是断了。 */
        if call.peerCameraOff { return "对方已关闭摄像头" }
        if call.peerMuted { return "对方已静音" }
        return ""
    }

    private var timeText: String {
        String(format: "%02d:%02d", call.seconds / 60, call.seconds % 60)
    }

    /* ---------------------------------------------------------- 底部三个圆按钮 */

    private var bottomBar: some View {
        Group {
            if call.phase == .incoming {
                VStack(spacing: 16) {
                    HStack(spacing: 51) {
                        roundKey(label: "拒绝", bg: Color(hex: 0xFA5151)) { call.reject() }
                        roundKey(label: "接听", bg: Color(hex: 0x19A47A), ink: .white,
                                 action: {
                                     if call.isGroupCall { call.acceptGroupCall() } else { call.accept() }
                                 }) {
                            Image(systemName: "phone.fill")
                                .font(.system(size: 27, weight: .medium))
                        }
                    }
                    /* 拒绝并回复（2026-10-13 用户要求，对齐微信）：不去接，但先回一句 */
                    Button { showReplies = true } label: {
                        Text(Tr("拒绝并回复"))
                            .font(pf(14))
                            .foregroundColor(.white.opacity(0.9))
                            .padding(.horizontal, 16).frame(height: 34)
                            .background(Capsule().fill(Color.white.opacity(0.16)))
                    }
                    .buttonStyle(.plain)
                    /* 视频来电：微信还能「语音接听」（先不接画面、只接声音） */
                    if call.isVideo && !call.isGroupCall {
                        Button { call.accept(asAudio: true) } label: {
                            Text(Tr("语音接听"))
                                .font(pf(15, .medium))
                                .foregroundColor(.white.opacity(0.92))
                                .padding(.horizontal, 18)
                                .frame(height: 34)
                                .background(Capsule().fill(Color.white.opacity(0.16)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 54)
            } else if call.isVideo {
                /* 视频通话：**接通前后两种布局**（都是照 vx 里那两张参考图量的）
                   接通前 y≈717 是「麦克风 / 翻转 / 摄像头」三颗，
                   接通后 y≈717 是「麦克风 / 扬声器」两颗（翻转、摄像头挪到右上角小钮），
                   两种情况的红色按钮都在 y≈830、居中、更靠下。 */
                VStack(spacing: 16) {
                    HStack(spacing: 0) {
                        if call.phase == .active {
                            micKey
                            Spacer(minLength: 0)
                            speakerKey
                        } else {
                            HStack(spacing: 0) {
                                micKey
                                Spacer(minLength: 0)
                                flipKey
                                Spacer(minLength: 0)
                                cameraKey
                            }
                        }
                    }
                    .padding(.horizontal, call.phase == .active ? 48 : 16)
                    hangupKey
                    if call.phase == .active && !call.isGroupCall {
                        Button { call.switchVideo() } label: { switchLabel }
                            .buttonStyle(.plain)
                            .padding(.top, 10)
                    }
                    /* 模糊背景（对齐微信那一档）：视频通话里点一下开/关，
                       人还是清楚的，背后的东西虚掉。手机吃力会自动关掉并提示。 */
                    if call.phase == .active {
                        Button { call.toggleBlurBackground() } label: {
                            Text(call.blurBackground ? Tr("关闭背景模糊") : Tr("模糊背景"))
                                .font(pf(14))
                                .foregroundColor(.white.opacity(0.9))
                                .padding(.horizontal, 16)
                                .frame(height: 32)
                                .background(Capsule().fill(Color.white.opacity(call.blurBackground ? 0.34 : 0.16)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 40)
            } else {
                if call.phase == .active {
                    /* 接通后（vx 参考图那张）：一行三颗 —— 麦克风 / 挂断 / 扬声器，挂断居中 */
                    VStack(spacing: 14) {
                        HStack(spacing: 51) {
                            micKey
                            hangupKey
                            speakerKey
                        }
                        /* 群语音里不做「切视频」（群视频是第二期），单聊才给这一颗 */
                        if !call.isGroupCall {
                            Button { call.switchVideo() } label: { switchLabel }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 54)
                } else {
                    /* 还没接通（呼出中）：微信只有两颗 —— 麦克风 + 红色的「取消」。
                       以前这里也摆三颗（扬声器也出来了），和微信不一致。 */
                    HStack(spacing: 72) {
                        micKey
                        hangupKey
                    }
                    .padding(.bottom, 54)
                }
            }
        }
    }

    /// 「切换为视频通话 / 切换为语音通话」那一小颗（通话中才有，微信也有这个）
    private var switchLabel: some View {
        Text(call.isVideo ? Tr("切换为语音通话") : Tr("切换为视频通话"))
            .font(pf(14))
            .foregroundColor(.white.opacity(0.9))
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(Capsule().fill(Color.white.opacity(0.16)))
    }

    private var micKey: some View {
        roundKey(key: call.muted ? "ui.callMicOff" : "ui.callMic",
                 symbol: call.muted ? "mic.slash.fill" : "mic.fill",
                 builtin: call.muted ? I.callMicOff : I.callMic,
                 label: call.muted ? "麦克风已关" : "麦克风已开",
                 engaged: call.muted) { call.toggleMute() }
    }

    /// 麦克风没开 / 没起来时挂在底部那颗麦克风上面的一条提示：
    /// 「对方听不到你」+「去开启」（去系统设置）+「重试」（权限已经开了、只是没抢到麦）。
    private var micBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
            Text(Tr("麦克风没开，对方听不到你"))
                .font(pfExact(13.5))
                .foregroundColor(.white)
                .lineLimit(2)
            Spacer(minLength: 6)
            Button { call.retryMic() } label: {
                Text(Tr("重试"))
                    .font(pfExact(13.5, .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .overlay(Capsule().stroke(Color.white.opacity(0.75), lineWidth: 1))
            }
            .buttonStyle(.plain)
            Button { call.openMicSettings() } label: {
                Text(Tr("去开启"))
                    .font(pfExact(13.5, .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(hex: 0xE08A10).opacity(0.95)))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var speakerKey: some View {
        roundKey(key: call.speakerOn ? "ui.callSpeaker" : "ui.callSpeakerOff",
                 symbol: call.speakerOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                 builtin: call.speakerOn ? I.callSpeaker : I.callSpeakerOff,
                 label: call.speakerOn ? "扬声器已开" : "扬声器已关",
                 engaged: call.speakerOn) { call.toggleSpeaker() }
            /* 长按 = 换声音输出（微信那样在听筒 / 扬声器 / 蓝牙之间切） */
            .onLongPressGesture(minimumDuration: 0.35) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                audioDevices = call.audioDevices()
                showAudioDevices = true
            }
    }

    private var hangupKey: some View {
        roundKey(label: call.phase == .active ? "挂断" : "取消",
                 bg: Color(hex: 0xFA5151)) { call.hangup() }
    }

    /// 接通前视频通话底部中间那颗：翻转摄像头（参考图里它在中间）
    private var flipKey: some View {
        roundKey(label: "翻转",
                 bg: Color.white.opacity(0.18),
                 ink: .white,
                 action: { call.flipCamera() }) {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
                .font(.system(size: 26, weight: .medium))
        }
    }

    /// 接通前视频通话底部右边那颗：摄像头开 / 关（遮挡）
    private var cameraKey: some View {
        roundKey(label: call.cameraOff ? "摄像头已关" : "摄像头已开",
                 bg: call.cameraOff ? Color.white : Color.white.opacity(0.18),
                 ink: call.cameraOff ? .black : .white,
                 action: { call.toggleCamera() }) {
            Image(systemName: call.cameraOff ? "video.slash.fill" : "video.fill")
                .font(.system(size: 26, weight: .medium))
        }
    }

    /// 左右两颗（麦克风 / 扬声器）：打开时**变白底 + 深色图标**（和微信一样），
    /// 关着的时候是半透明黑底 + 白色图标。图标本身后台「UI 图标」里能换。
    private func roundKey(key: String, symbol: String, builtin: String,
                          label: String, engaged: Bool,
                          action: @escaping () -> Void) -> some View {
        let ink: Color = engaged ? .black : .white
        return
        roundKey(label: label,
                 bg: engaged ? Color.white : Color.white.opacity(0.18),
                 ink: ink,
                 action: action) {
            CallIcon(key: key, symbol: symbol, builtin: builtin, size: 30, color: ink)
        }
    }

    /// 挂断/取消那颗：图标是微信那种宽横梁（SF Symbols 里没有一样的，自己画）
    private func roundKey(label: String, bg: Color,
                          action: @escaping () -> Void) -> some View {
        roundKey(label: label, bg: bg, ink: .white, action: action) {
            CallIcon(key: "ui.callHangup", symbol: "phone.down.fill", builtin: I.callHangup, size: 72)
        }
    }

    private func roundKey<Icon: View>(label: String, bg: Color, ink: Color,
                                      action: @escaping () -> Void,
                                      @ViewBuilder icon: () -> Icon) -> some View {
        VStack(spacing: 14) {
            Button(action: action) {
                icon()
                    .foregroundColor(ink)
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(bg))
            }
            .buttonStyle(.plain)
            Text(label)
                .font(pfExact(14))
                .foregroundColor(.white.opacity(0.92))
        }
    }

    /* ---------------------------------------------------------- 顶部两个按钮（照参考图） */

    /// 参考图实测：左上那个「画中画/最小化」在 x29-47 y79-97；右上「+」在 x384-400 y78-94
    private var topBar: some View {
        HStack {
            Button {
                call.minimize()
            } label: {
                CallIcon(key: "ui.callMinimize", symbol: "rectangle.inset.bottomright.filled",
                         builtin: I.callMinimize, size: 20)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 16)

            Spacer()

            Button {
                showInvite = true
            } label: {
                CallIcon(key: "ui.callAdd", symbol: "plus", builtin: I.callAdd, size: 17)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
        }
        .padding(.top, 19)
    }

    /// （旧版：一条横条。留着备用，不再使用）
    private var miniBarOld: some View {
        HStack(spacing: 8) {
            Circle().fill(C.green).frame(width: 8, height: 8)
            Text(call.phase == .active ? "通话中 \(timeText)" : call.tip)
                .font(pfExact(14))
                .foregroundColor(.white)
            Spacer(minLength: 0)
            Button {
                call.restore()
            } label: {
                Text(Tr("回到通话")).font(pfExact(14)).foregroundColor(Color(hex: 0x19A47A))
            }
            .buttonStyle(.plain)
            Button {
                call.hangup()
            } label: {
                CallIcon(key: "ui.callHangup", symbol: "phone.down.fill", builtin: I.callHangup, size: 24)
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(Capsule().fill(Color.black.opacity(0.72)))
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /* ---------------------------------------------------------- 邀请好友（右上 +） */

    /// 这个群里的成员（群通话邀请列表用）
    @State private var groupMembers: [User] = []

    /// 邀请名单：**群通话里列这个群的成员**（扣掉自己和已经在通话里的）；
    /// 单聊里才列好友。
    /// ⚠ 2026-10-16 用户：「群聊语音邀请好友好友进不来收不到」——
    /// 病根就是这里：以前不管是不是群通话，列的都是 `app.contacts`（我的好友），
    /// 而服务端只认「这个群的成员」，不是群成员的邀请会被直接丢掉，
    /// 对方什么都不会弹（连提示都没有）。
    private var inviteList: [User] {
        if call.isGroupCall && !call.groupChatId.isEmpty {
            let mine = app.me?.id ?? ""
            return groupMembers.filter { u in
                u.id != mine && !call.roster.contains(where: { $0.userId == u.id })
            }
        }
        return app.contacts
    }

    private var inviteSheet: some View {
        NavigationStack {
            List {
                Section {
                    if inviteList.isEmpty {
                        Text(call.isGroupCall
                             ? Tr("这个群里没有可以再拉的人了（要么已经在通话里，要么只有你自己）。想拉别人先把人加进群。")
                             : Tr("还没有好友可以邀请"))
                            .font(pf(13.5)).foregroundColor(C.subLabel)
                    }
                    ForEach(inviteList) { u in
                        Button {
                            showInvite = false
                            let name = u.nickname ?? u.username ?? "好友"
                            Task {
                                /* ④ 2026-10-13：群通话里「邀请成员」现在真的把人叫进**同一个通话**
                                   （服务端 group-invite → 对方弹群通话来电页 → 接听即入同一个房间）；
                                   不在群通话里（单聊）才退回原来那条「邀请消息」。 */
                                if call.isGroupCall {
                                    call.inviteToCall(u.id)
                                    app.show(Tr("已邀请 ") + name + Tr(" 加入通话"))
                                } else {
                                    let msg = await call.invite(userId: u.id, name: name)
                                    app.show(msg)
                                }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Avatar(path: u.avatar ?? "", size: 36, radius: 6)
                                Text(u.nickname ?? u.username ?? "好友").foregroundColor(C.label)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(call.groupCallFull
                         ? Tr("通话人数已满（最多 9 人）")
                         : Tr("邀请好友加入通话") + "（" + String(call.roster.count) + "/9）")
                } footer: {
                    Text(call.isGroupCall
                         ? Tr("群通话只能邀请**本群成员**（对方会看到群通话来电，接听即入会）。不是群成员的，先拉进群再来邀请。")
                         : Tr("对方会收到一条邀请消息，点那条消息就能回拨给你。"))
                }
            }
            .navigationTitle(Tr("添加通话"))
            .navigationBarTitleDisplayMode(.inline)
        }
        /* 进这个页先把群成员拉下来（群通话才需要） */
        .task {
            guard call.isGroupCall, !call.groupChatId.isEmpty, groupMembers.isEmpty else { return }
            if let r = try? await API.shared.chatMembers(chatId: call.groupChatId) {
                groupMembers = r.members
            }
        }
    }
}

/// 挂起（微信左上那个画中画按钮）之后，飘在页面最上面的小浮窗：
///   · 视频通话：显示对方画面（没画面就退回头像）；语音通话：绿色一条（头像 + 名字 + 计时）
///   · 点一下 → 回通话页；右上角小 ✕ → 直接挂断
///   · 可以拖着走，松手吸附到左右边（微信就是这么做的）
/// 关键：它是**透明容器**，只画这一个窗，所以底下的页面照常显示、照常能点 ——
/// 这就是「回到上一页，但通话还在」。
struct CallMiniWindow: View {
    @ObservedObject private var call = CallCenter.shared
    @ObservedObject private var trtc = TRTCBridge.shared

    /// 小窗位置（nil = 默认贴右上角；拖过之后记住，松手吸附到左右边）
    @State private var miniX: CGFloat? = nil
    @State private var miniY: CGFloat? = nil
    @State private var dragging: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let w: CGFloat = call.isVideo ? 108 : 146
            let h: CGFloat = call.isVideo ? 144 : 48
            /* 顶部留出状态栏/刘海：以前写死 6，会钻进灵动岛里 */
            let topSafe = max(geo.safeAreaInsets.top, 24)
            let minY = topSafe - 6
            let maxX = max(8, geo.size.width - w - 8)
            let maxY = max(minY, geo.size.height - h - 90)      // 90 = 底栏那一条
            let homeX = geo.size.width - w - 10
            let homeY = topSafe + 4
            let x = min(max((miniX ?? homeX) + dragging.width, 8), maxX)
            let y = min(max((miniY ?? homeY) + dragging.height, minY), maxY)
            windowBody(w: w, h: h)
                .position(x: x + w / 2, y: y + h / 2)
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { v in dragging = v.translation }
                        .onEnded { v in
                            let nx = (miniX ?? homeX) + v.translation.width
                            let ny = (miniY ?? homeY) + v.translation.height
                            // 松手吸附：靠近哪边就贴哪边（微信那种手感）
                            miniX = nx + w / 2 < geo.size.width / 2 ? 8 : maxX
                            miniY = min(max(ny, minY), maxY)
                            dragging = .zero
                        }
                )
        }
    }

    private func windowBody(w: CGFloat, h: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if call.isVideo {
                    ZStack {
                        if call.usingTRTC {
                            TRTCVideoView(view: trtc.remoteView)
                        } else {
                            VideoSurface(track: call.remoteVideo)
                        }
                        if call.usingTRTC ? (trtc.remoteView == nil) : (call.remoteVideo == nil) {
                            Avatar(path: call.peerAvatar, size: 44, radius: 8)
                        }
                    }
                } else {
                    HStack(spacing: 9) {
                        Avatar(path: call.peerAvatar, size: 28, radius: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(call.peerName)
                                .font(pfExact(13, .medium))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            Text(call.phase == .active ? miniTimeText : (call.tip.isEmpty ? "通话中" : call.tip))
                                .font(pfExact(11))
                                .foregroundColor(.white.opacity(0.72))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .background(Color(hex: 0x19A47A))
                }
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.black.opacity(0.18), lineWidth: 0.5))
            .contentShape(Rectangle())
            .onTapGesture { call.restore() }

            Button {
                call.hangup()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.black.opacity(0.55)))
            }
            .buttonStyle(.plain)
            .padding(5)
        }
        .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
    }

    /// 小浮窗上的计时（mm:ss；超过一小时给 h:mm:ss）
    private var miniTimeText: String {
        let s = call.seconds
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%02d:%02d", m, sec)
    }
}

/// 微信「挂断 / 取消」那个图标：一条略带弧度的宽横梁，两头向下收，宽高比约 4:1。
/// 参考图实测 67×16pt（在 72pt 的圆里几乎占满宽度）。
struct HangUpIcon: View {
    var width: CGFloat = 66
    var body: some View {
        let h = width * 0.25
        let s = width / 66
        return Path { p in
            p.move(to: CGPoint(x: 3 * s, y: 5.4 * s))
            p.addQuadCurve(to: CGPoint(x: 63 * s, y: 5.4 * s),
                           control: CGPoint(x: 33 * s, y: 0.4 * s))       // 上沿：中间略高
            p.addLine(to: CGPoint(x: 63 * s, y: 9.2 * s))
            p.addQuadCurve(to: CGPoint(x: 43 * s, y: 13.2 * s),
                           control: CGPoint(x: 53 * s, y: 13.4 * s))      // 右腿向下收
            p.addLine(to: CGPoint(x: 23 * s, y: 13.2 * s))
            p.addQuadCurve(to: CGPoint(x: 3 * s, y: 9.2 * s),
                           control: CGPoint(x: 13 * s, y: 13.4 * s))      // 左腿向下收
            p.closeSubpath()
        }
        .fill(Color.white)
        .frame(width: width, height: max(8, h))
    }
}

/// 左上「最小化」：画中画图标（一个大圆角方框，右下角套一个小方框）
struct PipIcon: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let line = max(1.4, w * 0.09)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: w * 0.16, style: .continuous)
                    .stroke(Color.white, lineWidth: line)
                    .frame(width: w * 0.86, height: h * 0.86)
                RoundedRectangle(cornerRadius: w * 0.12, style: .continuous)
                    .fill(Color.black.opacity(0.35))
                    .overlay(RoundedRectangle(cornerRadius: w * 0.12, style: .continuous)
                        .stroke(Color.white, lineWidth: line))
                    .frame(width: w * 0.52, height: h * 0.40)
                    .offset(x: w * 0.48, y: h * 0.60)
            }
        }
    }
}

/// 右上「+」：两根线交叉（参考图实测横竖各 16pt，线宽约 1.8）
struct PlusIcon: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Path { p in
                p.move(to: CGPoint(x: 0, y: w / 2))
                p.addLine(to: CGPoint(x: w, y: w / 2))
                p.move(to: CGPoint(x: w / 2, y: 0))
                p.addLine(to: CGPoint(x: w / 2, y: w))
            }
            .stroke(Color.white, style: StrokeStyle(lineWidth: max(1.6, w * 0.11), lineCap: .round))
        }
    }
}

/// 通话页的图标：后台「UI 图标」里配过（ui.callMinimize / ui.callAdd / ui.callMic /
/// ui.callMicOff / ui.callSpeaker / ui.callSpeakerOff / ui.callHangup）就用配的，
/// 可以传 SVG、图片地址（上传的图）或者 emoji；没配就用内置的。
struct CallIcon: View {
    let key: String
    var symbol: String = "circle"
    var builtin: String? = nil
    var size: CGFloat = 24
    var color: Color = .white

    var body: some View {
        if let v = IconOverrides.custom(key), !v.isEmpty {
            if v.hasPrefix("<svg") {
                SVGIcon(markup: v, size: size, color: color)
            } else if v.hasPrefix("http") || v.hasPrefix("/uploads") || v.hasPrefix("data:") {
                RemoteImage(path: v).frame(width: size, height: size)
            } else {
                Text(v)
                    .font(.system(size: size * 0.9))
                    .foregroundColor(color)
                    .frame(width: size, height: size)
            }
        } else if let b = builtin {
            SVGIcon(markup: b, size: size, color: color)
        } else {
            Image(systemName: symbol)
                .font(.system(size: size * 0.9, weight: .medium))
                .foregroundColor(color)
                .frame(width: size, height: size)
        }
    }
}

/// 「滚动屏」：文字从右边缘慢慢滚到左边，循环滚（等对方接的时候用）
struct MarqueeText: View {
    let text: String
    var size: CGFloat = 15
    var duration: Double = 7
    @State private var x: CGFloat = 0
    @State private var ready = false

    var body: some View {
        GeometryReader { geo in
            Text(text)
                .font(pfExact(size))
                .foregroundColor(.white.opacity(0.72))
                .fixedSize()
                .offset(x: x)
                .onAppear {
                    guard !ready else { return }
                    ready = true
                    x = geo.size.width
                    withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                        x = -geo.size.width
                    }
                }
        }
        .frame(height: size + 6)
    }
}

/* ---------------------------------------------------------- 视频画面 */

/// 把 WebRTC 的画面接到 SwiftUI 里（Metal 渲染，省电、延迟低）
struct VideoSurface: UIViewRepresentable {
    let track: RTCVideoTrack?

    final class Holder {
        var attached: RTCVideoTrack?
    }

    func makeCoordinator() -> Holder { Holder() }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let v = RTCMTLVideoView()
        v.videoContentMode = .scaleAspectFill
        v.clipsToBounds = true
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        if context.coordinator.attached === track { return }
        context.coordinator.attached?.remove(view)
        context.coordinator.attached = track
        track?.add(view)
    }

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Holder) {
        coordinator.attached?.remove(view)
    }
}
