import SwiftUI
import UIKit

/* ============================================================ 底部四个标签 */

struct MainTabView: View {
    @EnvironmentObject var app: AppState
    @State private var tab = 0
    @State private var shownCrash = false
    /* 读一下语言状态：切语言时这一层会重画（不重建整棵树，避免闪退） */
    @ObservedObject private var lang = LangStore.shared
    /* 音乐播放页那个开关（"要不要弹播放页"）：必须**这一层自己观察**它 ——
       以前只读了一个快照，弹/收都可能慢半拍，表现就是"关掉又自己弹回来" */
    @ObservedObject private var musicSheet = MusicSheet.shared
    /// 商城商品页（聊天里点那张商品卡片 → 弹这一页，和音乐播放页一个做法）
    @ObservedObject private var mallSheet = MallSheet.shared
    /* 未实名动钱时的全局提示（和微信一样：聊天不受影响，只有钱的功能要求实名） */
    @ObservedObject private var realNameGate = RealNameGate.shared

    private var unreadTotal: Int {
        /* ⚠ 2026-10-12 用户「消息未读有红点提示」「都对齐下微信」：
           微信那个数字红点只算**没开免打扰**的会话；开了免打扰的会话只在会话行上
           留一个小红点、**不往底栏数字里加**。以前这里把免打扰的也算进去了。 */
        app.chats.reduce(0) { $0 + (($1.muted == true) ? 0 : ($1.unread ?? 0)) }
    }
    /// 只有免打扰的会话有未读 → 底栏那一个**小红点**（不带数字），和微信一样
    private var mutedOnlyUnread: Bool {
        unreadTotal == 0 && app.chats.contains { $0.muted == true && ($0.unread ?? 0) > 0 }
    }

    var body: some View {
        /* ⚠ 底栏必须**浮在内容上面**（ZStack），不能排在内容下面（VStack）——
           排在下面时底栏背后只有一片页面底色，列表永远滚不到它后面，
           那层材质再透也看不到东西（用户反馈"底栏还是不透"就是这个原因）。
           改成 ZStack 之后：内容是整屏的，列表最后几行从底栏底下穿过去，
           底栏那层薄糊就会把后面的内容糊出来 —— 这才是微信那种透。
           内容这边用 safeAreaInset 给底栏让出 56+home 的高度，
           所以最后一行照样能滚上来，不会被底栏盖住。 */
        ZStack(alignment: .bottom) {
            /* 离线提示**不再挂横幅**（用户要求学微信）：微信断网时页面上什么都不弹，
               只是会话页顶栏的标题变成「微信（未连接）」。这里跟着改，
               标题那一条在 ChatsView.navTitle 里；内容照常显示上次拿到的那份。 */
            ZStack {
                if tab == 0 {
                    ChatsView()
                } else if tab == 1 {
                    ContactsView()
                } else if tab == 2 {
                    DiscoverView()
                } else {
                    MeView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            /* 内容**铺到屏幕最底**（底栏后面也铺）—— 底栏浮在它上面，
               列表最后几行才会从底栏玻璃后面穿过去。
               打开聊天页时底栏是藏起来的（tabBarHidden），那时不铺，
               免得输入框压到 home 手势条上。 */
            .ignoresSafeArea(edges: app.tabBarHidden ? [] : .bottom)
            /* 给底栏留出安全区：内容是"从它后面穿过去"，不是被它挡住（详见上面 ZStack 的说明） */
            .safeAreaInset(edge: .bottom) {
                Color.clear
                    .frame(height: app.tabBarHidden
                           ? 0
                           : L.tabH + L.safeBottom)
            }
            /* 登录后同步最近聊天记录：顶上挂一条小小的进度提示（同步是后台做的，不拦着用） */
            /* 登录后同步：微信那种居中的「正在同步最近的聊天记录…」卡片
               （同步很快，卡片是淡入淡出；不拦着用户操作） */
            .overlay {
                if app.syncing || !app.syncText.isEmpty {
                    ZStack {
                        Color.black.opacity(0.16).ignoresSafeArea()
                        VStack(spacing: 14) {
                            if app.syncing { ProgressView().scaleEffect(1.15) }
                            Text(app.syncing ? "正在同步最近的聊天记录…"
                                             : (app.syncText.isEmpty ? "已同步最近的聊天记录" : app.syncText))
                                .font(pf(14))
                                .foregroundColor(C.label)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 26)
                        .padding(.vertical, 22)
                        /* 同步提示不是浮层工具，用普通实色卡片即可。
                           之前套 CardGlassBox 会出现一团突然的玻璃感和亮边。 */
                        .background {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(C.cardBg)
                        }
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(C.hairline, lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.18), radius: 16, y: 4)
                    }
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }
            }

            if !app.tabBarHidden {
                TabBar(selection: $tab,
                       badge: app.showDot("chats", auto: unreadTotal > 0) ? unreadTotal : 0,
                       contactsDot: app.showDot("contacts", auto: app.friendRequests > 0),
                       momentsDot: app.showDot("discover", auto: app.momentsUnread > 0),
                       meDot: app.showDot("me", auto: false))
                    /* 底栏这一条的底色和页面一致（用户要求：顶栏/底栏颜色跟会话页统一）：
                       不铺这层的话，会话列表的白色行会从胶囊周围透出来，
                       看着就像"底栏和顶栏不是一个色"。想回到透出内容的样子，
                       后台 ui.json 把 tabBarOpaqueBg 写 0 就行。 */
                    .background {
                        /* 用户要求：**底栏要有"透"的感觉** —— 所以默认改成**不铺**那条实色底（0）：
                           列表会从底栏胶囊周围透出来（就是微信那种）。想回到"底栏和页面同色的一条"，
                           在后台把「底栏底下那条实色」写 1。 */
                        if UIConfig.num("tabBarOpaqueBg", 0) > 0 {
                            C.pageBg.ignoresSafeArea(edges: .bottom)
                        }
                    }
                    /* 底栏往下落的量：**默认 0** —— 微信那张参考图里底栏就是
                       56pt 标签行 + 34pt（home 条），没有上面多出来的一条。
                       想让它再往下落一点：后台 ui.json 写 tabBarDrop（原来默认 10）。 */
                    .offset(y: UIConfig.num("tabBarDrop", 0))
                    .transition(.move(edge: .bottom))
            }
        }
        /* 整块内容区的底色跟页面一致（深色下 navBg 是炭黑 #18181A，比页面 #0B0B0D 浅一档，
           状态栏那一条会看出「顶部是炭黑」）。底栏自己用 tabBg，比页面浅一点是对的。 */
        .background(C.pageBg.ignoresSafeArea())
        /* 注意：这里以前有一句 .animation(…, value: app.tabBarHidden)。
           它会让「整块内容区」在标签栏显隐时一起做动画 —— 打开聊天页（藏标签栏）那一下
           「上下缩放」就是这么来的。改成不给容器加动画：标签栏直接让位，页面照常推进来。 */
        /* 真人语音/视频通话：来电、通话界面挂在最外层，任何页面都能弹出来 */
        .overlay(CallOverlay())
        /* 上次崩过的话，进来就把崩溃信息弹出来（截图给我就能定位） */
        .sheet(isPresented: Binding(
            get: { !(UserDefaults.standard.string(forKey: "chris.lastCrash") ?? "").isEmpty && !shownCrash },
            set: { v in shownCrash = true })) {
                CrashLogView()
        }
        /* 接通 / 挂断弹的对话框（颜色圆角和聊天那个框一样），等用户点「确定」或超时自己关 */
        .overlay(CallDialogOverlay())
        /* 手机在另一台设备上登录（手机单点登录）：最外层弹这张卡片，
           点「退出」回登录页、点「我知道了」就关掉（本地聊天记录不动）。 */
        .overlay(OtherLoginCard().environmentObject(app))
        /* 扫到收付款码：不管在哪个页面扫的，都在最外层弹确认付款页 */
        .sheet(item: $app.payScan) { info in
            PayConfirmPage(target: info, scanText: app.payScanText)
                .environmentObject(app)
        }
        /* 扫到别人的个人码：不管在哪个页面扫的，都在最外层跳到他的资料页（和微信一样） */
        .sheet(isPresented: Binding(get: { app.scanCardUser != nil },
                                    set: { if !$0 { app.scanCardUser = nil } })) {
            if let u = app.scanCardUser {
                NavigationStack {
                    ContactCardView(user: u,
                                    onOpenChat: { chat in
                                        app.scanCardUser = nil
                                        app.openChatViaList(chat)
                                    },
                                    onOpenMoments: { _ in app.scanCardUser = nil })
                        .environmentObject(app)
                }
            }
        }
        /* 未实名却动了钱：弹微信那种对话框，点「去实名认证」直接进实名页 */
        .alert("根据国家规定", isPresented: $realNameGate.alert) {
            Button("去实名认证") { realNameGate.openPage = true }
            Button("取消", role: .cancel) { }
        } message: {
            Text("请先完成实名认证，之后才能使用转账、红包、收付款、零钱等功能。聊天不受影响。")
        }
        .sheet(isPresented: $realNameGate.openPage) {
            RealNameView().environmentObject(app)
        }
        /* 音乐播放页：**最外层**挂一次就行 —— 聊天里点音乐卡片、
           听一听里点一首歌，都弹这一页（大封面 + 进度 + 播放/暂停） */
        /* 播放页：**不用系统 sheet 了**。
           sheet 那种"关掉又自己弹回来"在真机上反复出现（用户反馈了三次），
           改成自己的一层整屏覆盖：关掉就是 open = false，没有第二套状态能把它顶回来。
           关的方式：左上角那颗 ⌄、顶栏往下拖、整页往下拖。 */
        .overlay {
            if musicSheet.open {
                MusicPlayingView()
                    .transition(.move(edge: .bottom))
                    .zIndex(60)
            }
        }
        .animation(.easeOut(duration: 0.22), value: musicSheet.open)
        /* 聊天里点那张**商品卡片** → 在这里弹商品页（和播放页同一层，哪条路径都盖得出来）。
           用 fullScreenCover 而不是 overlay：商品页左上角那颗返回是走 dismiss() 的。 */
        .fullScreenCover(item: Binding(
            get: { mallSheet.open ? mallSheet.product : nil },
            set: { if $0 == nil { mallSheet.close() } }
        )) { p in
            DDDetailView(product: p,
                         onCart: { mallSheet.close() },
                         onOpenOther: { mallSheet.product = $0 })
                .environmentObject(app)
        }
        /* 小图标（迷你播放球）：有歌在放就常驻在屏幕上（用户要求"要有个小图标
           可以在后台挂起"）—— 挂在最外层，四个 tab 和它们推进去的二级页都能看到。
           聊天页那条路径（openChat 整页打开）在下面单独再挂一份。 */
        /* ⚠ 全屏聊天弹出来的时候，这份先让位：不然两层各画一颗，
           过渡动画里会看到球在飘（用户反馈的"音乐图标在乱跳"）。 */
        .overlay(MiniPlayerBall(hidden: app.openChat != nil || musicSheet.open))
        /* 全局打开聊天：扫码进群 / 建完群 / 点推送都走这里（整页打开，不受当前在哪个 tab 影响） */
        .fullScreenCover(item: $app.openChat) { c in
            /* 外面套一层 NavigationStack：聊天页里的二级页（聊天信息）现在是 push 打开的，
              没有栈就会点不动。 */
            NavigationStack {
                ChatDetailView(chat: c).environmentObject(app)
            }
            /* 聊天页也留一份小播放球（两边位置共用同一个键） */
            .overlay(MiniPlayerBall())
            /* 聊天里点音乐卡片 / 点小球，播放页也在这条路径上盖出来 */
            .overlay {
                if musicSheet.open {
                    MusicPlayingView()
                        .transition(.move(edge: .bottom))
                        .zIndex(60)
                }
            }
            .animation(.easeOut(duration: 0.22), value: musicSheet.open)
        }
        /* 点推送通知 → 直接进那个会话（服务器在通知里带了 chatId） */
        /* 好友分享来的小游戏：从聊天里点那张卡片 → 这里全屏打开（最外层弹，稳） */
        .fullScreenCover(item: $app.openMiniApp) { g in
            GameWebPage(game: g).environmentObject(app)
        }
        .onReceive(NotificationCenter.default.publisher(for: .chrisOpenChat)) { note in
            guard let chatId = note.userInfo?["chatId"] as? String, !chatId.isEmpty else { return }
            CrashCatcher.note("推送", "点通知 chatId=" + chatId)
            Task { @MainActor in
                /* 点通知进来时 App 往往还在冷启动：先等真的 active */
                for _ in 0..<40 {
                    if UIApplication.shared.applicationState == .active { break }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                await app.loadChats()
                CrashCatcher.note("推送", "会话已加载 " + String(app.chats.count) + " 个")
                /* 2026-10-12 修「点推送通知依旧闪退」：
                   以前这里用 `app.openChatViaList(c)` —— 最外层 fullScreenCover 把**整页**聊天页
                   压上去；点通知进来时 App 常常刚冷启动，那一帧和启动打架就被系统杀掉
                   （服务器日志里既没有崩溃栈、内存也只有 40MB 左右，典型的 SIGKILL）。
                   现在**不再整页弹**：切回「会话」这个 tab，把会话 id 交给会话列表，
                   由它用自己那条导航路径 push —— 和用户手点一个会话**完全同一条路**，
                   那条路是稳的（日志里「8 准备打开 → 9 页面出现 → 刷新完」都正常）。 */
                tab = 0
                app.pendingPushChatId = chatId
            }
        }
        /* 别处要「打开某个会话」（建完群 / 扫码进群 / 搜索结果 / 通话结束…）：
           先把底栏切回「会话」，会话列表看到 pendingPushChatId 就自己 push 进去。 */
        .onChange(of: app.wantChatsTab) { v in
            if v { tab = 0; app.wantChatsTab = false }
        }
        /* 点了「登录确认」那条通知 → 直接出确认卡片（不用手输 6 位数字） */
        .onReceive(NotificationCenter.default.publisher(for: .chrisOpenPair)) { note in
            guard let code = note.userInfo?["code"] as? String, !code.isEmpty else { return }
            app.pairApproveCode = code
        }
        /* 每 5 秒探一次服务器通不通：离线就在最上面挂一条提示，
           页面里的内容一律不动（微信也是这样：能看，只是收不到新的） */
        .task {
            while !Task.isCancelled {
                await app.checkReachability()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        /* 启动打点：主界面真的画出来了（和 App.swift 里 1/3/4/5 那几条对着看，
           就知道是崩在配置、会话还是主界面上） */
        .onAppear { CrashCatcher.note("启动", "7 主界面出现") }
    }
}

/* ============================================================
   底栏的触摸层（UIKit 版）

   底栏要干两件事：
     · 轻点某一格 → 切到那一页
     · 按住 0.22 秒 → 出现一颗玻璃放大镜，**跟着手指滑**，滑过哪格放大哪格，
       松手切到那一格（WhatsApp / 苹果那种手感）

   以前这两件事是用 SwiftUI 的 `LongPressGesture.sequenced(before: DragGesture)`
   挂在底栏上的 —— 但那 4 个格子本身是 Button，按钮的手势优先级更高，
   长按会被按钮吃掉，所以「放大镜拖动」一直没生效（用户反馈的"没做放大镜移动"）。
   这里改成 UIKit 的方式：整条底栏盖一层透明视图，统一接管
   UITapGestureRecognizer（轻点）+ UILongPressGestureRecognizer（长按跟手）。
   两个手势天然互斥：长按成功之后抬手不会再被当成一次点击。
   ============================================================ */
struct TabBarTouchLayer: UIViewRepresentable {
    /// 轻点：参数是点在底栏里的横坐标
    var onTap: (CGFloat) -> Void
    var onLongPressBegan: (CGFloat) -> Void
    var onLongPressChanged: (CGFloat) -> Void
    var onLongPressEnded: (CGFloat) -> Void
    /// 直接在底栏上左右拖（不用等长按）：让那层超透玻璃滑块跟着手指走
    var onSlide: (CGFloat) -> Void
    /// 松手：吸附到手指停下的那一格
    var onSlideEnded: (CGFloat) -> Void

    final class Coord: NSObject, UIGestureRecognizerDelegate {
        var onTap: (CGFloat) -> Void = { _ in }
        var onBegan: (CGFloat) -> Void = { _ in }
        var onChanged: (CGFloat) -> Void = { _ in }
        var onEnded: (CGFloat) -> Void = { _ in }
        var onSlide: (CGFloat) -> Void = { _ in }
        var onSlideEnded: (CGFloat) -> Void = { _ in }
        /// 刚刚结束过一次长按：紧接着的那次抬手不要再当成"点击"
        private var lastPressEnd = Date.distantPast

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard g.state == .ended, let v = g.view else { return }
            if Date().timeIntervalSince(lastPressEnd) < 0.35 { return }
            onTap(g.location(in: v).x)
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let v = g.view else { return }
            let x = g.location(in: v).x
            switch g.state {
            case .began, .changed:
                onSlide(x)
            case .ended, .cancelled, .failed:
                onSlideEnded(x)
            default:
                break
            }
        }

        @objc func handlePress(_ g: UILongPressGestureRecognizer) {
            guard let v = g.view else { return }
            let x = g.location(in: v).x
            switch g.state {
            case .began:
                onBegan(x)
            case .changed:
                onChanged(x)
            case .ended, .cancelled, .failed:
                lastPressEnd = Date()
                onEnded(x)
            default:
                break
            }
        }

        /// 只让「横向拖动（滑块跟手）」和「长按（放大镜）」同时工作：
        /// 手指一边滑一边按住，滑块跟着走，0.22 秒后放大镜也浮出来 —— 一个动作两个反馈。
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            let pair = [g, other]
            let panAndPress = pair.contains { $0 is UIPanGestureRecognizer }
                && pair.contains { $0 is UILongPressGestureRecognizer }
            return panAndPress
        }
    }

    func makeCoordinator() -> Coord { Coord() }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = true

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coord.handleTap(_:)))
        v.addGestureRecognizer(tap)

        let press = UILongPressGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coord.handlePress(_:)))
        /* 按住多久出现放大镜（后台可调：ui.json 的 tabLoupePress，默认 0.22 秒） */
        press.minimumPressDuration = UIConfig.num("tabLoupePress", 0.22)
        /* 允许手指滑出底栏很远也不断（滑到屏幕别处也照样跟手） */
        press.allowableMovement = 10000
        press.delegate = context.coordinator
        v.addGestureRecognizer(press)

        /* 直接在底栏上左右拖：那一层超透玻璃滑块跟手走，松手吸附到最近一格。
           和轻点不冲突：手指一动，tap 自己就失败了。 */
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coord.handlePan(_:)))
        pan.delegate = context.coordinator
        v.addGestureRecognizer(pan)

        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onBegan = onLongPressBegan
        context.coordinator.onChanged = onLongPressChanged
        context.coordinator.onEnded = onLongPressEnded
        context.coordinator.onSlide = onSlide
        context.coordinator.onSlideEnded = onSlideEnded
    }
}

struct TabBar: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Binding var selection: Int
    var badge: Int
    /// 「通讯录」上那个小红点（有人加你为好友就亮，微信也是这样）
    var contactsDot: Bool = false
    /// 「发现」上那个小红点（有人发朋友圈就亮）
    var momentsDot: Bool = false
    /// 「我」上那个小红点（后台可以设成一直亮）
    var meDot: Bool = false

    private var items: [(String, String, String)] {
        [
            ("message", "message.fill", C.tabText0),
            ("person.2", "person.2.fill", C.tabText1),
            ("safari", "safari", C.tabText2),
            ("person.crop.circle", "person.crop.circle.fill", C.tabText3)
        ]
    }

    /// 每个图标能单独调大小：ui.json 里写 tabIcon0 / tabIcon1 / tabIcon2 / tabIcon3
    /// （0=微信 1=通讯录 2=发现 3=我）。SF Symbols 各图标自带的留白不一样，
    /// 微信和通讯录那两个本来就更满，所以默认给小一号。
    private func iconFont(_ i: Int) -> Font {
        let def = (i == 0 || i == 1) ? L.tabIcon - 2 : L.tabIcon
        return pf(UIConfig.num("tabIcon\(i)", def))
    }

    /// 底栏四个图标也允许在后台换掉
    private let customKeys = ["tab.chat", "tab.contacts", "tab.discover", "tab.me"]

    /// 自己上传/换过的图标（SVG、图片）用多大：跟内置图标一样吃 tabIcon0…3 的设置，
    /// 这样后台「界面文字」里调大小，两套图标一起变。
    private func customSize(_ i: Int) -> CGFloat {
        UIConfig.num("tabIcon\(i)", L.tabIconBox)
    }

    /* 底栏颜色（对着桌面 vx 文件夹那张参考图做的）：
       选中的是**深色实心**图标 + 深色字，没选中的是灰色描边图标 + 灰字，不用绿色。
       想改颜色：后台 ui.json 里加 tabSelColor / tabUnselColor（#浅色|#深色）。 */
    private var selColor: Color { UIConfig.color("tabSelColor", 0x1A1A1A, 0xEDEDED) }
    private var unselColor: Color { UIConfig.color("tabUnselColor", 0x6B6B6B, 0x8E8E93) }
    /// 选中那格图标大一点点（参考图里就是这样）
    private func tabIconFont(_ i: Int, on: Bool) -> Font {
        let base = UIConfig.num("tabIcon\(i)", (i == 0 || i == 1) ? L.tabIcon - 2 : L.tabIcon)
        return pf(on ? base + 1.5 : base)
    }

    /* ---------------- 长按拖动：苹果那种"放大镜跟着手指走" ----------------
       长按底栏 0.22 秒后出现一颗玻璃放大镜，跟着手指滑动，
       滑过哪一格就把那一格放大、并轻微震动一下，松手切到那一页。
       普通点按不受影响（长按手势不会抢走 tap）。 */
    @State private var barWidth: CGFloat = 0
    @State private var dragX: CGFloat? = nil
    @State private var dragIndex: Int? = nil
    /// 直接用手指在底栏上左右拖时，那层超透玻璃滑块的实时位置（松手就 nil，吸附到选中格）
    @State private var slideX: CGFloat? = nil
    private let dragHaptic = UIImpactFeedbackGenerator(style: .light)

    private func updateDrag(_ x: CGFloat) {
        guard barWidth > 1, !items.isEmpty else { return }
        let seg = barWidth / CGFloat(items.count)
        let i = min(items.count - 1, max(0, Int(x / seg)))
        if i != dragIndex { dragHaptic.impactOccurred() }
        dragX = x
        dragIndex = i
    }

    /// 轻点底栏：落在哪一格就切到哪一格
    private func selectTab(at x: CGFloat) {
        guard barWidth > 1, !items.isEmpty else { return }
        let seg = barWidth / CGFloat(items.count)
        selection = min(items.count - 1, max(0, Int(x / seg)))
    }

    /* 底栏那层遮罩：整条铺满宽度，没有胶囊、没有玻璃边。
       颜色是**照微信真机截图量的**（桌面 安全 文件夹那张 1260×2736 的会话页）：
         · 列表底 #191919（RGB 25,25,25）
         · 底栏   #232323（RGB 35,34,34）—— 比列表亮一档，就是微信那个观感
         · 底栏最上面那条 1px 亮线（RGB 48,48,48）= 微信也有，但用户不要"多出一条边"，
           所以默认**不画**（想画：后台 tabBarLine 写 1，颜色 tabBarLineColor）。
       底栏底色走 tabBarColor（没配就跟 tabBg，再跟内置的 #F7F7F7 / #232323），
       上面再压一层很轻的糊（tabGlassAlpha，默认 0.2）——
       后面的内容划过去时会透一丢丢，但不是一块死色。 */
    private var tabMaskLayer: some View {
        let fill = UIConfig.colorIfSet("tabBarColor")
            ?? UIConfig.colorIfSet("tabBg")
            ?? C.tabBg
        /* 用户要求：底栏的质感和**朋友圈顶栏那条**一样（灰玻璃 + 上面压一层色）。
           朋友圈那条用的是 GlassBackground（系统玻璃/自绘玻璃 + 亮边）+ 一层染色，
           这里照抄同一套配方：
             · tabBarGlass    玻璃浓度（默认 0.9，和朋友圈顶栏的 momentBarGlass 一个量级）
             · tabBarOpaque   上面压的那层色多浓（默认 0.22）—— 就是"底部遮罩"
             · tabGlass       写 0 = 不要这层玻璃（回到纯遮罩）
             · tabBarOpaqueBg 写 1 = 底栏后面再铺一条和页面同色的实底（会挡住玻璃） */
        let glassOn = UIConfig.num("tabGlass", 1) > 0
        if glassOn {
            return AnyView(ZStack {
                /* ★ 真·磨砂（2026-10-11 用户反馈「透色是透色了但是不磨砂」）：
                   iOS 26 那个原生液态玻璃**很"清"**，只透色、不糊；
                   这里单独补一层系统材质（.bar = UIVisualEffectView 的模糊），
                   浓淡用 tabBarBlur 调（写 0 就回到以前那种"只透不糊"）。 */
                let blurA = UIConfig.num("tabBarBlur", 0.9)
                if blurA > 0 {
                    Rectangle()
                        .fill(.bar)
                        .opacity(max(0, min(1, blurA)))
                }
                GlassBackground(shape: Rectangle(),
                                opacity: UIConfig.num("tabBarGlass", 0.9),
                                edgeAlpha: 0,
                                shadow: false,
                                seed: 0.55,
                                native: true)
                /* 2026-10-17 用户点出底栏的本质是 **vibrancy**（.bar 材质）——
                   那层颜色默认从 0.22 收到 0.10，让材质的味道出来；
                   想要更"实"就后台 ui.json 把 tabBarOpaque 调大。 */
                fill.opacity(UIConfig.num("tabBarOpaque", 0.10))
            })
        }
        let glass = UIConfig.num("tabGlass", 1) > 0 ? UIConfig.num("tabGlassAlpha", 0.5) : 0
        return AnyView(ZStack {
            fill
                .opacity(UIConfig.num("tabBarOpaque", 0.32))
            Rectangle().fill(.bar)
                .opacity(glass)
        })
    }

    /// 整条底栏往下落的量（tabBarDrop）。**默认 0** —— 微信那张参考图里
    /// 底栏正好占 56(pt) 标签行 + 34(home 条) = 90pt，上面没有多出来的一条。
    /// 让出来的那一条也会被同一层遮罩盖住（见下面的 overlay），不会露内容。
    private var dropH: CGFloat { max(0, UIConfig.num("tabBarDrop", 0)) }

    @ViewBuilder
    private func magnifier(_ i: Int, x: CGFloat) -> some View {
        let d: CGFloat = UIConfig.num("tabLoupeSize", 64)
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Circle().stroke(LinearGradient(colors: [Color.white.opacity(0.75),
                                                    Color.white.opacity(0.22)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1)
            if i < items.count {
                Image(systemName: i == selection ? items[i].1 : items[i].0)
                    .font(.system(size: d * 0.46, weight: .medium))
                    .foregroundColor(selColor)
            }
        }
        .frame(width: d, height: d)
        .shadow(color: .black.opacity(0.22), radius: 10, y: 5)
        .offset(x: x - d / 2, y: -d - 12)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                Button {
                    selection = i
                } label: {
                    VStack(spacing: 4) {
                        ZStack(alignment: .topTrailing) {
                            if let custom = IconOverrides.custom(customKeys[i]) {
                                /* 自己上传的图片图标：当模板图渲染，这样选中变绿、未选中变灰，
                                   和内置图标一个观感（图片本身是透明底的黑图形）。 */
                                if custom.hasPrefix("http") || custom.hasPrefix("/uploads") || custom.hasPrefix("data:") {
                                    RemoteImage(path: custom, template: true)
                                        .frame(width: customSize(i), height: customSize(i))
                                        .foregroundColor(selection == i ? selColor : unselColor)
                                } else {
                                    FlexIcon(custom: custom, size: customSize(i),
                                             color: selection == i ? selColor : unselColor,
                                             symbol: items[i].0)
                                }
                            } else if i == 3, let av = app.me?.avatarPath, !av.isEmpty {
                                /* 「我」这一格不放图标，直接用我自己的头像 */
                                Avatar(path: av, size: UIConfig.num("tabAvatar", 24), radius: 0, circle: true)
                                    .overlay(Circle().stroke(selection == i ? selColor : Color.clear, lineWidth: 1.5))
                            } else {
                                Image(systemName: selection == i ? items[i].1 : items[i].0)
                                    .font(tabIconFont(i, on: selection == i))
                                    .frame(width: L.tabIconBox, height: L.tabIconBox)
                            }
                            if i == 0 && badge > 0 {
                                Text(badge > 99 ? "99+" : "\(badge)")
                                    .font(pf(11, .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 3)
                                    .frame(minWidth: 15, minHeight: 15)
                                    .background(Capsule().fill(C.red))
                                    .offset(x: 9, y: -6)
                            }
                            // 发现：有人发朋友圈就一个红点（微信就是这样，不带数字）
                            if i == 2 && momentsDot {
                                Circle()
                                    .fill(C.red)
                                    .frame(width: 9, height: 9)
                                    .overlay(Circle().stroke(C.tabBg, lineWidth: 1.5))
                                    .offset(x: 5, y: -3)
                            }
                            // 通讯录：有人加你好友就一个红点
                            if i == 1 && contactsDot {
                                Circle()
                                    .fill(C.red)
                                    .frame(width: 9, height: 9)
                                    .overlay(Circle().stroke(C.tabBg, lineWidth: 1.5))
                                    .offset(x: 5, y: -3)
                            }
                            // 我：后台设成「一直亮」时显示
                            if i == 3 && meDot {
                                Circle()
                                    .fill(C.red)
                                    .frame(width: 9, height: 9)
                                    .overlay(Circle().stroke(C.tabBg, lineWidth: 1.5))
                                    .offset(x: 5, y: -3)
                            }
                        }
                        Text(items[i].2)
                            .font(pf(UIConfig.num("tabLabel", L.tabLabel),
                                     selection == i ? .medium : .regular))
                    }
                    .foregroundColor(selection == i ? selColor : unselColor)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: L.tabH)
        /* 4 个格子的点击不再由 Button 自己处理：整条底栏的触摸都交给下面那层 UIKit
           （单击切页 / 长按出放大镜跟手滑）—— 按钮在上面会把手势吃掉，这就是
           「放大镜拖动一直没生效」的原因。 */
        .allowsHitTesting(false)
        /* 选中格那一层「超透玻璃」滑块：当前选中哪一格，它就滑到哪一格；
           长按拖动底栏的时候它也跟着手指左右走（上面再浮那颗放大镜）。
           超透 = 只留一点点毛玻璃 + 一道上亮的玻璃边（透明度后台可调：
           ui.json 的 tabSliderAlpha，越小越透；尺寸 tabSliderInset / tabSliderVInset）。 */
        .background(alignment: .leading) {
            if barWidth > 1, !items.isEmpty {
                let seg = barWidth / CGFloat(items.count)
                let w = max(0, seg - UIConfig.num("tabSliderInset", 10))
                let cx = slideX ?? dragX ?? (seg * (CGFloat(selection) + 0.5))
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)                       // 超透玻璃底
                    /* ⚠ 这颗「超透玻璃胶囊」**不要动**（用户明确要求保留）：
                       选中哪一格它滑到哪一格，浓度还是后台 tabSliderAlpha。 */
                    .opacity(UIConfig.num("tabSliderAlpha", 0.55))
                    .shadow(color: .black.opacity(0.10), radius: 6, y: 3)
                    .frame(width: w, height: max(0, L.tabH - UIConfig.num("tabSliderVInset", 14)))
                    .offset(x: cx - w / 2)
                    /* 换页时滑过去是弹的；手指拖动时（dragX 在变）要跟手、不能有动画 */
                    .animation(.spring(response: 0.28, dampingFraction: 0.84), value: selection)
                    .animation(nil, value: dragX)
            }
        }
        .background(
            /* 最早的**遮罩底栏**（用户要求回到这套）：
               整条**铺满宽度**，就是一层半透明底色（遮罩）——
               没有悬浮胶囊、没有液态玻璃边、没有左右缩进。
               颜色和浓度还是后台可调：
                 · 「底栏底色」tabBg（配了就用它，改完立刻生效）；
                 · 没配 tabBg 退回 tabGlassTint；
                 · 浓度 tabGlassTintAlpha（调到 1 就是实色底栏）。 */
            /* 用**通讯录顶栏那同一套遮罩**：系统 .bar 材质（磨砂 + 跟着明暗自动换）
               打底，上面再压一层底栏底色（tabBg）。
               两个浓度都能后台调：
                 · tabGlassAlpha —— 材质浓度（1 最实、0.5 很透）
                 · tabGlassTintAlpha —— 底色浓度（1 = 只看底色、看不到磨砂）
               整条还是铺满宽度的遮罩，没有胶囊/没有玻璃边。 */
            /* 默认调透一点：原来材质 0.9 + 底色 0.55 太实，后面的内容/图片透不上来
               （用户："不透色"）。想回到原来的实色感就把这两个键调大。 */
            tabMaskLayer
                .ignoresSafeArea(edges: .bottom)
        )
        /* 量一下底栏宽度：拖动时要按宽度算落在哪一格 */
        .background(GeometryReader { g in
            Color.clear
                .onAppear { barWidth = g.size.width }
                .onChange(of: g.size.width) { w in barWidth = w }
        })
        /* 整条往下落了 dropH，上面那一条用**同一层遮罩**补齐 ——
           这样底栏顶上不会出现"内容没被抹到"的一条硬边 */
        .overlay(alignment: .top) {
            tabMaskLayer
                .frame(height: dropH)
                .offset(y: -dropH)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        /* 触摸层：轻点切页；按住 0.22 秒 → 放大镜出现并跟手移动，松手切到那一格 */
        .overlay {
            TabBarTouchLayer(
                onTap: { x in
                    selectTab(at: x)
                },
                onLongPressBegan: { x in
                    updateDrag(x)                       // 放大镜立刻出现在手指下面
                    dragHaptic.impactOccurred()
                },
                onLongPressChanged: { x in
                    updateDrag(x)                       // 跟着手指滑，滑过哪格放大哪格
                },
                onLongPressEnded: { x in
                    updateDrag(x)
                    if let i = dragIndex, i < items.count { selection = i }
                    withAnimation(.easeOut(duration: 0.16)) {
                        dragX = nil
                        dragIndex = nil
                    }
                },
                onSlide: { x in
                    /* 直接在底栏上左右拖：超透玻璃滑块跟着手指走（跟手，不加动画） */
                    slideX = x
                },
                onSlideEnded: { x in
                    /* 松手：吸附到手指停下的那一格 */
                    let seg = barWidth > 1 ? barWidth / CGFloat(items.count) : 0
                    if seg > 0 {
                        selection = min(items.count - 1, max(0, Int(x / seg)))
                    }
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        slideX = nil
                    }
                }
            )
        }
        .overlay(alignment: .bottomLeading) {
            if let i = dragIndex, let x = dragX {
                magnifier(i, x: x)
                    .transition(.scale.combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
    }
}

/* ============================================================ 顶部导航条 */

struct NavBar<Right: View>: View {
    let title: String
    /// 自定义标题（传了就用它画，比如会话页那个"会滚的未读数字"）
    let titleView: AnyView?
    let back: (() -> Void)?
    let onLongPressTitle: (() -> Void)?
    /// 返回箭头右边可以插一小块内容（聊天页那个未读数字就放这儿）
    let leftExtra: AnyView?
    /// 苹果那套浮动玻璃：返回=圆形玻璃、标题=胶囊玻璃、右边=胶囊玻璃，其余地方全透明（露出内容）
    /// **默认全站都开**（用户要求：所有页面都沿用 iOS 26 这套玻璃做全套升级）。
    /// 想整体退回老的整条顶栏：后台 ui.json 写 navFloating = 0。
    var floating: Bool = true
    /// floating 时要不要给 leftExtra 自动套玻璃框（调用方自己套两个独立玻璃框时传 false）
    var leftExtraGlass: Bool = true
    private let right: Right

    init(title: String,
         back: (() -> Void)? = nil,
         onLongPressTitle: (() -> Void)? = nil,
         titleView: AnyView? = nil,
         leftExtra: AnyView? = nil,
         floating: Bool = true,
         leftExtraGlass: Bool = true,
         @ViewBuilder right: () -> Right) {
        self.title = title
        self.titleView = titleView
        self.back = back
        self.onLongPressTitle = onLongPressTitle
        self.leftExtra = leftExtra
        self.floating = floating
        self.leftExtraGlass = leftExtraGlass
        self.right = right()
    }

    /// 实际走不走浮动玻璃（总开关在后台，出问题不用出包就能整体退回）
    private var useFloating: Bool { floating && UIConfig.num("navFloating", 1) > 0 }

    var body: some View {
        ZStack {
            if useFloating {
                /* 标题自己一块玻璃胶囊（空标题就不画） */
                if !title.isEmpty {
                    Group {
                        if let titleView { titleView } else { titleText }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background { GlassBackground(shape: Capsule(), shadow: true, seed: 0.30) }
                }
            } else {
                // 加黑程度可以在后台「界面文字」里调：navTitleStroke
                // 0 = 不加（苹方 Semibold 本身）· 0.2 = 加一点 · 0.4 = 更黑
                if let titleView { titleView } else { titleText }
                /* 用了自定义标题（比如会话页那个会滚的数字）就不再叠描边，
                   不然底下会多出一层旧文字 */
                if titleView == nil && titleStroke > 0 {
                    titleText.offset(x: titleStroke)
                }
            }

            HStack(spacing: 0) {
                if let back = back {
                    Button(action: back) {
                        FlexIcon(custom: IconOverrides.custom("nav.back"), size: 20,
                                 color: C.label, symbol: "chevron.left", weight: .medium)
                            .frame(width: useFloating ? 36 : 44, height: useFloating ? 36 : L.navH)
                            .background {
                                if useFloating {
                                    GlassBackground(shape: Circle(),
                                                    shadow: true,
                                                    seed: 0.10)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, useFloating ? 10 : 0)
                }
                if let leftExtra = leftExtra {
                    if useFloating && leftExtraGlass {
                        /* 返回箭头旁边那块（聊天页的未读数字）也套一个玻璃胶囊，
                           不然只有它是"裸"的，和返回/标题/⋯ 不一致 */
                        leftExtra
                            .frame(height: 36)
                            .padding(.horizontal, 6)
                            .background {
                                GlassBackground(shape: Capsule(),
                                                shadow: true,
                                                seed: 0.55)
                            }
                            .padding(.leading, 6)
                    } else {
                        leftExtra
                            .frame(height: useFloating ? 36 : L.navH)
                            .padding(.leading, useFloating ? 6 : 0)
                    }
                }
                Spacer(minLength: 0)
                if useFloating {
                    right
                        .frame(height: 36)
                        .background {
                            GlassBackground(shape: Capsule(),
                                            shadow: true,
                                            seed: 0.80)
                        }
                        .padding(.trailing, 10)
                } else {
                    right
                }
            }
        }
        .frame(height: L.navH)
    }

    private var titleText: some View {
        Text(title)
            .font(pf(titleSize, weight))
            .foregroundColor(C.label)
            .onLongPressGesture { onLongPressTitle?() }
    }

    /// 顶部标题：默认 17（发现页小一号 16）；想再调就改 ui.json 里的 navTitle
    private var titleSize: CGFloat {
        let base = UIConfig.num("navTitle", 17)
        return title == "发现" ? base - 1 : base
    }
    /// 顶部标题字重：明显加黑（苹方 Semibold，和手机微信一致）
    private var weight: Font.Weight { .semibold }

    /// 描叠偏移（在后台默认 0：只保留苹方 Semibold，不再叠第二遍）
    private var titleStroke: CGFloat { UIConfig.num("navTitleStroke", 0) }
}

extension NavBar where Right == EmptyView {
    init(title: String,
         back: (() -> Void)? = nil,
         onLongPressTitle: (() -> Void)? = nil,
         titleView: AnyView? = nil,
         leftExtra: AnyView? = nil,
         floating: Bool = true) {
        self.init(title: title, back: back, onLongPressTitle: onLongPressTitle,
                  titleView: titleView, leftExtra: leftExtra, floating: floating) { EmptyView() }
    }
}

/* ============================================================ 搜索框 */

/// 微信页：纯白、圆角 5、没输入时「放大镜 + 搜索」整组居中（和手机微信一样）
struct SearchBoxCenter: View {
    @Binding var text: String
    var externalFocus: FocusState<Bool>.Binding? = nil
    @FocusState private var localFocus: Bool

    private var focused: Bool { externalFocus?.wrappedValue ?? localFocus }

    private var centered: Bool { text.isEmpty && !focused }

    @ViewBuilder
    private var field: some View {
        let tf = TextField("", text: $text)
            .font(pf(16))
            .foregroundColor(C.label)
            .multilineTextAlignment(centered ? .center : .leading)
        if let externalFocus = externalFocus {
            tf.focused(externalFocus)
        } else {
            tf.focused($localFocus)
        }
    }

    var body: some View {
        HStack(spacing: centered ? 3 : 5) {
            SVGIcon(markup: I.searchSmall, size: 16, color: C.searchIcon)

            ZStack(alignment: centered ? .center : .leading) {
                if text.isEmpty {
                    Text(Tr("搜索"))
                        .font(pf(16))
                        .foregroundColor(C.searchIcon)
                }
                field
            }
            .frame(maxWidth: centered ? 46 : .infinity)
        }
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
        .padding(.leading, centered ? 28 : 9)
        .padding(.trailing, centered ? 18 : 9)
        .frame(height: L.searchBoxH)
        .background(
            /* 搜索框也做成玻璃（和顶栏/输入框一套）：**只留一层** ——
               玻璃本体就是那层"框"，不再额外描边（用户反馈：两层外框不好看）。
               浓度后台可调：ui.json 的 searchGlassAlpha（越小越透） */
            GlassBackground(shape: Capsule(style: .continuous),
                            opacity: UIConfig.num("searchGlassAlpha", 0.55),
                            edgeAlpha: UIConfig.num("searchGlassEdge", 0))
        )
    }
}

/// 通讯录页：圆角 10、带一点阴影、放大镜在左、「搜索」左对齐
struct SearchBoxLeft: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: L.v(5, 1.8, 8)) {
            SVGIcon(markup: I.searchBig, size: 16, color: C.searchIcon2)
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(Tr("搜索"))
                        .font(pf(15))
                        .foregroundColor(C.searchIcon2)
                }
                TextField("", text: $text)
                    .font(pf(15))
                    .foregroundColor(C.label)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .frame(height: L.searchBoxH)
        .background(
            /* 通讯录那个搜索框：同样玻璃、同样只有一层（不描边） */
            GlassBackground(shape: Capsule(style: .continuous),
                            opacity: UIConfig.num("searchGlassAlpha", 0.55),
                            edgeAlpha: UIConfig.num("searchGlassEdge", 0))
        )
    }
}

/* ============================================================ 通用行 */

/// 发现页 / 我页 / 设置页的一行：图标 + 文字 +（右侧值）+ 箭头
struct MenuRow: View {
    let icon: String
    var iconColor: Color = C.green
    /// 参考图：发现页和我页的行都是左边距 18、图标 22、间距 18 → 文字落在 x=58
    var padLeading: CGFloat = 18
    let title: String
    var detail: String = ""
    var showArrow: Bool = true
    var badge: Bool = false
    var thumb: String = ""
    var onTap: (() -> Void)? = nil
    /// 「我」页那种**玻璃分组卡**里的行：行自己不铺底色，直接透出卡片那层玻璃。
    /// 不这样会怎样：卡片底是半透明玻璃（≈ 底色的 42% 混过去），而行底是不透明的 cardBg，
    /// 于是同一张卡上"卡片边缘"和"内芯"是两个颜色 —— 深色模式下特别明显
    /// （卡边偏暗、内芯偏亮），用户看到的"深色下颜色不一致"就是这个。
    var clearBg: Bool = false
    /// **彩色圆角方块 + 白色图标**（和鸿蒙端那套统一）：
    /// 比如「朋友圈」= 蓝底白图标、「视频号」= 橙底白图标。
    /// 关着的时候还是老样子（SVG 直接染成彩色，没有方块底）。
    var iconTile: Bool = false
    /// 苹果自带 SF Symbols 的名字（非空就用它，**不再用后台那套手画 SVG**）。
    /// 名字由 RowIcon.sf(action:label:) 生成。
    var sf: String = ""

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: L.menuGap) {
                /* 服务端把图标写成 anim:xxx = 用会动的那套（原生 60fps）；
                   老版本 App 拿到的会被服务端回落成静态图，不会显示成一串字。 */
                if iconTile {
                    /* 彩色方块：方块跟着服务端配的 color 走，图标本身画成白色。
                       方块里优先用苹果 SF Symbols（sf 有值就用它），没有再退回后台 SVG。 */
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(iconColor)
                        if !sf.isEmpty {
                            Image(systemName: sf)
                                .font(.system(size: L.menuIcon * 0.60, weight: .semibold))
                                .foregroundColor(.white)
                        } else {
                            SVGIcon(markup: icon, size: L.menuIcon * 0.78, color: .white)
                        }
                    }
                    .frame(width: L.menuIcon, height: L.menuIcon)
                } else if !sf.isEmpty {
                    Image(systemName: sf)
                        .font(.system(size: L.menuIcon * 0.82, weight: .regular))
                        .foregroundColor(iconColor)
                        .frame(width: L.menuIcon, height: L.menuIcon)
                } else if UIConfig.num("menuIconAnim", 0) > 0,
                          icon.hasPrefix("anim:"),
                   let kind = MenuIconKind(rawValue: String(icon.dropFirst(5))) {
                    AnimatedMenuIcon(kind: kind, size: L.menuIcon)
                        .frame(width: L.menuIcon, height: L.menuIcon)
                } else {
                    SVGIcon(markup: icon, size: L.menuIcon * 1.13, color: iconColor)
                        .frame(width: L.menuIcon, height: L.menuIcon)
                }

                Text(title)
                    .font(pf(L.menuTextSize))
                    .foregroundColor(C.label)

                Spacer(minLength: 0)

                if !detail.isEmpty {
                    Text(detail).font(pf(15)).foregroundColor(C.subLabel)
                }
                if !thumb.isEmpty {
                    ZStack(alignment: .topTrailing) {
                        RemoteImage(path: thumb)
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        if badge {
                            Circle().fill(C.red).frame(width: 9, height: 9).offset(x: 4.5, y: -4.5)
                        }
                    }
                    .frame(width: 32, height: 32)
                    .padding(.trailing, -8)
                }
                if showArrow {
                    Chevron(size: 9, line: 1.6)
                        .padding(.trailing, 3)
                }
            }
            .padding(.leading, padLeading)
            .padding(.trailing, L.menuPadR)
            .frame(height: L.menuH)
            .background(clearBg ? Color.clear : C.cardBg)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuPressStyle())
    }
}

struct MenuPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.gray.opacity(0.16) : Color.clear)
    }
}

struct GroupCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let content: Content
    /// 玻璃版（「我」页在用）：半透明玻璃 + 圆角 + 一点投影，透出后面的封面。
    /// 其它页面不传就还是原来的白卡片，不受影响。
    var glass: Bool = false
    /// 卡片底色：不传就是全站通用的 cardBg。
    /// 视界页要单独比其它页淡一点，所以它传自己的 discoverCardBg 进来。
    var bg: Color? = nil
    init(glass: Bool = false, bg: Color? = nil, @ViewBuilder content: () -> Content) {
        self.glass = glass
        self.bg = bg
        self.content = content()
    }

    var body: some View {
        if glass {
            VStack(spacing: 0) { content }
                .background {
                    ZStack {
                        GlassBackground(shape: RoundedRectangle(cornerRadius: 16, style: .continuous),
                                        opacity: UIConfig.num("meGlassAlpha", 0.62),
                                        edgeAlpha: UIConfig.num("meGlassEdge", 0.55),
                                        shadow: true,
                                        seed: 0.42,
                                        native: true)
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(C.cardBg.opacity(0.42))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, UIConfig.num("meGlassInset", 12))
                .padding(.bottom, 10)
        } else {
            VStack(spacing: 0) { content }
                .background {
                    ZStack {
                        bg ?? C.cardBg
                        /* 深色模式给平面卡片一层极轻的上明下暗纹理；
                           不改基础色，不靠重阴影，浅色模式完全不受影响。 */
                        if scheme == .dark {
                            LinearGradient(
                                colors: [Color.white.opacity(0.028), Color.clear, Color.black.opacity(0.025)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                    }
                }
        }
    }
}

/// 组与组之间的缝：参考图里是「细线 + 8px 灰缝 + 细线」三条，不是只有一条
struct GroupGap: View {
    /// 缝的颜色：默认跟页面底色；视界页传自己的底色进来，免得缝里透出另一种颜色
    var bg: Color? = nil
    var body: some View {
        /* 用户要求：**底栏也要有"透"的感觉** ——
           以前底栏是排在页面下面的（VStack），页面内容永远滚不到它后面，
           所以那层玻璃后面只有一片纯底色，看着就是实心一条。
           现在改成 ZStack：底栏浮在页面上，页面用 safeAreaInset 给它让位 ——
           内容照样能滚到底、而且会**从底栏玻璃后面穿过去**。 */
        ZStack(alignment: .bottom) {
            HairLine()
            Rectangle().fill(bg ?? C.pageBg).frame(height: L.groupGap)
            HairLine()
        }
    }
}
