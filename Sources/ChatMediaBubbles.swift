import SwiftUI
import AVFoundation
import AVKit

/// 解析气泡里的 JSON（图片/视频消息的内容都是一小段 JSON）
private func jsonDict(_ s: String) -> [String: Any] {
    guard let d = s.data(using: .utf8),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return o
}

/* ============================================================
   名片消息（微信「＋ → 名片」发出去的那张小卡片）：
   头像 + 名字 + 微信号，点一下打开那个人的资料页 ——
   如果还不是好友，资料页上就有「添加到通讯录」，也就是微信那套"推名片可以加好友"。
   ============================================================ */

struct UserCardInfo {
    var userId: String = ""
    var name: String = ""
    var avatar: String = ""
    var username: String = ""

    /// 名片上的名字 / 微信号**先解码再显示**：
    /// 发送端和中间层可能各自编码过一次，直接显示就是一串 %E6%9D%8E…
    /// （用户说的「发出去乱码」就是叠了编码）。解不开就原样用，不会变空。
    static func decodePct(_ s: String) -> String {
        guard s.contains("%") else { return s }
        return s.removingPercentEncoding ?? s
    }

    init?(json: String) {
        let o = jsonDict(json)
        /* 老消息里有把用户 id 写在 "id" 上的，两种都认 */
        userId = ((o["userId"] as? String) ?? (o["id"] as? String)) ?? ""
        name = UserCardInfo.decodePct((o["name"] as? String) ?? "")
        avatar = (o["avatar"] as? String) ?? ""
        username = UserCardInfo.decodePct((o["username"] as? String) ?? "")
        guard !userId.isEmpty else { return nil }
    }
}

struct UserCardBubble: View {
    let info: UserCardInfo

    var body: some View {
        /* 照微信那张名片重做：
           上半：头像 + 名字（有微信号就再带一行，没填就不占那行）
           一条细线
           下半：「个人名片」这一行小字
           （以前没微信号时把「个人名片」塞在名字下面当副标题，
             看着像"这张名片没有名字/信息"，现在下面那一条才是它的位置。） */
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                /* ⚠ 名片里的头像**不走 Avatar 那套**：小星的头像在 Avatar 里是
                   「会动的眼睛」(JarvisEyesAvatar，自带两个无限循环的动画任务)，
                   放在名片这一行里会把 App 直接干掉（用户实测：把名片降级成文字就不闪，
                   把眼睛头像换成普通图也不闪）。这里就老老实实画一张图。 */
                RemoteImage(path: info.avatar, icon: "person.fill")
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.name.isEmpty ? Tr("微信联系人") : info.name)
                        .font(pf(16, .medium))
                        .foregroundColor(C.label)
                        .lineLimit(1)
                    Text(Tr("微信号：") + (info.username.isEmpty ? "—" : info.username))
                        .font(pf(12.5))
                        .foregroundColor(C.subLabel)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)

            HairLine(inset: 0)

            HStack(spacing: 4) {
                Image(systemName: "person.crop.square")
                    .font(.system(size: 11.5, weight: .medium))
                Text(Tr("个人名片"))
                    .font(pf(12))
                Spacer(minLength: 0)
            }
            .foregroundColor(C.subLabel)
            .padding(.horizontal, 12)
            .frame(height: 28)
        }
        .frame(width: 250, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(C.cardBg))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(C.hairline, lineWidth: 0.5))
    }
}

/* ============================================================
   群公告卡片（群里那条）：发群公告的时候自动落一条，所有成员都看得到
   ============================================================ */

struct AnnounceBubble: View {
    let text: String
    /// 点一下看全文（微信里点群里那条公告也是进一整页）
    var onOpen: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "megaphone.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(Tr("群公告"))
                    .font(pf(12, .medium))
            }
            .foregroundColor(C.green)
            Text(text)
                .font(pf(14))
                .foregroundColor(C.label)
                .lineLimit(6)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 232, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(C.cardBg))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(C.hairline, lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
    }
}

/* ============================================================
   聊天里的两种新气泡（和微信一致）：
   · 视频消息：封面 + 播放三角 + 时长；点一下全屏播放
   · 实况照片：静态图 + 左上角「实况」角标；**长按播那一小段**
   播放复用视频号那套（AVPlayerLayer + 播放器池）。
   ============================================================ */

/// 视频气泡
/// 视频气泡的尺寸（和微信一致）：按视频本身的横竖比例等比缩放，**不裁剪**。
/// 横屏：宽最多 250、高最多 170；竖屏：宽最多 190、高最多 250；太小/太扁兜一个最小边。
/// 老消息没记过宽高（w/h）就退回原来那个 160×205。
func videoBubbleSize(w: Int, h: Int) -> CGSize {
    let fw = CGFloat(w), fh = CGFloat(h)
    guard fw > 0, fh > 0 else { return CGSize(width: 160, height: 205) }
    let aspect = fw / fh
    let maxW: CGFloat = aspect >= 1 ? 250 : 190
    let maxH: CGFloat = aspect >= 1 ? 170 : 250
    var cw = maxW
    var ch = cw / aspect
    if ch > maxH { ch = maxH; cw = ch * aspect }
    /* 超宽幅/超窄幅：缩到最小边 110 以上，别成一条线 */
    if min(cw, ch) < 110 {
        let k = 110 / min(cw, ch)
        cw *= k; ch *= k
        if cw > maxW { let k2 = maxW / cw; cw *= k2; ch *= k2 }
        if ch > maxH { let k2 = maxH / ch; cw *= k2; ch *= k2 }
    }
    return CGSize(width: cw.rounded(), height: ch.rounded())
}

struct VideoBubble: View {
    let message: Message
    let mine: Bool
    var onOpen: (URL, UIImage?) -> Void = { _, _ in }

    private var info: (url: String, cover: String, seconds: Int, w: Int, h: Int) {
        let o = jsonDict(message.body)
        return ((o["url"] as? String) ?? "",
                (o["cover"] as? String) ?? "",
                (o["seconds"] as? Int) ?? 0,
                (o["w"] as? Int) ?? 0,
                (o["h"] as? Int) ?? 0)
    }

    /// 气泡尺寸：有视频本身的比例就按比例（微信逻辑），老消息退回 160×205
    private var size: CGSize { videoBubbleSize(w: info.w, h: info.h) }

    /* ⚠ 这里原来是一整坨写在 body 里的（ZStack + 角标 + 诊断浮层），
       Xcode 26.3 的编译器对那一大段表达式直接报
       「unable to type-check this expression in reasonable time」（26.6 才勉强过）。
       现在拆成 coverLayer / playIcon / timeBadge / diagOverlay 四个小块。 */
    var body: some View {
        ZStack {
            coverLayer
            playIcon
            if info.seconds > 0 { timeBadge }
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .topLeading) {
            if UIConfig.num("videoDiag", 0) > 0 { diagOverlay }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        /* 点一下 = 全屏播放。**不用 Button**：Button 会把长按吃掉，
           外面那层「撤回 / 转发 / 多选」的动作条就永远弹不出来（视频撤回不了就是这个原因）。 */
        .onTapGesture {
            let u = info.url
            let full = u.hasPrefix("http") ? u : API.shared.base + u
            if let url = URL(string: full) { onOpen(url, nil) }
        }
    }

    @ViewBuilder
    private var coverLayer: some View {
        if !info.cover.isEmpty {
            RemoteImage(path: info.cover, mode: .fill, maxSide: 1280)
        } else {
            Color.dyn(0xDDDDDD, 0x333333)
        }
    }

    private var playIcon: some View {
        Image(systemName: "play.circle.fill")
            .font(.system(size: 42))
            .foregroundColor(.white.opacity(0.92))
            .shadow(color: .black.opacity(0.35), radius: 6)
    }

    /// 右下角那个时长角标（「00:12」）
    private var timeBadge: some View {
        VStack {
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                Text(String(format: "%02d:%02d", info.seconds / 60, info.seconds % 60))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.45)))
            }
        }
        .padding(7)
    }

    /// ★ 视频诊断（后台 data/ui.json 写 videoDiag = 1 才显示，正式用户看不到）：
    /// 把这条视频**实际收到的东西**直接写在气泡上 —— 一眼就能分清是
    /// 「发送端没把 url/cover 传上去」还是「传上去了但这边拉不到/渲染不出来」。
    private var diagOverlay: some View {
        let urlText = info.url.isEmpty ? "（空！）" : String(info.url.suffix(26))
        let coverText = info.cover.isEmpty ? "（空！）" : String(info.cover.suffix(20))
        let secs = String(info.seconds)
        let wh = String(info.w) + "x" + String(info.h)
        let box = String(Int(size.width)) + "x" + String(Int(size.height))
        let missing = info.url.isEmpty || info.cover.isEmpty
        return VStack(alignment: .leading, spacing: 1) {
            Text("url:" + urlText)
            Text("cover:" + coverText)
            Text("秒:" + secs + " 尺寸:" + wh)
            Text("气泡:" + box)
            if missing {
                Text("→ 发送端就没带上，视频注定黑屏")
            }
        }
        .font(.system(size: 8.5, design: .monospaced))
        .foregroundColor(.white)
        .padding(4)
        .background(Color.black.opacity(0.68))
        .padding(3)
        .allowsHitTesting(false)
    }
}

/// 实况照片气泡：静态图 + 「实况」角标，长按播动效
struct LivePhotoBubble: View {
    let message: Message
    var onPlay: (URL) -> Void = { _ in }

    @State private var pressed = false

    private var info: (image: String, video: String) {
        let o = jsonDict(message.body)
        return ((o["image"] as? String) ?? "", (o["video"] as? String) ?? "")
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RemoteImage(path: info.image, mode: .fill, maxSide: 1600)
            Text(Tr("实况"))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.black.opacity(0.42)))
                .padding(7)
        }
        .frame(width: 150, height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .scaleEffect(pressed ? 0.97 : 1)
        /* ⚠ 这里**不能**用长按：长按要留给消息菜单（撤回/转发…）——
           以前实况气泡占了长按，长按它只播动效、弹不出菜单，
           用户反馈的「实况消息没有撤回按钮」就是这个原因。
           微信里实况也是"点开看"，所以这里改成**点一下**播那一小段。 */
        .onTapGesture {
            pressed = true
            let v = info.video
            let full = v.hasPrefix("http") ? v : API.shared.base + v
            if let url = URL(string: full) { onPlay(url) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { pressed = false }
        }
    }
}

/// 全屏播放一个视频（聊天里点视频气泡用它）—— 微信那套：
/// 点一下屏幕出**播放进度条**，底下还有「转发」「分享」；3 秒不动自动收起。
struct VideoPlayerSheet: View {
    let url: URL
    /// 这条视频消息的正文（转发时原样发一条**视频消息**出去，不是发链接）
    var forwardContent: String = ""
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    /// 画中画（左上角那颗按钮）
    @StateObject private var pip = PiPBox()
    /// 下载/播放失败时的提示（黑屏时说人话，不要给一块黑板）
    @State private var note = ""
    /* 进度条 */
    @State private var now: Double = 0
    @State private var total: Double = 0
    @State private var dragging = false
    @State private var timeObs: Any?
    /* 控制条（点屏幕显示/隐藏） */
    @State private var controls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var showForward = false
    @State private var showShare = false
    /// 倍速（用户要的 x1 / x2）
    @State private var speed: Double = 1
    /// 拖动时上一次轻震的位置（做"阻尼"的手感：每拖过一小段震一下）
    @State private var lastHaptic = 0.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let p = player {
                PiPHostView(player: p, box: pip).ignoresSafeArea()
            }
            /* 进了画中画就把这里的画面**盖掉**：不然同一段视频会出现两层
               （App 里这一层 + 画中画小窗那一层）。盖一层黑的不影响小窗继续播。 */
            if pip.active {
                Color.black.ignoresSafeArea()
                VStack(spacing: 10) {
                    Image(systemName: "pip.fill")
                        .font(.system(size: 34))
                        .foregroundColor(.white.opacity(0.85))
                    Text(Tr("正在画中画播放"))
                        .font(pf(14)).foregroundColor(.white.opacity(0.8))
                    Text(Tr("点左上角按钮收回这一页"))
                        .font(pf(12)).foregroundColor(.white.opacity(0.55))
                }
                .allowsHitTesting(false)
            }
            if !note.isEmpty {
                Text(note)
                    .font(pf(14))
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.14)))
                    .padding(30)
            }
            VStack(spacing: 0) {
                /* ① 进度条放在**最上面**（用户要求）：贴着屏幕顶部，可以直接拖。
                      左边当前时间、右边总时长。 */
                if controls {
                    HStack(spacing: 10) {
                        Text(Self.fmt(now))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.88))
                            .frame(width: 40, alignment: .leading)
                        scrubBar
                        /* 倍速：1x ⇄ 2x（点一下立刻变速） */
                        Button { toggleSpeed() } label: {
                            Text(speed > 1.5 ? "2x" : "1x")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(speed > 1.5 ? Color.black : .white)
                                .frame(width: 36, height: 22)
                                .background(Capsule().fill(speed > 1.5 ? Color.white : Color.white.opacity(0.18)))
                        }
                        .buttonStyle(.plain)
                        Text(Self.fmt(total))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.88))
                            .frame(width: 40, alignment: .trailing)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    .transition(.opacity)
                }

                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.black.opacity(0.35)))
                    }
                    .buttonStyle(.plain)
                    /* 画中画：点一下缩成小窗继续播（再点回到这一页） */
                    Button { pip.toggle() } label: {
                        Image(systemName: pip.active ? "pip.exit" : "pip.enter")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.black.opacity(0.35)))
                    }
                    .buttonStyle(.plain)
                    .opacity(pip.possible || pip.active ? 1 : 0.4)
                    .disabled(!(pip.possible || pip.active))
                    Spacer(minLength: 0)
                }
                .padding(12)
                .opacity(controls ? 1 : 0)

                Spacer(minLength: 0)

                if controls {
                    /* ② 转发 / 分享（和微信一样）留在下面，不跟进度条抢位置 */
                    HStack(spacing: 46) {
                        action("转发", "arrowshape.turn.up.right.fill") { showForward = true }
                        action("分享", "square.and.arrow.up") { showShare = true }
                    }
                    .padding(.bottom, 30)
                    .transition(.opacity)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleControls() }
        .onAppear {
            Task { await start() }
            autoHideControls()
        }
        .onDisappear {
            if let o = timeObs, let p = player { p.removeTimeObserver(o) }
            timeObs = nil
            hideTask?.cancel()
            player?.pause()
            player = nil
        }
        .sheet(isPresented: $showForward) {
            VideoForwardPicker(link: url.absoluteString, videoContent: forwardContent)
                .environmentObject(app)
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(items: shareItems)
        }
    }

    /// 转发/分享用的东西：本机有留底就给**文件**（微信转发视频也是发文件），
    /// 没有就给地址。
    private var shareItems: [Any] {
        if let local = LocalStore.localURL(url.path), FileManager.default.fileExists(atPath: local.path) {
            return [local]
        }
        return [url.absoluteString]
    }

    /// 播放进度（0…1）
    private var frac: Double {
        guard total > 0.05 else { return 0 }
        return min(1, max(0, now / total))
    }

    /* ============================================================
       进度条（用户要的「拖动阻尼质感」）：
         · 手指按住不放，拖出来的那颗球会**变大**（像被捏住）
         · 拖动过程中每滑过一小段**轻震一下** —— 就是那个"阻尼"的手感
         · 松手用弹簧回稳（不是硬切）
         · 到两端有顶住的感觉：再多拖也只停在那儿
       ============================================================ */
    private var scrubBar: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let dot: CGFloat = dragging ? 15 : 11
            let barH: CGFloat = dragging ? 5 : 3
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.24)).frame(height: barH)
                Capsule().fill(Color.white).frame(width: max(0, w * frac), height: barH)
                Circle()
                    .fill(Color.white)
                    .frame(width: dot, height: dot)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .offset(x: min(max(0, w * frac - dot / 2), max(0, w - dot)))
            }
            .frame(height: 26)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: dragging)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !dragging { dragging = true; lastHaptic = 0 }
                        let f = min(1, max(0, Double(v.location.x / w)))
                        now = f * max(total, 0.1)
                        /* 每滑过 3% 轻震一下（"越拖越有手感"） */
                        if abs(f - lastHaptic) >= 0.03 {
                            lastHaptic = f
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                    }
                    .onEnded { _ in
                        dragging = false
                        if let p = player {
                            p.seek(to: CMTime(seconds: now, preferredTimescale: 600),
                                   toleranceBefore: .zero, toleranceAfter: .zero)
                            p.play()
                            p.rate = Float(speed)
                        }
                    }
            )
        }
        .frame(height: 26)
    }

    /// 1x ⇄ 2x
    private func toggleSpeed() {
        speed = speed > 1.5 ? 1 : 2
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if let p = player {
            if p.rate == 0 { p.play() }        // 暂停着也允许先选倍速
            p.rate = Float(speed)
        }
    }

    private func action(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Color.white.opacity(0.16)))
                Text(Tr(title)).font(pf(12)).foregroundColor(.white.opacity(0.92))
            }
        }
        .buttonStyle(.plain)
    }

    private func toggleControls() {
        withAnimation(.easeOut(duration: 0.18)) { controls.toggle() }
        autoHideControls()
    }

    /// 3 秒没动就把控制条收起来（微信也是这样，不然挡画面）
    private func autoHideControls() {
        hideTask?.cancel()
        guard controls else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return }
            withAnimation(.easeOut(duration: 0.2)) { controls = false }
        }
    }

    /// 00:12 这种
    static func fmt(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "00:00" }
        let t = Int(s.rounded())
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    /// ★★ 关键修复：**AVPlayer 不认我们的自签证书**（`NSAllowsArbitraryLoads` 也救不了它 ——
    /// AVFoundation 走自己那套网络栈），所以 `AVPlayer(url: 远程地址)` 会一直黑屏。
    /// 这就是"以前一发视频就能播、现在黑屏"的原因：以前播放走的是有正式证书的域名，
    /// 现在走自签的 IP。改成和语音一样的老路 —— 先用 **App 自己的会话**（认我们的证书）
    /// 把文件下到本地，再播**本地文件**（本地文件没有任何证书问题）。
    private func start() async {
        /* ① 先看**本地留底**：自己刚发的这条、或者以前播过一次的，直接播本地文件 ——
              本地文件不挑证书，也立刻能出画面。 */
        if url.scheme == "http" || url.scheme == "https",
           let local = LocalStore.localURL(url.path),
           FileManager.default.fileExists(atPath: local.path) {
            mount(AVPlayer(url: local))
            return
        }
        if url.scheme == "http" || url.scheme == "https" {
            /* ② 远程：**边下边播**（走 App 自己的会话，认自签证书）——
                  以前这里是把整段下完才播，几 MB 的视频要干等十几秒。
                  现在够一小段就起播，剩下的按播放进度边看边下。 */
            if let p = StreamPlay.player(url) {
                mount(p)
                /* ③ 硬兜底：**3 秒还没画面**（分片拉不到 / 服务器没切好）就换「整段下完再播」 */
                let ok = await waitForPicture(p)
                if ok { return }
                CrashCatcher.note("视频", "边下边播 3 秒没画面，改用整段下载：" + url.absoluteString.suffix(40))
                p.pause()
                if player === p { player = nil }
                timeObs = nil
            }
            /* ④ 老路（很稳）：整段下到本地再播 */
            guard let data = try? await API.shared.assetData(url), !data.isEmpty else {
                note = "取不到视频文件\n（网络不通或证书没过）\n地址：" + url.absoluteString.suffix(40)
                return
            }
            let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
            let dst = FileManager.default.temporaryDirectory
                .appendingPathComponent("play-\(UUID().uuidString).\(ext)")
            guard (try? data.write(to: dst)) != nil else { note = "视频写不进临时文件"; return }
            /* 下过一次就留一份底（和图片一个待遇）：下次播直接走本地 */
            LocalStore.keep(url.path, data: data)
            mount(AVPlayer(url: dst))
            return
        }
        mount(AVPlayer(url: url))
    }

    /// 装上播放器 + 进度条 + 循环播放
    private func mount(_ p: AVPlayer) {
        p.actionAtItemEnd = .none
        if let item = p.currentItem {
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                   object: item, queue: .main) { _ in
                p.seek(to: .zero); p.play()
            }
        }
        player = p
        p.play()
        if speed > 1.5 { p.rate = Float(speed) }      // 上一段选了 2x 就继续用 2x
        /* 进度条：每 0.25 秒更新一次当前时间；总时长从 asset 上读出来 */
        timeObs = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                            queue: .main) { t in
            if !dragging { now = max(0, t.seconds) }
        }
        Task {
            if let item = p.currentItem, let d = try? await item.asset.load(.duration) {
                total = max(0.1, d.seconds)
            }
        }
    }

    /// 等「画面真的动起来」（最多 3 秒）；返回 true = 成功（或这一页已经关了，不用再折腾）
    private func waitForPicture(_ p: AVPlayer) async -> Bool {
        for _ in 0..<15 {                       // 15 × 0.2 秒 = 3 秒
            if player !== p { return true }     // 关了 / 换播放器了
            if let item = p.currentItem {
                if item.status == .failed { return false }
                if item.status == .readyToPlay, CMTimeGetSeconds(p.currentTime()) > 0.05 { return true }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }
}

/* ============================================================
   「发送中」的视频/实况气泡（微信的逻辑）：
   视频还在压缩/上传时，气泡就已经出来了 —— 封面 + 中间一圈进度 + 百分比，
   不用盯着「发送中…」几个字干等。
   ============================================================ */
struct SendingVideoBubble: View {
    var cover: UIImage?
    var progress: Double          // 0…1

    /// 尺寸和最终那条视频气泡一致（用封面的比例算），发送中→发送完不会跳一下
    private var size: CGSize {
        guard let c = cover, c.size.width > 0, c.size.height > 0 else {
            return videoBubbleSize(w: 0, h: 0)
        }
        return videoBubbleSize(w: Int(c.size.width), h: Int(c.size.height))
    }

    var body: some View {
        ZStack {
            if let c = cover {
                Image(uiImage: c)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.dyn(0xDDDDDD, 0x333333)
            }
            Color.black.opacity(0.42)
            /* 一圈进度 + 圈里的百分比（微信就是这样，**不写任何字**）。
               圈做大一点（54pt）、百分比放圈里，一眼就能看出传到哪了。 */
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.30), lineWidth: 4)
                    .frame(width: 54, height: 54)
                /* 一开始也给一小段白弧：一出现就能看出"这是在传"，不是卡住的图标 */
                Circle()
                    .trim(from: 0, to: max(0.04, min(1, progress)))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 54, height: 54)
                if progress > 0.01 {
                    Text("\(Int(min(1, progress) * 100))%")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(.white)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.95))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
