import SwiftUI
import UniformTypeIdentifiers
import Combine
import UIKit
import QuickLook

/* ============================================================
   多图消息「展开成九宫格」的状态（本机记住）

   微信里那条「相册堆叠」点开就是九宫格、再点收起；
   这里把「哪几条消息是展开的」记在本机（UserDefaults），
   重进聊天、重开 App 都还是上次的样子 —— 不上传服务器，纯本机偏好。
   ============================================================ */
enum AlbumFold {
    private static let key = "chris.albumOpen"

    static func isOpen(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        return Set(UserDefaults.standard.stringArray(forKey: key) ?? []).contains(id)
    }

    static func setOpen(_ id: String, _ open: Bool) {
        guard !id.isEmpty else { return }
        var list = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        if open { list.insert(id) } else { list.remove(id) }
        /* 记账别无限涨：只留最近 200 条（超了就随便丢一些老的，不影响体验） */
        var arr = Array(list)
        if arr.count > 200 { arr = Array(arr.suffix(200)) }
        UserDefaults.standard.set(arr, forKey: key)
    }
}

/// 还没发出去的消息（离线时挂在列表里：转圈 = 发送中，红色感叹号 = 失败可重发）
struct PendingMsg: Identifiable, Hashable {
    var id: String
    var kind: String
    var content: String
    var mentions: [String] = []
    /// 引用卡片（JSON 字符串，发给服务端的 quote 字段）；没引用就是 nil
    var quoteJSON: String?
    var sending = false
    var failed = false
    var at = Date()

    /// 气泡里显示什么（非文字消息给个方括号标签，和会话列表一致）
    var preview: String {
        switch kind {
        case "text": return content
        case "image", "images": return "[图片]"
        case "audio": return "[语音]"
        case "file": return "[文件]"
        case "video", "livephoto": return "[视频]"
        case "location": return "[位置]"
        case "transfer": return "[转账]"
        case "redpacket": return "[红包]"
        case "gift": return "[礼物]"
        case "link": return "[链接]"
        /* 笔记卡片（收藏里的笔记转发到聊天）：列表/引用里显示「[笔记]」 */
        case "note": return "[笔记]"
        default: return "[" + kind + "]"
        }
    }
}

/// 聊天内容的总高度（用来发现「有东西在之后才变高」——见 messageList 里的说明）
private struct ChatContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 气泡玻璃「七彩回光」的相位：用消息 id 算一个稳定的 0…1 值 ——
/// 每条消息的回光角度都不一样（但刷新不会变）。
func bubbleSeed(_ id: String) -> Double {
    var h = 5381
    for u in id.unicodeScalars { h = (h &* 33) &+ Int(u.value) }
    return Double(abs(h % 997)) / 997.0
}
/// 气泡形状：药丸 / 圆角 + 左上/右上那个小尖角
struct BubbleShape: Shape {
    let mine: Bool
    var radius: CGFloat = 6
    var tail: Bool = true
    /// 药丸模式（液态玻璃那套）：圆角取「高度一半」但最多 18 ——
    /// 单行气泡 = 完整胶囊；多行也不会因为圆角太大把首行文字切掉。
    var pill: Bool = false

    func path(in rect: CGRect) -> Path {
        let r = min(pill ? min(rect.height / 2, 18) : radius, rect.height / 2, rect.width / 2)
        /* ⚠ 以前那个小尖角是**单独画一个三角形再 addPath 贴上去**的 ——
           两段路径各画各的，交界处会留一道缝/一条边，看着就是个"贴上去的三角"
           （用户 2026-10-11 说「这个尖角不对」）。
           现在**一笔画完**：圆角 + 侧面那个小钝角是同一个轮廓，和微信一样。 */
        let out: CGFloat = tail ? 5 : 0
        let h: CGFloat = 9            // 尖尖的高度
        let y0 = rect.minY + 6        // 尖尖从顶上 6pt 开始（微信也在偏上的位置）
        let x0 = rect.minX, x1 = rect.maxX, yA = rect.minY, yB = rect.maxY
        var p = Path()

        if mine {
            p.move(to: CGPoint(x: x0 + r, y: yA))
            p.addLine(to: CGPoint(x: x1 - r, y: yA))
            p.addQuadCurve(to: CGPoint(x: x1, y: yA + r), control: CGPoint(x: x1, y: yA))
            if out > 0 {
                p.addLine(to: CGPoint(x: x1, y: y0))
                p.addLine(to: CGPoint(x: x1 + out, y: y0 + h / 2))
                p.addLine(to: CGPoint(x: x1, y: y0 + h))
            }
            p.addLine(to: CGPoint(x: x1, y: yB - r))
            p.addQuadCurve(to: CGPoint(x: x1 - r, y: yB), control: CGPoint(x: x1, y: yB))
            p.addLine(to: CGPoint(x: x0 + r, y: yB))
            p.addQuadCurve(to: CGPoint(x: x0, y: yB - r), control: CGPoint(x: x0, y: yB))
            p.addLine(to: CGPoint(x: x0, y: yA + r))
            p.addQuadCurve(to: CGPoint(x: x0 + r, y: yA), control: CGPoint(x: x0, y: yA))
        } else {
            p.move(to: CGPoint(x: x1 - r, y: yA))
            p.addLine(to: CGPoint(x: x0 + r, y: yA))
            p.addQuadCurve(to: CGPoint(x: x0, y: yA + r), control: CGPoint(x: x0, y: yA))
            if out > 0 {
                p.addLine(to: CGPoint(x: x0, y: y0))
                p.addLine(to: CGPoint(x: x0 - out, y: y0 + h / 2))
                p.addLine(to: CGPoint(x: x0, y: y0 + h))
            }
            p.addLine(to: CGPoint(x: x0, y: yB - r))
            p.addQuadCurve(to: CGPoint(x: x0 + r, y: yB), control: CGPoint(x: x0, y: yB))
            p.addLine(to: CGPoint(x: x1 - r, y: yB))
            p.addQuadCurve(to: CGPoint(x: x1, y: yB - r), control: CGPoint(x: x1, y: yB))
            p.addLine(to: CGPoint(x: x1, y: yA + r))
            p.addQuadCurve(to: CGPoint(x: x1 - r, y: yA), control: CGPoint(x: x1, y: yA))
        }
        p.closeSubpath()
        return p
    }
}

/// 气泡底板（"高级"那点质感全在这一层）：
/// **液态玻璃药丸**：毛玻璃底（透出聊天背景）+ 品牌色染色 + 顶部高光/底压暗 + 玻璃亮边。
/// 全是填充和描边，不加外阴影 —— 一屏几十个气泡滚起来也不会掉帧。
struct BubbleFill: View {
    var mine: Bool
    var tail: Bool = true
    /// 药丸模式：圆头胶囊（不带尖角）。
    /// **默认关** —— 用户要的是微信同款「圆角 + 小尖尖」。
    /// 想换成圆头胶囊：后台/代码里把这个设成 true。
    var pill: Bool = false
    /// 七彩回光的相位（每条消息不一样，回光颜色就不同）
    var seed: Double = 0
    @Environment(\.colorScheme) private var scheme

    /// 玻璃的染色：自己发的是品牌绿（淡），收到的是中性白
    /// 浓度后台可调（ui.json）：bubbleTintMine / bubbleTintOther，越小越透
    private var tint: Color {
        if mine {
            /* ★ 用后台配的**气泡底色**（bubbleMineColor）来染，而不是写死的品牌绿 ——
               以前玻璃模式下这个染色是写死的，所以后台改「气泡底色」看着一点反应都没有
               （用户反馈的"改不了"）。现在改底色就能立刻看到变化。
               想让自己发的气泡完全不染色：把 bubbleTintMine 写成 0。 */
            return C.bubbleMine.opacity(UIConfig.num("bubbleTintMine", scheme == .dark ? 0.20 : 0.16))
        }
        return C.bubbleOther.opacity(UIConfig.num("bubbleTintOther", scheme == .dark ? 0.20 : 0.34))
    }
    private var gloss: Color {
        /* 气泡的"液态"高光：用户要求**关掉玻璃感** → 默认 0（不画）。
           想要那道光回来，后台 bubbleGloss 写回 0.1 / 0.26。 */
        return Color.white.opacity(UIConfig.num("bubbleGloss", 0))
    }
    private var shade: Color {
        Color.black.opacity(UIConfig.num("bubbleShade", 0))
    }
    /// 玻璃边：上亮下淡（像一块玻璃的倒角）
    private var edge: LinearGradient {
        let a = UIConfig.num("bubbleEdge", 0)
        return LinearGradient(colors: [Color.white.opacity(a),
                                       Color.white.opacity(a * 0.42)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        #if compiler(>=6.2)
        /* iOS 26 可以用**苹果原生液态玻璃**（真折射 + 镜面回光），
           但是：聊天页是一屏十几条气泡的长列表，每条都上原生实时折射玻璃的话，
           每滚动一帧都要重算十几块玻璃的折射 —— 手机会直接卡住，
           表现就是「聊天页滑不动 / 移不动」（用户实测反馈）。
           所以气泡**默认走我们自己的近似玻璃**（观感一样是液态玻璃，但帧率稳），
           想要原生的：后台 ui.json 写 bubbleNativeGlass = 1 就能即时打开，不用出包。 */
        if #available(iOS 26.0, *), UIConfig.num("bubbleNativeGlass", 0) > 0 {
            Color.clear
                .glassEffect(.regular.tint(mine ? C.green.opacity(UIConfig.num("bubbleNativeTint", 0.30)) : nil),
                             in: BubbleShape(mine: mine, tail: tail, pill: pill))
                /* 气泡本身不接手势：滚动、长按、点图都要能落到消息行上 */
                .allowsHitTesting(false)
        } else {
            legacyBubble
        }
        #else
        legacyBubble
        #endif
    }

    /// 旧系统（和旧编译链）上用我们自己画的近似玻璃
    private var legacyBubble: some View {
        ZStack {
            /* ① 毛玻璃底：聊天背景从气泡里透出来（液态玻璃的关键）。
                  后台把 ui.json 的 bubbleGlass 写成 0 就回到原来的实色气泡
                  （万一某些老机器上毛玻璃滑动掉帧，一个开关就能关）。 */
            /* 用户要求：**气泡关掉玻璃感** → 默认 0 = 走下面那条"纯色气泡"分支
               （不画毛玻璃材质）。想要液态玻璃，后台 bubbleGlass 写回 1。 */
            if UIConfig.num("bubbleGlass", 0) > 0 {
                /* 毛玻璃叠几层：苹果那层是"糊得很厉害但仍然通透"——
                   叠两层比一层明显更糊、更像液态玻璃。层数后台可调
                   （ui.json 的 glassLayers，默认 2；写 1 就是单层）。
                   整组再乘一个透明度 bubbleGlassAlpha：0.2 = 只留 20% 玻璃（80% 透明）。 */
                let layers = max(1, min(3, Int(UIConfig.num("glassLayers", 2))))
                ZStack {
                    ForEach(0..<layers, id: \.self) { _ in
                        BubbleShape(mine: mine, tail: tail, pill: pill).fill(.ultraThinMaterial)
                    }
                }
                /* 用户要求：**气泡关掉玻璃感** → 默认 0（整组高光/玻璃不画），
                   气泡就是纯色气泡。想恢复玻璃质感，后台把 bubbleGlassAlpha 写回 0.2。 */
                .opacity(UIConfig.num("bubbleGlassAlpha", 0))
            } else {
                BubbleShape(mine: mine, tail: tail, pill: pill)
                    .fill(mine ? C.bubbleMine : C.bubbleOther)
            }
            /* ② 染色：自己绿、对方白 */
            BubbleShape(mine: mine, tail: tail, pill: pill).fill(tint)
            /* ③ 高光和压暗合成一条渐变（省一半路径绘制） */
            BubbleShape(mine: mine, tail: tail, pill: pill)
                .fill(LinearGradient(stops: [
                    .init(color: gloss, location: 0),
                    .init(color: Color.clear, location: 0.42),
                    .init(color: Color.clear, location: 0.68),
                    .init(color: shade, location: 1)
                ], startPoint: .top, endPoint: .bottom))
            /* ④ 玻璃亮边（和顶栏/底栏同一套苹果质感）：左上亮、右下淡 */
            BubbleShape(mine: mine, tail: tail, pill: pill)
                .stroke(edge, lineWidth: 0.9)
            /* ⑤ 底部一条极淡暗边：给一点厚度 */
            BubbleShape(mine: mine, tail: tail, pill: pill)
                .stroke(LinearGradient(colors: [Color.clear,
                                                Color.black.opacity(scheme == .dark ? 0.22 : 0.05)],
                                       startPoint: .center, endPoint: .bottom),
                        lineWidth: 0.6)
            /* ⑥ 七彩回光：默认**关**（用户反馈"气泡不要有五颜六色"）。
               以前它跟着全局的 glassIridescent 走，而每条气泡的相位是按消息 id 算的，
               所以一屏消息是青、紫、粉、金、绿各不相同，看着很花。
               顶栏/底栏那种"一块玻璃"上的七彩还在（那是对的方向：玻璃边缘的反光）；
               气泡是内容，要干净 —— 只留白色玻璃亮边 + 淡染色（自己绿、对方白）。
               想开回来：后台 ui.json 写 bubbleIridescent = 1。 */
            if UIConfig.num("bubbleIridescent", 0) > 0 {
                BubbleShape(mine: mine, tail: tail, pill: pill)
                    .stroke(AngularGradient(
                        colors: [
                            Color(red: 0.32, green: 0.86, blue: 1.00).opacity(0.55),
                            Color(red: 0.72, green: 0.58, blue: 1.00).opacity(0.50),
                            Color(red: 1.00, green: 0.58, blue: 0.78).opacity(0.46),
                            Color(red: 1.00, green: 0.86, blue: 0.48).opacity(0.50),
                            Color(red: 0.55, green: 1.00, blue: 0.72).opacity(0.46),
                            Color(red: 0.32, green: 0.86, blue: 1.00).opacity(0.55)
                        ],
                        center: .center,
                        angle: .degrees(seed * 360)),
                            lineWidth: 1.1)
            }
        }
    }
}

enum PanelKind { case none, emoji, plus, gift, mention }

/// 聊天页的键盘避让开关。
/// 这页的输入栏是 safeAreaInset，系统那套自动避让在这儿没把栏顶起来（用户反馈键盘盖住输入栏），
/// 所以改成我们自己量键盘高度、把输入栏顶上去；既然自己顶，就要把系统那套关掉，
/// 否则会顶两遍（栏被顶到屏幕中间）。
/// 后台 ui.json 里把 chatKeyboardManual 写 0，就回到完全交给系统。
struct KeyboardLiftDisable: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.ignoresSafeArea(.keyboard, edges: .bottom)
        } else {
            content
        }
    }
}

struct ChatDetailView: View {
    @ObservedObject private var lang = LangStore.shared
    /// 这个会话单独设的聊天背景（「⋯ → 选择背景图」）：变了要马上刷新
    @ObservedObject private var chatBg = ChatBgStore.shared
    let chat: Chat

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var messages: [Message] = []
    /// 把聊天记录写本机的防抖任务（消息一变就排一次，1.2 秒内的多次变化合成一次写）
    @State private var persistTask: Task<Void, Never>?
    @State private var input = ""
    @State private var loading = true
    @State private var panel: PanelKind = .none
    @State private var plusItems: [PlusItem] = []
    /// 「＋ → 名片」：拉起来选一个联系人，选完把那个人的名片发出去
    @State private var showPickCard = false
    @State private var gifts: [Gift] = []
    /// App 内打开的网页（AI 发的淘宝 / 闪购卡片，没装 App 时用这个）
    @State private var web: WebURL?
    /// 好友分享来的小游戏：点卡片全屏打开（用运行时跑）
    @State private var runningMiniApp: MiniApp?
    /// 已经自动跳过的卡片（同一条只跳一次）
    @State private var autoOpened: Set<String> = []
    /* 长按消息的那套（和微信一样）：动作条 / 转发 / 多选 / 引用 */
    @State private var actionMessage: Message?
    @State private var forwardItems: [ForwardItem] = []
    @State private var showForward = false
    @State private var selectMode = false
    @State private var selected: Set<String> = []
    @State private var quote: Message?
    /// 撤回自己的消息之后：底上挂一条「重新编辑」，点一下把刚撤回的内容填回输入框
    /// （微信的规矩：撤回自己发的消息，5 分钟内可以重新编辑）
    @State private var reEditDraft: String?
    /// 阅后即焚：上次扫描时间（限流用，别每次刷新都扫）+ 已经烧过的消息 id（同一条不重复烧）
    @State private var lastBurnSweep = Date.distantPast
    @State private var burnedIds: Set<String> = []
    /// 每条消息在屏幕上的位置（长按弹的小方框要贴在它旁边）
    /* 每条消息在屏幕上的位置：长按弹菜单时要贴在那条旁边。
       ⚠ 这里故意用「普通类」而不是 @State —— 以前是用 preference 把整张位置表
       塞回 @State，列表一滚动就「改状态 → 整页重绘 → 又改状态」，
       消息一多就一顿一顿的（客户反馈的「消息一多就不丝滑」就是这个）。
       放到普通对象里就不触发重绘了，值照样是新的。 */
    @State private var frameBox = MsgFrameBox()
    /* 消息 id → 下标：showTime / gapAfter / isRunStart 都要用。
       以前每条消息都 firstIndex(where:)，500 条就是 25 万次比较，
       而且每条消息会问好几遍 —— 消息一多就卡。改成查表 O(1)。 */
    @State private var msgIndex: [String: Int] = [:]
    @State private var menuRect: CGRect = .zero

    @State private var showPhoto = false
    @State private var showCamera = false
    /// 长按「拍照」= 录一段视频（录完走和「从相册选视频」同一条发送路）
    @State private var showCameraVideo = false
    @State private var recordedVideo: URL?
    @State private var showLocation = false
    /* 位置：微信「＋ → 位置」会先问一句「发送位置 / 共享实时位置」 */
    @State private var showLocationMenu = false
    @State private var showLiveLocation = false
    /// 发送位置：用新的地图选点页（微信那种），不再用那个手填经纬度的表单
    @State private var showSendLocation = false
    @State private var showTransfer = false
    /// 键盘高度：自己量出来，把输入栏顶上去（系统那套避让在这页没生效，见下面 KeyboardLift）
    @State private var kbHeight: CGFloat = 0
    /// 红包：发红包页 / 拆红包 / 详情
    @State private var showSendRedPacket = false
    /// 发红包成功那一下的全屏红包雨（播完自己关）
    @State private var rainOn = false
    @State private var openRedPacket: RedPacketInfo? = nil
    @State private var redPacketDetail: String? = nil
    @State private var showGroupInfo = false
    @State private var showSearch = false
    @State private var showChatInfo = false
    @State private var showFile = false
    /// 发文件：默认走**我们自己那一页**（我的文件），管理里打开 filePickerSystem 才回到苹果的文件 App
    @State private var showMyFiles = false
    /// 表情商店（聊天面板里那个「＋」）
    @State private var showStickerStore = false
    /// 我在表情商店里加过的表情包 / 单个表情（表情面板「我的」那一屏用）
    @State private var myStickers = StickerMine()
    /// 「拍摄表情」：相机拍一张，加进「我添加的表情」
    @State private var showCaptureSticker = false
    /// 「＋ → 音乐」：从曲库挑一首发出去（音乐卡片）
    @State private var showPickMusic = false
    /// 已经不是好友了（我删了他 / 他删了我）：输入框换成微信那句「发送朋友验证」
    @State private var showApply = false
    @State private var applyNote = ""
    /// 点群里那条公告卡片：进一整页看全文
    @State private var announcePage = ""
    @State private var showAnnouncePage = false
    @State private var showCall = false
    /// 点了通话记录：先问一句「语音通话 / 视频通话」再拨（防误触）
    @State private var redialAsk: Message? = nil
    /// 点「视频通话」以后弹的那个「语音通话 / 视频通话」选择（微信就是这样）
    @State private var showCallChoice = false
    @State private var billInfo: TransferInfo?
    @State private var uploading = false
    /// 点开聊天里的图片：paths = 这个会话里所有图片，index = 点的那张
    @State private var viewer: PhotoPager.Item?
    /// 语音转文字的结果（messageId → 文字）和「正在识别」的那几条
    @State private var asrCache: [String: String] = [:]
    @State private var asrBusy: Set<String> = []
    /// 还没发出去的消息（离线先挂在列表里，联网自动重发 —— 微信就是这个逻辑）
    @State private var outbox: [PendingMsg] = []
    @State private var flushing = false
    /// 点开文件后的预览（下到本机再给系统 QuickLook）
    @State private var filePreview: FilePreviewData?
    /// 点公众号文章卡片 → 打开文章页（整页 sheet，不依赖外层导航栈）
    @State private var oaArticleId = ""
    @State private var showOaArticle = false
    /// 聊天内容的整体高度（用它判断「有没有东西在之后才变高」）
    @State private var lastContentHeight: CGFloat = 0
    /// 点头像 → 名片（自己的头像是自己的名片）
    @State private var cardUser: User?
    /// 点位置气泡打开的大地图页
    @State private var openLocation: LocationPoint?
    /// 点机器人（AI 助手 / 腾讯新闻）的头像 → 弹它的名片
    @State private var botCard = false
    /// 「星联世界」这个机器人：这一页默认给新闻排版（腾讯新闻那种），切一下才是对话
    @State private var newsMode = true

    /// 是不是「星联世界」那个新闻机器人（服务端在会话里给了 bot 字段）
    private var isStarWorld: Bool { chat.bot == "qqnews" }

    /* ---------------------------------------------------------- 长按消息的动作 */

    private func openActions(_ m: Message) {
        if selectMode { toggleSelect(m); return }
        menuRect = frameBox.frames[m.id] ?? .zero
        actionMessage = m
    }

    private func actionTitle(_ m: Message) -> String {
        let t = m.kindName == "text" ? m.body : "[" + ((m.kindName == "image" || m.kindName == "images") ? "图片" : m.kindName) + "]"
        return String(t.prefix(40))
    }

    private func actions(for m: Message) -> [MsgAction] {
        var list: [MsgAction] = [
            MsgAction(key: "copy", label: "复制", icon: "doc.on.doc"),
            MsgAction(key: "forward", label: "转发", icon: "arrowshape.turn.up.right")
        ]
        /* 朗读：文字消息、通话记录、AI 回复都能念（微信里长按也有这一项） */
        if readableText(m).isEmpty == false {
            list.append(MsgAction(key: "speak", label: "朗读", icon: "speaker.wave.2"))
        }
        /* 语音消息：长按可以「转文字」（和微信一样，识别在本机跑） */
        if m.kindName == "audio", !m.isRecalled {
            list.insert(MsgAction(key: "asr", label: "转文字", icon: "text.bubble"), at: 0)
        }
        if !m.isRecalled {
            list.append(MsgAction(key: "fav", label: "收藏", icon: "star"))
            list.append(MsgAction(key: "quote", label: "引用", icon: "text.quote"))
        }
        if m.senderId == myId, !m.isRecalled {
            list.append(MsgAction(key: "recall", label: "撤回", icon: "arrow.uturn.backward", danger: true))
        }
        list.append(MsgAction(key: "multi", label: "多选", icon: "checkmark.circle"))
        list.append(MsgAction(key: "del", label: "删除", icon: "trash", danger: true))
        if m.senderId != myId {
            list.append(MsgAction(key: "report", label: "举报", icon: "exclamationmark.bubble"))
        }
        return list
    }

    /// 这条消息能不能念、念什么（表格/卡片这类没文字的就不显示「朗读」）
    private func readableText(_ m: Message) -> String {
        if m.isCallRecord { return m.callText }
        switch m.kindName {
        case "text", "link": return m.body
        default: return ""
        }
    }

    private func run(_ a: MsgAction, on m: Message) {
        switch a.key {
        case "asr":
            transcribeMessage(m)
        case "speak":
            Speaker.shared.speak(readableText(m))
            app.show(Tr("正在朗读…"))
        case "copy":
            UIPasteboard.general.string = m.kindName == "text" ? m.body : "[" + m.kindName + "]"
            app.show(Tr("已复制"))
        case "forward":
            forwardItems = [ForwardItem(kind: forwardedKind(m), content: m.body)]
            showForward = true
        case "fav":
            Task {
                let fav = favoritePayload(m)
                let ok = await API.shared.addFavorite(kind: fav.kind,
                                                      content: fav.content,
                                                      title: chat.name,
                                                      from: displayName(m))
                app.show(ok ? Tr("已收藏") : Tr("收藏失败"))
            }
        case "quote":
            quote = m
        case "recall":
            recall(m)
        case "multi":
            selectMode = true
            selected = [m.id]
        case "del":
            messages.removeAll { $0.id == m.id }
            app.show(Tr("已删除"))
        case "report":
            report(m)
        default:
            break
        }
    }

    private func toggleSelect(_ m: Message) {
        if selected.contains(m.id) { selected.remove(m.id) } else { selected.insert(m.id) }
    }

    private func mySelected() -> [Message] {
        messages.filter { selected.contains($0.id) }
    }

    /// 转发 / 收藏时用什么 kind：单张图和九宫格都按「图」走，
    /// 不然会被当成文字发出去，对面看到的是一串 JSON。
    private func forwardedKind(_ m: Message) -> String {
        switch m.kindName {
        /* 这些都是「原样转发」才有意义的类型：文件、图片、九宫格、视频、实况、位置、链接。
           以前只有 image/images 走了原类型，文件被当成文字发出去 —— 对面看到的是一串 JSON。 */
        case "images", "image", "file", "video", "livephoto", "location", "link":
            return m.kindName
        /* 商城商品卡片也原样转（转出去还是卡片，收端点一下照样能进商品页） */
        case "mall":
            return "mall"
        default:
            return "text"
        }
    }

    /// 收藏夹只认 text / image / images / transfer：别的类型（文件、视频、位置…）
    /// 存一句人话进去，别把 JSON 塞到收藏里
    private func favoritePayload(_ m: Message) -> (kind: String, content: String) {
        let k = forwardedKind(m)
        if ["text", "image", "images", "transfer"].contains(k) { return (k, m.body) }
        var title = ""
        if let data = m.body.data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            title = (o["name"] as? String) ?? (o["title"] as? String) ?? (o["text"] as? String) ?? ""
        }
        let label: String
        switch k {
        case "file": label = Tr("文件")
        case "video": label = Tr("视频")
        case "livephoto": label = Tr("实况")
        case "location": label = Tr("位置")
        case "link": label = Tr("链接")
        default: label = k
        }
        return ("text", "[" + label + "]" + (title.isEmpty ? "" : " " + title))
    }

    private func multiForward() {
        let picked = mySelected()
        guard !picked.isEmpty else { return }
        forwardItems = picked.map { ForwardItem(kind: forwardedKind($0), content: $0.body) }
        showForward = true
    }

    private func multiFavorite() {
        let picked = mySelected()
        guard !picked.isEmpty else { return }
        Task {
            var n = 0
            for m in picked {
                let fav = favoritePayload(m)
                if await API.shared.addFavorite(kind: fav.kind,
                                                content: fav.content, title: chat.name, from: displayName(m)) { n += 1 }
            }
            app.show(Tr("已收藏") + " \(n) " + Tr("条"))
            selectMode = false
            selected = []
        }
    }

    private func multiDelete() {
        let ids = selected
        messages.removeAll { ids.contains($0.id) }
        app.show(Tr("已删除"))
        selectMode = false
        selected = []
    }

    @State private var focused = false
    @StateObject private var composerBridge = ChatComposerBridge()
    @ObservedObject private var realtime = Realtime.shared
    @ObservedObject private var recorder = VoiceRecorder.shared
    /// 输入框里那个小喇叭：语音转文字
    @StateObject private var dictation = Dictation()
    /// 话筒按钮：按下多久了（<0.22s 松手 = 语音转文字，按住 = 发语音）
    @State private var pressStart: Date?
    @State private var voiceStarting = false
    @State private var pushTask: Task<Void, Never>?
    /// 左上角返回箭头旁边那个未读数字（微信同位置）
    @State private var unreadHere = 0
    /// 点一下那个数字 = 滚回最新消息
    @State private var scrollTick = 0
    /// 键盘 / 面板引起的贴底（单独一个计数：这种贴底**不带动画**，
    /// 免得和系统键盘自己的动画叠成"被顶上去"）
    @State private var pinTick = 0
    /// 正在等待落稳再贴底的任务（新事件来了就取消上一个）
    @State private var pinTask: Task<Void, Never>? = nil
    @State private var hasOlder = false          // 上面还有更早的记录
    @State private var loadingOlder = false
    @State private var holdScroll = false        // 上翻加载时不要自动跳到底部
    @State private var atBottom = true           // 列表是不是已经到底（没到底就别跟着新消息硬滚）
    /// 「刚才确实贴在底部」——只在手指真的滑动时更新（内容自己变高不算）。
    /// 光看 atBottom 会误判：长文/大图排完版把底部哨兵顶出屏幕，atBottom 立刻变 false，
    /// 后面所有补底都被跳过 —— 这就是「有些号莫名其妙下沉」的根因。
    @State private var wasAtBottom = true
    /// 分页用的滚动代理（加载完更早的记录要把「原来第一条」钉回原位，位置不跳）
    @State private var scroller: ScrollViewProxy?
    /// 上滑自动加载的节流：0.4 秒内只触发一次，免得一屏里反复触发
    @State private var lastOlderLoad = Date.distantPast
    /// 刚选好的照片/视频/实况：先出预览页（原图、实况开关），点发送才真发
    @State private var pendingMedia: MediaSendSheet.Payload?
    /// 点视频气泡 / 长按实况 → 全屏播放这个视频
    @State private var videoToPlay: URL?
    /// 正在全屏播的那条视频消息的正文（转发时要原样发出去）
    @State private var videoPayload = ""
    /* 「对方正在输入…」（微信那种感知）：收到打字事件就显示，4 秒没有新事件就收起 */
    @State private var peerTyping = ""
    @State private var typingClear: Task<Void, Never>?
    /// 自己打字时上报的节流（最多 2 秒发一次，别刷屏）
    @State private var lastTypingSent = Date.distantPast
    /// 视频/实况正在压缩上传时显示的提示（微信也是先出一个「发送中」）
    @State private var sendingMedia = ""
    /// 发送中的视频/实况：封面 + 进度（0…1）—— 微信那种气泡里转圈带百分比
    @State private var sendingPreview: UIImage?
    @State private var sendProgress: Double = 0
    @State private var voiceMode = false         // 输入区是不是「按住说话」模式（微信：左边那个语音/键盘切换）

    /* 群里发消息时的「@某人」（微信：输入框里打 @ 就弹出群成员列表选人） */
    @State private var mentionMembers: [User] = []
    @State private var mentionQuery = ""
    /// 这条草稿 @ 了谁（发送时带给服务端；没选的清空）
    @State private var mentionIds: [String] = []
    /// 上一次的输入内容：用来判断刚敲进去的是不是「@」
    @State private var lastInputSnapshot = ""

    private var myId: String { app.me?.id ?? "" }
    private var isGroup: Bool {
        /* 2026-10-17 用户：「群聊里发起语音，对方收不到邀请」——
           排查下来服务端一条群信令都没收到，客户端却在打 1:1：
           说明这里判成了单聊。**不只看 type**：老数据 / 别的入口建的群
           type 字段可能缺失或不是 "group"，但成员数明显是多人群 ——
           成员 ≥ 3 一律按群聊处理（1:1 会话只有 2 个人，不会误判）。 */
        if chat.type == "group" { return true }
        if (chat.memberIds ?? []).count >= 3 { return true }
        return false
    }

    /// 顶栏标题：群聊和微信一样带上当前群人数「群名(9)」，单聊就是对方名字
    private var navTitle: String {
        guard isGroup else { return chat.name }
        let n = chat.memberCount ?? (chat.memberIds?.count ?? 0)
        return n > 0 ? chat.name + "(" + String(n) + ")" : chat.name
    }

    /// 顶栏标题：对方正在打字时显示「对方正在输入…」（和微信一样，一眼能感知）
    private var navTitleShown: String {
        guard !peerTyping.isEmpty else { return navTitle }
        return isGroup ? "有人正在输入…" : "对方正在输入…"
    }

    /// 自己在打字 → 每 2 秒上报一次（服务端只转给会话里的其他人）
    /// 对面收到就显示「对方正在输入…」，2 秒的上报间隔刚好把那个提示一直续着。
    private func reportTyping() {
        guard Date().timeIntervalSince(lastTypingSent) > 2.0 else { return }
        lastTypingSent = Date()
        Realtime.shared.sendJSON(["type": "typing", "chatId": chat.id])
    }

    /// 一对一会话里的对方 id（真人语音/视频通话要用它去呼叫）
    /// ⚠️ 以前是 `ids.first(where: { $0 != myId })`：万一这一刻 myId 还没加载出来（空串），
    /// 条件永远成立，就会返回名单里的**第一个人** —— 可能是我自己，也可能是机器人或
    /// 群里的其他人，而且完全没检查这个会话是不是「两个人」。
    /// 线上表现就是「电话打给了另一个人」。现在必须同时满足：
    /// ① 我自己的 id 已经知道 ② 这个会话恰好两个人 ③ 我在名单里 ④ 对方不是我自己。
    private var peerUserId: String? {
        let me = myId
        guard !me.isEmpty else { return nil }
        guard let ids = chat.memberIds, ids.count == 2, ids.contains(me) else { return nil }
        guard let other = ids.first(where: { $0 != me }), !other.isEmpty else { return nil }
        return other
    }

    /// 这通电话是不是就跟当前这个会话的人在打（是的话聊天页顶部挂提示条）
    private var callActiveHere: Bool {
        let c = CallCenter.shared
        guard c.phase.isBusy, let peer = peerUserId else { return false }
        return c.peerId == peer
    }

    private var callBarText: String {
        let c = CallCenter.shared
        switch c.phase {
        case .incoming:   return c.isVideo ? "邀请你视频通话" : "邀请你语音通话"
        case .outgoing:   return c.isVideo ? "正在等待对方接受视频通话" : "正在等待对方接受语音通话"
        case .connecting: return "正在接通…"
        case .active:     return c.isVideo ? "正在视频通话中" : "正在语音通话中"
        case .idle:       return ""
        }
    }

    /// 打给真人（WebRTC）：语音或视频
    private func startRealCall(video: Bool) {
        /* 群聊：＋ → 视频通话 → 选语音/视频，直接发起**群通话**（用户要求对齐微信；
           以前这里是写死挡住的：「群聊通话还没做，先在单聊里打」）。
           群语音走服务端混音、群视频走腾讯云 TRTC，两条都在 CallCenter 里。 */
        if isGroup {
            if CallCenter.shared.phase != .idle { app.show(Tr("正在通话中")); return }
            CallCenter.shared.resetIfStale()
            CallCenter.shared.startGroupCall(chatId: chat.id, title: chat.name ?? "", video: video)
            return
        }
        guard let peer = peerUserId else { app.show(Tr("找不到对方账号，先刷新一下会话")); return }
       if CallCenter.shared.phase != .idle { app.show(Tr("正在通话中")); return }
        /* 万一状态卡住了（异步回调把「通话中」又设回来过），这里先自愈一次，
           不然用户会「打不出去」：点拨打只弹一句「正在通话中」。 */
        CallCenter.shared.resetIfStale()
        if CallCenter.shared.phase != .idle { app.show(Tr("正在通话中")); return }
        /* 呼叫时带的名字/头像用「这个 peer 自己的」，不要用会话名 ——
           会话名可能是群名或者是上一次同步下来的旧值，就会显示成别人。 */
        let peerName = app.contact(for: peer)?.name ?? chat.name
        CallCenter.shared.start(peerId: peer, name: peerName, avatar: chat.avatar ?? "", video: video)
    }

    private func displayName(_ message: Message) -> String {
        if let n = message.senderName, !n.isEmpty { return n }
        return app.contact(for: message.senderId ?? "")?.name ?? ""
    }

    /// 这个会话**现在**是不是开着阅后即焚（以会话列表里那份为准，取不到才用快照）
    private var burnOn: Bool { (app.chats.first { $0.id == chat.id }?.burn ?? chat.burn) ?? false }
    /// 这一屏里有没有「带小火苗」的消息：有就说明这个会话在焚毁状态。
    /// ⚠ 光看会话列表那个 burn 标记不够 —— 对方刚打开开关、我这边会话列表还没刷新时
    /// 它是 false，于是**谁都不去扫**，到点的消息就一直挂在屏幕上
    /// （用户反复报的「阅后即焚消息依旧在」就是这么来的）。
    private var hasBurnMsg: Bool { messages.contains { $0.burn == true } }
    private var needBurnSweep: Bool { burnOn || hasBurnMsg }

    private var backgroundPath: String {
        /* ⚠ 阅后即焚要用**最新的**会话状态：`chat` 是进页面那一刻的快照，
           用户在信息页把开关打开以后快照里的 burn 还是老的（false），
           所以这里以「会话列表里那份」为准，取不到才退回快照 —— 这就是
           用户报「阅后即焚没生效」的第一个原因。 */
        /* 这个会话单独设过背景（聊天页「⋯ → 选择背景图」，只存本机）就用它 —— 和微信一样 */
        let per = ChatBgStore.shared.get(chat.id)
        if !per.isEmpty { return per == "auto" ? "" : per }
        let v = app.me?.chatBackground ?? "auto"
        if v.isEmpty || v == "auto" {
            // 自己没设就用服务器上配的默认背景（和网页版一致），都没有才留空白
            let def = app.defaultChatBackground
            return (def == "auto") ? "" : def
        }
        return v
    }

    var body: some View {
        ZStack {
            /* 聊天区铺满整屏（含顶栏、输入栏下面那两块），
               顶栏和输入栏用 iOS 原生超薄毛玻璃浮在上面，
               所以消息滚到上面/下面的时候会透过玻璃看到 —— 就是微信那种质感 */
            messageList
                // 点一下（哪怕是空白处）：表情/＋ 面板收回去，打字键盘也收起来
                // 再叠一层：手一滑动也收（微信就是这样）
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { dismissTyping() })
                /* 手一滑：收起键盘/面板，同时告诉「图片加载闸门」现在在滚动 ——
                   滚动中先别开始新的图片解码，等停下 0.4 秒再加载（微信就是这么做的）。
                   ⚠ 只在键盘 / 表情 / ＋ 面板真的开着的时候才让这个手势参与
                   （including: 掩码）—— 它和列表滚动是同一根手指的手势，
                   iOS 26 SDK 下一直挂着会跟 ScrollView 抢，表现为「聊天页滑不动」。
                   没开键盘的时候就完全交给滚动，手势一律不碰。
                   （滚动中暂停图片解码这件事交给下面 ScrollOffsetProbe 的 onDragChange，
                    它读的是底层 UIScrollView，不需要我们额外挂手势。） */
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8).onChanged { _ in
                        dismissTyping()
                        ScrollGate.shared.touch()
                    },
                    including: (focused || panel != .none) ? .all : .none
                )
                .background {
                    ZStack {
                        C.pageBg
                        if !backgroundPath.isEmpty {
                            RemoteImage(path: backgroundPath)
                                .id(backgroundPath)     // 换聊天背景立刻生效
                        }
                    }
                    .ignoresSafeArea()
                    /* 背景图是异步加载的：不加这一句，图片一到就会跟着「推进来」那段
                       导航动画一起缩一下（打开聊天页那种缩放感就是这么来的）。 */
                    .transaction { $0.animation = nil }
                }

            /* 「星联世界」机器人这一页：盖上一层新闻流（腾讯新闻那种排版）。
               底下还是原来的聊天页，切成「对话」就露出来；输入框一直在下面，
               所以还能继续问它「讲讲第 2 条」。 */
            if isStarWorld && newsMode {
                NewsFeedView(compact: true)
                    .zIndex(12)
            }

            /* 以前发视频时会在整屏盖一层「正在上传…」的遮罩 ——
               它把底下那个带进度的视频气泡整个挡住了（用户看到的就是"没有进度条，
               只有一行正在上传"）。微信不会盖住聊天页，进度就在气泡里，
               所以这里彻底去掉这层遮罩。 */

            /* 按住说话时中间那个浮层：麦克风 + 音量条 + 提示 */
            if recorder.recording {
                VoiceHUD(seconds: recorder.seconds, level: recorder.level,
                         willCancel: recorder.willCancel, willTranscribe: recorder.willTranscribe,
                         maxSeconds: recorder.maxSeconds)
                    .zIndex(50)
            }

            /* 诊断版专用：把"谁在动滚动"的日志盖在聊天页最上面。
               后台 data/ui.json 里写 chatScrollDiag = 1 才显示（正式版用户看不到）。 */
            if UIConfig.num("chatScrollDiag", 0) > 0 {
                VStack(spacing: 0) {
                    ChatScrollDiagView()
                    Spacer(minLength: 0)
                }
                .zIndex(60)
            }

            /* 消息区右下角那两个箭头（用户要求：**上下两个，和微信逻辑一致**）：
                 · ↑ 往上翻了才出现 → 点一下回到最早那一条
                 · ↓ 现在在翻历史时才出现 → 点一下回到最新；**有未读就显示「N 条新消息」**
                   （微信就是这么一个胶囊，带未读条数 + 向下箭头）
               两个都贴在输入框上方右下角，不挡气泡。 */
            if !atBottomNow {
                VStack {
                    Spacer(minLength: 0)
                    HStack {
                        Spacer(minLength: 0)
                        VStack(spacing: 8) {
                            /* ↑ 回到最早 */
                            if let firstMsg = messages.first?.id {
                                arrowButton {
                                    withAnimation(.easeOut(duration: 0.26)) {
                                        scroller?.scrollTo(firstMsg, anchor: .top)
                                    }
                                } icon: {
                                    Image(systemName: "chevron.up")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(C.label)
                                }
                            }
                            /* ↓ 回到最新（带未读条数） */
                            if let lastMsg = messages.last?.id {
                                Button {
                                    withAnimation(.easeOut(duration: 0.26)) {
                                        scroller?.scrollTo(lastMsg, anchor: .bottom)
                                    }
                                    unreadHere = 0
                                } label: {
                                    HStack(spacing: 5) {
                                        if unreadHere > 0 {
                                            Text("\(unreadHere) 条新消息")
                                                .font(pf(11.5, .medium))
                                                .foregroundColor(C.label)
                                        }
                                        Image(systemName: "chevron.down")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundColor(C.label)
                                    }
                                    .padding(.horizontal, unreadHere > 0 ? 11 : 0)
                                    .frame(minWidth: 34, minHeight: 34)
                                    .background(Capsule().fill(C.cardBg.opacity(0.96)))
                                    .overlay(Capsule().stroke(C.hairline, lineWidth: 0.5))
                                    .shadow(color: Color.black.opacity(0.18), radius: 8, y: 3)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.trailing, 12)
                        .padding(.bottom, 10)
                    }
                }
                .zIndex(55)
            }

        }
        /* 按住说话到 60 秒自动发出（微信就是这样），免得录个没完 */
        .onChange(of: recorder.seconds) { s in
            if recorder.recording, s >= recorder.maxSeconds { finishVoice() }
        }
        /* 进来先收掉"孤儿录音"：上一次按住在别处被打断了（切页/来电/系统打断），
           松手那一下没走到结束，录音器是全局的，那颗球就会一直挂在页面上
           （用户反馈的"彩色的球刷新完还在页面上"）。 */
        .onAppear {
            if recorder.stale {
                CrashCatcher.note("录音", "进聊天页发现孤儿录音，已清掉")
                recorder.forceStop()
            }
            if applyNote.isEmpty { applyNote = "我是" + (app.me?.nickname ?? "") }
        }
        /* 不是好友了：点「发送朋友验证」→ 填一句验证消息发出去（微信那个申请页的简化版） */
        .alert(Tr("发送朋友验证"), isPresented: $showApply) {
            TextField(Tr("验证消息"), text: $applyNote)
            Button(Tr("发送")) { sendApply() }
            Button(Tr("取消"), role: .cancel) { }
        } message: {
            Text(Tr("对方通过验证后，你们就能聊天了。"))
        }
        /* 键盘 / 表情面板 / ＋ 面板一弹出来，底部高度就变了 —— 列表很容易停在那不动，
           最后一条就被输入框盖住（线上反馈的「输入框一跳出来就覆盖文字」）。
           所以这里等动画走完，把列表重新贴到底。 */
        /* 点输入框（键盘起来）：微信会顺手把列表贴回最新一条，这里也一样 */
        .onChange(of: focused) { f in pinToBottomSoon(force: f) }
        .onChange(of: panel) { _ in pinToBottomSoon() }
        /* 顶栏：超薄毛玻璃（浅色模式下就是 iOS 那种浅浅的磨砂），背景图/消息从底下透过去 */
        .safeAreaInset(edge: .top, spacing: 0) {
            /* 必须显式 VStack：导航栏和下面那条「通话中」绿条要**上下排**。
               以前两个视图并列塞进 safeAreaInset，SwiftUI 会把它们叠在一起，
               绿条的背景就盖到导航栏/屏幕上（线上反馈的「一根绿条遮盖屏幕」）。 */
            VStack(spacing: 0) {
            /* 苹果那套：返回/标题/⋯ 各自一块玻璃（floating: true），顶栏其余地方全透明，
               消息滚到上面能直接看见 —— 和 iOS 26 的悬浮玻璃一致 */
            NavBar(title: navTitleShown, back: { dismiss() }, leftExtra: leftUnreadBadge,
                   floating: true) {
                HStack(spacing: 0) {
                    /* 「星联世界」这个机器人：右上角先给一个「对话 / 新闻」开关 ——
                       默认就是新闻排版（腾讯新闻那种），想跟它说话再切回对话 */
                    if isStarWorld {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) { newsMode.toggle() }
                        } label: {
                            Text(newsMode ? Tr("对话") : Tr("新闻"))
                                .font(pf(15.5))
                                .foregroundColor(C.label)
                                .frame(width: 52, height: 36)
                        }
                        .buttonStyle(.plain)
                    }
                    if !isStarWorld || !newsMode {
                        Button {
                            /* 微信逻辑：右上「⋯」不是弹菜单，而是进聊天信息页
                               —— 群聊进「群聊信息」，单聊进「聊天信息」 */
                            if isGroup { showGroupInfo = true } else { showChatInfo = true }
                        } label: {
                            Text("⋯")
                                .font(pf(22))
                                .foregroundColor(C.label)
                                .frame(width: 44, height: 36)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .background {
                /* 【取消了整条顶栏的背景】按用户要求：只有返回/标题/⋯ 三块玻璃，
                   其余地方全透明 —— 消息直接滚到状态栏下面（苹果 iOS 26 的样子）。
                   真要退回"整条毛玻璃"，后台 ui.json 里写 navGlassBar: 1 就行。 */
                if UIConfig.num("navGlassBar", 0) > 0 {
                    ZStack {
                        let topLayers = max(1, min(3, Int(UIConfig.num("glassLayers", 2))))
                        ForEach(0..<topLayers, id: \.self) { _ in
                            Rectangle().fill(.ultraThinMaterial)
                        }
                        Color.dyn(0xFFFFFF, 0x1C1C1E)
                            .opacity(max(0, min(0.5, UIConfig.num("glassAlpha", 0.8) - 0.5)))
                    }
                    .ignoresSafeArea(edges: .top)
                }
            }

            /* 通话中：顶栏下面挂一条绿提示，点一下回到通话界面（微信就是这样） */
            if callActiveHere {
                Button {
                    CallCenter.shared.restore()
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(Color.white.opacity(0.92)).frame(width: 7, height: 7)
                        Text(callBarText)
                            .font(pf(13.5))
                            .foregroundColor(.white)
                        Spacer(minLength: 0)
                        Text(Tr("回到通话 ›"))
                            .font(pf(13.5))
                            .foregroundColor(.white.opacity(0.9))
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(C.green)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selectMode {
                MultiSelectBar(count: selected.count,
                               onForward: { multiForward() },
                               onFavorite: { multiFavorite() },
                               onDelete: { multiDelete() },
                               onCancel: { selectMode = false; selected = [] })
            } else {
                composer
                    /* 键盘自己量出来的高度：把输入栏顶到键盘上方（用户反馈、也最稳）。
                       再减掉底部安全区那一条 —— 不然整个输入区会浮在键盘上方 34pt 的空隙里
                       （用户要求：快捷键那排要落在**键盘正上方那条空隙的位置**，不能悬空）。
                       想回到原来的"留一条空隙"：后台 ui.json 写 chatKbFlush 0。 */
                    .padding(.bottom, UIConfig.num("chatKeyboardManual", 1) > 0
                             ? max(0, kbHeight - (UIConfig.num("chatKbFlush", 1) > 0 ? L.safeBottom : 0))
                             : 0)
            }
        }
        /* 关掉系统的键盘避让：我们自己顶（不关的话两套叠加会顶两倍高） */
        .modifier(KeyboardLiftDisable(enabled: UIConfig.num("chatKeyboardManual", 1) > 0))
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { n in
            guard UIConfig.num("chatKeyboardManual", 1) > 0 else { return }
            guard let f = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let screenH = (UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.screen.bounds.height }.first) ?? UIScreen.main.bounds.height
            let h = max(0, screenH - f.origin.y)
            withAnimation(.easeOut(duration: 0.25)) { kbHeight = h }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.22)) { kbHeight = 0 }
        }
        /* 长按：贴着那条消息弹出一个小方框（微信那种，不是从底下滑上来的） */
        .overlay {
            GeometryReader { geo in
                if let m = actionMessage {
                    let g = geo.frame(in: .global)
                    let box = MsgMenuBox.size(actions(for: m).count)
                    let rect = menuRect == .zero
                        ? CGRect(x: g.midX, y: g.midY, width: 0, height: 0)
                        : menuRect
                    let above = (rect.minY - g.minY) > (box.height + 16)
                    let x = min(max(8, rect.midX - g.minX - box.width / 2),
                                max(8, geo.size.width - box.width - 8))
                    /* 贴着那条消息（原来隔 8pt，用户要求再贴紧一点）：间距后台可调
                       ui.json 的 msgMenuGap，默认 6。 */
                    let gap = UIConfig.num("msgMenuGap", 6)
                    let y = above ? (rect.minY - g.minY - box.height - gap)
                                  : min(geo.size.height - box.height - 8, rect.maxY - g.minY + gap)
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.03)
                            .ignoresSafeArea()
                            .onTapGesture { actionMessage = nil }
                        MsgMenuBox(actions: actions(for: m)) { a in
                            actionMessage = nil
                            run(a, on: m)
                        }
                        .offset(x: x, y: max(8, y))
                    }
                }
            }
            .zIndex(30)
        }
        .sheet(isPresented: $showForward) {
            ForwardPickerView(items: forwardItems) { }
                .environmentObject(app)
        }
        /* ⚠ 2026-10-11 先摘掉：用户报「进任何聊天都闪退」，而日志停在
           「8 准备打开」——怀疑就是这一层（进会话时构建的）. 摘掉验证一下，
           确认无关马上加回来（好友分享来的小游戏卡片就暂时打不开）。
        .fullScreenCover(item: $runningMiniApp) { g in
            GameWebPage(game: g).environmentObject(app)
        }
        */
        /* 点「视频通话」→ 微信那样弹「语音通话 / 视频通话」两个选择 */
        .confirmationDialog(Tr("音视频通话"), isPresented: $showCallChoice, titleVisibility: .hidden) {
            Button(Tr("语音通话")) { startRealCall(video: false) }
            Button(Tr("视频通话")) { startRealCall(video: true) }
            Button(Tr("取消"), role: .cancel) { }
        }
        /* 点通话记录回拨：先确认再拨 —— 以前点一下就拨出去，在列表上划一下就可能误拨
           （用户反馈「聊天页的电话有时一直会误触」）。记录本来是视频就把它排前面。 */
        .confirmationDialog(redialTitle, isPresented: Binding(
            get: { redialAsk != nil },
            set: { if !$0 { redialAsk = nil } }
        ), titleVisibility: .visible) {
            if redialAsk?.isVideoCall == true {
                Button(Tr("视频通话")) { startRedial(true) }
                Button(Tr("语音通话")) { startRedial(false) }
            } else {
                Button(Tr("语音通话")) { startRedial(false) }
                Button(Tr("视频通话")) { startRedial(true) }
            }
            Button(Tr("取消"), role: .cancel) { redialAsk = nil }
        }
        /* 右上「⋯」进的是聊天信息页（微信那套）；页里能打语音/视频、免打扰、置顶、
           查记录、换背景、清空、删除 —— 见 DirectChatInfoView */
        /* 用 push 整页打开（不再是半屏 sheet）—— DirectChatInfoView 本来就是按整页做的
           （自带 NavBar / 返回 / 侧滑返回）。⚠ 全屏打开聊天那条路（扫码进群 / 点推送）
           在 MainTab 里已经套了 NavigationStack，不然这里会什么都不弹。 */
        .navigationDestination(isPresented: $showChatInfo) {
            DirectChatInfoView(chat: chat).environmentObject(app)
        }
        .swipeBack { dismiss() }
        .hidesTabBar()
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showPhoto) {
            /* 照片入口：图片 / 视频 / 实况都支持（老的 PhotoPicker 只认图片，选视频/实况没反应）。
               选完先出「发送预览页」（原图 / 实况 两个开关），点发送才真发 —— 和微信一致。 */
            /* maxImages = 9：一次能挑多张；挑到 2 张以上就合成一条「九宫格」（和微信一样） */
            MediaPicker(onImage: { image in pendingMedia = .image(image) },
                        onVideo: { url in
                            Task {
                                let cover = await MediaTool.firstFrame(url)
                                pendingMedia = .video(url, cover)
                            }
                        },
                        onLive: { image, url in pendingMedia = .live(image, url) },
                        maxImages: 9,
                        onImages: { list in
                            if list.count > 1 { pendingMedia = .images(list) }
                            else if let one = list.first { pendingMedia = .image(one) }
                        },
                        /* 多选里混了实况照片：给用户一句话说清楚（多选那条路没有「实况」开关） */
                        onNotice: { msg in app.show(msg) })
        }
        .sheet(isPresented: $showCamera) {
            /* 相机里自带「照片 / 视频」切换（和微信那个拍摄页一样）：
               拍照片走原来那条路，录了视频走视频那条路 —— 这样"按住拍视频"
               就算没生效，也能在相机里自己切到视频录。 */
            CameraPicker(onPick: { image in sendImage(image) },
                         onVideo: { url in sendRecordedVideo(url) })
        }
        /* 长按「拍摄」→ 拍小视频：**录完直接发**（微信就是这样，不再走「原图/实况」
           那页预览；点一下拍摄还是拍照片）。 */
        .sheet(isPresented: $showCameraVideo, onDismiss: {
            guard let url = recordedVideo else { return }
            recordedVideo = nil
            sendRecordedVideo(url)
        }) {
            CameraVideoPicker { url in
                recordedVideo = url
                showCameraVideo = false
            }
        }
        /* 「＋ → 名片」：选一个联系人 → 把那个人的名片发出去（微信就是这么发的） */
        .sheet(isPresented: $showPickCard) {
            PickContactView { u in sendCard(u) }
                .environmentObject(app)
        }
        .sheet(isPresented: $showLocation) {
            LocationSheet { payload in send(kind: "location", content: payload) }
        }
        /* 位置：发送位置 / 共享实时位置（微信那一套） */
        .confirmationDialog(Tr("位置"), isPresented: $showLocationMenu, titleVisibility: .visible) {
            Button(Tr("发送位置")) { showSendLocation = true }
            Button(Tr("共享实时位置")) { showLiveLocation = true }
            Button(Tr("取消"), role: .cancel) { }
        }
        .sheet(isPresented: $showSendLocation) {
            SendLocationView { payload in send(kind: "location", content: payload) }
        }
        .sheet(isPresented: $showLiveLocation) {
            LiveLocationView(chat: chat) {
                send(kind: "text", content: "📍 我发起了共享实时位置，点＋→位置→共享实时位置就能加入")
            }
            .environmentObject(app)
        }
        .sheet(isPresented: $showTransfer, onDismiss: {
            /* 关掉这页就重新拉一次消息：转账卡片必须马上出现在会话里
               （以前要退出去再进来才看得到） */
            Task { await load(initial: false); await app.loadChats() }
        }) {
            /* 转账这套按微信重做：转账页（自定义数字键盘）→ 收银台（安全键盘 + 6 位密码）
               → 输完直接回聊天看转账卡片 */
            TransferView(chat: chat, onPaid: {
                Task { await load(initial: false); await app.loadChats() }
            })
        }
        /* 红包：发红包（半屏）→ 塞钱进红包要支付密码；抢 / 看详情各自一套 */
        .sheet(isPresented: $showSendRedPacket) {
            RedPacketSendView(chat: chat) { _ in
                /* 发出去的那一下：全屏**红包雨**（金红渐变、带摆动和淡出），
                   播完自己关掉。不想看：后台写 redPacketRain = 0。 */
                if UIConfig.num("redPacketRain", 1) > 0 { rainOn = true }
                Task { await load(initial: false); await app.loadChats() }
            }
            .environmentObject(app)
        }
        .overlay {
            if rainOn {
                RedPacketRain(duration: UIConfig.num("redPacketRainSec", 3.2)) { rainOn = false }
                    .zIndex(30)
            }
        }
        .fullScreenCover(item: $openRedPacket) { info in
            RedPacketOpenView(info: info, myId: myId) { id in
                redPacketDetail = id
            }
            .environmentObject(app)
        }
        .sheet(isPresented: Binding(
            get: { redPacketDetail != nil },
            set: { if !$0 { redPacketDetail = nil } }
        )) {
            if let id = redPacketDetail {
                RedPacketDetailView(id: id, myId: myId).environmentObject(app)
            }
        }
        .fullScreenCover(isPresented: $showCall) {
            AICallView(chat: chat)
        }
        .fullScreenCover(item: $viewer) { item in
            /* 看大图：底下跟微信一样带「转发 / 保存」那一排 */
            PhotoPager(paths: item.paths, startIndex: item.index, showActions: true) { viewer = nil }
        }
        .modifier(TapAvatarCard(cardUser: $cardUser))
        .sheet(isPresented: $botCard) {
            BotCardView(chat: chat).environmentObject(app)
        }
        .sheet(item: $web) { SafariSheet(url: $0.url) }
        /* 聊天里的链接：用 App 内置浏览器打开（微信就是这样），不跳出 App。
           其它 scheme（电话、地图、App 跳转）交回系统处理。 */
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "http" || url.scheme == "https" {
                web = WebURL(url: url)
                return .handled
            }
            return .systemAction
        })
        /* 点位置气泡 → 整页大地图（微信那样） */
        .sheet(item: $openLocation) { p in
            LocationDetailView(point: p).environmentObject(app)
        }
        .onChange(of: messages.count) { _ in autoOpenShopCard() }
        /* 群聊的「⋯」→ 聊天信息，同样是 push 整页 */
        .navigationDestination(isPresented: $showGroupInfo) {
            GroupInfoView(chat: chat).environmentObject(app)
        }
        .sheet(isPresented: $showSearch) { ChatSearchView(chat: chat) }
        /* 表情商店：关掉的时候把「我的表情」重新拉一遍（刚加的表情包要立刻出现在面板里） */
        .sheet(isPresented: $showStickerStore, onDismiss: { Task { await loadMyStickers() } }) {
            StickerView().environmentObject(app)
        }
        /* 拍摄表情：**单独一整页**（和微信一致：点了就进相机那一页）。
           页里是一小块小相机 + 特效 tab + 快门；拍完自动抠背景，
           「使用」之后走同一条上传 / 加进「我添加的表情」的路。 */
        .fullScreenCover(isPresented: $showCaptureSticker) {
            StickerCamera { image in captureSticker(image) }
        }
        /* ＋ → 音乐：挑一首发出去（发的是音乐卡片） */
        .sheet(isPresented: $showPickMusic) {
            ListenView(sendTo: chat) { t in sendMusic(t) }
                .environmentObject(app)
        }
        /* 点群里那条群公告卡片：一整页看全文（微信也是这样） */
        .fullScreenCover(isPresented: $showAnnouncePage) {
            GroupAnnounceView(text: announcePage, groupName: isGroup ? chat.name : "")
        }
        .hidesTabBar()
        .sheet(isPresented: Binding(
            get: { billInfo != nil },
            set: { if !$0 { billInfo = nil } }
        )) {
            if let info = billInfo {
                BillDetailView(chat: chat, info: info)
            }
        }
        /* 选完照片/视频/实况 → 发送预览页（原图 / 实况 开关），点发送才真发 */
        .sheet(isPresented: Binding(get: { pendingMedia != nil },
                                    set: { if !$0 { pendingMedia = nil } })) {
            if let p = pendingMedia {
                MediaSendSheet(payload: p) { live, original in
                    let payload = p
                    pendingMedia = nil
                    sendMedia(payload, live: live, original: original)
                }
            }
        }
        /* 点视频气泡 / 长按实况 → 全屏播放 */
        .sheet(isPresented: Binding(get: { videoToPlay != nil },
                                    set: { if !$0 { videoToPlay = nil } })) {
            /* 全屏播放：把这条视频消息的正文一起传进去 ——
               里面那根进度条旁边的「转发」就是靠它把视频**原样转发**出去的。 */
            if let u = videoToPlay {
                VideoPlayerSheet(url: u, forwardContent: videoPayload)
                    .environmentObject(app)
            }
        }
        /* 点文件气泡 → 系统预览（QuickLook：pdf/word/excel/图片/文本都能看，还能分享） */
        .sheet(item: $filePreview) { f in
            FilePreviewSheet(name: f.name, local: f.local)
        }
        /* 点公众号文章卡片 → 文章页 */
        .sheet(isPresented: $showOaArticle) {
            NavigationStack { ArticleView(articleId: oaArticleId).environmentObject(app) }
        }
        /* 微信那样：文件可以一次选好几个，一个一个发过去 */
        .fileImporter(isPresented: $showFile, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { sendFiles(urls) }
        }
        /* 我们自己的文件选择页（管理里 filePickerSystem = 0 时走它；
           里面底下那颗按钮随时能切回苹果的文件 App） */
        .sheet(isPresented: $showMyFiles) {
            MyFilesPickerView(onPick: { f in sendExistingFile(f) },
                              onSystemPicker: {
                                  /* 等这一页收完再弹苹果那个（两个一起弹 iOS 会打架） */
                                  DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showFile = true }
                              })
                .environmentObject(app)
        }
        .task(id: chat.id) {
            HitchWatch.shared.start("聊天页")
            loadOutbox()                       // 上次没发出去的还挂着
            await load(initial: true)
            await flushOutbox()                // 进页面先试着把欠的发出去
            await API.shared.markRead(chatId: chat.id)
            /* 进这个会话：把它挂在通知中心/锁屏上的通知撤掉（微信也是这样，看完就没了） */
            LocalNotify.clearChat(chat.id)
            await app.loadChats()
            if plusItems.isEmpty { plusItems = (try? await API.shared.plusPanel()) ?? [] }
            await loadMyStickers()
            /* 表情图库（服务器上那套图片表情包）：拉一次缓在本机，面板底下那排要用 */
            await StickerCatalog.shared.loadIfNeeded()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled { break }
                await load(initial: false)
                await flushOutbox()            // 离线期间攒下的，联网后自己补发
                /* 阅后即焚：**停在会话里也要烧**（以前只在进页面/刷新时扫一次，
                   用户停在聊天页等一分钟什么都不会发生）。每 15 秒顺手扫一遍。 */
                if needBurnSweep {
                    let gone = await API.shared.burnSweep(chatId: chat.id)
                    if !gone.isEmpty { burnAway(gone) }
                }
            }
        }
        /* 阅后即焚的**快扫**：屏幕上还有小火苗的时候每 3 秒扫一次 ——
           倒计时一归零，服务端那边其实已经删了，我们立刻把这条从列表收走
           （不用等上面那个 15 秒的轮询，用户看到的就是「到点真的消失」）。 */
        .task(id: chat.id) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { break }
                guard hasBurnMsg else { continue }
                let gone = await API.shared.burnSweep(chatId: chat.id)
                if !gone.isEmpty { burnAway(gone) }
            }
        }
        // 服务器一推消息，立刻拉一次（不用等轮询）
        /* 网络一恢复（离线提示消失的那一刻），马上把欠着的消息补发出去 */
        .onChange(of: app.offline) { off in
            if !off { Task { await flushOutbox() } }
        }
        .onChange(of: realtime.event) { _ in
            let ev = realtime.event
            /* 对方正在打字（服务端只把 typing 转给会话里的其他人，所以这里收到的一定是对面）：
               顶栏显示「对方正在输入…」，5 秒没有新事件就收起 —— 和微信一样能感知到。
               （对面每隔 2 秒会再报一次，所以只要还在打字就一直亮着。） */
            if ev.type == "typing", ev.chatId == chat.id {
                peerTyping = "对方"
                typingClear?.cancel()
                typingClear = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if !Task.isCancelled { peerTyping = "" }
                }
            }
            /* 对面的消息到了：立刻把「正在输入…」收起来 —— 微信也是消息一到就没了，
               以前会一直挂到 4 秒超时，看着像对面还在打字。 */
            if ev.type == "message", ev.chatId == chat.id {
                typingClear?.cancel()
                peerTyping = ""
            }
            /* 有人拍一拍（我被拍的时候震得重一点）：比"等消息拉回来"更即时 */
            if ev.type == "pat", ev.chatId == chat.id {
                UIImpactFeedbackGenerator(style: ev.patTo == myId ? .medium : .light).impactOccurred()
            }
            /* 阅后即焚：服务端到点销毁了那几条 → 这一页立刻带着动画把它们收走
               （只加代码，不动视图层；首帧有 DeferredChatView 那层轻占位挡着） */
            if ev.type == "burn", ev.chatId == chat.id, !ev.burnIds.isEmpty {
                burnAway(ev.burnIds)
            }
            // 一下子来很多条时合并成一次刷新，别把手机刷爆
            pushTask?.cancel()
            pushTask = Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
                /* 打点（各 1 分钟最多一次）：聊天页每次「推送到达 → 刷新」都记一笔，
                   万一又被系统 watchdog 杀掉（无崩溃栈），最后一条就能告诉我们是死在
                   刷新开头还是刷新中间 —— 2026-10-12 用户报「190 推送过来会闪退」。 */
                AppLog.error("聊天页刷新开", "事件=" + ev.type + " 条数=\(messages.count)")
                await load(initial: false)
                AppLog.error("聊天页刷新完", "条数=\(messages.count)")
            }
        }
        /* 聊天记录一变就排一次本机落盘（防抖，见 schedulePersist） */
        .onChange(of: messages) { _ in schedulePersist() }
        /* 离开会话时立刻存一次，别等防抖 */
        .onDisappear {
            persistTask?.cancel()
            persistTask = nil
            LocalStore.saveChat(chat.id, messages)
        }
    }

    /* ---------------------------------------------------------- 消息列表 */

    private var messageList: some View {
        /* 「提前一屏开始拉」：最早的这十几条随便哪条一露面，就说明用户快到顶了 ——
           这时候就去拉上一页，等他真滑到顶，内容已经在手里了（这才是微信那种无感）。
           以前是等最顶上那条出现才拉，等于到了顶还要等一个网络来回。 */
        let nearTopIds = Set(messages.prefix(12).map { $0.id })
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    /* 上面还有更早的记录：**顶部什么都不显示**（要的就是"无感上滑"）——
                       滑到顶，更早的记录自己就续上来，不出现任何「查看更早/加载中」的字，
                       也没有转圈。这个 1pt 的透明哨兵就是触发器（它一进可视区就加载下一页）。 */
                    if hasOlder {
                        Color.clear
                            .frame(height: 1)
                            .onAppear { autoLoadOlder() }
                    }
                    ForEach(messages) { message in
                        messageBlock(message)
                            .id(message.id)
                            /* 最早的那条露出来了 = 用户已经把列表滑到顶：
                               自动把更早的一页续上（和微信一样，往上滑就是无限的历史） */
                            .onAppear {
                                if nearTopIds.contains(message.id) { autoLoadOlder() }
                                /* 最后一条露出来了 = 已经在底部（比底部那个 1pt 哨兵更可靠） */
                                if message.id == messages.last?.id { atBottom = true }
                            }
                    }
                    /* 还没发出去的（发送中 / 发失败的红叹号）挂在最后面 —— 微信就是这样 */
                    ForEach(outbox) { p in
                        pendingBubble(p)
                    }
                    /* 视频/实况在压缩上传：先占一行「发送中」，别让人干等（微信也是这样） */
                    if !sendingMedia.isEmpty {
                        HStack(spacing: 8) {
                            Spacer(minLength: 0)
                            /* 微信那样：立刻出一个视频气泡（封面），中间转圈 + 百分比 */
                            SendingVideoBubble(cover: sendingPreview,
                                               progress: sendProgress)
                        }
                        .id("__sending")          // 发视频时滚到它（见 scrollToEnd）
                        .padding(.bottom, 12)
                        .padding(.trailing, 6)
                    }
                    if loading && messages.isEmpty {
                        ProgressView().padding(.top, 40)
                    }
                    /* 底部哨兵：它必须在**整段内容的最最后**（贴底滚动、判断"是不是到底了"都靠它）。
                       只有到底了才允许跟着新消息自动滚 —— 不然你正往上翻旧消息时
                       来一条新消息，列表会被硬拽到底，手感上就是「卡住划不动」。 */
                    Color.clear
                        .frame(height: 1)
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                        .id("__bottom")
                    /* 底下留一点点空地：最后一条气泡不要贴死在输入框上。
                       （群聊里最后一条上面还带发送人昵称，行更高，贴到底时
                         文字那截有时会被输入框压住 —— 留 8pt 就稳了） */
                    Spacer().frame(height: 8)
                }
                .padding(L.msgPad)
                /* 内容整体高度：只要有东西（图片、表情、长文重排、视频封面…）在之后才定型，
                   高度就会变大 —— 本来贴底的这时候必须再贴一次，否则底部就被顶到屏幕外，
                   用户看到的就是「消息掉底」。这一条是兜底的通用规则，不挑消息类型。 */
                .background(GeometryReader { geo in
                    Color.clear.preference(key: ChatContentHeightKey.self, value: geo.size.height)
                })
                .onPreferenceChange(ChatContentHeightKey.self) { h in
                    let grew = h > lastContentHeight + 0.5
                    lastContentHeight = h
                    if grew, atBottomNow {
                        scrollToEnd(proxy, animated: false)
                        /* 长文/大图是**分几次**长高的（先出框、再排完版）：
                           跟着补两下，别让最新一条被一点点顶到屏幕外面。 */
                        for d in [0.1, 0.3, 0.7] {
                            DispatchQueue.main.asyncAfter(deadline: .now() + d) { repinIfAtBottom() }
                        }
                    }
                }
                /* 挂一个看不见的探针：把底层的 UIScrollView 交给 ChatScrollHandle。
                   贴底用它直接设偏移最可靠 —— 懒加载列表里 scrollTo 有时会空转，
                   那正是「发了消息不跳到最新」的原因。 */
                .overlay(alignment: .topLeading) {
                    ScrollOffsetProbe(onChange: { _ in
                        /* 只在「手指在滑 / 松手惯性还没停」时重算：
                           内容自己变高（图片解码完、长文排完版）不算你翻页了 ——
                           否则长文一排版就被判成「你翻走了」，再也不补底 = 下沉。 */
                        if ChatScrollHandle.shared.moving, let g = ChatScrollHandle.shared.gap {
                            wasAtBottom = g <= 16
                        }
                    }, onDragChange: { dragging in
                        /* 手指一按下滑动：告诉「图片加载闸门」先别再开新的图片解码，
                           停下 0.4 秒再继续（微信也是这么做的）。
                           这件事以前挂在 SwiftUI 的 DragGesture 上，会和滚动抢手势；
                           改成读底层 UIScrollView 的 isDragging，一点都不碰手势。 */
                        if dragging { ScrollGate.shared.touch() }
                    }, onSizeChange: {
                        /* 内容尺寸变了 = 长文排完版 / 图片解码完 / 来了新消息。
                           本来贴在底部的就再贴一次（这就是治「有些号下沉」的那一下：
                           以前要等 SwiftUI 的偏好值回调，长内容那一瞬间会被漏掉）。 */
                        guard wasAtBottom, !holdScroll else { return }
                        if ChatScrollHandle.shared.moving { return }   // 你手正按着，别抢
                        ChatScrollDiag.shared.note("内容变高 → 哨兵贴底")
                        ChatScrollHandle.shared.pinToBottom(animated: false)
                    })
                        .frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _ in
                /* 只有「已经到底了」或者「刚才是自己发的」才跟着滚；
                   而且不用动画 —— 动画会和正在拖动的手势打架（就是那个「划不动」）。 */
                backfillVoiceText()
                ChatScrollDiag.shared.note("消息数变了=\(messages.count) atBottom=\(atBottomNow ? 1 : 0)")
                guard !holdScroll else { return }
                guard atBottomNow || messages.last?.senderId == myId else { return }
                scrollToEnd(proxy, animated: false)
                /* 新消息也可能是长文/大图：排完版再补两次 */
                for d in [0.08, 0.25, 0.6] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + d) { repinIfAtBottom() }
                }
            }
            .onChange(of: scrollTick) { _ in
                atBottom = true                       // 用户自己点的「回到底部」
                wasAtBottom = true
                scrollToEnd(proxy, animated: true)
            }
            /* 键盘 / 面板引起的贴底：不带动画，直接贴（见 pinToBottomSoon 的说明） */
            .onChange(of: pinTick) { _ in
                scrollToEnd(proxy, animated: false)
            }
            /* 键盘上下移（弹起 / 收起 / 换输入法都算）：等它落稳，再贴一次底。
               只给「本来就在底部」的会话补，正往上翻历史时不动。 */
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)) { _ in
                ChatScrollDiag.shared.note("键盘位置变了")
                pinToBottomSoon()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                ChatScrollDiag.shared.note("键盘弹起")
                pinToBottomSoon()
            }
            /* 从后台回来（锁屏 / 切走再回来）布局可能已经变了：在底部的照样贴回去 */
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                ChatScrollDiag.shared.note("回前台 atBottom=\(atBottomNow ? 1 : 0)")
                if atBottomNow { scrollToEnd(proxy, animated: false) }
            }
            .onAppear {
                ChatScrollDiag.shared.note("onAppear 打开会话")
                /* 启动/进会话打点：连 ChatDetailView 都没到，就说明崩在上一层 */
                CrashCatcher.note("聊天页", "9 页面出现 " + chat.id)
                scroller = proxy          // 上翻加载完要靠它把位置钉住
                backfillVoiceText()       // 以前转过的语音，把文字贴回来
                wasAtBottom = true        // 刚打开会话 = 贴在底部（后面按手指滑动再更新）
                atBottom = true
                scrollToEnd(proxy, animated: false)
                /* 图片/表情是**异步解码**的：行高要等解码完才定型。
                   本来贴底的，这会儿内容会长高，底部就被顶到屏幕外面（用户说的「掉底」）。
                   所以之后几个时间点再悄悄补几次贴底。 */
                for d in [0.12, 0.35, 0.8, 1.5] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + d) { repinIfAtBottom() }
                }
                /* 打点：打开会话 1.8 秒后，「最后一条离底部还剩多少 pt」——
                   ≈0（或负数）就是对的，正数就是被压在输入框下面多少。往后这个问题靠数据说话。 */
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    CrashCatcher.note("聊天页",
                        "打开 \(chat.id) 条数=\(messages.count) 内容高=\(Int(lastContentHeight))"
                        + " 离底=\(Int(ChatScrollHandle.shared.gap ?? -999))"
                        + " 哨兵=\(atBottom) 跟随=\(wasAtBottom)")
                }
            }
        }
    }

    /// 滑到顶了：自动加载更早的记录（微信也是滑到顶就自动续，不用点）
    private func autoLoadOlder() {
        guard hasOlder, !loadingOlder, !loading else { return }
        guard Date().timeIntervalSince(lastOlderLoad) > 0.25 else { return }
        lastOlderLoad = Date()
        Task { await loadOlder() }
    }

    /// 键盘 / 面板弹出来会改变底部高度：本来就在底部的，等动画走完再贴回去
    /// （不然最后那条消息会被输入框盖住 —— 就是「输入框一跳出来就覆盖文字」）
    private func pinToBottomSoon(force: Bool = false) {
        /* ⚠ 先记下"现在是不是贴底的"：键盘一起来可视区就变矮，
           底部哨兵会瞬间消失、把 atBottom 打成 false —— 如果等 0.28 秒后再读它，
           就永远不会补底，「底下看不到的字」就是这么来的。
           另外每个事件只补一次（后一次取消前一次），落稳后不带动画地贴：
           以前是每个系统事件补 5 次、次次带动画，键盘动画那 0.25 秒里系统连发好几个事件，
           列表被一段一段往上顶 —— 就是用户说的「像是故意顶上来的、不丝滑」。 */
        var stick = force || atBottomNow
        /* ★ 再用**实时的离底距离**核对一遍（直接读底层 UIScrollView，不靠哨兵）：
           哨兵在懒加载列表里会误判 —— 人已经翻上去很远了，哨兵还被预渲染着，
           atBottomNow 就还是 true，于是键盘一弹、图片一解码就把人硬拽回底部
           （用户反馈的"部分用户会出现聊天页自动滚动"）。
           离底超过 200pt 一律不贴。force（自己发消息）不受这条限制。 */
        if !force, let g = ChatScrollHandle.shared.gap, g > 200 { stick = false }
        ChatScrollDiag.shared.note("pinToBottomSoon force=\(force ? 1 : 0) stick=\(stick ? 1 : 0)")
        guard stick else { return }
        pinTask?.cancel()
        pinTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 280_000_000)     // 键盘动画 ≈0.25s，等它落稳
            if Task.isCancelled { return }
            atBottom = true
            pinTick += 1
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool) {
        /* 一律滚到**底部哨兵**：它永远在整段内容的最最后（消息、待发消息、发送中的视频都在它前面）
           —— 对着「最后一条消息」滚，遇上那一条自己还在长高就贴不死。 */
        /* 优先直接命令底层滚动视图滚到最大偏移：不依赖任何 SwiftUI 的 id，
           懒加载还没渲染到那一行也照样一次到位（修「发了消息不跳到最新」）。 */
        ChatScrollDiag.shared.note("scrollToEnd anim=\(animated ? 1 : 0)")
        if ChatScrollHandle.shared.pinToBottom(animated: animated) { return }
        let target = "__bottom"
        guard !target.isEmpty else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.22)) { proxy.scrollTo(target, anchor: .bottom) }
        } else {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    /// 本来就在底部的话，悄悄地再贴一次底（不带动画）。
    /// 用在「异步解码完、行高变了」之后 —— 这就是有些账号「消息掉底」的来源。
    private func repinIfAtBottom() {
        ChatScrollDiag.shared.note("repinIfAtBottom atBottom=\(atBottomNow ? 1 : 0)")
        guard atBottomNow else { return }
        /* ★ 同一个道理：哨兵只说明"那一行被渲染过"，不代表人真的在底部。
           这里直接问底层滚动视图"现在离底还有多远"，超过 200pt 就不贴 ——
           不然长文排完版 / 图片解码完就把正在翻历史的人拽回去了。 */
        if let g = ChatScrollHandle.shared.gap, g > 200 { return }
        pinTick += 1
    }


    /// 「现在算不算在底部」：两个信号取或。
    /// · atBottom     —— 底部哨兵可见（会长文排完版时被顶出屏幕 → 会误判成 false）
    /// · wasAtBottom  —— 手指最后一次滑动时，底层滚动视图确实在最底下（准）
    /// 取或：任一成立就补底，不会因为哨兵被顶走而漏掉补底（「有些号下沉」就是漏在这儿）；
    /// 你真的往上翻过（手指滑动把它置 false，哨兵也 false），两个都不成立 → 不补底。
    private var atBottomNow: Bool { wasAtBottom || atBottom }

    /* ---------------------------------------------------------- 待发消息（离线） */

    /// 「发送中 / 发送失败」的那条：右边一个转圈，或者一个红色感叹号（点一下就重发）
    private func pendingBubble(_ p: PendingMsg) -> some View {
        HStack(alignment: .center, spacing: 7) {
            Spacer(minLength: 0)
            if p.sending {
                ProgressView().scaleEffect(0.72)
            } else if p.failed {
                Button {
                    Task { await flushOutbox() }
                } label: {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(C.red)
                }
                .buttonStyle(.plain)
            }
            Text(p.preview)
                .font(pf(16))
                .foregroundColor(C.bubbleText)
                .lineLimit(6)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(BubbleFill(mine: true, tail: false))
                .opacity(p.failed ? 0.9 : 1)
        }
        .padding(.vertical, 4)
        .id(p.id)
    }

    /// 队列存本机：退出 App 再进来，没发出去的那条还在（微信也是这样）
    private func saveOutbox() {
        let arr = outbox.map { p -> [String: Any] in
            var d: [String: Any] = ["id": p.id, "kind": p.kind, "content": p.content,
                                    "at": p.at.timeIntervalSince1970]
            if let q = p.quoteJSON { d["quote"] = q }
            return d
        }
        UserDefaults.standard.set(arr, forKey: "chris.outbox." + chat.id)
    }

    private func loadOutbox() {
        let arr = (UserDefaults.standard.array(forKey: "chris.outbox." + chat.id) as? [[String: Any]]) ?? []
        outbox = arr.compactMap { d in
            guard let id = d["id"] as? String,
                  let kind = d["kind"] as? String,
                  let content = d["content"] as? String else { return nil }
            return PendingMsg(id: id, kind: kind, content: content,
                              quoteJSON: d["quote"] as? String)
        }
    }

    /// 存在队列里的引用（JSON 字符串）→ 发的时候解回字典
    private static func quoteDict(_ json: String?) -> [String: Any]? {
        guard let json = json, let d = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o
    }

    /// 以前转过文字的语音：进聊天时把结果贴回来（存在本机，和微信一样）
    private func backfillVoiceText() {
        for m in messages where m.kindName == "audio" && asrCache[m.id] == nil {
            if let t = VoiceText.get(m.id) { asrCache[m.id] = t }
        }
    }

    /* ----------------------------------------------------------
       一条消息 = 时间线 + 内容 + 底部间距（微信的排版逻辑）：
         · 同一个人连着发：中间只留 4（看起来是一组）
         · 换个人发：留 15（明显断开）
         · 出现时间线：让时间线自己带上下 12，消息这边就不留了
         · 系统消息（通话记录 / 撤回提示）居中一行灰字，上下各 12
       还有两条跟着分组走：群里昵称只挂在连发的第一条上、气泡的小尖角也只画在第一条上。
       ---------------------------------------------------------- */

    @ViewBuilder
    private func messageBlock(_ message: Message) -> some View {
        VStack(spacing: 0) {
            if showTime(for: message) { timeLine(message) }
            if message.kindName == "pat" {
                /* 拍一拍：居中一行灰字（说法按「我」在这件事里的位置变）。
                   用户要求：**框起来**，而且这一行的底色/文字色能在后台调
                   （ui.json：patBg / patInk，圆角 patRadius，底色浓淡 patBgAlpha）。 */
                Text(message.patText(myId: myId))
                    .font(pf(12.5))
                    .foregroundColor(UIConfig.color("patInk", 0x8A8A8E, 0x9A9AA0))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: UIConfig.num("patRadius", 6), style: .continuous)
                            .fill(UIConfig.color("patBg", 0xEDEDF0, 0x2C2C31)
                                .opacity(max(0, min(1, UIConfig.num("patBgAlpha", 1)))))
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 40)
                    .padding(.bottom, gapAfter(message))
            } else if message.kindName == "system" {
                /* 微信的通话记录是一条气泡，摆在哪边看「谁打的」：
                   自己打出去的 → 右边（绿），对方打过来的 → 左边（白）。
                   老记录里没有「谁打的」这个信息，就还是居中一行灰字。 */
                if message.isCallRecord && !message.callFrom.isEmpty {
                    callRow(message)
                } else {
                        SystemLine(message: message)
                            .padding(.bottom, gapAfter(message))
                            /* 老记录（没有「谁打的」信息）：点一下也先确认再回拨 ——
                               以前这里点一下直接拨，居中一行灰字在列表里随手一碰就误拨出去。 */
                            .contentShape(Rectangle())
                            .onTapGesture { redialAsk = message }
                }
            } else if message.isRecalled {
                recallLine(message)
                    .padding(.bottom, gapAfter(message))
            } else {
                messageRow(message)
                    /* 阅后即焚的小火苗（2026-10-13 用户要求「气泡旁要有个小火苗」）：
                       自己发的贴左边、别人发的贴右边，一眼看出「这条会烧掉」。
                       只对开了焚毁标记的消息加这一层。 */
                    .overlay(alignment: (message.senderId == myId) ? .leading : .trailing) {
                        if message.burn == true {
                            /* 小火苗 + **焚毁倒计时**（用户要求）：服务端告诉我们这条什么时候烧，
                               每秒刷新一次；还没人看过就先只显示火苗。 */
                            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                HStack(spacing: 3) {
                                    Image(systemName: "flame.fill")
                                        .font(.system(size: 11))
                                    if let d = TimeFmt.date(message.burnAt) {
                                        Text(burnCountText(d, now: ctx.date))
                                            .font(.system(size: 10, weight: .medium))
                                            .monospacedDigit()
                                    }
                                }
                                .foregroundColor(Color(hex: 0xFF9A2E))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color(hex: 0xFF9A2E).opacity(0.14)))
                                .offset(x: (message.senderId == myId) ? -26 : 26)
                            }
                        }
                    }
            }
        }
    }

    private func timeLine(_ message: Message) -> some View {
        Text(TimeFmt.bubble(message.createdAt))
            .font(pf(L.msgTimeSize))
            .foregroundColor(C.chatTimeInk)
            /* 时间加一个明显的圆角小框（和微信一样；颜色/圆角后台能调，只作用于聊天页） */
            .padding(.horizontal, L.o("chatTimePadX", 8))
            .padding(.vertical, L.o("chatTimePadY", 3))
            .background(RoundedRectangle(cornerRadius: L.o("chatTimeRadius", 4), style: .continuous)
                .fill(C.chatTimeBg))
            .frame(maxWidth: .infinity)
            .padding(.top, L.o("chatTimeGapTop", 12))
            .padding(.bottom, L.o("chatTimeGapBottom", 12))
    }

    /// 撤回的提示：微信里不是气泡，是居中一行灰字
    private func recallLine(_ message: Message) -> some View {
        Text(recallText(message))
            .font(pf(13))
            /* 和群里那些系统提示一样：垫一层淡底 + 深一点的灰，压在花哨的聊天背景上也看得清 */
            .foregroundColor(C.chatTimeInk)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(C.chatTimeBg))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)
    }

    private func recallText(_ message: Message) -> String {
        if message.senderId == myId { return Tr("你撤回了一条消息") }
        if isGroup { return displayName(message) + " " + Tr("撤回了一条消息") }
        return Tr("对方撤回了一条消息")
    }

    @ViewBuilder
    private func messageRow(_ message: Message) -> some View {
        MessageRow(message: message,
                   mine: mineFor(message),
                   myId: myId,
                   senderName: senderNameFor(message),
                   showTail: isRunStart(message),
                   onTapTransfer: { info in billInfo = info },
                   onOpenImage: { path in openImage(path) },
                   onOpenAvatar: { id in openAvatar(id) },
                   onOpenWeb: { url in web = WebURL(url: url) },
                   onOpenLocation: { p in openLocation = p },
                   onOpenUserCard: { uid in openCardUser(uid) },
                   onOpenAnnounce: { text in announcePage = text; showAnnouncePage = true },
                   /* ⚠ 交给最外层去弹（见 AppState.openMiniApp 的说明）：
                      在聊天页里挂 fullScreenCover(item:) 会让这一页一打开就闪退 */
                   onOpenMiniApp: { g in app.openMiniApp = g },
                   onOpenVideo: { u in videoToPlay = u; videoPayload = message.body },
                   onPat: { uid in pat(uid) },
                   onTapRedPacket: { info in tapRedPacket(info) },
                   asrText: asrCache[message.id] ?? "",
                   asrBusy: asrBusy.contains(message.id),
                   onOpenFile: { body in openFile(body) },
                   onOpenArticle: { id in oaArticleId = id; showOaArticle = true },
                   onLayoutChanged: { repinIfAtBottom() },
                   /* 点引用条 → 跳到被引用的那条原消息（微信就是这么跳的） */
                   onOpenQuote: { id in jumpToMessage(id) })
            .padding(.bottom, gapAfter(message))
            /* 长按一条消息：弹微信那套动作条（复制/转发/收藏/引用/撤回/删除/多选）。
               ⚠ 这里必须用 simultaneousGesture，不能用 onLongPressGesture：
               九宫格、图片、视频这些气泡里每一格都是 Button，普通长按会被按钮吃掉，
               长按它们弹不出菜单（用户反馈的「九宫格/实况没有撤回按钮」就是这个）。 */
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.42).onEnded { _ in openActions(message) }
            )
            /* 关怀模式 +「听文字消息」：点一下文字消息就念出来（微信关怀模式的做法）——
               用 simultaneousGesture，免得把正文里的链接点击吃掉。 */
            .simultaneousGesture(
                TapGesture().onEnded {
                    guard CareMode.on, CareMode.speakText else { return }
                    let t = readableText(message)
                    if !t.isEmpty { Speaker.shared.speak(t) }
                }
            )
            .overlay(alignment: .leading) {
                if selectMode {
                    Image(systemName: selected.contains(message.id)
                          ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 21))
                        .foregroundColor(selected.contains(message.id) ? C.green : C.subLabel)
                        .padding(.leading, 10)
                }
            }
            .overlay {
                if selectMode {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { toggleSelect(message) }
                }
            }
            .background(GeometryReader { g in
                /* 只把位置记进普通对象（不写 @State → 不触发整页重绘） */
                Color.clear
                    .onAppear { frameBox.frames[message.id] = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { f in frameBox.frames[message.id] = f }
            })
    }

    /// 通话记录按「谁打的」定左右（其他消息还是看发送者）
    private func mineFor(_ message: Message) -> Bool {
        if message.isCallRecord && !message.callFrom.isEmpty { return message.callFrom == myId }
        return message.senderId == myId
    }

    /// 通话记录那一行：头像 + 气泡（里面是电话/摄像机图标 +「通话时长 00:12」）
    @ViewBuilder
    private func callRow(_ message: Message) -> some View {
        let mine = mineFor(message)
        let callerAvatar = app.contact(for: message.callFrom)?.avatarPath ?? ""
        HStack(alignment: .top, spacing: 0) {
            if mine { Spacer(minLength: 0) }
            if !mine {
                Avatar(path: callerAvatar, size: L.chatAvatar, radius: 4)
                Spacer().frame(width: L.chatGapMsg)
            }
            CallRecordBubble(message: message, mine: mine)
            if mine {
                Spacer().frame(width: L.chatGapMsg)
                Avatar(path: callerAvatar, size: L.chatAvatar, radius: 4)
            }
            if !mine { Spacer(minLength: 0) }
        }
        .padding(.bottom, gapAfter(message))
        /* 关键：整行都要能点（以前只给气泡加了点击，点左右留白没反应 → 看着像"点不了"）。
           微信那样：点一下这条通话记录 = 直接回拨（视频记录就回拨视频），长按才是菜单。 */
        .contentShape(Rectangle())
        .onTapGesture { redialAsk = message }
        .onLongPressGesture { openActions(message) }
    }

    /// 双击头像 = 拍一拍（微信的手势）：这里只把「拍了谁」告诉服务器，
    /// 由服务器往会话里写一条灰字（这样双方、群里的第三条人都能看到同一条记录）。
    private func pat(_ userId: String) {
        guard !userId.isEmpty else { return }
        Realtime.shared.sendJSON(["type": "pat", "chatId": chat.id, "targetId": userId])
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// 这条通话记录要拨给谁（解析不出就返回空串）。
    /// 三种来源依次兜底：① 记录里写了 from/to ② 我自己发的就看 call.to ③ 用这个会话的对方。
    private func redialPeerId(_ message: Message) -> String {
        var peer = (message.callFrom == myId) ? (message.call?.to ?? "") : message.callFrom
        if peer.isEmpty || peer == myId {
            if let other = message.call?.to, !other.isEmpty, other != myId { peer = other }
            else if let other = message.call?.from, !other.isEmpty, other != myId { peer = other }
            else if let other = peerUserId { peer = other }
        }
        return peer == myId ? "" : peer
    }

    private func redialName(_ message: Message) -> String {
        let peer = redialPeerId(message)
        if peer.isEmpty { return chat.name }
        return app.contact(for: peer)?.name ?? chat.name
    }

    private var redialTitle: String {
        guard let m = redialAsk else { return "" }
        return Tr("给「") + redialName(m) + Tr("」打电话？")
    }

    /// 确认框里选了「语音通话 / 视频通话」才真拨（严格校验：空的、等于我自己都不拨）
    private func startRedial(_ video: Bool) {
        guard let message = redialAsk else { return }
        redialAsk = nil
        let peer = redialPeerId(message)
        guard !peer.isEmpty else { app.show(Tr("这条记录里找不到对方账号")); return }
        if CallCenter.shared.phase != .idle { app.show(Tr("正在通话中")); return }
        CallCenter.shared.resetIfStale()
        if CallCenter.shared.phase != .idle { app.show(Tr("正在通话中")); return }
        CallCenter.shared.start(peerId: peer,
                                name: app.contact(for: peer)?.name ?? chat.name,
                                avatar: app.contact(for: peer)?.avatarPath ?? (chat.avatar ?? ""),
                                video: video)
    }

    private func indexOf(_ message: Message) -> Int? {
        /* 查表 O(1)：表在 load / loadOlder 里重建。
           以前这里是 firstIndex(where:) —— 每条消息都要问好几遍（时间线、间距、连发判断），
           500 条消息就是 25 万次 id 比较，消息一多必卡。 */
        if let i = msgIndex[message.id], i < messages.count, messages[i].id == message.id {
            return i
        }
        return messages.firstIndex(where: { $0.id == message.id })   // 表还没建好时兜底
    }

    /// 重建「消息 id → 下标」的表（消息列表一变就调一次，很便宜）
    private func rebuildIndex() {
        var m = [String: Int](minimumCapacity: messages.count)
        for (i, x) in messages.enumerated() { m[x.id] = i }
        msgIndex = m
    }

    /// 是不是「同一个人连发」里的第一条（昵称和气泡尖角都挂这一条）
    private func isRunStart(_ message: Message) -> Bool {
        guard let i = indexOf(message), i > 0 else { return true }
        let prev = messages[i - 1]
        if prev.kindName == "system" || prev.kindName == "pat" || prev.isRecalled { return true }
        if (prev.senderId ?? "") != (message.senderId ?? "") { return true }
        return TimeFmt.minutesBetween(prev.createdAt, message.createdAt) >= 5
    }

    /// 群里才写昵称，而且只写在连发的第一条上（微信就是这样）
    private func senderNameFor(_ message: Message) -> String {
        guard isGroup, message.senderId != myId else { return "" }
        return isRunStart(message) ? displayName(message) : ""
    }

    /// 这一条下面留多少空隙
    private func gapAfter(_ message: Message) -> CGFloat {
        guard let i = indexOf(message) else { return 15 }
        guard i + 1 < messages.count else { return 4 }
        let next = messages[i + 1]
        if showTime(for: next) { return 0 }        // 时间线自己带上下间距
        if next.kindName == "system" || next.kindName == "pat" || next.isRecalled { return 12 }
        if message.kindName == "system" || message.kindName == "pat" || message.isRecalled { return 12 }
        let same = (next.senderId ?? "") == (message.senderId ?? "")
        /* 同一个人连发：也留一点空隙（用户反馈"同一人发的消息和消息之间要有空隙"）——
           以前是 4pt，药丸气泡挨在一起看着像黏住了。两个值都放进后台可调：
           ui.json 的 msgGapSame（同人）/ msgGapOther（换人）。 */
        return same ? UIConfig.num("msgGapSame", 7) : UIConfig.num("msgGapOther", 15)
    }

    /* 左上角「返回箭头」旁边那个未读数字：和微信一样的位置。
       进聊天页先带上会话原来的未读数，之后每多收到一条别人的消息就 +1；
       点一下这个数字 = 当作看完，数字清零并滚回最新一条。 */
    private var leftUnreadBadge: AnyView? {
        guard unreadHere > 0 else { return nil }
        return AnyView(
            Button {
                unreadHere = 0
                scrollTick += 1
            } label: {
                Text(unreadHere > 99 ? "99+" : "\(unreadHere)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 20, minHeight: 18)
                    /* 数字外面那个「药丸框」：里面填色，外面再描一圈白边 */
                    .background(
                        Capsule()
                            .fill(C.red)
                            .overlay(Capsule().stroke(Color.white.opacity(0.9), lineWidth: 1.2))
                    )
            }
            .buttonStyle(.plain)
            .padding(.trailing, 2)
        )
    }

    private func showTime(for message: Message) -> Bool {
        /* 查表 O(1)（以前这里是 firstIndex 全表扫 —— 每行都要扫一遍，
           消息一多就是 O(n²)，正是"不丝滑"的大头） */
        guard let index = indexOf(message) else { return false }
        if index == 0 { return true }
        return TimeFmt.minutesBetween(messages[index - 1].createdAt, message.createdAt) >= 5
    }

    /* ---------------------------------------------------------- 输入栏 */

    /// 输入框上面那一排快捷按钮：图片 / 拍摄 / 位置 / 文件 / 转账 / 红包 / 常用语
    /// （用的都是下面那套已经存在的动作，不新增逻辑）
    private var quickBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                /* 这一排现在是**管理里配的**（增删 / 排序 / 改名 / 开关）：
                   拉不到后台配置就退回原来那七个（见 QuickChip.defaults） */
                ForEach(quickChips) { c in quickChip(c) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        /* **不要底色**（用户要求）：这排就是浮在键盘上面那条空隙里的几个字，
           不铺色条、也不给它铺卡片底 —— 后面是聊天背景，直接透出来。
           想找回一条底色：后台 ui.json 写 quickBarBg（1 = 铺 cardBg）。 */
        .background(UIConfig.num("quickBarBg", 0) > 0 ? C.cardBg : Color.clear)
    }

    /// 这会儿该显示哪几个快捷按钮（后台配的去掉关掉的；一个都不剩就退回默认那排）
    private var quickChips: [QuickChip] {
        let list = app.quickChips.filter { $0.enabled }
        return list.isEmpty ? QuickChip.defaults : list
    }

    /// 输入框右边那个「＋」：管理里能换**颜色 / 大小 / 图片**（都没配就跟主题走）
    @ViewBuilder
    private var plusIcon: some View {
        let cfg = app.plusButton
        let side = cfg.size > 0 ? CGFloat(cfg.size) : L.composerIcon
        Group {
            if !cfg.image.isEmpty {
                RemoteImage(path: cfg.image, mode: .fit, maxSide: 200)
                    .frame(width: side, height: side)
            } else {
                SVGIcon(markup: I.plusCircle, size: side,
                        color: optionalHexColor(cfg.color) ?? C.chatBarIcon)
            }
        }
        .frame(width: L.composerIconBox, height: L.composerIconBox)
        .contentShape(Rectangle())
    }

    /// 表情 / ＋ 两个辅助按钮。**不论输入框有没有字都常驻**：
    /// 以前有字时整组被“发送”替掉，用户打字后根本找不到表情入口。
    private var composerAuxButtons: some View {
        HStack(spacing: 2) {
            Button {
                focused = false
                panel = (panel == .emoji) ? .none : .emoji
            } label: {
                SVGIcon(markup: I.smile, size: L.composerIcon, color: C.chatBarIcon)
                    .frame(width: L.composerIconBox, height: L.composerIconBox)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                focused = false
                panel = (panel == .plus) ? .none : .plus
                if panel == .plus && plusItems.isEmpty {
                    Task { plusItems = (try? await API.shared.plusPanel()) ?? [] }
                }
            } label: {
                plusIcon
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .frame(height: L.composerIconBox + 8)
        .background {
            GlassBackground(shape: Capsule(style: .continuous), shadow: true, seed: 0.45)
                .opacity(panel == .none ? 0.9 : 1)
        }
    }

    private func quickChip(_ c: QuickChip) -> some View {
        Button {
            switch c.action {
            case "photo": showPhoto = true
            case "camera": showCamera = true
            case "location": showSendLocation = true
            case "file": openFilePicker()
            case "transfer": showTransfer = true
            case "redpacket": showSendRedPacket = true
            case "card": showPickCard = true
            /* 其余动作（礼物 / 音乐 / 视频通话 / 语音输入 / 收藏）走「＋」面板那一套处理，
               免得两处逻辑各写一遍、以后改一处忘一处 */
            default:
                handlePlus(PlusItem(id: c.id, label: c.label, icon: c.action,
                                    action: c.action, enabled: true))
            }
        } label: {
            Text(c.label)
                .font(pf(13.5))
                .foregroundColor(C.label)
                .padding(.horizontal, 12)
                .frame(height: 30)
                /* 按钮自己也**不要底色/玻璃胶囊**（用户要求）——
                   想要回"胶囊玻璃底"就后台写 quickChipGlass = 1。 */
                .background {
                    if UIConfig.num("quickChipGlass", 0) > 0 {
                        CardGlassBox(radius: 15)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var composer: some View {
        Group {
            if !isFriendPeer {
                /* 微信那套：不是好友了就不给直接发消息，底下换成「发送朋友验证」 */
                verifyComposer
            } else if mutedForMe {
                mutedComposer
            } else {
                activeComposer
            }
        }
    }

    /// 单聊对方是谁
    private var peerId: String {
        (chat.memberIds ?? []).first(where: { $0 != myId }) ?? ""
    }

    /// 单聊对方还在不在我的好友里。
    /// 删了好友（服务端会把会话从我这边藏掉）之后，如果他再发消息，
    /// 这个会话会重新冒出来 —— 这时候就该出「发送朋友验证」，和微信一致。
    private var isFriendPeer: Bool {
        guard !isGroup, !peerId.isEmpty else { return true }
        if (chat.bot ?? "").isEmpty == false || (chat.oaId ?? "").isEmpty == false { return true }
        if app.contacts.isEmpty { return true }        // 通讯录还没拉下来：别误判
        return app.contacts.contains { $0.id == peerId }
    }

    /// 微信那一句 + 一颗绿色「发送朋友验证」
    private var verifyComposer: some View {
        VStack(spacing: 10) {
            Text(Tr("你还不是他（她）朋友。请先发送朋友验证请求，对方验证通过后，才能聊天。"))
                .font(pf(13.5))
                .foregroundColor(C.subLabel)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Button { showApply = true } label: {
                Text(Tr("发送朋友验证"))
                    .font(pf(15, .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(C.green))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
        }
        .padding(.top, 14)
        .padding(.bottom, 20)
        .background(C.cardBg)
    }

    private func sendApply() {
        let note = applyNote.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                try await API.shared.addFriend(userId: peerId,
                                               note: note.isEmpty ? ("我是" + (app.me?.nickname ?? "")) : note)
                app.show(Tr("已发送朋友验证"))
            } catch {
                app.show((error as? APIError)?.errorDescription ?? "发送失败")
            }
        }
    }

    /// 键盘是不是正开着（用自己量出来的那套高度判断）——
    /// 快捷按钮那排的位置就跟着它换：没开在上面，开了就落到键盘正上方那条空隙里
    private var kbUp: Bool { kbHeight > 1 }

    /* 群禁言：群主开了「全员禁言」以后，别人进来不能再摆一个「发不出去」的输入框
       （微信就是这样 —— 底下换成一条灰提示）。群主自己在全员禁言里还能说话，
       所以这里只看：我有没有被单独禁言 / 全员禁言里我是不是群主。 */
    private var mutedForMe: Bool {
        let c = liveChat
        guard c.type == "group" else { return false }
        if c.meMuted == true { return true }
        /* 群主不认识的时候（老数据里 ownerId 是空的）也按「不让我说话」处理 */
        return c.muteAll == true && c.ownerId != myId
    }

    /// 会话状态以 app.chats 里那份为准：群主刚开了全员禁言，别人这边要立刻变过来，
    /// 不能还拿着「点进来那一刻」的旧快照（点开时 app.loadChats() 已经把最新的拉回来了）
    private var liveChat: Chat { app.chats.first(where: { $0.id == chat.id }) ?? chat }

    private var mutedComposer: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.slash.fill")
                .font(.system(size: 15))
                .foregroundColor(C.subLabel)
            Text(liveChat.meMuted == true
                 ? Tr("你已被群主禁言，暂时不能发言")
                 : Tr("全员禁言中，只有群主可以发言"))
                .font(pf(14))
                .foregroundColor(C.subLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
        .frame(height: L.inputH)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(C.navLine).frame(height: 0.5)
        }
        .background {
            ZStack {
                /* 输入栏的毛玻璃也叠（和气泡同一套观感），层数同一个开关 */
                let layers = max(1, min(3, Int(UIConfig.num("glassLayers", 2))))
                ForEach(0..<layers, id: \.self) { _ in
                    Rectangle().fill(.ultraThinMaterial)
                }
                Color.dyn(0xFFFFFF, 0x1C1C1E)
                    .opacity(max(0, min(0.5, UIConfig.num("glassAlpha", 0.8) - 0.5)))
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    private var activeComposer: some View {
        VStack(spacing: 0) {
            /* **输入框上面那一排快捷按钮**（用户要求）：常用的几个动作一步到位，
               不用先去点「＋」再挑。横向可滑，深色/浅色都跟着主题走。 */
            /* 键盘**没收起来时这一排不显示**了（用户要求："输入框上面的按钮去掉"）；
               键盘一出来才排在输入框**下面**、落在键盘正上方那条空隙里
               （见下面 if kbUp 那一段）。 */
            /* 引用了某条消息：上面挂一条引用条（点 ✕ 取消） */
            if let q = quote {
                HStack(spacing: 8) {
                    Rectangle().fill(C.green).frame(width: 3, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(q.senderId == myId ? Tr("我") : displayName(q))
                            .font(pf(11.5))
                            .foregroundColor(C.green)
                        Text(q.kindName == "text" ? String(q.body.prefix(40)) : "[" + q.kindName + "]")
                            .font(pf(12.5))
                            .foregroundColor(C.subLabel)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button { quote = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundColor(C.subLabel)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .background(C.tabBg)
            }
            /* 撤回的是**自己**发的消息 → 微信会在输入框上沿挂一条「重新编辑」，
               点一下就把刚撤回的内容填回输入框（5 分钟内有效，点 ✕ 或超时就没了）。 */
            if let draft = reEditDraft {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundColor(C.green)
                    Text(Tr("重新编辑"))
                        .font(pf(13.5))
                        .foregroundColor(C.label)
                    Spacer(minLength: 0)
                    Button { reEditDraft = nil } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(C.subLabel)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .frame(height: 36)
                .background(C.tabBg)
                .overlay(alignment: .top) {
                    Rectangle().fill(C.navLine).frame(height: 0.5)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    input = draft
                    reEditDraft = nil
                    focused = true
                }
            }
            HStack(spacing: 6) {
                /* 这个键两种用法（微信也是这样，同时照顾老习惯）：
                   轻点 = 切「语音 / 键盘」模式；**按住 = 直接开始录音** ——
                   靠「按了多久」区分。上一版只保留了切换，按住毫无反应，
                   用户就以为「浮层没了」（线上真被这么反馈过）。 */
                Image(systemName: voiceMode ? "keyboard" : "mic")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundColor(recorder.recording ? C.green : C.chatBarIcon)
                    .frame(width: L.composerIconBox, height: L.composerIconBox)
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                if pressStart == nil { pressStart = Date() }
                                if recorder.recording {
                                    recorder.drag(v.translation.height)
                                    return
                                }
                                if !voiceStarting, Date().timeIntervalSince(pressStart ?? Date()) > 0.22 {
                                    voiceStarting = true
                                    focused = false
                                    panel = .none
                                    Task { _ = await recorder.begin(); voiceStarting = false }
                                }
                            }
                            .onEnded { _ in
                                let held = Date().timeIntervalSince(pressStart ?? Date())
                                pressStart = nil
                                voiceStarting = false
                                if recorder.recording {
                                    if recorder.willCancel { recorder.cancel(); return }
                                    if recorder.willTranscribe {
                                        guard let got = recorder.end() else { return }
                                        transcribeToInput(got.url)
                                        return
                                    }
                                    finishVoice()
                                    return
                                }
                                if held < 0.22 {                 // 轻点 = 切「语音 / 键盘」
                                    voiceMode.toggle()
                                    if voiceMode { focused = false; panel = .none }
                                }
                            }
                    )

                HStack(spacing: 0) {
                    if voiceMode {
                        /* 微信那种「按住 说话」：按住开始录、上滑取消、松手发送。
                           打字内容存成草稿，切回键盘时原样回来。 */
                        HStack(spacing: 7) {
                            if recorder.recording {
                                Image(systemName: "waveform")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(recorder.willCancel ? C.red : C.green)
                            }
                            Text(recorder.recording
                                 ? (recorder.willCancel ? Tr("松开手指，取消发送") : Tr("松开 发送"))
                                 : Tr("按住 说话"))
                                .font(pf(15.5))
                                .foregroundColor(recorder.willCancel ? C.red : C.label)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .contentShape(Rectangle())
                        /* ★ 按压回弹（用户要求）：手指按下去那一格**轻微下沉 + 变暗**，
                           松手（或录完）**弹回来** —— spring 回弹，和顶栏那个 ＋ 一套手感。
                           按住不动时会一直保持"按下"的样子，配合那三下震动就是"有物理感"。 */
                        .scaleEffect(pressStart != nil ? 0.965 : 1)
                        .opacity(pressStart != nil ? 0.86 : 1)
                        .animation(.spring(response: 0.20, dampingFraction: 0.68), value: pressStart)
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { v in
                                    if recorder.recording {
                                        recorder.drag(v.translation.height)
                                        return
                                    }
                                    /* ★ 误触防护：这根「按住说话」的条原来是**手指一碰就开始录**
                                       （划过、蹭到都会录一下再取消，用户反馈的「语音容易误触」）。
                                       现在和左边那个麦克风图标一样：得**按住 0.22 秒**才开始录，
                                       0.22 秒内松手 / 只是碰一下 → 什么都不做，也不会震一下。 */
                                    guard pressStart == nil else { return }
                                    pressStart = Date()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                                        guard pressStart != nil, !recorder.recording else { return }
                                        voiceStarting = true
                                        focused = false
                                        panel = .none
                                        Task {
                                            _ = await recorder.begin()
                                            voiceStarting = false
                                        }
                                    }
                                }
                                .onEnded { _ in
                                    pressStart = nil
                                    voiceStarting = false
                                    guard recorder.recording else { return }
                                    /* 松手时按当前滑到的档位处理（照微信那张图）：
                                       取消区 → 丢弃；转文字区 → 本地识别成文字进输入框；其余 → 发语音 */
                                    if recorder.willCancel { recorder.cancel(); return }
                                    if recorder.willTranscribe {
                                        guard let got = recorder.end() else { return }
                                        transcribeToInput(got.url)
                                        return
                                    }
                                    finishVoice()
                                }
                        )
                    } else if recorder.recording {
                        /* 录音时把输入框整条收起来（微信就是这样）：
                           不然刚打的字一直露在框里，还和录音按钮混在一起。
                           松手立刻恢复，原来打的字还在（草稿）。 */
                        HStack(spacing: 7) {
                            Image(systemName: "waveform")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(recorder.willCancel ? C.red : C.green)
                            Text(recorder.willCancel ? Tr("松开手指，取消发送") : Tr("松开 发送"))
                                .font(pf(15.5))
                                .foregroundColor(recorder.willCancel ? C.red : C.label)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        HStack(spacing: 4) {
                        ChatComposerTextField(text: $input,
                                              focused: $focused,
                                              bridge: composerBridge,
                                              font: chatComposerUIFont(),
                                              tintColor: UIColor(hex: 0x2F7FD8),
                                              onBeginEditing: { panel = .none })
                            /* 光标那根**闪动的蓝线**（用户要求）：iOS 的光标本来就会自己闪，
                               这里只把它染成蓝色 —— 默认会跟随 App 的强调色（偏绿），
                               染一下才是正经的"蓝线"。 */
                            /* 自己在打字 → 顺手告诉对面「正在输入」（每 2 秒最多一次） */
                            .onChange(of: input) { v in
                                reportTyping()
                                /* 群里打「@」→ 弹出群成员列表选人（微信的规矩；单聊不弹） */
                                if isGroup, justTypedAtSign(from: lastInputSnapshot, to: v) { openMentionPicker() }
                                lastInputSnapshot = v
                            }
                            /* 「听声出字」：只在**点进输入框、键盘起来**的时候才出现（微信就是这个时机），
                               点一下开始听，说的字直接落进输入框，可以改完再发 */
                            if focused {
                                Button {
                                    let base = input
                                    dictation.toggle { s in input = base.isEmpty ? s : (base + s) }
                                } label: {
                                    Image(systemName: dictation.listening ? "mic.fill" : "mic")
                                        .font(.system(size: 17))
                                        .foregroundColor(dictation.listening ? C.green : C.chatBarIcon)
                                        .frame(width: 30, height: 30)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: L.inputH)
                .background(
                    ZStack {
                        /* 输入框：**胶囊 + 液态玻璃**（和气泡/底栏同一套，亮边走 GlassBackground）
                           —— 整体透明度后台可调：inputGlassAlpha（越小越透）；
                           染色浓度：inputGlassTint。 */
                        GlassBackground(shape: Capsule(style: .continuous),
                                        opacity: UIConfig.num("inputGlassAlpha", 0.55),
                                        seed: 0.45)
                        Capsule(style: .continuous)
                            .fill(recorder.recording
                                  ? (recorder.willCancel ? Color.dyn(0xFFF1F1, 0x3A2A2A) : Color.dyn(0xF2F2F2, 0x242427))
                                  : Color.dyn(0xFFFFFF, 0x2C2C2E))
                            .opacity(UIConfig.num("inputGlassTint", 0.35))
                    }
                )
                .overlay(
                    ZStack {
                        /* 录音时：红了=松手取消、绿了=松手发送（原来的提示保留） */
                        if recorder.recording {
                            Capsule(style: .continuous)
                                .stroke(recorder.willCancel ? C.red.opacity(0.6) : C.green.opacity(0.6),
                                        lineWidth: 1.2)
                        }
                    }
                )

                if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    /* 笑脸和 ＋ **一起套一块**玻璃胶囊（用户要求：别各自一个圆框）。
                       做法：先把两个按钮放进一个 HStack，再给整组加一层胶囊玻璃。 */
                    composerAuxButtons
                } else {
                    HStack(spacing: 6) {
                        composerAuxButtons
                        Button {
                            sendText()
                        } label: {
                            Text(Tr("发送"))
                                .font(pf(16, .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 13)
                                .frame(height: 32)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(C.green))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 11)
            .padding(.vertical, 8)

            /* 键盘起来时：快捷键排到这儿（紧贴键盘上沿，填住原来那条空隙） */
            if kbUp {
                quickBar
            }

            panelView
                /* 2026-10-17 用户：「聊天加号面板也改成磨砂玻璃感」——
                   ＋ 面板改成**磨砂玻璃**（.bar 材质 + 一点点底色，后面聊天的内容会模糊透上来），
                   表情 / 礼物那两个保持不变（实心底，和微信一致）。 */
                .background {
                    if panel == .none {
                        Color.clear
                    } else if panel == .plus {
                        ZStack {
                            Rectangle().fill(.bar)
                            C.tabBg.opacity(0.35)
                        }
                    } else {
                        C.tabBg
                    }
                }
        }
        .overlay(alignment: .top) {
            if dictation.listening {
                Text("正在听你说，说完自己上屏…")
                    .font(pf(12))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(C.green))
                    .offset(y: -22)
            }
        }
        .onChange(of: dictation.error) { msg in
            if !msg.isEmpty { app.show(msg) }
        }
        .onDisappear { dictation.stop() }
        /* 输入栏：和顶栏同一套超薄毛玻璃 + 一层白；上面压一条 0.5px 细线做分隔（微信也有） */
        .background {
            ZStack {
                /* 输入栏毛玻璃叠层（和气泡同一开关） */
                let barLayers = max(1, min(3, Int(UIConfig.num("glassLayers", 2))))
                ForEach(0..<barLayers, id: \.self) { _ in
                    Rectangle().fill(.ultraThinMaterial)
                }
                Color.dyn(0xFFFFFF, 0x1C1C1E)
                    .opacity(max(0, min(0.5, UIConfig.num("glassAlpha", 0.8) - 0.5)))
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(C.navLine).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var panelView: some View {
        switch panel {
        case .emoji:
            EmojiPanel(draft: $input,
                       onSend: { sendText(); panel = .none },
                       onDelete: { composerBridge.deleteBackward() },
                       onInsert: { composerBridge.insert($0) },
                       onSendSticker: { url in
                           /* 我们的表情：以图片消息发出去（和微信发自定义表情一样） */
                           send(kind: "image", content: url)
                           panel = .none
                       },
                       /* 面板里的「＋」：去表情商店加表情包 */
                       onOpenStore: { panel = .none; showStickerStore = true },
                       /* 「拍摄表情」：拍一张直接加进「我添加的表情」 */
                       onCaptureSticker: { panel = .none; showCaptureSticker = true },
                       mine: myStickers)
        case .plus:
            PlusPanel(items: plusItems,
                      onTap: { item in handlePlus(item) },
                      onLongPress: { item in handlePlusLong(item) })
        case .mention:
            MentionPanel(members: mentionMembers,
                         query: $mentionQuery,
                         canAtAll: chat.ownerId == myId,
                         title: { mentionName($0) },
                         onPick: { pickMention($0) },
                         onPickAll: { pickMentionAll() })
        case .gift:
            GiftPanel(gifts: gifts) { gift in
                let payload = "{\"id\":\"\(gift.id)\",\"name\":\"\(gift.name ?? "礼物")\",\"icon\":\"\(gift.icon ?? "🎁")\",\"price\":\(Int(gift.price ?? 0))}"
                send(kind: "gift", content: payload)
                panel = .none
            }
        case .none:
            EmptyView()
        }
    }

    /* ---------------------------------------------------------- 各个动作 */

    private func handlePlus(_ item: PlusItem) {
        switch item.action ?? "none" {
        case "photo":
            panel = .none
            showPhoto = true
        case "camera":
            panel = .none
            showCamera = true
        case "location":
            panel = .none
            showLocationMenu = true
        case "gift":
            panel = .gift
            if gifts.isEmpty { Task { gifts = (try? await API.shared.gifts()) ?? [] } }
        case "transfer":
            panel = .none
            showTransfer = true
        case "file":
            panel = .none
            openFilePicker()
        case "videocall":
            panel = .none
            if (chat.botRank ?? 9) < 9 {
                showCall = true                       // 机器人：走 AI 通话
            } else {
                /* 微信的写法：点「视频通话」不是直接拨，而是弹出「语音通话 / 视频通话」两个选择 */
                showCallChoice = true
            }
        case "voice":
            panel = .none
            app.show(Tr("按住输入框左边的麦克风说话：松开发送，上滑取消"))
        case "redpacket":
            panel = .none
            showSendRedPacket = true
        case "favorite":
            panel = .none
            app.show(Tr("收藏夹还是空的"))
        case "card":
            panel = .none
            showPickCard = true
        case "music":
            /* 微信「＋ → 音乐」：从曲库挑一首，发出去是一张音乐卡片 */
            panel = .none
            showPickMusic = true
        default:
            app.show("\(item.label ?? "")排在下一批")
        }
    }

    /// 收起打字键盘 / 表情面板（点聊天区域、或者滑动聊天区域时调用）
    private func dismissTyping() {
        if panel != .none { panel = .none }
        if focused { focused = false }
    }

    /// 把「我的表情」拉回来（表情面板「我的」那一屏用）
    private func loadMyStickers() async {
        if let r = try? await API.shared.stickerShop() { myStickers = r.mine }
    }

    /// 拍了一张表情：裁成小方图 → 上传 → 加进「我添加的表情」→ 直接发给对方
    private func captureSticker(_ image: UIImage) {
        app.show(Tr("正在添加表情…"))
        Task {
            guard let url = try? await API.shared.upload(image: image) else {
                app.show(Tr("表情上传失败，再试一次"))
                return
            }
            await API.shared.addSingleSticker(url)
            await loadMyStickers()
            app.show(Tr("已添加到我的表情"))
        }
    }

    /// 「＋ → 音乐」挑好一首：发一张音乐卡片（封面 + 歌名 + 歌手 + 音频地址）
    private func sendMusic(_ t: MusicTrack) {
        let body: [String: Any] = [
            "id": t.id,
            "title": t.title,
            "artist": t.artist ?? "",
            "cover": t.cover ?? "",
            "url": t.url
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: body),
              let json = String(data: d, encoding: .utf8) else { return }
        send(kind: "music", content: json)
    }

    private func sendText() {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return }
        /* 「星联世界」这一页默认是新闻排版：一旦开始跟它说话，就自动切回对话，
           不然它的回答被新闻流盖着，用户会以为「发出去没反应」 */
        if isStarWorld, newsMode { withAnimation(.easeInOut(duration: 0.18)) { newsMode = false } }
        /* 引用：**结构化**发给服务端（微信那种引用卡片：上面一条带缩略图的引用条，
           点一下能跳到原消息）—— 不再把「「谁：摘要」」硬拼进正文里。 */
        let quotePayload = quoteFields(quote)
        input = ""
        quote = nil
        reEditDraft = nil
        /* 这条 @ 了谁：一起带给服务端（被 @ 的人那边出「有人@我」）。
           发送前再对一遍正文 —— 用户可能把选好的「@某某」删掉了，那就当他没 @ 过（微信也是这样）。 */
        let ids = mentionIds.filter { id in
            guard let u = mentionMembers.first(where: { $0.id == id }) else { return true }
            return text.contains("@" + mentionName(u))
        }
        mentionIds = []
        /* 手打的 [微笑] 这类码，发出去之前换成表情（微信也是打字出表情） */
        send(kind: "text", content: ClassicEmojiSet.expand(text), mentions: ids, quote: quotePayload)
    }

    /// 把要引用的那条消息收拾成服务端认识的一小包（id / 谁 / 类型 / 摘要 / 缩略图）
    private func quoteFields(_ q: Message?) -> [String: Any]? {
        guard let q = q, !q.id.isEmpty else { return nil }
        let who = q.senderId == myId ? Tr("我") : displayName(q)
        var d: [String: Any] = ["id": q.id, "who": who, "kind": q.kindName]
        switch q.kindName {
        case "text":
            d["text"] = String(q.body.prefix(90))
        case "image":
            d["text"] = Tr("[图片]")
            d["thumb"] = q.imagePath
        case "images":
            d["text"] = Tr("[图片]")
            if let p = Self.firstImagePath(q.body) { d["thumb"] = p }
        case "audio":
            d["text"] = Tr("[语音]")
        case "video", "livephoto":
            d["text"] = Tr("[视频]")
        default:
            d["text"] = "[" + q.kindName + "]"
        }
        return d
    }

    /// 九宫格那条消息（{"paths":[...]}）里的第一张图：引用卡片拿它当缩略图
    private static func firstImagePath(_ body: String) -> String? {
        guard let d = body.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let paths = o["paths"] as? [String], let first = paths.first, !first.isEmpty else { return nil }
        return first
    }

    /* ---------------------------------------------------------- 群里 @ 某人 */

    /// 刚敲进去的那个字符是不是「@」（删字、整体替换都不算）
    private func justTypedAtSign(from old: String, to new: String) -> Bool {
        let a = Array(old), b = Array(new)
        guard b.count == a.count + 1 else { return false }
        for i in 0..<b.count {
            if i >= a.count { return b[i] == "@" }     // 加在末尾
            if b[i] != a[i] { return b[i] == "@" }     // 插在中间
        }
        return false
    }

    /// 打开群成员浮层（微信：打完 @ 键盘就收起来，让成员列表占满下面）
    private func openMentionPicker() {
        mentionQuery = ""
        panel = .mention
        focused = false
        guard mentionMembers.isEmpty else { return }
        Task {
            if let r = try? await API.shared.chatMembers(chatId: chat.id) {
                mentionMembers = r.members.filter { $0.id != myId }
            }
        }
    }

    /// 选人时写进正文的名字：和服务端算的显示名保持一致（备注 → 昵称 → 微信号），
    /// 这样就算老版本客户端发的消息，服务端也能按名字认出「@了谁」
    private func mentionName(_ u: User) -> String {
        /* 群里设了群昵称就用群昵称（微信 @ 出来的就是群昵称） */
        if let a = u.alias, !a.isEmpty { return a }
        if let r = app.contact(for: u.id)?.remark, !r.trimmingCharacters(in: .whitespaces).isEmpty { return r }
        if let n = u.nickname, !n.isEmpty { return n }
        return u.username ?? Tr("成员")
    }

    /// 选中一个成员：把「@昵称 」插进草稿（原来打的那个 @ 换成它）
    private func pickMention(_ u: User) {
        insertMention(mentionName(u))
        if !mentionIds.contains(u.id) { mentionIds.append(u.id) }
    }

    /// 群里 @所有人（只有群主能用；服务端按这条文本给全体成员发提示）
    private func pickMentionAll() {
        insertMention(Tr("所有人"))
    }

    private func insertMention(_ name: String) {
        if input.hasSuffix("@") { input.removeLast() }
        if !input.isEmpty, !input.hasSuffix(" ") { input += " " }
        input += "@" + name + " "
        mentionQuery = ""
        panel = .none
        focused = true
    }

    /// 点聊天里的图片：把那一条所在的整个会话的图片都收进去，可以左右翻
    private func openImage(_ path: String) {
        /* 单张的（image）+ 九宫格里的（images）都收进来，点哪张都能左右翻 */
        var all: [String] = []
        for m in messages where !m.isRecalled {
            if m.kindName == "image" {
                all.append(m.imagePath)
            } else if m.kindName == "images" {
                if let data = m.body.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let paths = obj["paths"] as? [String] {
                    all.append(contentsOf: paths)
                }
            }
        }
        guard !all.isEmpty else { return }
        viewer = PhotoPager.Item(paths: all, index: all.firstIndex(of: path) ?? 0)
    }

    /// 点头像 → 名片。自己的头像是自己的名片；查不到的（陌生人 / 群里的人）现拉一次
    private func openAvatar(_ senderId: String) {
        let id = senderId.isEmpty ? myId : senderId
        if id.isEmpty { return }
        /* 机器人：不用去通讯录找，直接弹它自己的名片（AI 助手 / 腾讯新闻） */
        if (chat.botRank ?? 9) < 9, senderId.isEmpty || senderId == peerUserId {
            botCard = true
            return
        }
        if id == myId, let me = app.me { cardUser = me; return }
        if let u = app.contact(for: id) { cardUser = u; return }
        Task {
            if let u = try? await API.shared.user(id: id) { cardUser = u }
            else { app.show(Tr("打不开这个人的名片")) }
        }
    }

    /// 点名片气泡 → 打开那个人的资料页（不是好友的话，资料页上就能直接「添加到通讯录」）
    private func openCardUser(_ id: String) {
        guard !id.isEmpty else { return }
        if let u = app.contact(for: id) { cardUser = u; return }
        Task {
            if let u = try? await API.shared.user(id: id) { cardUser = u }
            else { app.show(Tr("打不开这个人的名片")) }
        }
    }

    /// 长按「拍照」→ 拍视频（微信就是这么干的：点一下拍照片，按住拍小视频）。
    /// 返回 true 表示这一下长按被接住了，面板里就不再把它当成点击。
    private func handlePlusLong(_ item: PlusItem) -> Bool {
        guard (item.action ?? "").lowercased() == "camera" else { return false }
        panel = .none
        showCameraVideo = true
        return true
    }

    /// 相机里录完那段视频 → 取第一帧当封面 → 直接发出去（微信也是拍完就发）
    private func sendRecordedVideo(_ url: URL) {
        Task {
            /* ★ 系统相机录完给的那个文件**在临时目录里**，我们把相机界面一收，
               系统随时可能把它清掉 —— 上传到一半文件没了，对方就"视频加载不出来"。
               所以先把它拷进我们自己的临时目录再走后面那套（和相册选的视频一模一样）。 */
            var file = url
            let dst = FileManager.default.temporaryDirectory
                .appendingPathComponent("shot-\(Int(Date().timeIntervalSince1970 * 1000)).mov")
            if (try? FileManager.default.copyItem(at: url, to: dst)) != nil { file = dst }
            let cover = await MediaTool.firstFrame(file)
            /* 等相机那个 sheet 收干净再发，不然上传/气泡插进去的时候界面还在收 sheet */
            try? await Task.sleep(nanoseconds: 200_000_000)
            sendMedia(.video(file, cover), live: false, original: false)
        }
    }

    /// 发名片：选完联系人以后，把「名片」当一条消息发出去
    /// （收到的人点这张卡片就能进那个人的资料页，不是好友就能加 —— 微信那套）
    private func sendCard(_ u: User) {
        Task {
            /* 通讯录那份资料不一定带「星言号 / 头像」（列表接口为了省流量只给最少的字段），
               直接拿它拼名片的话，对方收到的卡片上**只有名字** ——
               用户反馈的「名片出来还是只是名字」就是这个。
               所以发之前补一次完整资料（拿不到就用原来那份，不会卡住发送）。 */
            var name = u.name
            var username = u.username ?? ""
            var avatar = u.avatarPath
            if username.isEmpty || avatar.isEmpty {
                if let full = try? await API.shared.user(id: u.id) {
                    name = full.name.isEmpty ? name : full.name
                    username = (full.username ?? "").isEmpty ? username : (full.username ?? "")
                    avatar = full.avatarPath.isEmpty ? avatar : full.avatarPath
                }
            }
            let body: [String: Any] = [
                "userId": u.id,
                "name": name,
                "avatar": avatar,
                "username": username
            ]
            let json = (try? JSONSerialization.data(withJSONObject: body))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            send(kind: "card", content: json)
        }
    }

    private func send(kind: String, content: String, mentions: [String] = [],
                      quote: [String: Any]? = nil) {
        /* 同上：星联世界那一页只要往外发东西，就切回对话，别让回答被新闻流盖住 */
        if isStarWorld, newsMode { withAnimation(.easeInOut(duration: 0.18)) { newsMode = false } }
        /* 微信那边：消息**先上屏**（发送中），发不出去就留在列表里打个红叹号，
           网络回来自动重发 —— 不弹「发送失败」把字塞回输入框。 */
        /* 引用那包是字典（[String: Any] 不能直接进 Hashable 的结构体），
           落成 JSON 字符串存着，发的时候再解回来。 */
        var qJSON: String?
        if let q = quote, !q.isEmpty,
           let d = try? JSONSerialization.data(withJSONObject: q) {
            qJSON = String(data: d, encoding: .utf8)
        }
        outbox.append(PendingMsg(id: UUID().uuidString, kind: kind, content: content,
                                 mentions: mentions, quoteJSON: qJSON))
        saveOutbox()
        pinToBottomSoon(force: true)
        Task { await flushOutbox() }
    }

    /// 把队列里还没发出去的一条条发掉：成功就从队列拿掉（正式消息并入列表），
    /// 失败就留着等下一轮重试（页面顶上的离线提示会告诉用户现在收不到新消息）。
    @MainActor
    private func flushOutbox() async {
        guard !flushing, !outbox.isEmpty else { return }
        flushing = true
        defer { flushing = false }
        for p in outbox.filter({ !$0.sending }) {
            guard let idx = outbox.firstIndex(where: { $0.id == p.id }) else { continue }
            outbox[idx].sending = true
            outbox[idx].failed = false
            do {
                if let message = try await API.shared.send(chatId: chat.id, kind: p.kind, content: p.content,
                                                           mentions: p.mentions, clientId: p.id,
                                                           quote: Self.quoteDict(p.quoteJSON)) {
                    messages.append(message)
                }
                outbox.removeAll { $0.id == p.id }
            } catch {
                if let i2 = outbox.firstIndex(where: { $0.id == p.id }) {
                    outbox[i2].sending = false
                    outbox[i2].failed = true
                }
            }
        }
        saveOutbox()
        await app.loadChats()
    }

    /// 点红包卡片：还能抢就直接拆红包；自己发的 / 已领过 / 领完 / 过期 → 看详情
    private func tapRedPacket(_ info: RedPacketInfo) {
        if info.fromId != myId && info.stillOpen && !info.claimed(by: myId) {
            openRedPacket = info
        } else {
            redPacketDetail = info.id
        }
    }

    /* ---------------------------------------------------------- 发视频 / 实况（和微信一致） */

    /// dataURL → UIImage（视频封面预览用）
    private func dataURLToImage(_ s: String) -> UIImage? {
        guard let comma = s.firstIndex(of: ","),
              let data = Data(base64Encoded: String(s[s.index(after: comma)...])) else { return nil }
        return UIImage(data: data)
    }

    /// [String] → JSON 数组字符串（九宫格那条消息的 body 就是这个）
    private static func jsonStringArray(_ items: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: items),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    /// 预览页点「发送」：按「实况」「原图」两个开关决定怎么发
    private func sendMedia(_ p: MediaSendSheet.Payload, live: Bool, original: Bool) {
        switch p {
        case .image(let img):
            uploading = true
            let px = img.sendPixelSize
            Task {
                let t0 = Date()
                do {
                    let up = try await API.shared.uploadImageForSend(img, original: original)
                    let url = up.url
                    seedLocalImage(url, img, data: up.data)
                    let tUp = Date()
                    if let m = try await API.shared.send(chatId: chat.id, kind: "image", content: url,
                                                         imgW: px.w, imgH: px.h) {
                        messages.append(m)
                    }
                    let tSend = Date()
                    Task { await API.shared.callDiag("发图(+) 压+传=\(Int(tUp.timeIntervalSince(t0) * 1000))ms"
                        + " 发送=\(Int(tSend.timeIntervalSince(tUp) * 1000))ms"
                        + " 原图=\(original ? 1 : 0) 原始=\(Int(img.size.width))x\(Int(img.size.height))") }
                } catch { app.show((error as? APIError)?.errorDescription ?? "图片发送失败") }
                uploading = false
                await app.loadChats()
            }

        case .images(let list):
            /* 一次选了好几张：
               · 4 张及以上 → 合成**一条**消息，聊天气泡里排成九宫格
               · 2~3 张     → 还是一张一条（这是明确要求过的规则，别改） */
            guard !list.isEmpty else { return }
            CrashCatcher.note("发图", "多选 \(list.count) 张，开始上传")
            uploading = true
            Task {
                do {
                    var urls: [String] = []
                    var dims: [(w: Int, h: Int)] = []
                    /* ⚠ 2026-10-14 用户反馈「发多图变慢」：原来是**一张一张串行**上传，
                       实测手机↔服务器只有几百 KB/s，9 张串行 ≈ 9 秒。
                       改成**并行 3 张**（9 张 ≈ 3 轮），结果按原下标回填 → 九宫格顺序不变。 */
                    var upResults: [(idx: Int, url: String, w: Int, h: Int, data: Data)] = []
                    var upError: String? = nil
                    await withTaskGroup(of: (Int, String, Int, Int, Data, String?).self) { group in
                        var nextIdx = 0
                        func addUpload(_ i: Int) {
                            let img = list[i]
                            let px = img.sendPixelSize
                            group.addTask {
                                do {
                                    let up = try await API.shared.uploadImageForSend(img, original: original)
                                    return (i, up.url, px.w, px.h, up.data, nil)
                                } catch {
                                    return (i, "", 0, 0, Data(),
                                            (error as? APIError)?.errorDescription ?? "图片上传失败")
                                }
                            }
                        }
                        while nextIdx < min(3, list.count) { addUpload(nextIdx); nextIdx += 1 }
                        for await r in group {
                            if let e = r.5 {
                                if upError == nil { upError = e }
                            } else {
                                upResults.append((idx: r.0, url: r.1, w: r.2, h: r.3, data: r.4))
                            }
                            if nextIdx < list.count { addUpload(nextIdx); nextIdx += 1 }
                        }
                    }
                    if let e = upError, upResults.count != list.count { throw APIError.message(e) }
                    for r in upResults.sorted(by: { $0.idx < $1.idx }) {
                        urls.append(r.url)
                        dims.append((w: r.w, h: r.h))
                        seedLocalImage(r.url, list[r.idx], data: r.data)
                    }
                    if urls.count >= 4 {
                        CrashCatcher.note("发图", "合成一条九宫格（\(urls.count) 张）")
                        let body = "{\"paths\":" + Self.jsonStringArray(urls) + "}"
                        if let m = try await API.shared.send(chatId: chat.id, kind: "images", content: body) {
                            messages.append(m)
                        }
                    } else {
                        CrashCatcher.note("发图", "\(urls.count) 张，分开一条一条发")
                        for (i, u) in urls.enumerated() {
                            let d: (w: Int, h: Int) = i < dims.count ? dims[i] : (w: 0, h: 0)
                            if let m = try await API.shared.send(chatId: chat.id, kind: "image", content: u,
                                                                 imgW: d.w, imgH: d.h) {
                                messages.append(m)
                            }
                        }
                    }
                } catch { app.show((error as? APIError)?.errorDescription ?? "图片发送失败") }
                uploading = false
                await app.loadChats()
            }

        case .video(let url, let preview):
            uploading = true
            sendProgress = 0.02          // 一出现就有一小段弧，不是"卡住的图标"
            sendingPreview = preview
            sendingMedia = Tr("视频发送中…")
            scrollTick += 1                 // 立刻滚到「发送中」的气泡，进度条看得见
            Task {
                /* ① 封面：预览页那张现成的先用（本来就有），没有再抽第一帧 ——
                      这样"发送中"的气泡立刻就有画面，不用等处理完（微信也是马上出封面）。 */
                let cover: UIImage?
                if let p = preview { cover = p } else { cover = await MediaTool.firstFrame(url) }
                if cover != nil { sendingPreview = cover }
                /* 封面很小，和视频上传**并行**传掉，省掉最后那一下等待 */
                let coverTask = Task { () -> String? in
                    guard let c = cover else { return nil }
                    let up = try? await API.shared.uploadImageForSend(c, original: false)
                    if let up = up { seedLocalImage(up.url, c, data: up.data) }
                    return up?.url
                }
                /* ② 压缩：小视频直接跳过（重编码最费时间，跳掉能快十几秒）；
                      真要压就把进度映射到 0～45%，边压边看得到动 */
                var file = url
                /* 上传这一段在整条进度里从哪开始算：压过就是 45% 起，没压直接从 0 起 */
                var uploadFrom = 0.0
                if !original, await MediaTool.needsCompress(url) {
                    sendingMedia = Tr("视频压缩中…")
                    uploadFrom = 0.45
                    file = (await MediaTool.compress(url) { p in
                        DispatchQueue.main.async { sendProgress = min(0.45, p * 0.45) }
                    }) ?? url
                    sendingMedia = Tr("视频发送中…")
                }
                /* ③ 上传视频（真实进度：压缩占前 45%，上传占剩下的） */
                let secs = await MediaTool.seconds(file)
                /* 视频本身的宽高一起带上：气泡按这个比例显示（微信逻辑）——
                   不然横着拍的会被裁成竖的、竖着拍的会被裁成横的 */
                let wh = await MediaTool.aspect(file)
                let from = uploadFrom
                guard let up = await MediaTool.upload(file, onProgress: { p in
                    DispatchQueue.main.async { sendProgress = from + p * (1 - from) }
                }, skipServerTranscode: !original) else {
                    uploading = false
                    sendingMedia = ""
                    sendingPreview = nil
                    app.show(Tr("视频上传失败"))
                    return
                }
                /* 自己发的视频：本机留一份底（不占内存，只拷文件）——
                   播自己的这条时直接播本地，不用再把整段视频下一遍。 */
                LocalStore.keepOriginal(up, from: file)
                var body: [String: Any] = ["url": up, "seconds": secs]
                if let wh = wh { body["w"] = wh.w; body["h"] = wh.h }
                /* 封面必须上传成服务器路径（以前塞的是 dataURL，气泡加载不出来 → 「不显示」） */
                if let cp = await coverTask.value {
                    body["cover"] = cp
                }
                let json = (try? JSONSerialization.data(withJSONObject: body)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                if let m = try? await API.shared.send(chatId: chat.id, kind: "video", content: json) {
                    messages.append(m)
                }
                uploading = false
                sendingMedia = ""
                sendingPreview = nil
                await app.loadChats()
            }

        case .live(let img, let url):
            /* 微信：实况开关没打开 → 就按普通图片发 */
            if !live { sendImage(img); return }
            uploading = true
            sendProgress = 0.02
            sendingPreview = img
            sendingMedia = Tr("实况发送中…")
            scrollTick += 1
            Task {
                do {
                    let up = try await API.shared.uploadImageForSend(img, original: original)
                    let iurl = up.url
                    seedLocalImage(iurl, img, data: up.data)
                    DispatchQueue.main.async { sendProgress = 0.25 }
                    var file = url
                    var uploadFrom = 0.25
                    if !original, await MediaTool.needsCompress(url) {
                        sendingMedia = Tr("实况压缩中…")
                        file = (await MediaTool.compress(url) { p in
                            DispatchQueue.main.async { sendProgress = 0.25 + p * 0.15 }
                        }) ?? url
                        uploadFrom = 0.4
                        sendingMedia = Tr("实况发送中…")
                    }
                    let from = uploadFrom
                    guard let vurl = await MediaTool.upload(file, onProgress: { p in
                        DispatchQueue.main.async { sendProgress = from + p * (1 - from) }
                    }, skipServerTranscode: !original) else { throw APIError.message("实况上传失败") }
                    /* 实况里那段视频也一样：本机留底，自己看的时候直接播本地 */
                    LocalStore.keepOriginal(vurl, from: file)
                    let body: [String: Any] = ["image": iurl, "video": vurl]
                    let json = (try? JSONSerialization.data(withJSONObject: body)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    if let m = try await API.shared.send(chatId: chat.id, kind: "livephoto", content: json) {
                        messages.append(m)
                    }
                } catch { app.show((error as? APIError)?.errorDescription ?? "实况发送失败") }
                uploading = false
                sendingMedia = ""
                sendingPreview = nil
                await app.loadChats()
            }
        }
    }

    /// 自己刚发出去的图片（或视频封面）：按**「下载过一次的图」同样的待遇**缓存到本机。
    ///
    /// 为什么必须这样：气泡里的图是 `RemoteImage(path:)` **按服务器地址**拉的，
    /// 所以以前发完一条图片消息，发送端自己还得把同一张图从服务器再下载一遍才显示 ——
    /// 线路一慢（实测这条线只有 ~50KB/s）就变成「发了图片要一会才出来」。
    ///
    /// 三级都写：
    ///   ① ImageStore 内存 —— 气泡立刻显示，一点不卡；
    ///   ② ImageStore 磁盘缓存（Caches）—— 重开 App、清内存后也不用重新下载；
    ///   ③ LocalStore（Documents/Local/Media）—— 长期留底，和下载下来的图一个待遇。
    private func seedLocalImage(_ path: String, _ image: UIImage, data: Data) {
        guard !path.isEmpty else { return }
        ImageStore.shared.put(path, image)
        ImageSizeCache.put(path, ImageBubble.thumb(image.size))
        guard !data.isEmpty else { return }
        Task.detached(priority: .utility) {
            ImageStore.shared.diskWrite(path, data)
            LocalStore.keep(path, data: data)
        }
    }

    private func sendImage(_ image: UIImage) {
        uploading = true
        let px = image.sendPixelSize
        Task {
            let t0 = Date()
            do {
                let up = try await API.shared.uploadImageForSend(image, original: false)
                let url = up.url
                /* 手里就有这张图：直接塞进图片缓存，气泡立刻显示，
                   不用再等服务器把同一张图传回来（见 seedLocalImage 的说明）。 */
                seedLocalImage(url, image, data: up.data)
                let tUp = Date()
                if let message = try await API.shared.send(chatId: chat.id, kind: "image", content: url,
                                                           imgW: px.w, imgH: px.h) {
                    messages.append(message)
                }
                let tSend = Date()
                /* 诊断（写进服务器 call-trace.log）：图发得慢的时候，
                   一眼分清是「压图+上传」慢还是「发消息」慢。 */
                Task { await API.shared.callDiag("发图 压+传=\(Int(tUp.timeIntervalSince(t0) * 1000))ms"
                    + " 发送=\(Int(tSend.timeIntervalSince(tUp) * 1000))ms"
                    + " 原始=\(Int(image.size.width))x\(Int(image.size.height))") }
            } catch {
                app.show((error as? APIError)?.errorDescription ?? "图片发送失败")
            }
            uploading = false
            await app.loadChats()
        }
    }

    /* ---------------------------------------------------------- 按住说话 */

    /// 松手：录到了就发，太短/取消了就啥也不做
    private func finishVoice() {
        guard let got = recorder.end() else { return }
        sendVoice(url: got.url, seconds: got.seconds)
    }

    /// 长按别人/自己发的语音 → 转文字：把这条语音下下来，在本机识别，弹卡片显示（可复制）
    private func transcribeMessage(_ m: Message) {
        guard let data = m.body.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = o["url"] as? String,
              let url = API.shared.assetURL(path) else {
            app.show(Tr("这条语音找不到了"))
            return
        }
        asrCache.removeValue(forKey: m.id)
        asrBusy.insert(m.id)
        Task {
            defer { asrBusy.remove(m.id) }
            guard await FileSpeech.authorize() else {
                app.show(Tr("请先在 设置 → 星言 → 语音识别 里允许，才能转文字"))
                return
            }
            var text = ""
            if let d = try? await API.shared.assetData(url), !d.isEmpty {
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("asr-\(m.id).m4a")
                try? d.write(to: tmp)
                text = await FileSpeech.recognize(url: tmp)
                try? FileManager.default.removeItem(at: tmp)
            }
            if text.isEmpty {
                app.show(Tr("没听清，再说一次或者直接发语音"))
            } else {
                /* 就贴在语音气泡下面（微信那样），点一下可以复制。
                   带一点入场动画：卡片从上面滑进来淡入。 */
                VoiceText.set(m.id, text)      // 存本机：下次进聊天还在
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    asrCache[m.id] = text
                }
            }
        }
    }

    /// 上滑「转文字」：先在本地识别成文字，再填进输入框（微信就是这样，用户能改完再发）。
    /// 关键点：**先等授权**。以前是先 requestAuth 再马上识别 —— 第一次用必然失败，
    /// 用户看到的就是「没听清，再说一次」。
    private func transcribeToInput(_ url: URL) {
        Task {
            guard await FileSpeech.authorize() else {
                app.show(Tr("请先在 设置 → 星言 → 语音识别 里允许，才能转文字"))
                return
            }
            let text = await FileSpeech.recognize(url: url)
            if text.isEmpty {
                app.show(Tr("没听清，再说一次或者直接发语音"))
            } else {
                input = text
                voiceMode = false          // 切回键盘，文字直接可编辑
            }
        }
    }

    private func sendVoice(url: URL, seconds: Int) {
        Task {
            uploading = true
            defer { uploading = false }
            /* 真人变声：选了不是「原声」的预设，先在本机把这段语音处理一遍再上传
               （后台线程，失败就原样发原声，绝不会因为变声发不出去） */
            let effect = VoiceChangerStore.shared.current
            var file = url
            if effect.id != "origin" {
                file = await Task.detached(priority: .userInitiated) {
                    VoiceChanger.process(url, preset: effect)
                }.value
            }
            guard let data = try? Data(contentsOf: file), !data.isEmpty else {
                app.show(Tr("录音读不到，再录一次"))
                return
            }
            let payload: [String: Any] = [
                "dataUrl": "data:audio/mp4;base64," + data.base64EncodedString(),
                "filename": "voice.m4a"
            ]
            do {
                let up = try await API.shared.rawUpload(payload)
                let body = "{\"url\":\"\(up.url)\",\"seconds\":\(seconds),\"bytes\":\(data.count)}"
                send(kind: "audio", content: body)
            } catch {
                app.show((error as? APIError)?.errorDescription ?? "语音发送失败")
            }
            try? FileManager.default.removeItem(at: url)
            if file != url { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func sendFile(_ url: URL) {
        Task { await uploadAndSendFile(url) }
    }

    /// 一次选了好几个文件：按顺序发（一个一个来，别一次并发上传一堆）
    private func sendFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            for u in urls { await uploadAndSendFile(u) }
        }
    }

    /// 点「＋ → 文件」：默认开**我们自己的文件页**（我的文件）；
    /// 管理里把 filePickerSystem 打开（= 1）才回到苹果那个文件 App 的选法。
    private func openFilePicker() {
        if UIConfig.num("filePickerSystem", 0) > 0 {
            showFile = true
        } else {
            showMyFiles = true
        }
    }

    /// 在自己的文件页点了一个文件：它已经在服务器上了，直接把这条 file 消息发出去
    /// （不用再上传一遍，也就不用等进度条）
    private func sendExistingFile(_ f: API.MyFileItem) {
        let url = f.url ?? ""
        guard !url.isEmpty else { app.show(Tr("这个文件找不到了")); return }
        let name = f.fileName.replacingOccurrences(of: "\"", with: "")
                      .replacingOccurrences(of: "\\", with: "")
        let content = "{\"url\":\"\(url)\",\"name\":\"\(name)\",\"bytes\":\(f.bytes ?? 0)}"
        send(kind: "file", content: content)
    }

    private func uploadAndSendFile(_ url: URL) async {
        let name = url.lastPathComponent
        uploading = true
        defer { uploading = false }
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        /* 太大先说清楚：服务器单文件上限 80MB（base64 传过去还要再涨 1/3），
           不然用户等到最后只看到一句「文件发送失败」 */
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let sizeBytes = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        if sizeBytes > 80 * 1024 * 1024 {
            app.show(Tr("这个文件超过 80MB，先压缩一下再发"))
            return
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            app.show(Tr("读不到这个文件"))
            return
        }
        let b64 = data.base64EncodedString()
        let payload: [String: Any] = ["dataUrl": "data:application/octet-stream;base64," + b64,
                                      "filename": name]
        do {
            let bytes = try await API.shared.rawUpload(payload)
            let content = "{\"url\":\"\(bytes.url)\",\"name\":\"\(name)\",\"bytes\":\(data.count)}"
            if let message = try await API.shared.send(chatId: chat.id, kind: "file", content: content) {
                messages.append(message)
            }
        } catch {
            app.show((error as? APIError)?.errorDescription ?? "文件发送失败")
        }
        await app.loadChats()
    }

    /// 点文件气泡：把文件下到本机，再用系统预览打开（可分享 / 用其他应用打开）
    private func openFile(_ body: String) {
        guard let data = body.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = o["url"] as? String,
              let remote = API.shared.assetURL(path) else {
            app.show(Tr("这个文件找不到了"))
            return
        }
        let raw = (o["name"] as? String) ?? "文件"
        /* 文件名少扩展名就从 url 里借一个：QuickLook 靠扩展名判断类型，
           没有 .docx / .xlsx 它就把 Word/Excel 当成不认识的二进制，表现就是"打不开"。 */
        let name = MyFilesPickerView.previewName(raw, path: path)
        app.show(Tr("正在打开…"))
        Task {
            guard let d = try? await API.shared.assetData(remote), !d.isEmpty else {
                app.show(Tr("文件下载失败，检查一下网络"))
                return
            }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            do { try d.write(to: tmp) } catch {
                app.show(Tr("存不进本机，看看手机空间够不够"))
                return
            }
            filePreview = FilePreviewData(name: name, local: tmp)
        }
    }

    private func doTransfer(amount: Double, note: String, method: String, password: String) {
        Task {
            do {
                try await API.shared.transfer(chatId: chat.id, amount: amount, note: note,
                                              method: method, password: password)
                await load(initial: true)
                await app.loadChats()
                app.show("已转账 ¥\(moneyFmt(amount))")
            } catch {
                app.show((error as? APIError)?.errorDescription ?? "转账失败")
            }
        }
    }

    private func recall(_ message: Message) {
        /* 撤回自己刚发的文字 → 留着原件，底上出「重新编辑」（微信那套，5 分钟） */
        let draft = message.kindName == "text" ? message.body : ""
        Task {
            await API.shared.recall(chatId: chat.id, messageId: message.id)
            await load(initial: true)
            guard !draft.isEmpty else { return }
            reEditDraft = draft
            /* 5 分钟后自己收掉（微信也是过了时限就没了） */
            try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
            if reEditDraft == draft { reEditDraft = nil }
        }
    }

    /// 点引用条：跳到被引用的那条原消息（微信就是这么跳的）。
    /// 那条如果还在更早的历史里，就先把历史一页页拉下来再跳 —— 点了不能没反应。
    private func jumpToMessage(_ id: String) {
        guard !id.isEmpty else { return }
        if messages.contains(where: { $0.id == id }) {
            withAnimation(.easeInOut(duration: 0.25)) { scroller?.scrollTo(id, anchor: .center) }
            return
        }
        Task { @MainActor in
            var tries = 0
            while hasOlder, tries < 12, !messages.contains(where: { $0.id == id }) {
                await loadOlder()
                tries += 1
            }
            guard messages.contains(where: { $0.id == id }) else {
                app.show(Tr("那条消息在更早的记录里，往上翻就能看到"))
                return
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
            withAnimation(.easeInOut(duration: 0.25)) { scroller?.scrollTo(id, anchor: .center) }
        }
    }

    private func report(_ message: Message) {
        let target = message.senderId ?? ""
        guard !target.isEmpty else { return }
        Task {
            await API.shared.report(userId: target, chatId: chat.id,
                                    reason: "聊天内容举报",
                                    content: String(message.body.prefix(200)))
            app.show(Tr("已举报，管理员会处理"))
        }
    }

    /* ---------------------------------------------------------- 数据 */

    /// 消息区右下角那个小圆钮（↑ 回到最早用）：白底 + 细边 + 轻投影
    private func arrowButton<Icon: View>(_ action: @escaping () -> Void,
                                         @ViewBuilder icon: () -> Icon) -> some View {
        Button(action: action) {
            icon()
                .frame(width: 34, height: 34)
                .background(Circle().fill(C.cardBg.opacity(0.96)))
                .overlay(Circle().stroke(C.hairline, lineWidth: 0.5))
                .shadow(color: Color.black.opacity(0.18), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
    }

    /// 聊天记录写本机（用户要求「聊天信息也全部本地保存」）：
    /// 防抖 —— 消息一变就排一次，1.2 秒内多次变化合并成一次写，
    /// 免得边翻历史边反复序列化整段 JSON。
    private func schedulePersist() {
        persistTask?.cancel()
        /* ⚠ 落盘要放到**主线程外面**做（2026-10-12 改）：
           以前这个 Task 是 @MainActor，等于把「整段聊天记录 JSON 编码 + 写文件」
           压在主线程上 —— 会话大一点（几百上千条）就是几百毫秒到几秒不响应，
           再撞上"推送来了要重画列表"，主线程被堵住，系统 watchdog 直接把 App 杀掉
           （用户报的「点推送通知就闪退」「在聊天页收到消息就闪退」，日志里
             内存只有 45MB、一条崩溃栈都没有，就是这种被杀）。
           现在：先睡 1.2 秒（防抖），起来后在后台线程编码 + 写盘，主线程只负责安排。 */
        persistTask = Task { @MainActor [messages, chatId = chat.id] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if Task.isCancelled { return }
            let list = messages                       // 拷一份常量交给后台线程
            Task.detached(priority: .utility) {
                LocalStore.saveChat(chatId, list)
            }
        }
    }

    private func load(initial: Bool) async {
        /* 登录后同步下来的最近记录：先铺在界面上（微信也是先出内容再刷），
           然后再向服务器要最新的 —— 这样点开会话是"立刻有内容"，不是白屏等网络。 */
        if initial, messages.isEmpty, let cached = app.prefetched[chat.id], !cached.isEmpty {
            messages = cached
            hasOlder = true
        } else if initial, messages.isEmpty {
            /* 登录时没预取到（或者断网进会话）：用**本机留底的聊天记录**先铺上 ——
               用户要求「聊天信息也全部本地保存」，点开会话永远先有内容。 */
            let local = LocalStore.cachedChat(chat.id)
            if !local.isEmpty {
                messages = local
                hasOlder = true
            }
        }
        do {
            let result = try await API.shared.messages(chatId: chat.id, limit: 40)
            /* 不能只看条数和最后一条的 id：对方收款以后转账卡片还是同一条消息，
               只是 body 里的 status 从 pending 变成 received —— 以前这种情况会被
               当成「没变化」跳过，气泡就一直停在「待对方确认收款」。 */
            /* ⚠ 「有没有变化」只比最近这一页：用户往上翻过历史以后，本地条数本来就比
               这一页多，拿总数比会永远判成"变了"（列表跟着反复重画、位置乱跳）。 */
            let n = min(result.messages.count, messages.count)
            let same = n > 0
                && result.messages.last?.id == messages.last?.id
                && zip(result.messages.suffix(n), messages.suffix(n))
                    .allSatisfy { $0.id == $1.id && $0.body == $1.body }
            if initial || !same {
                /* 左上角未读数字：首次进来带上列表里的未读；之后只要多出别人的新消息就往上加 */
                if initial {
                    unreadHere = chat.unreadCount
                } else if !messages.isEmpty {
                    /* 用 seq 比，别看条数差 —— 上面翻过历史以后条数本来就对不上 */
                    let oldLastSeq = messages.last?.seq ?? 0
                    let incoming = result.messages.filter {
                        ($0.seq ?? 0) > oldLastSeq && $0.senderId != myId && $0.kindName != "system"
                    }.count
                    if incoming > 0 { unreadHere += incoming }
                }
                if messages.count > result.messages.count {
                    /* 用户已经往上看过更早的记录：这一刷新只换「最近一页」，
                       上面翻出来的历史原样留着（微信也是——看着老消息来了新消息，位置不动，
                       更不会把看过的历史弄丢）。 */
                    let oldestFresh = result.messages.first?.seq ?? 0
                    let older = messages.filter { ($0.seq ?? 0) < oldestFresh }
                    messages = older + result.messages
                } else {
                    messages = result.messages
                }
                if initial { hasOlder = result.hasMore }
                /* 回执：这些消息已经到我手机上了（后台投递日志按这个算"已送达"） */
                if let last = result.messages.last, let sq = last.seq {
                    Realtime.shared.ackDelivery(chatId: chat.id, seq: sq)
                }
            }
        } catch {
            if initial { app.show(Tr("聊天记录加载失败")) }
        }
        rebuildIndex()          // 消息列表变了：把「id → 下标」的表重建一次
        loading = false
        autoOpenShopCard()
        /* 阅后即焚（2026-10-13 接回来）：这个会话开着就顺手扫一遍 ——
           我这边看过的那些，服务端看过满 1 分钟会销毁，回来的 id 直接从列表里去掉。
           ⚠ 只加代码、不动视图层；外面还有 DeferredChatView 那层轻占位挡着首帧。 */
        if needBurnSweep {
            /* 限流：每 5 秒最多扫一次（以前每次 load 都扫 —— 配合服务端那个缓存 bug
               就变成「一秒扫两次、每次都说烧了 3 条」，客户端一直跳） */
            if Date().timeIntervalSince(lastBurnSweep) > 5 {
                lastBurnSweep = Date()
                let gone = await API.shared.burnSweep(chatId: chat.id)
                if !gone.isEmpty { burnAway(gone) }
            }
        }
    }

    /// 「焚毁」这一下：服务端到点销毁了那几条 → 轻震一下 + 弹一句提示 +
    /// 0.5 秒淡出收缩地把这几行收走（SwiftUI 自己就把「行消失」画成淡出收缩）。
    /// 小火苗上的倒计时文字：还剩几秒；归零写「焚毁…」（等服务器真删掉再收走这一行）
    private func burnCountText(_ deadline: Date, now: Date) -> String {
        let left = Int(deadline.timeIntervalSince(now).rounded(.up))
        if left > 0 { return "\(left)s" }
        return Tr("焚毁…")
    }

    private func burnAway(_ ids: [String]) {
        /* 同一条只烧一次（服务端要是又回了同一批 id，不再重复播动画、也不重复删） */
        let fresh = ids.filter { !burnedIds.contains($0) }
        guard !fresh.isEmpty else { return }
        burnedIds.formUnion(fresh)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        BurnFX.shared.fire()          // 焚烧动画（画在聊天页外面那层，见 BurnFX.swift）
        app.show(Tr("🔥 消息已焚毁"))
        withAnimation(.easeOut(duration: 0.5)) {
            messages.removeAll { fresh.contains($0.id) }
        }
        rebuildIndex()
    }

    /* 往上看更早的记录：服务端支持 before 翻页（一次 40 条），加载完把更早的接在前面 */
    private func loadOlder() async {
        guard !loadingOlder, let first = messages.first, let seq = first.seq else { return }
        loadingOlder = true
        lastOlderLoad = Date()
        defer { loadingOlder = false }
        do {
            /* 一次 60 条（服务端最多 100）：翻历史时来回次数少一半，手感更顺 */
            let r = try await API.shared.messages(chatId: chat.id, limit: 60, before: seq)
            hasOlder = r.hasMore
            /* 一页都没有 = 上面确实没有更早的了：把入口收掉，别让用户一直滑一直等 */
            guard !r.messages.isEmpty else { hasOlder = false; return }
            let keep = first.id
            holdScroll = true
            messages = r.messages + messages
            rebuildIndex()
            /* 把「原来第一条」钉回原来的位置：往上看的时候内容不会跳，
               也不会把用户手上正在拖的列表拽走（之前「划不动」就是这个坑）。 */
            if let proxy = scroller {
                ChatScrollDiag.shared.note("上翻加载完 → 钉回原位置")
                DispatchQueue.main.async { proxy.scrollTo(keep, anchor: .top) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { holdScroll = false }
        } catch {
            /* 这次没拉到（网络抖了）：把节流复位，用户再往上滑一下就能立刻重试 */
            lastOlderLoad = Date.distantPast
            app.show(Tr("聊天记录加载失败"))
        }
    }

    /// AI 发来的「点外卖 / 买东西」卡片：一到手就直接跳（装了淘宝跳淘宝 App，没装用 App 内网页），
    /// 不用用户自己去点那串网址。同一条只跳一次。
    private func autoOpenShopCard() {
        guard let last = messages.last, last.kindName == "link",
              last.senderId != myId, !autoOpened.contains(last.id),
              let link = ShopLink(json: last.body) else { return }
        autoOpened.insert(last.id)
        ShopOpener.open(link) { url in web = WebURL(url: url) }
    }
    /// 转账页预填的「收款账号」：一对一会话里对方的微信号；找不到就留空让用户自己填
    private var peerAccount: String {
        if let t = chat.title, let u = app.contacts.first(where: { ($0.nickname ?? "") == t || ($0.name ?? "") == t }) {
            return u.username ?? ""
        }
        return ""
    }
}

/* ============================================================ 单条消息 */

/// 系统消息行：通话记录就是「📞 通话时长 00:12」这样居中的一行灰字（和微信一样）。
/// 图标后台能换：ui.callRecord（语音）/ ui.callRecordVideo（视频）。
struct SystemLine: View {
    let message: Message

    var body: some View {
        HStack(spacing: 4) {
            if message.isCallRecord {
                CallIcon(key: message.isVideoCall ? "ui.callRecordVideo" : "ui.callRecord",
                         symbol: message.isVideoCall ? "video.fill" : "phone.fill",
                         builtin: message.isVideoCall ? I.callRecordVideo : I.callRecord,
                         size: 13, color: ink)
            }
            Text(message.body)
                .font(pf(13))
                .foregroundColor(ink)
                .multilineTextAlignment(.center)
        }
        /* 群里那些系统提示（「XXX 被移出了群聊」「XXX 加入了群聊」…）：
           微信是在聊天里居中一条**带底色的灰字**。我们以前是纯灰字（#AEAEB2）
           直接压在聊天背景上 —— 背景一花就看不清（用户反馈的「群里的字看不清」）。
           现在给它垫一层淡淡的底 + 换成深一点的灰。 */
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(C.chatTimeBg))
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }

    /// 没接通的通话记录用红色（微信里「未接听 / 已拒绝 / 已取消 / 对方无应答」都是红的）；
    /// 其余是灰字（不是黑字）—— 用 message.isBadCallRecord ，
    /// 正文和 call.state 一起看，新老记录都判得准。
    private var ink: Color {
        /* 系统提示用深一点的灰（#8A8A8E），不再用那个几乎看不见的 #AEAEB2 */
        guard message.isCallRecord else { return C.chatTimeInk }
        return message.isBadCallRecord ? Color(hex: 0xFA5151) : C.chatTimeInk
    }
}

/// 通话记录的气泡：电话/摄像机小图标 +「通话时长 00:12」（微信里通话记录就是这么一条气泡，
/// 自己打出去的在右边、对方打过来的在左边）
struct CallRecordBubble: View {
    let message: Message
    let mine: Bool

    var body: some View {
        HStack(spacing: 6) {
            CallIcon(key: message.isVideoCall ? "ui.callRecordVideo" : "ui.callRecord",
                     symbol: message.isVideoCall ? "video.fill" : "phone.fill",
                     builtin: message.isVideoCall ? I.callRecordVideo : I.callRecord,
                     size: 15, color: ink)
            Text(message.callText)
                .font(pf(L.chatFontSize))
                .foregroundColor(ink)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(BubbleFill(mine: mine))
        .frame(maxWidth: L.bubbleMaxW, alignment: mine ? .trailing : .leading)
    }

    /// 没接通的通话记录用红色；其余用**灰字**（以前这里用的是 bubbleText，
    /// 浅色模式下就是纯黑 —— 用户反馈的「无应答 / 已取消 都是黑色字」）。
    private var ink: Color {
        message.isBadCallRecord ? Color(hex: 0xFA5151) : C.msgTime
    }
}

struct MessageRow: View {
    let message: Message
    let mine: Bool
    /// 我自己的 id：红包卡片要判断「我抢过没有」
    var myId: String = ""
    var senderName: String = ""
    /// 气泡那个小尖角只画在「连发的第一条」上（微信就是这样，后面的气泡是普通圆角）
    var showTail: Bool = true
    /// 点转账卡片 → 打开账单详情
    var onTapTransfer: ((TransferInfo) -> Void)? = nil
    /// 点图片 → 打开大图
    var onOpenImage: ((String) -> Void)? = nil
    /// 点头像 → 名片
    var onOpenAvatar: ((String) -> Void)? = nil
    /// 点 AI 的「点外卖 / 买东西」卡片 → 打开（没装淘宝就用 App 内网页）
    var onOpenWeb: ((URL) -> Void)? = nil
    /// 点位置气泡 → 打开大地图
    var onOpenLocation: ((LocationPoint) -> Void)? = nil
    /// 点名片气泡 → 打开那个人的资料页（不是好友的话上面能直接加）
    var onOpenUserCard: ((String) -> Void)? = nil
    /// 点群里那条群公告卡片 → 进一整页看全文
    var onOpenAnnounce: ((String) -> Void)? = nil
    /// 点好友分享来的小游戏卡片 → 打开那个小游戏
    var onOpenMiniApp: ((MiniApp) -> Void)? = nil
    /// 点视频气泡 / 长按实况 → 交给聊天页去全屏播放
    var onOpenVideo: ((URL) -> Void)? = nil
    /// 双击头像 = 拍一拍（微信的手势）
    var onPat: ((String) -> Void)? = nil
    /// 点红包卡片 → 拆红包 / 看详情
    var onTapRedPacket: ((RedPacketInfo) -> Void)? = nil
    /// 这条语音已经转出来的文字（长按 → 转文字以后，像微信那样显示在气泡下面）
    var asrText: String = ""
    /// 正在识别这条语音
    var asrBusy: Bool = false
    /// 点文件气泡 → 打开预览（微信那样：能看、能用其他应用打开、能转发）
    var onOpenFile: ((String) -> Void)? = nil
    /// 点公众号文章的卡片 → 打开文章页
    var onOpenArticle: ((String) -> Void)? = nil
    /// 这一行的**高度变了**（图片解码完成等）→ 告诉聊天页，它要再贴一次底
    var onLayoutChanged: (() -> Void)? = nil
    /// 点引用条 → 跳到被引用的那条原消息（微信就是这么跳的）
    var onOpenQuote: ((String) -> Void)? = nil

    @EnvironmentObject var app: AppState
    /// 语音消息播放状态（哪条在播）
    @ObservedObject private var voicePlayer = VoicePlayer.shared
    /// 这次进聊天页里已经听过哪些语音（配合本机记录，用来点掉那个小红点）
    @State private var playedVoice: Set<String> = []
    /// 正在拖的那条语音的进度（0~1）；-1 = 没在拖
    @State private var voiceScrub: Double = -1
    /// 多图那条消息：相册堆叠是不是展开成九宫格了（本机记住，重进聊天还是上次的样子）
    @State private var albumOpen = false

    private var avatarPath: String {
        if let p = message.senderAvatar, !p.isEmpty { return p }
        return app.contact(for: message.senderId ?? "")?.avatarPath ?? ""
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if mine { Spacer(minLength: 0) }

            if !mine {
                avatarView
                Spacer().frame(width: L.chatGapMsg)
            }

            bubbleColumn

            if mine {
                Spacer().frame(width: L.chatGapMsg)
                avatarView
            }

            if !mine { Spacer(minLength: 0) }
        }
        /* 多图那条「展开 / 收起」的状态记在本机：重进聊天、重开 App 还是上次的样子 */
        .onAppear { albumOpen = AlbumFold.isOpen(message.id) }
    }

    /// 头像（点一下看名片）：微信是 40、圆角 4
    private var avatarView: some View {
        /* 自己发的消息：头像上用我自己的等级（自己不在好友表里，以前这里查不到、
           等级算 0，所以自己那一侧永远没有头像框） */
        let lv = (message.senderId == myId)
            ? GrowthStore.shared.shownLevel
            : (app.contact(for: message.senderId ?? "")?.qqLevel ?? 0)
        return Avatar(path: avatarPath, size: L.chatAvatar, radius: 4, level: lv)
            .contentShape(Rectangle())
            /* 双击头像 = 拍一拍（微信就是这个手势）；单击还是看名片。
               两个手势叠在一起时，单击会等双击判定失败再触发，不会打架。 */
            .onTapGesture(count: 2) { onPat?(message.senderId ?? "") }
            .onTapGesture { onOpenAvatar?(message.senderId ?? "") }
    }

    /// 昵称（群里才有）+ 气泡，整列最宽按微信的 66% 卡住
    private var bubbleColumn: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
            if !senderName.isEmpty {
                /* 群里那行发送者昵称：后面可以挂等级图标（后台「成长系统 → 显示在聊天里」开着才显示） */
                HStack(spacing: 4) {
                    Text(senderName)
                        .font(pf(12))
                        .foregroundColor(C.subLabel)
                        .lineLimit(1)
                    if let lv = app.contact(for: message.senderId ?? "")?.qqLevel, lv > 0,
                       GrowthFlags.showInChats == true {
                        QQLevelBadge(level: lv, size: 11, maxIcons: 2).fixedSize()
                    }
                }
            }
            content
            /* 长按语音「转文字」的结果：就贴在语音气泡下面（微信那样）。
               点一下复制。 */
            if asrBusy || !asrText.isEmpty {
                asrLine
            }
        }
        .frame(maxWidth: L.bubbleMaxW, alignment: mine ? .trailing : .leading)
    }

    /// 语音下面那行转文字（识别中转圈；出来了就是一短段文字，点一下复制）
    private var asrLine: some View {
        VStack(alignment: .leading, spacing: 7) {
            /* 顶部一行小标：左边一个 sparkles + 「语音转文字」，右边是复制图标/复制提示 */
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(C.green)
                Text(Tr("语音转文字"))
                    .font(pf(11, .medium))
                    .foregroundColor(C.green)
                Spacer(minLength: 8)
                if !asrBusy {
                    Text(Tr("点按复制"))
                        .font(pf(10))
                        .foregroundColor(C.time)
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10.5))
                        .foregroundColor(C.time)
                }
            }
            if asrBusy {
                HStack(spacing: 7) {
                    ProgressView().scaleEffect(0.65)
                    Text(Tr("正在识别…"))
                        .font(pf(13))
                        .foregroundColor(C.subLabel)
                }
            } else {
                Text(asrText)
                    .font(pf(13.5))
                    .foregroundColor(C.label)
                    .lineSpacing(2.5)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(C.cardBg)
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        LinearGradient(colors: [C.green.opacity(0.16), C.green.opacity(0.04)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(C.green.opacity(0.22), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 5, x: 0, y: 2)
        .frame(maxWidth: 240, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !asrText.isEmpty else { return }
            UIPasteboard.general.string = asrText
            app.show(Tr("已复制"))
        }
        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)),
                                removal: .opacity))
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: asrText)
    }

    @ViewBuilder
    private var content: some View {
        if message.isRecalled {
            Text(mine ? "你撤回了一条消息" : "对方撤回了一条消息")
                .font(pf(12))
                .foregroundColor(C.msgTime)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 5).fill(C.bubbleOther))
        } else {
            bubble
        }
    }

    /// 气泡底色（自己的绿、对方的白/深灰）
    private var bubbleFill: Color { mine ? C.bubbleMine : C.bubbleOther }

    @ViewBuilder
    private var bubble: some View {
        switch message.kindName {
        case "image":
            /* 微信里的图片：按原比例出缩略图（最长边 200），不是硬裁成正方形 */
            ImageBubble(path: message.imagePath, pixel: message.imagePixelSize,
                        onSized: { onLayoutChanged?() }) { onOpenImage?(message.imagePath) }

        case "images":
            /* 一次发的多张图：一条消息里的九宫格（微信那样，点哪张都能左右翻） */
            imagesGridBubble

        case "location":
            /* 点一下就进「位置详情」大地图页（微信就是这么点的） */
            locationBubble
                .onTapGesture {
                    if let p = LocationPoint.parse(message.body) { onOpenLocation?(p) }
                }

        case "transfer":
            transferBubble
                .onTapGesture {
                    if let info = TransferInfo(json: message.body) { onTapTransfer?(info) }
                }

        case "redpacket":
            redPacketBubble
                .onTapGesture {
                    if let info = RedPacketInfo(json: message.body) { onTapRedPacket?(info) }
                }

        case "gift":
            giftBubble

        case "link":
            if let link = ShopLink(json: message.body) {
                ShopLinkCard(link: link) {
                    ShopOpener.open(link) { url in onOpenWeb?(url) }
                }
            } else {
                /* 解析不出来也别把一整段 JSON 甩给用户看（里面还有图片路径那种东西，
                   看着就像"回复的是路径不是图"）。这里只显示标题。 */
                Text(linkFallbackText(message.body))
                    .font(pf(L.chatFontSize))
                    .foregroundColor(C.bubbleText)
                    .padding(.horizontal, L.bubblePadHPill)
                    .padding(.vertical, L.bubblePadV)
                .background(BubbleFill(mine: mine, tail: showTail, seed: bubbleSeed(message.id)))
            }

        case "file":
            fileBubble

        case "oa":
            /* 公众号文章卡片：点开进文章页 */
            OAArticleCard(json: message.body) {
                if let d = message.body.data(using: .utf8),
                   let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let aid = o["articleId"] as? String, !aid.isEmpty {
                    onOpenArticle?(aid)
                }
            }

        case "card":
            /* 名片：点一下打开那个人的资料页（微信就是这么点的 ——
               还不是好友的话，资料页上就能「添加到通讯录」） */
            if let info = UserCardInfo(json: message.body) {
                UserCardBubble(info: info)
                    .onTapGesture { onOpenUserCard?(info.userId) }
            } else {
                /* 解析不出名片 JSON 时：如果后台开了 cardDiag，就把**实际收到的东西**显示出来 ——
                   一眼能看出是"服务器把它降级成纯文本了"（老版本 App 收到的就是这样），
                   还是"收到了 JSON 但缺 userId"。 */
                Text(UIConfig.num("cardDiag", 0) > 0
                     ? "[名片] 原文：" + String(message.body.prefix(80))
                     : Tr("[名片]"))
                    .font(pf(L.chatFontSize))
                    .foregroundColor(C.bubbleText)
                    .padding(.horizontal, L.bubblePadHPill)
                    .padding(.vertical, L.bubblePadV)
                    .background(BubbleFill(mine: mine, tail: showTail, seed: bubbleSeed(message.id)))
            }

        case "music":
            /* 音乐卡片（微信「＋ → 音乐」发出去的那种）：点一下进播放页 */
            if let m = MusicCardInfo(json: message.body) {
                MusicBubble(info: m) {
                    let t = m.asTrack
                    MusicPlayer.shared.play(t)
                    MusicSheet.shared.open(t)
                }
            } else {
                Text(Tr("[音乐]"))
                    .font(pf(L.chatFontSize))
                    .foregroundColor(C.bubbleText)
                    .padding(.horizontal, L.bubblePadHPill)
                    .padding(.vertical, L.bubblePadV)
                    .background(BubbleFill(mine: mine, tail: showTail, seed: bubbleSeed(message.id)))
            }

        case "mall":
            /* 商城商品卡片（2026-10-15 用户：「分享应该是卡片可以直接跳转的」）：
               封面 + 商品名 + 价格，**点一下直接进商品页**（不走浏览器） */
            if let m = MallCardInfo(json: message.body) {
                MallCardBubble(info: m) {
                    MallSheet.shared.open(m.asProduct)
                }
            } else {
                Text(Tr("[商品]"))
                    .font(pf(L.chatFontSize))
                    .foregroundColor(C.bubbleText)
                    .padding(.horizontal, L.bubblePadHPill)
                    .padding(.vertical, L.bubblePadV)
                    .background(BubbleFill(mine: mine, tail: showTail, seed: bubbleSeed(message.id)))
            }

        case "announce":
            /* 群公告：发公告时自动落的那条卡片（群里所有人可见），点一下看全文 */
            AnnounceBubble(text: message.body) {
                onOpenAnnounce?(message.body)
            }

        case "note":
            /* 收藏里的笔记转发到聊天：收到的是一张**笔记卡片**（微信就是这样），
               点开才看全文 —— 不是一大段带 [图]路径 的文字。 */
            NoteCardBubble(text: message.body, mine: mine,
                           showTail: showTail, seed: bubbleSeed(message.id))

        case "miniapp":
            /* 好友分享来的小游戏 / 小程序卡片：点一下直接用运行时打开 */
            if let m = MiniAppShare(json: message.body) {
                MiniAppCardBubble(info: m) { onOpenMiniApp?(m.asApp) }
            } else {
                Text(Tr("[小游戏]"))
                    .font(pf(L.chatFontSize))
                    .foregroundColor(C.bubbleText)
                    .padding(.horizontal, L.bubblePadHPill)
                    .padding(.vertical, L.bubblePadV)
                    .background(BubbleFill(mine: mine, tail: showTail, seed: bubbleSeed(message.id)))
            }

        case "sysnotice":
            /* 系统通知号（星言团队）的卡片：排版照微信那个「微信团队」
               —— 标题 + 正文 + 细线 + 「查看详情 ›」，点开一整页看全文 */
            if let n = SysNoticeInfo(json: message.body) {
                SysNoticeBubble(info: n) { onOpenAnnounce?(n.fullText) }
            } else {
                Text(Tr("[通知]"))
                    .font(pf(L.chatFontSize))
                    .foregroundColor(C.bubbleText)
                    .padding(.horizontal, L.bubblePadHPill)
                    .padding(.vertical, L.bubblePadV)
                    .background(BubbleFill(mine: mine, tail: showTail, seed: bubbleSeed(message.id)))
            }

        case "audio":
            audioBubble

        case "video":
            VideoBubble(message: message, mine: mine) { url, _ in onOpenVideo?(url) }

        case "livephoto":
            LivePhotoBubble(message: message) { url in onOpenVideo?(url) }

        default:
            /* 兜底：收到这个版本还不认识的卡片消息（正文是 JSON）时，**绝不把 JSON 当正文显示**
               —— 用户看到的"一串乱码"就是这么来的。
               以前只在含 title 时才兜，别的卡片（比如名片）还是会原样甩出去；
               现在只要是以 { 开头的（就是 JSON）一律换成能看的一句话。 */
            if message.body.hasPrefix("{") {
                Text(unknownCardText(message.body))
                    .font(pf(L.chatFontSize))
                    .foregroundColor(C.bubbleText)
                    .padding(.horizontal, L.bubblePadHPill)
                    .padding(.vertical, L.bubblePadV)
                    .background(BubbleFill(mine: mine, tail: showTail, seed: bubbleSeed(message.id)))
                } else if let q = message.quote {
            /* 引用了某条消息：微信那样，气泡里先摆一条引用条（带缩略图），下面是正文 */
            quotedTextBubble(q, raw: message.body)
                } else {
            /* 正文：网址涂成能点开的蓝链接；群里 @某人 涂成链接色，
               **@我的那一段涂红**，一眼就能看到自己被 @ 了（微信也是这样） */
            Text(richBody(message.body))
                .font(pf(L.chatFontSize))
                /* 自己发的气泡：底色被后台配成深色（比如深蓝）时用**白字**，
                   不然深底 + 深字就看不清了（ui.json 的 bubbleMineWhiteText = 0 可关） */
                .foregroundColor(mine && UIConfig.num("bubbleMineWhiteText", 1) > 0 ? .white : C.bubbleText)
                .lineSpacing(L.msgLineSpacing)         // 微信正文的行距（16 号字 → 行高约 22）
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, L.bubblePadHPill)
                .padding(.vertical, L.bubblePadV)
                .background(
                    BubbleFill(mine: mine, tail: showTail)
                )
                }
        }
    }

    /// 「引用 + 正文」那一种气泡（微信排版：圆角气泡里上面一条引用条，下面是正文）
    private func quotedTextBubble(_ q: QuoteRef, raw: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                VStack(alignment: .leading, spacing: 2) {
                    if !q.sender.isEmpty {
                        Text(q.sender)
                            .font(pf(12, .medium))
                            .foregroundColor(C.subLabel)
                            .lineLimit(1)
                    }
                    Text(q.summary.isEmpty ? Tr("[引用]") : q.summary)
                        .font(pf(12.5))
                        .foregroundColor(C.subLabel)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                /* 引用的是一条图片 → 右边挂一张小缩略图（微信就是这样） */
                if q.thumbPath.isEmpty == false {
                    RemoteImage(path: q.thumbPath, mode: .fill, maxSide: 200)
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.dyn(0xE9E9EB, 0x3A3A3C)))
            .contentShape(Rectangle())
            .onTapGesture {
                if !q.refId.isEmpty { onOpenQuote?(q.refId) }
            }
            Text(richBody(raw))
                .font(pf(L.chatFontSize))
                .foregroundColor(mine && UIConfig.num("bubbleMineWhiteText", 1) > 0 ? .white : C.bubbleText)
                .lineSpacing(L.msgLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, L.bubblePadHPill)
        .padding(.vertical, L.bubblePadV)
        .background(BubbleFill(mine: mine, tail: showTail))
    }

    private func dict(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }


    /// 把消息里的 http/https 链接挑出来，做成可以点开的链接（微信里就是蓝色的那种）
    private func linkText(_ s: String) -> AttributedString {
        /* 网址识别统一放在 RichText 里（小星的对话页、以后的其它页面共用一套规则） */
        RichText.linkified(s)
    }

    /* ---------------------------------------------------------- 正文里的 @ */

    /// 气泡正文：网址还是蓝色链接；「@某人」涂成链接色；
    /// 正文里所有 @ 统一用链接色。气泡内不再保留持续红字标记。
    /// 链接卡片解析失败时的兜底文案：从 JSON 里抠出 title，抠不到就写「链接」
    private func linkFallbackText(_ raw: String) -> String {
        if let r = raw.range(of: "\"title\":\""),
           let e = raw.range(of: "\"", range: r.upperBound..<raw.endIndex) {
            let t = String(raw[r.upperBound..<e.lowerBound])
            if !t.isEmpty { return t }
        }
        return Tr("链接")
    }

    /// 收到**这个版本还不认识的卡片消息**（正文是 JSON）时，用来顶替正文的那句话。
    /// 顺序：名字 → 标题 → 正文 → 一句人话。
    /// ⚠ 绝对不要把 JSON 原样显示出去 —— 用户看到的"一串乱码"就是这么来的。
    private func unknownCardText(_ raw: String) -> String {
        guard let d = raw.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return Tr("[卡片消息]")
        }
        for key in ["name", "title", "text", "content", "preview", "desc", "label"] {
            if let v = o[key] as? String, !v.isEmpty { return v }
        }
        /* 名片那种没有 name 的，用 userId 兜一个能看的东西 */
        if let uid = o["userId"] as? String, !uid.isEmpty { return Tr("[名片]") }
        return Tr("[卡片消息]")
    }

    private func richBody(_ raw: String) -> AttributedString {
        /* 同一条消息解析一次就够：往上翻、来回滑的时候不必每次重新扫一遍
           （消息一多的时候，正文解析是每条都要算的大头） */
        let cacheKey = message.id + "|" + raw
        if let hit = RichBodyCache.get(cacheKey) { return hit }
        /* 历史里（或者对方那台老版本）可能是手打的 [微笑] 这种码，显示时一并换成表情 */
        /* 首尾的换行/空格剪掉：AI 那种长回复经常以 \n\n 结尾，
           不剪的话气泡最下面会多出一条空白行，看着就是"排版乱"。 */
        let s = ClassicEmojiSet.expand(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        let atMe = message.mentionsUser(myId)
        let mineNames = atMe ? myMentionNames : []
        /* 逐行拼。代码行单独上**等宽字体**：比例字体里缩进、括号、引号全挤在一起，
           长文（最常见的就是 AI 回复里的代码 / 命令行）看着"排版乱"就是这么来的。 */
        /* 正文的实际字号（和 pf() 算出来的一致），等宽那行**也用它** ——
           以前等宽是「正文字号 - 1.5」，同一段话里只要有几行被认成代码，
           就会"一行大一行小"（用户反馈的「聊天框内的字怎么有大有小」）。 */
        let baseSize = max(9, (L.chatFontSize * fontScale * CareMode.scale).rounded())
        let mono = Font.system(size: baseSize, design: .monospaced)
        /* 正文一律**钉成苹方**（用户反馈过「汽泡里的字不是苹方体」）。
           以前只靠外面 .font(pf(...)) 继承下来，只要某一段被 AttributedString
           带了别的字体属性、或者整行命中了代码行规则，那段就会换成别的字体。
           这里把字体写死在每一段上，不再依赖继承 —— 只有真正的代码行才走等宽。 */
        let base = pfExact(baseSize)
        var out = AttributedString()
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        for (idx, sub) in lines.enumerated() {
            let line = String(sub)
            if RichText.looksLikeCode(line) {
                var seg = AttributedString(line)
                seg.font = mono
                out += seg
            } else if line.contains("@") || line.contains("http") {
                var seg = decorateLine(line, atMe: atMe, mineNames: mineNames)
                seg.font = base
                out += seg
            } else {
                var seg = AttributedString(line)
                seg.font = base
                out += seg
            }
            if idx < lines.count - 1 { out += AttributedString("\n") }
        }
        RichBodyCache.put(cacheKey, out)
        return out
    }

    /// 一行里的 @ 和网址上色（原来的逻辑，抽出来给逐行解析用）
    private func decorateLine(_ s: String, atMe: Bool, mineNames: [String]) -> AttributedString {
        var out = AttributedString()
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "@" {
                var j = s.index(after: i)
                while j < s.endIndex, !isMentionStop(s[j]) { j = s.index(after: j) }
                let token = String(s[i..<j])
                var seg = AttributedString(token)
                let name = String(token.dropFirst())
                seg.foregroundColor = C.link
                out += seg
                i = j
                continue
            }
            /* 普通的一段：交给网址识别（@ 之前的那段文字） */
            var j = i
            while j < s.endIndex, s[j] != "@" { j = s.index(after: j) }
            out += linkText(String(s[i..<j]))
            i = j
        }
        return out
    }

    /// @昵称 到哪里算结束（空格、换行、标点都算）
    private func isMentionStop(_ c: Character) -> Bool {
        if c.isWhitespace || c.isNewline { return true }
        return "，。！？；：、（）()[]【】{}<>《》\"'!?,;:".contains(c)
    }

    /// 我自己可能被 @ 到的写法（昵称 / 微信号）—— 用来把「@我」那段涂红
    private var myMentionNames: [String] {
        var names: [String] = []
        if let n = app.me?.nickname, !n.isEmpty { names.append(n) }
        if let u = app.me?.username, !u.isEmpty { names.append(u) }
        return names
    }

    private var locationBubble: some View {
        let o = dict(message.body)
        let lat = (o["lat"] as? Double) ?? 0
        let lng = (o["lng"] as? Double) ?? 0
        let name = (o["name"] as? String) ?? "位置"
        let addr = (o["addr"] as? String) ?? ""
        let pt = LocationPoint(lat: lat, lng: lng, name: name, addr: addr)
        return VStack(spacing: 0) {
            /* 小地图改成**本机用苹果地图渲染的快照**：
               以前用的是 tile.openstreetmap.org 的瓦片，国内网络经常拉不到 → 气泡一片空白。 */
            MapSnapshotView(point: pt, width: 216, height: 136)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(pf(15)).foregroundColor(C.bubbleText).lineLimit(1)
                Text(addr.isEmpty ? "点击查看地图" : addr)
                    .font(pf(12)).foregroundColor(C.subLabel).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .frame(width: 216)
        /* 微信的位置气泡是白卡 + 小尖角（自己的也是白的）。
           先把内容裁成圆角，再把带尖角的形状铺在底下，尖角才不会被裁掉。 */
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        /* 位置气泡在微信里自己的也是白卡，所以底板固定用对方那套配色 */
        .background(BubbleFill(mine: false, tail: showTail))
    }

    private var transferBubble: some View {
        let o = dict(message.body)
        let amount = (o["amount"] as? Double) ?? 0
        let note = (o["note"] as? String) ?? ""
        let status = (o["status"] as? String) ?? "pending"
        let state = status == "received" ? "已收款" : (status == "refunded" ? "已退回" : "待对方确认收款")
        /* 转账卡片的颜色：
           还没人收 = 微信橙 #FA9D3D（参考图实测的橙）；
           收了之后（不管是发钱那侧还是收钱那侧）都变淡橙 #F0C69A —— 这就是「已收款要变色」；
           24 小时没人收退回是灰的。 */
        let card: Color
        if status == "refunded" {
            card = Color(hex: 0xC2C2C2)
        } else if status == "received" {
            card = Color(hex: 0xF0C69A)
        } else {
            card = Color(hex: 0xFA9D3C)
        }
        /* 排版照微信：左边一个白色圆底图标，右边金额（大字）+"转账"/说明，
           最下面一条细线隔开的底栏：左边「转账」，右边状态（待对方确认收款 / 已收款 / 已退回） */
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 9) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.22)).frame(width: 34, height: 34)
                    Image(systemName: "yensign")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("¥\(moneyFmt(amount))")
                        .font(pfMoney(19, .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(note.isEmpty ? Tr("转账") : note)
                        .font(pf(11))
                        .foregroundColor(Color.white.opacity(0.85))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.top, 11)
            .padding(.bottom, 10)

            Rectangle()
                .fill(Color.white.opacity(0.22))
                .frame(height: 0.5)

            HStack(spacing: 5) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.85))
                Text(Tr("转账"))
                    .font(pf(11))
                    .foregroundColor(Color.white.opacity(0.85))
                Spacer(minLength: 4)
                Text(state)
                    .font(pf(11.5))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .frame(height: 28)
        }
        /* 卡片宽度后台可调（ui.json 里写 transferCardW）。
           用户说"支付卡片太小了，要和微信一样" → 默认回到 **240**（微信转账卡片就是 240 左右），
           要再大/再小改后台这个键即可。 */
        .frame(width: UIConfig.num("transferCardW", 240), alignment: .leading)
        .background(card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// 红包气泡：橙色卡片（领过 / 领完 / 过期都变淡）
    @ViewBuilder
    private var redPacketBubble: some View {
        if let info = RedPacketInfo(json: message.body) {
            RedPacketCard(info: info, mine: mine, myId: myId)
        } else {
            /* 老版本留下来的、结构对不上的红包消息（服务端已经删掉那套逻辑了）：
               不显示一堆 JSON，给一句人话 */
            Text("[红包] 这条记录是旧版本的，已经失效")
                .font(pf(14))
                .foregroundColor(C.subLabel)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(C.hairline))
        }
    }

    /// 语音消息气泡：喇叭 + 可拖动的进度条 + 秒数。
    /// 点一下播放/暂停（微信那套），进度条上按住左右拖 = 拖到哪从哪放。
    private var audioBubble: some View {
        let o = dict(message.body)
        let secs = max(1, (o["seconds"] as? Int) ?? 1)
        let playing = voicePlayer.playingID == message.id
        let scrubbing = voiceScrub >= 0
        /* 正在播 / 正在拖：显示「播到第几秒」，平时显示这条一共多少秒 */
        let dot: Double = scrubbing ? voiceScrub : (playing ? voicePlayer.progress : 0)
        let shown: Int = {
            if scrubbing, voicePlayer.total > 0 { return max(0, Int((voicePlayer.total * dot).rounded())) }
            if playing { return max(0, Int(voicePlayer.elapsed.rounded())) }
            return secs
        }()
        /* 比原来宽一点：中间要给进度条留位置。
           几十秒的长语音进度条要够长才拖得准（60 秒时最长 252，其中进度条能占 160 左右） */
        let width = min(252, 118 + CGFloat(secs) * 2.6)
        /* 微信里喇叭永远贴着「靠头像那一边」：对方发的在左、自己发的在右 */
        return VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
        HStack(spacing: 8) {
            if mine { Spacer(minLength: 0) }
            if mine {
                Text(playing || scrubbing ? "\(shown)″" : "\(secs)″")
                    .font(pfMoney(12.5))
                    .foregroundColor(playing || scrubbing ? C.green : C.subLabel)
                    .frame(minWidth: 26, alignment: .trailing)
                voiceTrack(playing: playing)
                speakerIcon(playing: playing)
            } else {
                speakerIcon(playing: playing)
                voiceTrack(playing: playing)
                Text(playing || scrubbing ? "\(shown)″" : "\(secs)″")
                    .font(pfMoney(12.5))
                    .foregroundColor(playing || scrubbing ? C.green : C.subLabel)
                    .frame(minWidth: 26, alignment: .leading)
            }
            if !mine { Spacer(minLength: 0) }
        }
        .padding(.horizontal, 12)
        .frame(width: width, height: 40, alignment: mine ? .trailing : .leading)
        .background(BubbleFill(mine: mine, tail: showTail, seed: bubbleSeed(message.id)))
        /* 没听过的语音：气泡右上角一个小红点（微信），听过就没了；
           自己发的语音不点这个点 */
        .overlay(alignment: .topTrailing) {
            if !mine, !playedVoice.contains(message.id), !VoicePlayed.isPlayed(message.id) {
                Circle().fill(C.red)
                    .frame(width: 8, height: 8)
                    .offset(x: -5, y: 5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            playedVoice.insert(message.id)
            VoicePlayed.markPlayed(message.id)
            guard let url = voiceURL() else {
                app.show(Tr("这条语音找不到了"))
                return
            }
            voicePlayer.toggle(id: message.id, url: url)
        }
        /* 正在播这条：底下挂一颗 1x/2x（用户要的倍速），点一下立刻变速 */
        if playing || scrubbing { speedChip }
        }
    }

    /// 倍速小按钮：1x ⇄ 2x（微信那种挂在语音气泡下面的小胶囊）
    private var speedChip: some View {
        Button {
            voicePlayer.toggleRate()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Text(voicePlayer.rate > 1.5 ? "2x" : "1x")
                .font(pf(11, .semibold))
                .foregroundColor(C.green)
                .frame(width: 32, height: 19)
                .background(Capsule().fill(Color.dyn(0xFFFFFF, 0x2C2C2E).opacity(0.94)))
                .overlay(Capsule().stroke(C.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .padding(mine ? .trailing : .leading, 2)
    }

    private func voiceURL() -> URL? {
        let o = dict(message.body)
        let path = (o["url"] as? String) ?? ""
        return API.shared.assetURL(path)
    }

    /// 气泡里那条**声波进度条**（用户挑的方案 ②）：
    /// 一条由细柱组成的波，播到哪哪些柱子变绿；按住左右拖 = 拖到哪从哪放
    /// （没在播就先播起来再跳过去）。柱子高低按消息 id 算，固定不变 ——
    /// 重画、重进页面都是同一条波形，不会"每次都不一样"。
    private func voiceTrack(playing: Bool) -> some View {
        let f: Double = voiceScrub >= 0 ? voiceScrub : (playing ? voicePlayer.progress : 0)
        let live = playing || voiceScrub >= 0
        return GeometryReader { geo in
            let w = max(24, geo.size.width)
            /* 柱子根数跟着宽度走（每根占 4.3pt），这样长语音/短语音都一样好看 */
            let n = max(10, min(40, Int(w / 4.3)))
            let step = w / CGFloat(n)
            let hs = waveHeights(message.id, n)
            HStack(spacing: 0) {
                ForEach(0..<n, id: \.self) { i in
                    let at = (Double(i) + 0.5) / Double(n)
                    let on = live && at <= f
                    Capsule()
                        .fill(on ? C.green : C.bubbleText.opacity(0.22))
                        /* 边界那根加粗一点，当播放头 */
                        .frame(width: on && at + 1.0 / Double(n) > f ? 3.4 : 2.6,
                               height: 5 + hs[i] * 13)
                        .frame(width: step)
                }
            }
            .frame(height: geo.size.height, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let nf = min(1, max(0, Double(v.location.x / w)))
                        voiceScrub = nf
                        playedVoice.insert(message.id)
                        VoicePlayed.markPlayed(message.id)
                        if voicePlayer.playingID != message.id, let url = voiceURL() {
                            voicePlayer.toggle(id: message.id, url: url)
                        }
                        voicePlayer.seek(to: nf)
                    }
                    .onEnded { _ in voiceScrub = -1 }
            )
        }
        /* 触摸区给高一点：柱子本身很细，手指按在 26 点高的范围内都算在拖它 */
        .frame(height: 26)
        .frame(maxWidth: .infinity)
    }

    /// 这条语音的波形高度（0.3…1）：用消息 id 当种子算，固定不变
    private func waveHeights(_ id: String, _ n: Int) -> [CGFloat] {
        /* ⚠ 不能用 id.hashValue：Swift 的字符串哈希**每个进程随机加盐**，
           重开一次 App 波形就全变了。这里自己算一个稳定的种子。 */
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for u in id.unicodeScalars {
            seed = (seed ^ UInt64(u.value)) &* 1099511628211
        }
        seed |= 1
        var out: [CGFloat] = []
        out.reserveCapacity(n)
        for _ in 0..<n {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let v = Double((seed >> 33) & 0xFFFF) / 65535.0
            out.append(CGFloat(0.30 + v * 0.70))
        }
        return out
    }

    /// 语音那个小喇叭（播放中变绿）
    private func speakerIcon(playing: Bool) -> some View {
        SVGIcon(markup: I.speaker, size: 20,
                color: playing ? C.green : C.bubbleText)
    }

    /// 一次发多张：**默认是「相册堆叠」**（封面 + 露出来的两张边 + 共 N 张），
    /// 点一下展开成九宫格，再点「收起」缩回去（弹簧 + 轻震，状态记本机）。
    /// 单张不走这里（单张有自己的气泡）。2 张及以上都按微信那样折成一张堆叠。
    private var imagesGridBubble: some View {
        let o = dict(message.body)
        let paths = (o["paths"] as? [String]) ?? []
        return Group {
            if paths.count >= 2 && !albumOpen {
                albumStackBubble(paths)
            } else {
                albumGridBubble(paths)
            }
        }
    }

    /// 展开 / 收起（弹簧 + 轻震；状态写本机）
    private func toggleAlbum() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.36, dampingFraction: 0.72)) {
            albumOpen.toggle()
        }
        AlbumFold.setOpen(message.id, albumOpen)
    }

    /// 折起来的样子：像一叠相册 —— 后面两张露出右下角的边，封面上压「共 N 张」和展开按钮
    private func albumStackBubble(_ paths: [String]) -> some View {
        let n = paths.count
        let side: CGFloat = 148
        let pad: CGFloat = 11
        return ZStack(alignment: .topLeading) {
            photoEdge(side).offset(x: pad, y: pad)
            photoEdge(side).offset(x: pad / 2, y: pad / 2)
            RemoteImage(path: paths[0], maxSide: 900)
                .frame(width: side, height: side)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .bottomLeading) { albumCountBadge(n).padding(7) }
                .overlay(alignment: .bottomTrailing) { albumExpandButton.padding(7) }
                .contentShape(Rectangle())
                .onTapGesture { toggleAlbum() }
        }
        .frame(width: side + pad, height: side + pad, alignment: .topLeading)
        /* 相册堆叠也一样：整块像一张卡片浮在背景上（有一点点阴影层次） */
        .shadow(color: Color.black.opacity(0.16), radius: 7, x: 0, y: 3)
    }

    /// 堆叠后面露出来的那张「边」
    private func photoEdge(_ side: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.dyn(0xE9E9EB, 0x3A3A3F))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(C.hairline, lineWidth: 0.5))
            .frame(width: side, height: side)
    }

    private func albumCountBadge(_ n: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 10.5, weight: .semibold))
            Text(Tr("共") + " \(n) " + Tr("张"))
                .font(pf(11.5, .medium))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.black.opacity(0.42)))
    }

    private var albumExpandButton: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 24, height: 24)
            .background(Circle().fill(Color.black.opacity(0.42)))
    }

    /// 展开的样子：九宫格（微信那样）。2 张 → 一行两张；4 张 → 2×2；5 张以上 → 一行三张。
    /// 右下角一条「收起」，再点回堆叠。
    private func albumGridBubble(_ paths: [String]) -> some View {
        let n = paths.count
        let cols = n <= 2 ? max(1, n) : (n == 4 ? 2 : 3)
        let side: CGFloat = cols == 2 ? 122 : 78
        let rows = n > 0 ? (n + cols - 1) / cols : 0
        return VStack(alignment: .trailing, spacing: 5) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: 2) {
                        ForEach(0..<cols, id: \.self) { c in
                            let i = r * cols + c
                            if i < n {
                                Button { onOpenImage?(paths[i]) } label: {
                                    RemoteImage(path: paths[i], maxSide: 900)
                                        .frame(width: side, height: side)
                                        .clipped()
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            /* 九宫格整块也有点层次感（微信的九宫格是"一张卡片"，不是九张贴纸） */
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.black.opacity(0.10), lineWidth: 0.6))
            .shadow(color: Color.black.opacity(0.16), radius: 7, x: 0, y: 3)
            /* 只有「能折起来的那种」才给收起：n<2 时不用 */
            if n >= 2 {
                Button { toggleAlbum() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 9.5, weight: .bold))
                        Text(Tr("收起")).font(pf(11.5))
                    }
                    .foregroundColor(C.subLabel)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(Color.dyn(0xEDEDF0, 0x33333A)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var giftBubble: some View {
        let o = dict(message.body)
        let icon = (o["icon"] as? String) ?? "🎁"
        let name = (o["name"] as? String) ?? "礼物"
        let price = (o["price"] as? Double) ?? 0
        return HStack(spacing: 10) {
            Text(icon).font(pf(30))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(pf(15, .medium)).foregroundColor(C.bubbleText)
                    Text("¥\(String(format: "%.0f", price))").font(pfMoney(12)).foregroundColor(C.red)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            BubbleFill(mine: mine, tail: showTail)
        )
    }

    private var fileBubble: some View {
        let o = dict(message.body)
        let name = (o["name"] as? String) ?? "文件"
        let bytes = (o["bytes"] as? Int) ?? 0
        let look = FileKind.look(name)                       // 按后缀出图标和颜色（微信那样）
        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(look.color.opacity(0.16))
                    .frame(width: 38, height: 38)
                Image(systemName: look.symbol)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundColor(look.color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(pf(14)).foregroundColor(C.bubbleText).lineLimit(2)
                Text(byteText(bytes)).font(pf(11)).foregroundColor(C.subLabel)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(width: 216, alignment: .leading)
        .background(
            BubbleFill(mine: mine, tail: showTail)
        )
        .contentShape(Rectangle())
        .onTapGesture { onOpenFile?(message.body) }
    }

    private func byteText(_ n: Int) -> String {
        if n > 1024 * 1024 { return String(format: "%.1f MB", Double(n) / 1024 / 1024) }
        if n > 1024 { return "\(n / 1024) KB" }
        return "\(n) B"
    }

    private func card(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            SVGIcon(markup: icon, size: 20, color: mine ? C.bubbleText : C.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(pf(15, .medium)).foregroundColor(C.bubbleText)
                if !detail.isEmpty {
                    Text(detail).font(pf(12)).foregroundColor(C.subLabel).lineLimit(2)
                }
            }
        }
        .padding(.horizontal, L.bubblePadHPill)
        .padding(.vertical, L.bubblePadV)
        .background(
            BubbleFill(mine: mine, tail: showTail)
        )
    }
}

/* ============================================================ 地图小图 */

/* ============================================================
   图片气泡（照微信）：保持原比例，最长边不超过 200；图还没加载出来时
   先按 150 的方块占位，加载完自动变成真实比例。点一下看大图。
   ============================================================ */

/* ============================================================
   图片尺寸缓存（按图片路径）—— **骨架落位**用的。

   聊天里的图片气泡一开始不知道图多大，只能先画个 150 的方块，等图下完解码完
   才知道真实比例、行高才定型 —— 这一下"内容变高"就会把列表顶一下
   （用户反馈的"聊天页自己上下移"、以及"没有骨架落位"）。

   这里把**解码出来的尺寸按路径存下来**（内存 + 本机）：见过一次的图，
   下次（重进会话、往上翻回来、重开 App）第一帧就按真实比例把框占好，
   图只是"填"进来，行高全程不变 —— 这就是骨架。
   不改消息格式，老图不受任何影响。
   ============================================================ */
enum ImageSizeCache {
    private static var mem: [String: CGSize] = [:]
    private static let defaultsKey = "chris.imageSizes"
    private static var disk: [String: [CGFloat]] =
        (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [CGFloat]]) ?? [:]

    static func get(_ path: String) -> CGSize? {
        guard !path.isEmpty else { return nil }
        if let s = mem[path] { return s }
        if let a = disk[path], a.count == 2 {
            let s = CGSize(width: a[0], height: a[1])
            mem[path] = s
            return s
        }
        return nil
    }

    static func put(_ path: String, _ size: CGSize) {
        guard !path.isEmpty, size.width > 1, size.height > 1 else { return }
        /* ⚠ 一样就别写了：UserDefaults 每次写都要序列化整张表。
           聊天页一屏十几张图、每次 onAppear 都来写一遍的话，
           光这一项就能把滚动/进出聊天页拖慢（图片"出来得慢"有一部分就是这个）。 */
        if let old = mem[path], abs(old.width - size.width) < 0.5, abs(old.height - size.height) < 0.5 {
            return
        }
        mem[path] = size
        disk[path] = [size.width, size.height]
        if disk.count > 1200 { disk.removeAll(); disk[path] = [size.width, size.height] }
        UserDefaults.standard.set(disk, forKey: defaultsKey)
    }
}

struct ImageBubble: View {
    let path: String
    /// 图片解码完、尺寸定型了 → 告诉聊天页（它可能要再贴一次底，不然最后一条会被顶下去）
    var onSized: (() -> Void)? = nil
    /// 消息里带的原始像素宽高（发送端带上来的 / 服务端补的）：
    /// 有它的话**第一帧**就按真实比例把框占好，根本不会等到图下完（骨架落位）
    var pixel: CGSize? = nil
    let onTap: () -> Void

    @State private var box: CGSize? = nil
    /// 从相册加进来的「单个表情」也是小方图：算出来以后按表情尺寸显示
    @State private var smallSticker = false

    init(path: String, pixel: CGSize? = nil, onSized: (() -> Void)? = nil, onTap: @escaping () -> Void) {
        self.path = path
        self.pixel = pixel
        self.onSized = onSized
        self.onTap = onTap
        var seed: CGSize? = nil
        var sticker = false
        if let p = pixel, p.width > 1, p.height > 1 {
            if ImageBubble.looksLikeSticker(p) { sticker = true; seed = CGSize(width: 120, height: 120) }
            else { seed = ImageBubble.thumb(p) }
        }
        _box = State(initialValue: seed)
        _smallSticker = State(initialValue: sticker)
    }

    /// 表情包里的表情（本站图库 /emoji/… 和我们自己的 /uploads/emj…）：
    /// 不管原图是 160 还是 204，聊天里一律按同一个方框显示 ——
    /// 微信的大表情就是这样，一串发出去尺寸是齐的（用户反馈：新增的表情大小不一）。
    private var isSticker: Bool {
        path.hasPrefix("/emoji/") || path.contains("/emj")
    }
    /// 认不出路径的那种小方图（自己从相册加的单个表情）也按表情显示
    private var stickerLook: Bool { isSticker || smallSticker }
    private let stickerSide: CGFloat = 120

    var body: some View {
        let size = stickerLook
            ? CGSize(width: stickerSide, height: stickerSide)
            : (box ?? CGSize(width: 150, height: 150))
        /* 表情：保持比例不裁切（.fit）；普通图片：按比例铺满 */
        RemoteImage(path: path, icon: "photo", mode: stickerLook ? .fit : .fill, onLoaded: { img in
            guard !isSticker else { return }
            if ImageBubble.looksLikeSticker(img.size) {
                smallSticker = true
            } else if box == nil {
                box = ImageBubble.thumb(img.size)
                /* 记下这条图的显示尺寸：下次进这个会话 / 往上翻回来，
                   第一帧就按它占好位（骨架落位），行高不再变、列表不再被顶 */
                ImageSizeCache.put(path, box ?? ImageBubble.thumb(img.size))
            }
            onSized?()
        })
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: stickerLook ? 8 : 5, style: .continuous))
        /* 用户要求：照片要有**层次感**（微信那种像一张卡片压在背景上，不是"贴"在墙上）：
           一圈极细的描边 + 一点很轻的投影。表情不投影（表情就是要"贴"上去）。 */
        .overlay(
            RoundedRectangle(cornerRadius: stickerLook ? 8 : 5, style: .continuous)
                .stroke(Color.black.opacity(stickerLook ? 0 : 0.10), lineWidth: 0.6)
        )
        .shadow(color: stickerLook ? .clear : Color.black.opacity(0.16),
                radius: 7, x: 0, y: 3)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        /* 进来先用缓存把框占好（见过一次的图不会有任何位移） */
        .onAppear {
            if box == nil, let cached = ImageSizeCache.get(path) { box = cached }
            /* 把信封里带来的尺寸也存进缓存：同一张图在别处再出现（往上翻回来、
               重进会话）就永远不用等图下完了 */
            if let p = pixel, p.width > 1, p.height > 1, !stickerLook {
                ImageSizeCache.put(path, ImageBubble.looksLikeSticker(p) ? CGSize(width: 120, height: 120) : ImageBubble.thumb(p))
            }
        }
    }

    /// 小方图（最长边 ≤ 400 且接近正方形）当表情处理：
    /// 从相册加的「单个表情」就是这种，以前会按原图比例放到 200 点，看着比表情包里的表情大一圈。
    static func looksLikeSticker(_ size: CGSize) -> Bool {
        let w = max(1, size.width)
        let h = max(1, size.height)
        let m = max(w, h)
        return m <= 400 && abs(w - h) / m < 0.25
    }

    /// 微信的缩略图尺寸：按比例缩到最长边 200；太小的图给到 60 以上好点
    static func thumb(_ size: CGSize) -> CGSize {
        let w = max(1, size.width)
        let h = max(1, size.height)
        let scale = min(1, 200 / max(w, h))
        var tw = (w * scale).rounded()
        var th = (h * scale).rounded()
        if max(tw, th) < 60 {
            let k = 60 / max(tw, th)
            tw = (tw * k).rounded()
            th = (th * k).rounded()
        }
        return CGSize(width: min(200, tw), height: min(200, th))
    }
}

enum Tiles {
    static func url(lat: Double, lng: Double, z: Int = 15) -> String {
        let n = pow(2.0, Double(z))
        let x = Int(floor((lng + 180) / 360 * n))
        let rad = lat * .pi / 180
        let y = Int(floor((1 - log(tan(rad) + 1 / cos(rad)) / .pi) / 2 * n))
        return "https://tile.openstreetmap.org/\(z)/\(x)/\(y).png"
    }
}

/* ============================================================
   文件（微信那套）
     · 发送：可以一次选好几个（一个一个发过去）
     · 气泡：左边按类型出图标（pdf 红、word 蓝、excel 绿、压缩包黄…），
       右边文件名 + 大小；文件名最多两行
     · 点一下：下到本机用系统预览打开 —— 能用「用其他应用打开 / 分享」，
       和微信里点文件是一个感觉
   ============================================================ */

enum FileKind {
    /// 按文件名猜图标和颜色
    static func look(_ name: String) -> (symbol: String, color: Color) {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf":
            return ("doc.richtext", Color(hex: 0xE5433B))
        case "doc", "docx", "rtf", "pages":
            return ("doc.text", Color(hex: 0x2A6BC4))
        case "xls", "xlsx", "csv", "numbers":
            return ("tablecells", Color(hex: 0x1E9E5A))
        case "ppt", "pptx", "key":
            return ("chart.bar.doc.horizontal", Color(hex: 0xE07B1F))
        case "zip", "rar", "7z", "tar", "gz":
            return ("doc.zipper", Color(hex: 0xC79A2A))
        case "txt", "md", "log", "json", "xml":
            return ("doc.plaintext", Color(hex: 0x8A8A8E))
        case "mp3", "m4a", "wav", "aac", "flac":
            return ("music.note", Color(hex: 0x8A6FE8))
        case "mp4", "mov", "m4v", "avi", "mkv", "webm":
            return ("film", Color(hex: 0x5B6B7C))
        case "jpg", "jpeg", "png", "gif", "heic", "webp":
            return ("photo", Color(hex: 0x1180E0))
        default:
            return ("doc", Color(hex: 0x8A93FF))
        }
    }
}

/// 聊天里点开的文件（sheet(item:) 要 Identifiable）
struct FilePreviewData: Identifiable {
    let id = UUID()
    var name: String
    var local: URL
}

/// 文件预览页：系统 QuickLook + 右上角「分享」（分享里就有「用其他应用打开」）
struct FilePreviewSheet: View {
    let name: String
    let local: URL

    @Environment(\.dismiss) private var dismiss
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            QuickLookView(url: local)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(Tr("关闭")) { dismiss() }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { showShare = true } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
                .sheet(isPresented: $showShare) { ShareSheet(items: [local]) }
        }
    }
}

/// QuickLook 的 SwiftUI 包装（系统自带的预览：pdf / word / excel / 图片 / 文本都能看）
struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let vc = QLPreviewController()
        vc.dataSource = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: QLPreviewController, context: Context) { }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}



