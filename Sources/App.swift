import SwiftUI
import LocalAuthentication
import UIKit
import CoreImage

/* ============================================================ 全局状态 */

@MainActor
final class AppState: ObservableObject {
    @Published var booting = true

    /// 扫一扫扫到「登录码」：交给最外层弹微信那张「登录确认」卡片
    /// （扫一扫自己是盖在最上面的一页，让它先收起来再弹）
    @Published var pairApproveCode = ""

    /// 离线（连不上服务器）：界面照常显示缓存里的内容，顶上挂一条提示。
    @Published var offline = false

    init() {
        /* 冷启动先用本机存的那份界面配置（字号 / 颜色 / 间距）把界面画出来，
           再去服务器拉最新的。以前这里什么都没做：第一帧按硬编码默认值画，
           赶上网络慢或者配置没拉到，用户看到的就是「字体啥的恢复原样了」。 */
        applyCachedUIConfig()
    }

    /// 每几秒探一次服务器通不通（只打 /api/health）。
    /// 离线时**什么都不清空**：会话列表、聊天记录、联系人全留着，只是收不到新的。
    func checkReachability() async {
        await API.shared.ping()
        if offline != API.shared.offline { offline = API.shared.offline }
    }
    /// 服务器有没有开「登录滑动验证」（登录页配置里一起下发；默认开着更安全）
    @Published var sliderLogin = true
    @Published var me: User? {
        didSet {
            rememberLastUser()               // 谁登录（或改了头像）就记住谁，登录页圆圈用它
            /* 一登录就开始「红点兜底」轮询；退出登录就停 */
            if me != nil { startDotWatch() } else { dotTask?.cancel() }
        }
    }
    /// 这台设备上最后登录的人（登录页圆圈显示他的头像 / 名字）
    @Published var lastAvatar: String = UserDefaults.standard.string(forKey: "chris.lastAvatar") ?? ""
    @Published var lastName: String = UserDefaults.standard.string(forKey: "chris.lastName") ?? ""
    /// 已经登录过的人：启动先出一层**二级登录框**（微信那样：头像 + 名字 + 「登录」），
    /// 点了「登录」才进主界面；点「切换账号」回登录页。不是直接冲进去。
    @Published var needConfirmLogin = false
    /// 退出登录之后：**回二级登录框**（上次登录的那个人 + 「登录」/「切换账号」），
    /// 不是直接掉回一级登录页（用户要求）。
    @Published var showSavedLogin = false
    /// 登录过、可以一键切换的账号（最多 3 个）
    @Published var accounts: [SavedAccount] = AccountStore.load()
    /// 待处理的好友申请数量（通讯录红点用它）
    @Published var friendRequests = 0
    /// 后台配的红点规则（哪个位置该不该亮）
    @Published var badges: [String: String] = [:]

    /* ---------------- 版本更新 / 弹窗公告（后台「运营配置」里配） ---------------- */
    /// 必须更新：盖住整个 App，不给用（和微信一样）
    @Published var forcedUpdate: AppUpdateInfo? = nil
    /// 可选更新：可以「以后再说」
    @Published var optionalUpdate: AppUpdateInfo? = nil
    /// 弹窗公告
    @Published var noticeAlert: NoticeInfo? = nil

    /// 当前包的构建号（"B533 · 09-25 08:45" → 533）
    static var buildNumber: Int {
        let s = AppInfo.build
        guard let r = s.range(of: "B") else { return 0 }
        let digits = s[r.upperBound...].prefix { $0.isNumber }
        return Int(digits) ?? 0
    }
    /// 后台配的版本号（"B534" → 534；写别的格式就当 0，不弹更新）
    static func buildNumberOf(_ v: String?) -> Int {
        let s = String(v ?? "")
        guard let r = s.range(of: "B") else { return 0 }
        let digits = s[r.upperBound...].prefix { $0.isNumber }
        return Int(digits) ?? 0
    }
    /// "2026-10-01 00:00" / "2026-10-01" → Date（空 = 不限）
    private static func parseTime(_ s: String?) -> Date? {
        let t = String(s ?? "").trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        for fmt in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: t) { return d }
        }
        return nil
    }
    /// 公告在不在生效时间内
    private static func inWindow(start: String?, end: String?) -> Bool {
        let now = Date()
        if let s = parseTime(start), now < s { return false }
        if let e = parseTime(end), now > e { return false }
        return true
    }
    /// 公告的版本范围（B533 ~ B540 这种；留空 = 不限）
    private static func versionInRange(_ n: NoticeInfo) -> Bool {
        let mine = buildNumber
        let lo = buildNumberOf(n.minVersion)
        let hi = buildNumberOf(n.maxVersion)
        if lo > 0 && mine < lo { return false }
        if hi > 0 && mine > hi { return false }
        return true
    }
    /// 公告的稳定标识（做"弹过没"的标记用；不能用 hashValue，每次启动都不一样）
    private static func noticeKey(_ n: NoticeInfo) -> String {
        let s = (n.title ?? "") + "|" + (n.content ?? "")
        return String(s.prefix(40)) + "-" + String(s.count)
    }
    private static func dayKey() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// 拉一次版本 + 公告（启动时、回到前台各一次；失败就静默跳过）
    func checkVersionAndNotice() async {
        let (info, notice) = await API.shared.versionInfo()
        if let info = info {
            let want = Self.buildNumberOf(info.version)
            if want > Self.buildNumber {
                if info.force == true {
                    forcedUpdate = info                       // 强制：盖住整个 App
                } else {
                    let key = "chris.update.seen." + String(want)
                    if !UserDefaults.standard.bool(forKey: key) { optionalUpdate = info }
                }
            }
        }
        if let n = notice, !(n.content ?? "").isEmpty,
           Self.inWindow(start: n.startAt, end: n.endAt), Self.versionInRange(n) {
            let kind = n.kind ?? "popup"
            let key = "chris.notice.seen." + Self.noticeKey(n)
            switch kind {
            case "once":
                if !UserDefaults.standard.bool(forKey: key) { noticeAlert = n }
            case "daily":
                if UserDefaults.standard.string(forKey: key) != Self.dayKey() { noticeAlert = n }
            default:
                noticeAlert = n                                    // 每次打开都弹
            }
        }
    }

    func dismissNotice() {
        if let n = noticeAlert {
            let kind = n.kind ?? "popup"
            let key = "chris.notice.seen." + Self.noticeKey(n)
            // popup 类型不落标记（下次打开还要弹）
            if kind == "once" { UserDefaults.standard.set(true, forKey: key) }
            if kind == "daily" { UserDefaults.standard.set(Self.dayKey(), forKey: key) }
        }
        noticeAlert = nil
    }

    func dismissOptionalUpdate() {
        if let u = optionalUpdate {
            let want = Self.buildNumberOf(u.version)
            if want > 0 { UserDefaults.standard.set(true, forKey: "chris.update.seen." + String(want)) }
        }
        optionalUpdate = nil
    }

    /// 点「立即更新」：直接开下载页（自签包不能走 App Store，跳浏览器下载）
    func openUpdate(_ u: AppUpdateInfo) {
        let fallback = (u.downloadPage?.isEmpty == false ? u.downloadPage! : (u.url ?? ""))
        Task {
            /* 优先要一条限时签名链接：安装包直链收口（后台一个开关）以后，
               只有这条链接能下 —— 拿不到就退回原来的公开地址（过渡期老服务器也兼容） */
            let signed = await API.shared.appDownloadTicket()
            let s = signed ?? fallback
            /* 用带 completionHandler 的那个重载：Task 里直接 open(url) 会被解析成 async 版本，
               编译报「expression is 'async' but is not marked with 'await'」（B721 就栽在这儿） */
            if let url = URL(string: s) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
            dismissOptionalUpdate()
        }
    }

    /// 这个位置要不要显示红点：auto = 看真实数据；on = 一直亮；off = 不显示
    func showDot(_ key: String, auto: Bool) -> Bool {
        switch badges[key] ?? "auto" {
        case "on": return true
        case "off": return false
        default: return auto
        }
    }

    func loadBadges() async {
        badges = await API.shared.badgeConfig()
    }
    @Published var chats: [Chat] = []
    /* 通讯录。`contact(for:)` 在聊天页每一行都要问好几次（头像、昵称、通话头像…），
       以前是 `contacts.first { $0.id == id }` —— 500 个好友就是每条消息几百次比较，
       消息一多滚动就掉帧。这里跟着 contacts 一起维护一张 id → User 的表，查表 O(1)。 */
    @Published var contacts: [User] = [] {
        didSet { rebuildContactIndex() }
    }
    private var contactIndex: [String: User] = [:]
    private func rebuildContactIndex() {
        var m = [String: User](minimumCapacity: contacts.count)
        for u in contacts { m[u.id] = u }
        contactIndex = m
    }
    @Published var moments: [Moment] = []
    /// 朋友圈有没有新的（别人发了就 > 0，「发现」上挂红点）
    @Published var momentsUnread = 0
    /// 朋友圈「消息列表」未读数（谁赞了/评论了我）：朋友圈右上角小信封上的红点
    @Published var momentNoticeUnread = 0
    /// 聊天输入栏上面那排「快捷按钮」（管理 → 聊天快捷 里能增删/排序/改名/开关）
    @Published var quickChips: [QuickChip] = QuickChip.defaults
    /// 输入框右边那个「＋」按钮的外观（颜色 / 大小 / 图片）
    @Published var plusButton = PlusButtonCfg()
    /// 切换界面语言时 +1：让整棵界面树重建，所有文案立刻变
    @Published var langVersion = 0
    /// 启动页是否已经展示过（放全局：界面刷新、从后台切回来都不会重弹）
    @Published var splashDone = false
    /// 服务器上配的默认聊天背景（自己没设时用它，和网页版一致）
    @Published var defaultChatBackground = ""
    /// 后台配的启动页图片（空 = 用 App 包里那张）
    @Published var splashImage = ""
    @Published var toast: String?
    /// 扫到收付款码之后要弹的确认付款页（扫一扫在哪个页面都能弹出来）
    @Published var payScan: PayScanInfo?
    /// 扫到码的原文（一起交给付款页，金额以服务器解析的为准）
    @Published var payScanText: String = ""
    /// 扫一扫扫到别人的个人码：解析出来的人 —— 跳他的资料页（和微信一样，先看是谁再加）
    @Published var scanCardUser: User?
    /// 全局打开某个聊天：扫码进群、建完群、点推送都用它。
    /// 走最外层整页打开，不依赖「会话页的导航栈还在不在」——扫一扫从任何页面都能开，
    /// 以前那种「往会话页栈里 push」的写法，人不在会话页时通知就丢了（所以看着像不跳转）。
    @Published var openChat: Chat?
    /// 点了推送通知要让会话页自己把某个会话推进去（2026-10-12）：
    /// ⚠ 以前是直接 `openChat = c`（最外层 fullScreenCover 整页压上去）——
    /// 用户反复报「点推送通知就闪退」，因为点通知进来时 App 可能还在冷启动，
    /// 整页视图压上去会和启动那几帧打架被系统杀掉。
    /// 现在改成把会话 id 放这儿，**由会话列表按它自己的导航** push（和手点一个会话一模一样）。
    @Published var pendingPushChatId: String?
    /// 置 true 时 MainTab 把底栏切回「会话」那一页（配合 openChatViaList 用）
    @Published var wantChatsTab = false

    /// **统一的「打开某个会话」入口**（2026-10-12）：
    /// 以前各处都是 `app.openChat = c` —— 最外层 fullScreenCover 把整页聊天页压上去。
    /// 那条路在「页面正在切换」的瞬间会被系统杀掉：点推送（用户报过）、**刚建完群**（用户报
    /// 「创建了群也会闪退」）、扫码进群、搜索结果点进去……都是同一类。
    /// 现在统一改成：切回会话 tab + 把会话 id 交给会话列表，由它用自己那条导航 push
    /// —— 和用户手点一个会话**完全同一条路**，那条路一直是稳的。
    func openChatViaList(_ c: Chat) {
        wantChatsTab = true
        pendingPushChatId = c.id
    }
    /// 从聊天里点好友分享来的小游戏卡片 → 全屏打开那个小游戏。
    /// ⚠ 挂在**最外层**（MainTab）来弹，不放在聊天页里 —— 在聊天页里挂
    /// `fullScreenCover(item:)` 会让聊天页一打开就闪退（2026-10-11 踩过）。
    @Published var openMiniApp: MiniApp?
    @Published var loadingChats = false
    @Published var loadError: String?
    /// 服务器上的界面配置变了就 +1，整个界面重建一次（不用重装 App）
    @Published var uiVersion = 0
    /// 点进二级页面（聊天、名片、朋友圈、设置…）时把底部 4 个 tab 收起来。
    /// 用「层数」而不是布尔：从第三层返回第二层时，底栏不能错误地冒出来。
    @Published var tabBarDepth = 0
    /// 会话列表「二楼」拉下来时也要把底栏收起来。它不走导航栈（是同一页里叠出来的一层），
    /// 所以单独一个标志位；底栏该不该藏 = 导航栈有层数 **或者** 二楼开着。
    @Published var floorFull = false
    var tabBarHidden: Bool { tabBarDepth > 0 || floorFull }
    /// 外观：auto=跟随系统 · light=浅色 · dark=深色（存在本机，和网页版那个「切换外观」一样）
    @Published var appearance: String = UserDefaults.standard.string(forKey: "chris.appearance") ?? "auto"
    func setAppearance(_ v: String) {
        appearance = v
        UserDefaults.standard.set(v, forKey: "chris.appearance")
    }
    var preferredScheme: ColorScheme? {
        appearance == "light" ? .light : (appearance == "dark" ? .dark : nil)
    }
    private var lastUIConfig = ""
    private var refreshTask: Task<Void, Never>?
    /// 界面配置重试用过没有（拉失败以后 5 秒再拉一次）
    private var uiRetryScheduled = false

    /* 上一次成功拿到的界面配置（存在本机）。
       为什么要存：后台配的字号/颜色/间距是**每次启动从服务器拉**的。
       以前拉到空（断网、服务器重启的那十几秒、登录态过期）也会照样套用，
       于是 numbers/strings 被清空 → 全站字号、颜色、间距全掉回硬编码默认值，
       用户看到的就是「字体啥的怎么恢复原样了」。现在：拉失败就保持上一次的。 */
    private static let uiCacheKey = "chris.uiConfigJSON"
    private static let uiIconCacheKey = "chris.uiIconsJSON"

    /// 把短时间内的很多次推送合并成一次刷新（比如一下子涌进来几百条消息）
    private func coalesce(_ work: @escaping () async -> Void) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            await work()
            self?.refreshTask = nil
        }
    }

    /// 长连接推过来的事情，安排界面去刷新
    func handle(_ ev: PushEvent) {
        // 自己的资料变了（换封面 / 换头像 / 改昵称 / 改状态 / 换聊天背景）
        if let u = ev.user, u.id == me?.id || me == nil {
            me = u
            coalesce { [weak self] in
                await self?.loadChats()
                await self?.loadContacts()
            }
            return
        }
        if let b = ev.balance, var me = me {
            me.balance = b
            self.me = me
        }
        if !ev.announce.isEmpty && ev.type == "announce" {
            show("系统公告：" + ev.announce)
        }
        if let n = ev.momentUnread { momentsUnread = n }      // ready 里带的朋友圈未读数
        if let n = ev.momentNoticeUnread { momentNoticeUnread = n }   // 朋友圈「消息列表」未读数
        if let n = ev.friendRequests {
            /* 长连接重连（手机刚从后台回来）时把「新的朋友」红点补上；
               数字变了就把通讯录重拉一次，行里那个红点数字也跟着新 */
            let changed = n != friendRequests
            friendRequests = n
            if changed { coalesce { [weak self] in await self?.loadContacts() } }
        }
        switch ev.type {
        case "message", "chat":
            /* 新消息：按「消息通知」里的设置真响真震（免打扰时段里不响） */
            let cid = ev.chatId
            coalesce { [weak self] in
                await self?.loadChats()
                guard let self = self else { return }
                if !cid.isEmpty, let c = self.chats.first(where: { $0.id == cid }) {
                    if c.muted == true { return }              // 这个会话自己开了免打扰
                    /* ⚠ 同一条消息只推一次，而且只推**刚发来的**（两分钟内）——
                       用户 2026-10-14 报「同一条通知反复推」「后面的消息不推、就推一条
                       已经发了好些时间的」，就是这个：以前每收到一次事件就照当前
                       最后一条消息推一遍，同一条会重复推、旧消息也会被翻出来推。 */
                    let mid = c.lastMessage?.id ?? ""
                    guard LocalNotify.shouldNotify(chatId: c.id, msgId: mid,
                                                   at: c.lastMessage?.createdAt) else { return }
                    LocalNotify.incoming(title: c.name,
                                         body: c.lastMessage?.preview ?? "你收到一条新消息",
                                         chatId: c.id,
                                         msgId: mid,
                                         badge: unreadForIcon)
                } else {
                    LocalNotify.incoming(title: "新消息", body: "你收到一条新消息", badge: unreadForIcon)
                }
            }
        case "transfer":
            /* 转账状态变了（对方收款 / 24 小时自动退回）：
               付款方这边弹一句提示，会话列表跟着刷一遍 */
            if ev.transferStatus == "received", ev.transferFromId == me?.id,
               let a = ev.transferAmount {
                show("对方已收款 ¥" + money(a))
            }
            coalesce { [weak self] in await self?.loadChats() }
        case "moment":
            momentsUnread = max(1, momentsUnread)          // 有人发朋友圈：先点红点，再拉一次
            coalesce { [weak self] in await self?.loadMoments() }
        case "moment-notice":
            /* 朋友圈「消息列表」：谁赞了/评论了我。小信封上的红点立刻变，
               顺便真弹一条通知（微信也是收得到这个提醒的）。 */
            if let n = ev.momentNoticeUnread { momentNoticeUnread = n }
            else if ev.momentNotice != nil { momentNoticeUnread += 1 }
            if let nt = ev.momentNotice {
                let who = nt.name ?? "有人"
                let what: String
                switch nt.kind ?? "" {
                case "like": what = "赞了你的朋友圈"
                case "reply": what = "回复了你"
                default: what = "评论了你的朋友圈"
                }
                LocalNotify.incoming(title: "朋友圈", body: who + what, badge: unreadForIcon)
            }
        case "friend", "presence", "profile":
            coalesce { [weak self] in await self?.loadContacts() }
        case "toast":
            /* 服务器一句轻提示（比如"拍一拍太频繁了"） */
            if !ev.announce.isEmpty { show(ev.announce) }
        case "transferRemind":
            /* 对方点了「提醒你收款」：真弹一条提示（以前那颗按钮只是自己这边弹个假的） */
            show(ev.announce.isEmpty ? "对方提醒你确认收款" : ev.announce)
            coalesce { [weak self] in await self?.loadChats() }
        default:
            break
        }
    }

    private var toastTask: Task<Void, Never>?

    func show(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_900_000_000)
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    func boot() async {
        CrashCatcher.note("启动", "3 boot 开始")
        /* 兜底：不管网络多慢，最多 6 秒一定离开「正在连接…」这一屏。
           线路被掐的时候让用户盯着「正在连接」干等，是最容易被投诉的那种体验：
           到点就先放进 App（有缓存资料就用缓存），后台继续连，连上了界面自己会更新。 */
            let watchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled, booting else { return }
            if me == nil, let cached = AppState.cachedUser() {
                me = cached
                needConfirmLogin = true
            }
            booting = false
        }
        defer { watchdog.cancel() }
        await refreshUI(force: true)
        CrashCatcher.note("启动", "4 界面配置就绪")
        await loadBadges()
        /* 版本更新 / 弹窗公告：不阻塞启动（失败了也不影响进 App） */
        await checkVersionAndNotice()
        if API.shared.token.isEmpty {
            booting = false
            return
        }
        do {
            let s = try await API.shared.session()
            CrashCatcher.note("启动", "5 会话查询返回")
            if s.ok, let user = s.user {
                me = user
                rememberLastUser()      // 登录页那个圆圈用「最后登录的人」的头像
                /* 已经登录过：先出**二级登录框**（微信那样），点了「登录」才进主界面 */
                needConfirmLogin = true
                await refreshAll()
                Realtime.shared.start()
            } else {
                API.shared.clearToken()
            }
        } catch {
            /* 连不上服务器（电脑没开 / 不在同一个 Wi-Fi）：不要把人踢回登录页，
               先用本地缓存的资料进 App，等服务器回来了再自动同步。 */
            if let cached = AppState.cachedUser() {
                me = cached
                needConfirmLogin = true      // 断网也算"已经登录过"，先出二级登录框
            }
            /* 而且要把**上次的会话/通讯录/朋友圈**也铺出来（API 那边存了一份），
               不然冷启动断网时主界面是空的 —— 微信断网也是照常显示上次的列表。 */
            await refreshAll()
        }
        booting = false
    }

    /// 本地缓存的当前用户（离线进 App 用）
    static func cachedUser() -> User? {
        guard let s = UserDefaults.standard.string(forKey: "chris.lastUserJSON"),
              let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(User.self, from: d)
    }

    /// 拉服务器上的 data/ui.json：改了数字/颜色，App 重开或回到前台就生效
    func refreshUI(force: Bool = false) async {
        let cfg = await API.shared.uiConfig()
        /* 空 = 这次没拉到（断网 / 正好赶上服务器重启 / 掉登录）：
           千万别把空配置套上去，那会把后台配的字号、颜色、间距全清掉。
           保持上一次的，并安排在 5 秒后自己再拉一次。 */
        if cfg.ui.isEmpty && cfg.icons.isEmpty {
            applyCachedUIConfig()
            scheduleUIRetry()
            return
        }
        let stamp = String(describing: cfg.ui.sorted { $0.key < $1.key })
            + "|icons:" + String(describing: cfg.icons.sorted { $0.key < $1.key })
        if force || stamp != lastUIConfig {
            lastUIConfig = stamp
            UIConfig.apply(cfg.ui)
            IconOverrides.map = cfg.icons
            cacheUIConfig(cfg.ui, cfg.icons)
            uiVersion += 1
        }
        // 服务器上配的默认聊天背景（自己没设时用）
        if let b = await API.shared.branding() {
            defaultChatBackground = b.chatBackground ?? ""
            splashImage = b.splash ?? ""
        }
        /* 聊天输入栏那一份配置（快捷按钮 + 「＋」按钮外观）跟着一起拉：
           管理里改完不用重开 App，回到前台就生效 */
        await loadChatQuick()
        /* 顺手把「线路入口」列表拉一份存起来：后台改了备用地址，用户在下次进前台就生效，
           不用等出新包。主入口连不上时，下一次请求会自动换到这份列表里的下一条。 */
        await API.shared.loadEndpointList()
    }

    /* ---------------------------------------------------------- 界面配置的本机缓存 */

    /// 存一份到本机（下次启动先用它渲染，不用等服务器）
    private func cacheUIConfig(_ ui: [String: Any], _ icons: [String: String]) {
        if let d = try? JSONSerialization.data(withJSONObject: ui),
           let s = String(data: d, encoding: .utf8) {
            UserDefaults.standard.set(s, forKey: Self.uiCacheKey)
        }
        if !icons.isEmpty,
           let d = try? JSONSerialization.data(withJSONObject: icons),
           let s = String(data: d, encoding: .utf8) {
            UserDefaults.standard.set(s, forKey: Self.uiIconCacheKey)
        }
    }

    /// 先用本机存的那一份（启动时、以及某次拉失败时都走这里）
    func applyCachedUIConfig() {
        if let s = UserDefaults.standard.string(forKey: Self.uiCacheKey),
           let d = s.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d),
           let ui = obj as? [String: Any],
           !ui.isEmpty {
            UIConfig.apply(ui)
        }
        if let s = UserDefaults.standard.string(forKey: Self.uiIconCacheKey),
           let d = s.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d),
           let icons = obj as? [String: String],
           !icons.isEmpty {
            IconOverrides.map = icons
        }
    }

    /// 拉失败后 5 秒再拉一次（只排一次，别堆起来）
    private func scheduleUIRetry() {
        guard !uiRetryScheduled else { return }
        uiRetryScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self = self else { return }
            self.uiRetryScheduled = false
            await self.refreshUI()
        }
    }

    func login(username: String, password: String) async throws {
        me = try await API.shared.login(username: username, password: password, sliderTicket: "")
        rememberLastUser()
        await refreshAll()
        Realtime.shared.start()
    }

    /// 账号密码登录：服务器开着滑动验证时，要带上滑块换来的一次性通行证
    func login(username: String, password: String, sliderTicket: String) async throws {
        me = try await API.shared.login(username: username, password: password, sliderTicket: sliderTicket)
        rememberLastUser()
        await refreshAll()
        Realtime.shared.start()
        /* 登录后同步最近的聊天记录（微信那句文案对应的动作） */
        Task { await syncRecentMessages() }
    }

    /// 注册成功后直接用返回的用户进去（注册接口已经把登录态发下来了，不用再走一次登录）
    func adoptRegistered(_ user: User) async {
        me = user
        rememberLastUser()
        await refreshAll()
        Realtime.shared.start()
        Task { await syncRecentMessages() }
    }

    /// 新用户引导完成：服务端保存头像和分类后，根视图会自动从引导页切到首页。
    func finishNewUserOnboarding(avatar: String, interests: [String]) async throws {
        let updated = try await API.shared.completeOnboarding(avatar: avatar, interests: interests)
        me = updated
        rememberLastUser()
        await loadContacts()
        await loadChats()
    }

    func login(phone: String, code: String) async throws {
        me = try await API.shared.loginPhone(phone: phone, code: code)
        rememberLastUser()
        await refreshAll()
        Realtime.shared.start()
        Task { await syncRecentMessages() }
    }

    /// 身份证自助解封成功后走这里：等同于登录成功（解封接口会把登录态一起发下来）
    func finishLogin(_ user: User) async {
        me = user
        rememberLastUser()
        await refreshAll()
        Realtime.shared.start()
        Task { await syncRecentMessages() }
    }

    /* ---------------- 红点兜底 ----------------
       推送偶尔会漏（手机在后台、长连接正在重连、被系统掐了）。
       所以除了推送，还有两层：
       ① 长连接重连时服务器在 ready 里带上 friendRequests；
       ② 回到前台 + 每 25 秒轻量问一次 /api/badge-counts。
       这样「有人加你好友」最迟 25 秒内通讯录一定出红点。 */
    private var dotTask: Task<Void, Never>?
    func startDotWatch() {
        dotTask?.cancel()
        dotTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                if Task.isCancelled { break }
                await self?.refreshDotCounts()
            }
        }
    }
    func refreshDotCounts() async {
        guard me != nil, let d = await API.shared.badgeCounts() else { return }
        if d.friendRequests != friendRequests {
            friendRequests = d.friendRequests
            await loadContacts()          // 让「新的朋友」行里的数字也跟上
        }
        if d.momentUnread != momentsUnread { momentsUnread = d.momentUnread }
    }

    /// 记住这台设备上最后登录的人（登录页的圆圈用它显示头像）
    func rememberLastUser() {
        guard let me = me else { return }
        lastAvatar = me.avatar ?? ""
        lastName = me.nickname ?? me.username ?? ""
        UserDefaults.standard.set(lastAvatar, forKey: "chris.lastAvatar")
        UserDefaults.standard.set(lastName, forKey: "chris.lastName")
        /* 缓存一份完整资料：连不上服务器时用它先进 App，不把人踢回登录页 */
        if let d = try? JSONEncoder().encode(me), let s = String(data: d, encoding: .utf8) {
            UserDefaults.standard.set(s, forKey: "chris.lastUserJSON")
        }
        /* 记进「登录过的账号」列表：最多 3 个，登录页可以左右滑 */
        if let u = me.username, !u.isEmpty, !API.shared.token.isEmpty {
            accounts = AccountStore.upsert(username: u,
                                           nickname: me.nickname ?? u,
                                           avatar: me.avatar ?? "",
                                           token: API.shared.token)
        }
    }

    func refreshAll() async {
        CrashCatcher.install()              // 装上崩溃上报：崩了会把调用栈发到服务器
        LocalNotify.prepare()               // 先要通知权限，之后新消息才会真响真震
        PushCenter.shared.start()           // 苹果推送：要权限 + 拿 device token 交给服务器
        PushCenter.shared.uploadIfPossible()
        /* 换账号 / 重新登录进来了：「已被顶下线」那张卡片复位，顺便拉一次小星的档位
           （会话页顶栏那颗眼睛按档位画：开启会动 / 静态不动 / 关闭不画） */
        OtherLogin.shared.reset()
        /* 先把本机存的「小星档位」铺上（按账号存的），再去服务器拉真档位 ——
           不然关了眼睛的人每次进来都会先冒出那双眼睛、两秒后才消失。 */
        EyesStore.shared.primeFromCache()
        /* 小星档位**延后 2 秒**再去拉：一登录就拉的话，@Published 一变会话页整个顶栏会重画，
           要是正好撞上用户"点聊天"那一下，这台测试机就被系统直接杀进程（无崩溃栈）。
           2 秒够启动画面走完，用户也很少在 2 秒内点开一个会话。 */
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await EyesStore.shared.refresh()
        }
        /* 启动就留一条系统日志（Console 里能看到）+ 打点：
           出了「内容不动了」这类问题，先看启动时间点对不对得上。 */
        AppLog.info("启动 " + AppInfo.build + " · " + AppInfo.deviceKind + " · " + API.shared.server)
        await LocalNotify.refresh()
        await loadChats()
        await loadContacts()
        await loadMoments()
    }

    /* ----------------------------------------------------------
       登录后同步最近的聊天记录（微信那句「登录后同步最近的聊天记录」）
       一次把最近 10 个会话、每个最近 30 条消息拉下来：
         · 会话列表立刻就有
         · 每个会话的最近消息先存在 prefetched 里，进会话时直接铺出来，不用等网络
       同步是后台做的，界面顶部显示一条进度提示，失败也不拦着用。
       ---------------------------------------------------------- */
    @Published var syncing = false
    @Published var syncText = ""
    /// 预取的最近消息：chatId -> 最近 N 条
    var prefetched: [String: [Message]] = [:]

    func syncRecentMessages(chatCount: Int = 10, limit: Int = 30) async {
        syncing = true
        syncText = "正在同步最近的聊天记录…"
        defer { syncing = false }
        do {
            let r = try await API.shared.chatsWithRecentMessages(chats: chatCount, limit: limit)
            chats = r.chats          // 这里的 chats 是 AppState 自己那份列表
            var total = 0
            for c in r.synced {
                if let msgs = c.messages, !msgs.isEmpty {
                    prefetched[c.id] = msgs
                    total += msgs.count
                }
            }
            syncText = "已同步 " + String(r.synced.count) + " 个会话 / " + String(total) + " 条消息"
            /* 提示留一会儿再消失，别一闪而过 */
            try? await Task.sleep(nanoseconds: 900_000_000)
            syncText = ""
        } catch {
            syncText = ""
        }
    }

    func loadChats() async {
        loadingChats = true
        defer { loadingChats = false }
        do {
            let fresh = try await API.shared.chats()
            /* 只在内容真的变了才赋值。
               以前每 4 秒（会话页的定时刷新）都无条件赋值一次，SwiftUI 会把整个
               列表行（头像、左滑手势、角标）重建一遍 —— 这就是"看着卡卡的"的主因。 */
            if !AppState.sameChats(chats, fresh) { chats = fresh }
            loadError = nil
        } catch {
            loadError = (error as? APIError)?.errorDescription ?? "加载失败"
        }
        syncIconBadge()
    }

    /// 两份会话列表内容是不是一样（用来避免无意义的重画）
    static func sameChats(_ a: [Chat], _ b: [Chat]) -> Bool {
        if a.count != b.count { return false }
        for i in 0..<a.count {
            let x = a[i], y = b[i]
            if x.id != y.id { return false }
            if x.unreadCount != y.unreadCount { return false }
            if (x.pinned ?? false) != (y.pinned ?? false) { return false }
            if (x.muted ?? false) != (y.muted ?? false) { return false }
            /* 「标为未读」的红点标记：变了也要重画（红点 ↔ 数字的切换靠它） */
            if (x.flagged ?? false) != (y.flagged ?? false) { return false }
            if (x.title ?? "") != (y.title ?? "") { return false }
            if (x.avatar ?? "") != (y.avatar ?? "") { return false }
            if (x.moodIcon ?? "") != (y.moodIcon ?? "") { return false }
            if (x.lastMessage?.preview ?? "") != (y.lastMessage?.preview ?? "") { return false }
            if (x.lastMessage?.createdAt ?? "") != (y.lastMessage?.createdAt ?? "") { return false }
        }
        return true
    }

    /// 桌面图标右上角那个红点数字（微信也是这个数）：所有会话未读加一起。
    /// 读完了就归零；有未读就显示。系统没给通知权限时这一句是空操作。
    var unreadForIcon: Int {
        var n = 0
        for c in chats where c.muted != true { n += c.unreadCount }
        return min(999, max(0, n))
    }

    func syncIconBadge() {
        let v = unreadForIcon
        DispatchQueue.main.async {
            UIApplication.shared.applicationIconBadgeNumber = v
        }
    }

    func loadContacts() async {
        if let r = try? await API.shared.contactsFull() {
            /* 同样只在变了才赋值：通讯录也是几百行，无条件重画同样会卡 */
            let sameOrder = contacts.map { $0.id } == r.friends.map { $0.id }
            let sameLook = contacts.count == r.friends.count
                && zip(contacts, r.friends).allSatisfy { $0.avatarPath == $1.avatarPath && $0.name == $1.name }
            if !(sameOrder && sameLook) { contacts = r.friends }
            friendRequests = r.incoming.count        // 别人加你好友 → 通讯录亮红点
        }
    }

    func loadMoments() async {
        if let feed = try? await API.shared.momentsFeed() {
            moments = feed.moments
            momentsUnread = feed.unread
            momentNoticeUnread = feed.noticeUnread      // 朋友圈小信封上的红点
        }
    }

    /// 拉聊天输入栏那份配置（快捷按钮 + 「＋」按钮外观）。
    /// 拉不到就保持原来那排默认的，绝不把用户的按钮清空。
    func loadChatQuick() async {
        guard let c = try? await API.shared.plusConfig() else { return }
        if !c.quick.isEmpty { quickChips = c.quick }
        plusButton = c.plus
    }

    func logout() async {
        /* 退出登录：这台手机不再收这个账号的推送 */
        KeepAlive.shared.stop()          // 别在后台白占着音频
        OtherLogin.shared.reset()        // 「已被顶下线」那张卡片复位
        await API.shared.unregisterPushToken(PushCenter.shared.token)
        await API.shared.logout()
        Realtime.shared.stop()
        me = nil
        chats = []
        contacts = []
        moments = []
        /* 用户要求：退出登录之后**回二级登录框**（上次登录的那个人 + 登录/切换账号），
           不要直接掉回一级登录页 —— 设这个标记，RootView 就会先出那一屏。 */
        showSavedLogin = true
        needConfirmLogin = false
        syncIconBadge()          // 退出登录：图标上的数字清零
    }

    /// 一键登录：用这台设备上保存的登录令牌直接进去（登录页点头像就用这个）
    func quickLogin(token: String? = nil) async -> Bool {
        if let t = token, !t.isEmpty { API.shared.setToken(t) }
        guard !API.shared.token.isEmpty else { return false }
        guard let s = try? await API.shared.session(), s.ok, let user = s.user else {
            API.shared.clearToken()      // 令牌过期/失效：清掉，让用户重新输密码
            return false
        }
        me = user
        rememberLastUser()
        await refreshAll()
        Realtime.shared.start()
        GrowthStore.shared.start()               // 等级：登录后开始记活跃天
        Task { await syncRecentMessages() }      // 进来后顺手同步最近的聊天记录（不拦着用）
        return true
    }

    func contact(for id: String) -> User? {
        if me?.id == id { return me }
        /* 查表（见上面 contactIndex 的说明）。表还没建好时兜底扫一遍。 */
        if let hit = contactIndex[id] { return hit }
        if contactIndex.isEmpty { return contacts.first { $0.id == id } }
        return nil
    }
}

/* ============================================================ 入口 */

private extension View {
    /// iOS 26 会给滚动视图自动加一层顶部玻璃边缘，看起来像一团白光。
    /// 三个主页面都自己控制顶部背景，因此在这里统一关闭系统边缘效果。
    @ViewBuilder
    func hideTopScrollEdgeEffect() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

@main
struct CHRISApp: App {
    @StateObject private var app = AppState()
    /* 苹果推送：拿 device token、收通知、点通知进聊天 */
    @UIApplicationDelegateAdaptor(PushCenter.self) private var push

    init() {
        /* 一启动就装崩溃上报：连登录页崩都能抓到（以前放在登录之后，前面的崩抓不到） */
        CrashCatcher.install()
        /* 启动分阶段打点：万一崩在启动路上，服务器日志里能看到卡在第几步
           （只看 "launch" 一条的话，不知道是崩在配置、会话还是主界面） */
        CrashCatcher.note("启动", "1 App init")
        /* 图片/视频/媒体走系统磁盘缓存：服务器现在给上传文件发的是「一年内不用再问」的长缓存，
           把缓存容量调大以后，头像、封面、朋友圈图片、看过的视频就不再每次重下了 ——
           这是手机上"卡"和费流量的大头。默认只有 10MB，太小。 */
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024,
                                   diskCapacity: 512 * 1024 * 1024,
                                   diskPath: "chris-media-cache")
    }

    var body: some Scene {
        WindowGroup {
            /* 启动页挂在窗口最外层：这样它是**整块屏幕**铺满（含状态栏那一条），
               以前挂在页面里只覆盖安全区，顶部会露出一条。 */
            ZStack {
                RootView()
                    .environmentObject(app)
                    .preferredColorScheme(app.preferredScheme)   // 跟随系统 / 强制浅色 / 强制深色
                    .hideTopScrollEdgeEffect()
                /* 扫一扫扫到「登录码」：出微信那张「登录确认」卡片（写清设备名和时间） */
                Color.clear
                    .frame(width: 0, height: 0)
                    .sheet(isPresented: Binding(
                        get: { !app.pairApproveCode.isEmpty },
                        set: { if !$0 { app.pairApproveCode = "" } }
                    )) {
                        PairApproveView(startCode: app.pairApproveCode) { app.pairApproveCode = "" }
                            .environmentObject(app)
                    }
                if !app.splashDone {
                    SplashView(remote: app.splashImage)
                        .transition(.opacity)
                        .zIndex(9)
                }
                /* 弹窗公告 / 可选更新 / 强制更新：一层层盖上去（和微信一样，强制更新盖在最上面） */
                if let n = app.noticeAlert {
                    CenterCard(title: (n.title?.isEmpty == false ? n.title! : Tr("公告")),
                               text: n.content ?? "",
                               primary: Tr("我知道了"),
                               onPrimary: { app.dismissNotice() })
                        .transition(.opacity)
                        .zIndex(12)
                }
                if let u = app.optionalUpdate {
                    CenterCard(title: Tr("发现新版本") + " " + (u.version ?? ""),
                               text: u.notes ?? "",
                               primary: Tr("立即更新"),
                               onPrimary: { app.openUpdate(u) },
                               secondary: Tr("以后再说"),
                               onSecondary: { app.dismissOptionalUpdate() })
                        .transition(.opacity)
                        .zIndex(13)
                }
                if let u = app.forcedUpdate {
                    ForceUpdateView(info: u)
                        .transition(.opacity)
                        .zIndex(20)
                }
            }
        }
    }
}

/* ============================================================
   二级登录框（微信那样）

   已经登录过的人（本机还留着上次的登录状态），启动后**先出这一屏**：
   上面是上次那个人的头像 + 名字（+ 一句提示），底下一条「登录」，
   再下面一行「切换账号」。点了「登录」才进主界面 —— 不是直接冲进去。
   ============================================================ */
struct SavedLoginConfirm: View {
    @EnvironmentObject var app: AppState
    @State private var appear = false
    @State private var busy = false

    /// 本机保存的登录令牌（退出登录之后靠它一键登回来；没有就只能去一级登录页）
    private var savedToken: String {
        /* 令牌是**按账号存在钥匙串**里的（SavedAccount 里没有 token 字段），
           所以这里先按"上次登录那个人"的头像找到账号名，再取钥匙串里那把令牌。 */
        if let a = app.accounts.first(where: { $0.avatar == app.lastAvatar }) {
            let t = AccountStore.token(for: a.username)
            if !t.isEmpty { return t }
        }
        for a in app.accounts {
            let t = AccountStore.token(for: a.username)
            if !t.isEmpty { return t }
        }
        return ""
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 16) {
                Avatar(path: app.lastAvatar, size: 88, radius: 12, circle: false)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(C.hairline, lineWidth: 0.6))
                    .shadow(color: Color.black.opacity(0.14), radius: 14, y: 6)

                VStack(spacing: 5) {
                    Text(app.lastName.isEmpty ? Tr("星言用户") : app.lastName)
                        .font(pf(20, .semibold))
                        .foregroundColor(C.label)
                        .lineLimit(1)
                    Text(Tr("上次登录的账号"))
                        .font(pf(12.5))
                        .foregroundColor(C.subLabel)
                }
            }
            .scaleEffect(appear ? 1 : 0.94)
            .opacity(appear ? 1 : 0)

            Spacer(minLength: 0)

            VStack(spacing: 14) {
                Button {
                    go()
                } label: {
                    Text(Tr("登录"))
                        .font(pf(16, .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(Capsule().fill(LinearGradient(
                            colors: [C.green, C.green.opacity(0.78)],
                            startPoint: .topLeading, endPoint: .bottomTrailing)))
                }
                .buttonStyle(.plain)

                Button {
                    /* 切换账号：把本机的登录状态清掉，回登录页 */
                    API.shared.clearToken()
                    app.me = nil
                    app.needConfirmLogin = false
                    app.showSavedLogin = false
                } label: {
                    Text(Tr("切换账号"))
                        .font(pf(15))
                        .foregroundColor(C.subLabel)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 44)
            .opacity(appear ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.pageBg.ignoresSafeArea())
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { appear = true }
        }
    }

    /// 点「登录」：
    /// · 启动那次（会话还在）→ 直接进主界面
    /// · **退出登录之后**（会话已清）→ 用本机保存的令牌一键登回来；令牌失效就去一级登录页
    private func go() {
        if app.me != nil {
            withAnimation(.easeOut(duration: 0.18)) { app.needConfirmLogin = false }
            return
        }
        guard !busy else { return }
        busy = true
        Task {
            let ok = await app.quickLogin(token: savedToken)
            busy = false
            if ok {
                app.showSavedLogin = false
            } else {
                app.showSavedLogin = false      // 令牌不管用了：回一级登录页，让用户重新输
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var realtime = Realtime.shared

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if app.booting {
                    LaunchView()
                } else if app.needConfirmLogin || app.showSavedLogin {
                    /* 二级登录框：启动时（之前登录过）和**退出登录之后**都先出这一屏 */
                    SavedLoginConfirm()
                } else if app.me == nil {
                    /* 2026-10-16 用户点名要「最早那版、能换圆圈头像的」——
                       就是这版 LoginView（方案 3）：上面是登录过的账号头像（正圆，
                       最多 3 个，左右滑切换，点一下就用那个账号一键登录），
                       底下一颗玻璃主按钮 + 「更多登录方式 ›」（手机号 / 账号密码 / 人脸 / 声音锁）。
                       当时切走是因为「更多登录方式 → 账号密码登录」点不动，
                       那个坑（sheet 叠 sheet 被系统丢掉）已经在 openWay/afterSheet 里修好了：
                       先把上一个弹窗关掉、等它收完再开目标页。
                       微信风那版 LoginViewOld 一行没删，随时能切回来。 */
                    LoginView()
                } else if app.me?.needsOnboarding == true {
                    NewUserOnboardingView()
                        .environmentObject(app)
                } else {
                    MainTabView()
                }

                if let text = app.toast {
                    VStack {
                        Spacer()
                        Text(text)
                            .font(pf(14))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.78)))
                            .padding(.bottom, L.tabH + L.safeBottom + 40)
                    }
                    .allowsHitTesting(false)
                }
            }
            .id(app.uiVersion)
            // 根视图也铺一层底色：万一哪个页面没铺满，顶上也不会露出系统窗口的白色
            .background(C.pageBg.ignoresSafeArea())
            .onAppear { L.width = geo.size.width }
            .onChange(of: geo.size.width) { w in L.width = w }
        }
        .task { await app.boot() }
        .onAppear {
            /* 启动页只在冷启动显示 1 秒；从后台切回来、界面刷新都不再弹 */
            guard !app.splashDone else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                withAnimation(.easeOut(duration: 0.35)) { app.splashDone = true }
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active && app.me != nil {
                KeepAlive.shared.stop()          // 回到前台：不用再保活了
                Task {
                    GrowthStore.shared.start()   // 等级：回前台继续记「活跃天」
                    await app.refreshUI()
                    await app.loadChats()
                    await app.loadContacts()      // 回到前台也要重拉好友申请，不然通讯录红点不亮
                    await app.refreshDotCounts()
                    Realtime.shared.start()
                }
            } else if phase == .background {
                GrowthStore.shared.stop()        // 退后台：把这段时长先报上去
                /* 退到后台：放一段静音把进程留住 —— 长连接不断，来消息才能弹通知
                   （上滑强杀之后谁都叫不醒，那只能靠真 APNs） */
                KeepAlive.shared.start()
            }
        }
        .onChange(of: realtime.event) { ev in
            /* 后台换了图标/界面配置：服务器会推一条 type=ui，收到就立刻重拉，
               这样不用划掉 App 重开也能看到新图标。 */
            if ev.type == "ui" {
                Task { await app.refreshUI(force: true) }
                return
            }
            /* 后台改了成长系统（阈值/显示位置）：立刻重拉一次 */
            if ev.type == "growth" {
                Task { await GrowthStore.shared.refresh() }
                return
            }
            app.handle(ev)
        }
    }
}

struct LaunchView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 14) {
                if let img = AppIconImage.image {
                    Image(uiImage: img)
                        .resizable()
                        .frame(width: 66, height: 66)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                Text(Tr("正在连接…")).font(pf(13)).foregroundColor(C.loginGray)
            }
        }
    }
}

/* ============================================================ 登录页 */

/* 旧的微信风登录页（保留但不再使用；新的是下面那个简洁版 LoginView） */
struct LoginViewOld: View {
    @EnvironmentObject var app: AppState
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focus: Field?

    private enum Field: Hashable { case phone, code, user, pass }

    @State private var usePassword = false
    @State private var country = "中国大陆 (+86)"
    /* 上次用过的手机号：进来就带出来，省得每次重打（iCloud 钥匙串不接管我们这套登录，
       所以自己存一份在本机）。真正的"读取本机号码"iOS 不给 API，只能靠运营商一键登录 SDK。 */
    @State private var phone = UserDefaults.standard.string(forKey: "chris.lastPhone") ?? ""
    @State private var code = ""
    @State private var username = ""
    @State private var password = ""
    @State private var syncHistory = true
    @State private var busy = false
    @State private var error: String?
    @State private var codeSent = false
    @State private var showServer = false
    @State private var server = API.shared.server

    var body: some View {
        ZStack {
            /* 底色跟着后台「登录页」那套走：配了底色就用它（现在是紫底 + 白卡 + 靛蓝主色），
               没配才回落到系统背景。以前这里写死 systemBackground，卡片又写死深色 ——
               浅色模式下就是"白底上一块黑砖"，输入框连边都看不出来。 */
            LoginTheme.bg(scheme).ignoresSafeArea()
            VStack(spacing: 0) {
                nav
                ScrollView {
                    VStack(spacing: 0) {
                        panel
                        if let error = error {
                            Text(error)
                                .font(pf(13.5))
                                .foregroundColor(LoginTheme.pageBg == nil ? C.red : Color(hex: 0xFF8E8E))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 18)
                                .padding(.top, 12)
                        }
                        if !usePassword {
                            Text(Tr("仅上述手机号用于登录验证"))
                                .font(pf(13.5))
                                .foregroundColor(LoginTheme.onBgSub(scheme))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 18)
                                .padding(.top, 11)
                        }
                        Spacer(minLength: 30)
                    }
                    .padding(.top, 14)
                    .frame(minHeight: 660, alignment: .top)
                }
                foot
            }
        }
        .onAppear {
            /* 上一次填过的手机号带出来（用户换了号也会被下面的 textField 改掉） */
            if phone.isEmpty, let last = UserDefaults.standard.string(forKey: "chris.lastPhone"), !last.isEmpty {
                phone = last
            }
        }
        .sheet(isPresented: $showServer) {
            ServerSheet(server: $server) {
                API.shared.setServer(server)
                server = API.shared.server
                showServer = false
                app.show("服务器已改成 \(server)")
            }
        }
    }

    /* 「账号密码登录」入口：用户从 4 个排法里选了 D ——
       放在主按钮**正上方的右对齐**位置（不挤按钮，也不在卡片上再加一块东西），
       一点就切到账号/密码两行，再点变「用手机号登录」。 */
    private var switchLink: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { usePassword.toggle() }
                error = nil
                focus = nil
            } label: {
                HStack(spacing: 3) {
                    Text(Tr(usePassword ? "用手机号登录" : "账号密码登录"))
                        .font(pf(14))
                    Image(systemName: "chevron.right")
                        .font(pf(11, .semibold))
                }
                .foregroundColor(LoginTheme.onBg(scheme))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 11)
    }

    private var nav: some View {
        ZStack {
            Text(usePassword ? "账号密码登录" : "手机号登录")
                .font(pf(18, .semibold))
                .foregroundColor(LoginTheme.onBg(scheme))
            HStack {
                Button {
                    focus = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(pf(22, .regular))
                        .foregroundColor(LoginTheme.onBg(scheme))
                        .frame(width: 44, height: 52)
                }
                Spacer()
            }
        }
        .frame(height: 52)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            if !usePassword {
                loginRow(label: "国家/地区") {
                    Spacer()
                    Text(country).font(pf(16)).foregroundColor(LoginTheme.inkSub(scheme))
                    Chevron(size: 9, line: 1.6, color: LoginTheme.inkSub(scheme))
                }
                HairLine(color: LoginTheme.ink(scheme).opacity(0.09))
                loginRow(label: "手机号") {
                    Text("+86").font(pf(17)).foregroundColor(LoginTheme.ink(scheme))
                    TextField("", text: $phone)
                        .focused($focus, equals: .phone)
                        .keyboardType(.numberPad)
                        .textContentType(.telephoneNumber)
                        .font(pf(17.5))
                        .foregroundColor(LoginTheme.ink(scheme))
                        .frame(height: 46)
                }
                HairLine(color: LoginTheme.ink(scheme).opacity(0.09))
                loginRow(label: "验证码") {
                    TextField("", text: $code)
                        .focused($focus, equals: .code)
                        .keyboardType(.numberPad)
                        /* iOS 自带的「短信验证码自动填充」：收到短信时键盘上方会直接给出
                           那串数字，点一下就填进来 —— 这是不接运营商 SDK 也能做到的"半自动"。 */
                        .textContentType(.oneTimeCode)
                        .font(pf(17.5))
                        .foregroundColor(LoginTheme.ink(scheme))
                        .frame(height: 46)
                    Button {
                        sendCode()
                    } label: {
                        Text(codeSent ? "已发送" : "获取验证码")
                            .font(pf(15, .medium))
                            .foregroundColor(codeSent ? LoginTheme.inkSub(scheme) : LoginTheme.accent)
                            .padding(.vertical, 6)
                    }
                }
            } else {
                loginRow(label: "账号") {
                    TextField("", text: $username)
                        .focused($focus, equals: .user)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .font(pf(17.5))
                        .foregroundColor(LoginTheme.ink(scheme))
                        .frame(height: 46)
                }
                HairLine(color: LoginTheme.ink(scheme).opacity(0.09))
                loginRow(label: "密码") {
                    SecureField("", text: $password)
                        .focused($focus, equals: .pass)
                        /* 登录密码本来就是安全输入框（iOS 会自动切"系统安全键盘"、第三方输入法拿不到按键）；
                           这里再把自动纠正/自动大写关掉、并标记为隐私内容（App 切后台时系统截图里会打码） */
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                        .privacySensitive()
                        .font(pf(17.5))
                        .foregroundColor(LoginTheme.ink(scheme))
                        .frame(height: 46)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(LoginTheme.cardBg(scheme)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(LoginTheme.ink(scheme).opacity(0.06), lineWidth: 0.8))
        .shadow(color: Color.black.opacity(LoginTheme.pageBg == nil ? 0 : 0.12), radius: 12, y: 5)
        .padding(.horizontal, 16)
    }

    private func loginRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10.9) {
            Text(label)
                .font(pf(17))
                .foregroundColor(LoginTheme.ink(scheme))
                .frame(width: 74, alignment: .leading)
            content()
        }
        .padding(.horizontal, 18)
        .frame(height: 60)
    }

    private var foot: some View {
        VStack(spacing: 0) {
            Button {
                syncHistory.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: syncHistory ? "checkmark.circle.fill" : "circle")
                        .font(pf(15))
                        .foregroundColor(syncHistory ? LoginTheme.accent : LoginTheme.onBgSub(scheme))
                    Text(Tr("登录后同步最近的聊天记录"))
                        .font(pf(13.5))
                        .foregroundColor(LoginTheme.onBgSub(scheme))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .padding(.bottom, 12.6)

            /* 「账号密码登录 ›」紧贴主按钮上方、右对齐（用户选的 D 版排法） */
            switchLink

            Button {
                submit()
            } label: {
                Text(busy ? "登录中…" : "同意并继续")
                    .font(pf(17, .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(busy ? LoginTheme.accent.opacity(0.6) : LoginTheme.accent))
            }
            .disabled(busy)

            Button {
                showServer = true
            } label: {
                Text("服务器 \(server)（长按可改）")
                    .font(pf(11))
                    .foregroundColor(LoginTheme.onBgSub(scheme).opacity(0.7))
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, max(16, L.safeBottom))
        .background(LoginTheme.bg(scheme))
    }

    private func sendCode() {
        let p = phone.trimmingCharacters(in: .whitespaces)
        if p.count < 5 { error = "请填写手机号"; return }
        error = nil
        Task {
            do {
                let dev = try await API.shared.phoneCode(phone: p)
                codeSent = true
                if let c = dev { code = c; app.show("验证码：\(c)") } else { app.show(Tr("验证码已发送")) }
            } catch {
                self.error = (error as? APIError)?.errorDescription ?? "发送失败"
            }
        }
    }

    private func submit() {
        busy = true
        error = nil
        Task {
            do {
                if usePassword {
                    let u = username.trimmingCharacters(in: .whitespaces)
                    if u.isEmpty || password.isEmpty { throw APIError.message("请填写账号和密码") }
                    try await app.login(username: u, password: password)
                } else {
                    let p = phone.trimmingCharacters(in: .whitespaces)
                    if p.isEmpty || code.isEmpty { throw APIError.message("请填写手机号和验证码") }
                    try await app.login(phone: p, code: code)
                    /* 登录成功才记住这个号：下次进来手机号已经填好，只要等短信验证码 */
                    UserDefaults.standard.set(p, forKey: "chris.lastPhone")
                }
            } catch {
                self.error = (error as? APIError)?.errorDescription ?? "登录失败"
            }
            busy = false
        }
    }
}

struct ServerSheet: View {
    @Binding var server: String
    var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(Tr("电脑的局域网地址（IP:端口）"))) {
            TextField("aa.x8iu.com（加密）", text: $server)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.numbersAndPunctuation)
                }
                Section(footer: Text(Tr("电脑上运行 CHRIS聊天，手机连同一个 Wi-Fi，用电脑的 IP 填这里。"))) {
                    EmptyView()
                }
            }
            .navigationTitle(Tr("服务器"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button(Tr("取消")) { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) { Button(Tr("保存")) { onSave() } }
            }
        }
    }
}

/* ============================================================ 简洁版登录 / 注册页
   和网页版一致的极简风格：图标 + 名称 → 登录/注册两个 Tab → 一张卡片 → 一个绿色按钮。
   注册带图形验证码（服务器给的是 SVG，用 CaptchaView 把点阵字画出来）。 */

struct CaptchaView: View {
    let svg: String
    var body: some View {
        Canvas { ctx, size in
            let sx = size.width / 160.0, sy = size.height / 64.0
            let groups = CaptchaView.parseGroups(svg)
            for g in groups {
                let color = Color(hexString: g.fill)
                for r in g.rects {
                    var p = Path(roundedRect: CGRect(x: r.x * sx, y: r.y * sy,
                                                     width: r.w * sx, height: r.h * sy),
                                 cornerRadius: r.rx * min(sx, sy))
                    if g.angle != 0 {
                        var t = CGAffineTransform(translationX: g.cx * sx, y: g.cy * sy)
                        t = t.rotated(by: g.angle * .pi / 180)
                        t = t.translatedBy(x: -g.cx * sx, y: -g.cy * sy)
                        p = p.applying(t)
                    }
                    ctx.fill(p, with: .color(color))
                }
            }
        }
        .background(Color.white)
    }

    struct Rect { var x, y, w, h, rx: CGFloat }
    struct Group { var fill: String; var angle: CGFloat; var cx, cy: CGFloat; var rects: [Rect] }

    static func parseGroups(_ svg: String) -> [Group] {
        var out: [Group] = []
        let ns = svg as NSString
        guard let gRe = try? NSRegularExpression(pattern: "<g\\s+fill=\"([^\"]+)\"([^>]*)>([\\s\\S]*?)</g>") else { return out }
        let rRe = try? NSRegularExpression(pattern: "<rect\\s+x=\"([-\\d.]+)\"\\s+y=\"([-\\d.]+)\"\\s+width=\"([-\\d.]+)\"\\s+height=\"([-\\d.]+)\"(?:\\s+rx=\"([-\\d.]+)\")?")
        let tRe = try? NSRegularExpression(pattern: "rotate\\(\\s*([-\\d.]+)\\s+([-\\d.]+)\\s+([-\\d.]+)\\s*\\)")
        gRe.enumerateMatches(in: svg, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m = m else { return }
            let fill = ns.substring(with: m.range(at: 1))
            let attrs = ns.substring(with: m.range(at: 2))
            let body = ns.substring(with: m.range(at: 3))
            var angle: CGFloat = 0, cx: CGFloat = 0, cy: CGFloat = 0
            if let tRe = tRe, let tm = tRe.firstMatch(in: attrs, range: NSRange(location: 0, length: (attrs as NSString).length)) {
                let a = attrs as NSString
                angle = CGFloat(Double(a.substring(with: tm.range(at: 1))) ?? 0)
                cx = CGFloat(Double(a.substring(with: tm.range(at: 2))) ?? 0)
                cy = CGFloat(Double(a.substring(with: tm.range(at: 3))) ?? 0)
            }
            var rects: [Rect] = []
            let bs = body as NSString
            rRe?.enumerateMatches(in: body, range: NSRange(location: 0, length: bs.length)) { rm, _, _ in
                guard let rm = rm else { return }
                func num(_ i: Int, _ d: Double) -> CGFloat { CGFloat(Double(bs.substring(with: rm.range(at: i))) ?? d) }
                rects.append(Rect(x: num(1, 0), y: num(2, 0), w: num(3, 0), h: num(4, 0), rx: num(5, 0)))
            }
            if !rects.isEmpty { out.append(Group(fill: fill, angle: angle, cx: cx, cy: cy, rects: rects)) }
        }
        return out
    }
}

/* ============================================================ 登录页（按设计稿）
   ← 返回 + 标题「账号登录」
   图标 + App 名 → 欢迎语 →【微信登录】大按钮 → 其他登录选项 → 协议 → 版本号 */

/* ============================================================
   登录页（按你给的 WechatLoginIOSView 代码原样实现）
   说明：你代码里有两处 iOS 上不能用，我按同款外观等价替换了：
     · .toggleStyle(.checkbox) 是 macOS 专有 → iOS 用同外观的自定义方框勾选
     · Text.rich(TextSpan{...}) 不是 SwiftUI 的类型 → 用 Text 拼接 / Markdown 链接，样式一致
   「微信登录」按钮：没有微信 SDK，接到自建的「设备确认登录」（点它出 6 位数字，在已登录设备上确认）
   ============================================================ */

struct LoginView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @FocusState private var focus: Field?

    private enum Field: Hashable { case phone, code, user, pass, regUser, regNick, regPass, regCap }

    @State private var isAgree = false
    @State private var showPair = false
    @State private var showTerms = false
    @State private var termsKind = 0
    @State private var sheet: Way? = nil
    @State private var appName = "我的App"
    @State private var logoPath: String?
    /// 登录页背景图（后台配的）—— 用 @State 才能刷新生效
    @State private var bgImage = ""
    /// 后台配置一拉到就 +1，让配色/背景跟着重绘一次
    @State private var themeTick = 0
    /// 一键登录进行中
    @State private var quickBusy = false
    /// 出错提示（比如一键登录的登录态过期了）
    @State private var error: String?
    /// 当前滑到第几个账号
    @State private var avatarIndex = 0
    /// 声音锁那一页开着没有
    @State private var showVoiceLock = false
    /// 方案 3 的「更多登录方式」弹窗
    @State private var showMoreWays = false
    /// 临时排查用：连接诊断的输出
    @State private var diag = ""

    enum Way: String, Identifiable { case phone, password; var id: String { rawValue } }

    var body: some View {
        ZStack {
            loginBackground
            /* 这里原来套的是 NavigationStack —— 它会自带一层不透明的系统背景，
               把后面的登录页背景图整个盖掉，所以后台换了背景图手机上永远看不到。
               换成 App 自己的 NavBar（透明背景），背景图就能透出来了。 */
            VStack(spacing: 0) {
                /* 方案 3（用户选的）：**极简登录页** —— 不要「账号登录」那个大标题栏，
                   头像往下挪成视觉中心，底下只留一个玻璃主按钮 + 「更多登录方式」。
                   头像区：登录过的账号最多 3 个，可以左右滑；点一下就用那个账号一键登录
                   （放在滚动区外面，横向滑动才不会被上下滚动抢走手势）。 */
                avatarPager
                    .padding(.top, 64)
                    .padding(.horizontal, 20)
                    ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                    Text(appName)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(LoginTheme.ink(colorScheme))   // 文字颜色接后台
                        .padding(.top, 16)
                    Text(Tr("登录后同步最近的聊天记录"))
                        .font(.system(size: 13))
                        .foregroundColor(LoginTheme.inkSub(colorScheme))
                        .padding(.top, 18)

                    Spacer(minLength: 44)

                    /* 主按钮：**永远点得动**。
                       ⚠ 2026-10-16 用户反馈「点击登录没反应」——病根就在这：
                       这里原来挂着 .disabled(!isAgree)，协议没勾上时按钮是**禁用状态**，
                       点下去一声不响、连提示都没有（协议那行在页面下面是灰字，很容易没注意）。
                       现在：没勾协议点 → 弹一行红字「请先勾选并同意…」；勾了 →
                       这台设备登过的账号就直接一键进，没登过就展开「更多登录方式」。 */
                    Button {
                        guard requireAgree() else { return }
                        let last = app.accounts.first(where: { $0.avatar == app.lastAvatar }) ?? app.accounts.first
                        if let acc = last {
                            quickLogin(account: acc)      // 登过的账号：一键登录
                        } else {
                            showMoreWays = true           // 这台手机还没登过：先选登录方式
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "message.fill")
                                .resizable()
                                .frame(width: 22, height: 22)
                            Text(Tr("星言登录"))
                                .font(.system(size: 16, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        /* 方案 3：主按钮改成**玻璃**（原来是一整块实心绿）——
                           但玻璃底下要垫一层品牌色，白字才看得清
                           （只做透明玻璃的话，背景一浅白字就糊了 —— 「星言登录」看不见就是这个原因）。
                           没勾协议时压暗一档，一眼看出"点不动"。 */
                        .background {
                            ZStack {
                                GlassBackground(shape: RoundedRectangle(cornerRadius: 16, style: .continuous),
                                                opacity: 1, seed: 0.28)
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(LoginTheme.accent.opacity(isAgree ? 0.88 : 0.38))
                            }
                        }
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(isAgree ? 0.50 : 0.25), lineWidth: 0.9))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }

                    /* 方案 3：其他登录方式不再摊成一行，收进「更多登录方式 ›」——
                       页面更干净；点开是系统弹单（手机号 / 账号密码 / 人脸 / 声音锁）。
                       没勾协议一样进不去（每个入口都做了同样的判断）。 */
                    Button { showMoreWays = true } label: {
                        HStack(spacing: 4) {
                            Text(Tr("更多登录方式"))
                                .font(.system(size: 13.5))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundColor(LoginTheme.inkSub(colorScheme))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 18)
                    /* 更多登录方式：照微信做成从底下推上来的白卡（每项一个彩色圆图标） */
                    .sheet(isPresented: $showMoreWays) {
                        LoginWaysSheet(
                            /* ⚠ 这里是「点了账号密码登录没反应」的真正原因：
                               这几个回调是在 LoginWaysSheet **这个弹窗里面**点出来的，
                               而它们做的事是 `sheet = .password` —— **第一个弹窗还没关**，
                               SwiftUI 不允许在一个 sheet 上再叠一个 sheet，请求就被丢掉了。
                               修法：先把当前弹窗关掉，等它收完再开下一个（0.35s 是收起的动画时长）。 */
                            onPhone: { openWay(.phone) },
                            onPassword: { openWay(.password) },
                            onFace: { if requireAgree() { showMoreWays = false; afterSheet { faceLogin() } } },
                            onVoice: { if requireAgree() { showMoreWays = false; afterSheet { voiceLogin() } } })
                    /* 2026-10-16 用户：「大的星言登录不要跳二维码」「还是错误」——
                       索性把「设备确认登录（扫码 / 输数字）」这条入口从登录页**彻底去掉**：
                       不传 onPair，白卡里那一行就不出现；登录页任何入口都不会再弹二维码。
                       （服务端那套配对逻辑保留，以后要做"网页版登录"再接回来。） */
                    }
                    /* ⚠ 2026-10-16 用户：「更多登录方式点开就点不进去」——
                       病根：这里**同时**挂了一个 .sheet(LoginWaysSheet) 和一个 .confirmationDialog，
                       两个弹层绑在同一个 $showMoreWays 上，互相抢 → 打开的是白卡，
                       点里面的行却又去开"系统确认框"，等于点不动。
                       现在只留白卡那套（LoginWaysSheet），这个多余的确认框整段删掉；
                       白卡里的回调走 openWay()：先关白卡、等它收完再开目标页，不会叠弹层。 */

                    if let e = error {
                        Text(e)
                            .font(.system(size: 13))
                            .foregroundColor(C.red)
                            .multilineTextAlignment(.center)
                            .padding(.top, 12)
                    }

                    Spacer(minLength: 26)

                    // 协议勾选
                    HStack(alignment: .top, spacing: 8) {
                        Button { isAgree.toggle() } label: {
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(isAgree ? LoginTheme.accent : LoginTheme.disabledGray, lineWidth: 1.4)
                                .background(RoundedRectangle(cornerRadius: 3)
                                    .fill(isAgree ? LoginTheme.accent : Color.clear))
                                .frame(width: 16, height: 16)
                                .overlay(isAgree
                                         ? Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                                         : nil)
                        }
                        .padding(.top, 1)

                        Text(.init("我已阅读并同意 [《用户协议》](terms://0) 和 [《隐私政策》](terms://1)"))
                            .font(.system(size: 12))
                            .foregroundColor(LoginTheme.ink(colorScheme))    // 协议那行文字颜色也接后台
                            .tint(LoginTheme.accent2)
                            .environment(\.openURL, OpenURLAction { url in
                                if url.scheme == "terms" {
                                    termsKind = Int(url.host ?? "0") ?? 0
                                    showTerms = true
                                }
                                return .handled
                            })
                    }

                    /* ⚠ 临时排查用：点一下就把「App 实际连的地址 / DNS 解析 / 原始错误」
                       全打在屏幕上。定位完这个问题就删掉这一段。 */
                    Button {
                        diag = "诊断中…"
                        Task {
                            var lines: [String] = []
                            let saved = UserDefaults.standard.string(forKey: "chris.server") ?? "(空)"
                            lines.append("缓存地址: \(saved)")
                            lines.append("主入口: \(API.shared.server)")
                            lines.append("候选: " + API.shared.diagCandidates.joined(separator: " → "))
                            let host = String(API.shared.server.split(separator: ":").first ?? "")
                            let ips = API.resolve(host)
                            lines.append("DNS(\(host)): " + (ips.isEmpty ? "解析不出来" : ips.joined(separator: ", ")))
                            lines.append("请求: " + (await API.shared.probe("/api/version")))
                            lines.append("公网 apple: " + (await API.shared.probeAbsolute("https://www.apple.com/")))
                            lines.append("明文 8899: " + (await API.shared.probeAbsolute("http://43.242.194.89:8899/api/version")))
                            /* 媒体诊断：ICE(TURN) 配置 + HLS 取流 */
                            let br = await API.shared.probeText(API.shared.base + "/api/branding", 1500)
                            if let r = br.range(of: "iceServers") {
                                lines.append("ICE: " + String(String(br[r.lowerBound...]).prefix(110)))
                            } else {
                                lines.append("ICE: " + String(br.prefix(80)))
                            }
                            let hls = "dy_7687095302297945786-tmuo257g7"
                            lines.append("HLS列表: " + (await API.shared.probeAbsolute(API.shared.base + "/hls/\(hls)/index.m3u8")))
                            lines.append("HLS切片: " + (await API.shared.probeAbsolute(API.shared.base + "/hls/\(hls)/seg_00000.ts")))
                            diag = lines.joined(separator: "\n")
                        }
                    } label: {
                        Text(Tr("连接诊断"))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(LoginTheme.accent)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(Capsule().stroke(LoginTheme.accent.opacity(0.5), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 16)

                    if !diag.isEmpty {
                        Text(diag)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(LoginTheme.ink(colorScheme))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.06)))
                            .padding(.top, 8)
                    }

                    /* 安全提示：和网页版登录页保持一致 */
                    HStack(spacing: 5) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                        Text(Tr("全程 HTTPS 加密传输，密码只以加密哈希保存"))
                            .font(.system(size: 11.5))
                    }
                    .foregroundColor(LoginTheme.inkSub(colorScheme))
                    .padding(.top, 14)

                    Spacer()

                    Text("V1.0.0")
                        .font(.system(size: 11))
                        .foregroundColor(LoginTheme.inkSub(colorScheme))
                        .padding(.top, 60)
                        .padding(.bottom, 20)
                }
                .padding(.horizontal, 20)
                .frame(minHeight: UIScreen.main.bounds.height - 170, alignment: .top)
            }
            .background(Color.clear)
            .scrollContentBackground(.hidden)
        }
        .sheet(isPresented: $showPair) { PairSheet() }
        .sheet(isPresented: $showTerms) { TermsSheet(kind: termsKind) }
        .sheet(isPresented: $showVoiceLock) {
            /* 读数字那一步单独一页：过了就用这台手机记住的登录态进去 */
            VoiceUnlockView { voiceLoginPassed() }
        }
        .sheet(item: $sheet) { w in
            if w == .phone { PhoneLoginView() } else { AccountLoginSheet(mode: w) }
        }
        .onAppear {
            Task {
                await loadLoginBranding()
            }
        }
        }   // 关掉最外层 ZStack
    }

    /// 拉登录页那套配色（后台「🎨 登录页」）。
    /// 刚启动网络偶尔会抖，所以最多试 4 次；一次成功就应用 + 让界面重画。
    private func loadLoginBranding() async {
        for attempt in 0..<4 {
            if let b = await API.shared.branding() {
                LoginTheme.apply(b)
                /* 服务器关了滑动验证（security.json 里 sliderLogin: 0）就不显示那一块 */
                app.sliderLogin = b.sliderLogin ?? true
                if let n = b.login?.appName ?? b.appName, !n.isEmpty { appName = n }
                if let lg = b.login?.logo ?? b.logo, !lg.isEmpty { logoPath = lg }
                bgImage = b.login?.bgImage ?? ""      // 背景图（用状态存，才能刷新生效）
                themeTick += 1
                return
            }
            if attempt < 3 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
        }
    }

    /// 登录页背景：后台配了背景图就铺满整屏（压一层很淡的底色保证文字看得清），否则用系统背景
    /// 头像区：最多 3 个登录过的账号，左右滑动切换；点头像 = 用那个账号一键登录
    private var avatarPager: some View {
        VStack(spacing: 8) {
            if app.accounts.isEmpty {
                // 这台设备还没登录过：显示后台 logo / App 图标 / 灰圆
                Group {
                    if let p = logoPath {
                        RemoteImage(path: p, icon: "message.fill", mode: .fill)
                    } else if let img = AppIconImage.image {
                        Image(uiImage: img).resizable()
                    } else {
                        Circle().foregroundColor(.gray.opacity(0.2))
                    }
                }
                .frame(width: 80, height: 80)
                .clipShape(Circle())
            } else {
                HStack(spacing: 6) {
                    if app.accounts.count > 1 {
                        Button { withAnimation { avatarIndex = max(0, avatarIndex - 1) } } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(avatarIndex > 0 ? LoginTheme.accent : LoginTheme.disabledGray)
                                .frame(width: 30, height: 60)
                        }
                        .disabled(avatarIndex <= 0)
                    }
                    TabView(selection: $avatarIndex) {
                    ForEach(Array(app.accounts.enumerated()), id: \.element.id) { idx, acc in
                        Group {
                            if !acc.avatar.isEmpty {
                                RemoteImage(path: acc.avatar, icon: "person.fill", mode: .fill)
                            } else {
                                Circle().fill(LoginTheme.accent.opacity(0.25))
                                    .overlay(Text(String(acc.nickname.prefix(1)))
                                        .font(.system(size: 30, weight: .semibold))
                                        .foregroundColor(LoginTheme.accent))
                            }
                        }
                        .frame(width: 80, height: 80)
                        .clipShape(Circle())
                        .contentShape(Circle())
                        .onTapGesture { quickLogin(account: acc) }
                        .tag(idx)
                    }
                }
                    .tabViewStyle(.page(indexDisplayMode: app.accounts.count > 1 ? .always : .never))
                    .frame(height: 108)
                    .frame(maxWidth: app.accounts.count > 1 ? .infinity : 96)
                    if app.accounts.count > 1 {
                        Button { withAnimation { avatarIndex = min(app.accounts.count - 1, avatarIndex + 1) } } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(avatarIndex < app.accounts.count - 1 ? LoginTheme.accent : LoginTheme.disabledGray)
                                .frame(width: 30, height: 60)
                        }
                        .disabled(avatarIndex >= app.accounts.count - 1)
                    }
                }

                if app.accounts.count > 1 {
                    Text(Tr("← 左右滑动切换账号，点头像直接登录 →"))
                        .font(.system(size: 11))
                        .foregroundColor(LoginTheme.sub ?? .secondary)
                } else {
                    Text(quickBusy ? "正在登录…" : "点一下头像，快捷登录")
                        .font(.system(size: 12))
                        .foregroundColor(LoginTheme.accent)
                }
                Text(app.accounts[min(avatarIndex, app.accounts.count - 1)].nickname)
                    .font(.system(size: 13))
                    .foregroundColor(LoginTheme.sub ?? .secondary)
            }
        }
        .onChange(of: app.accounts.count) { _ in clampAvatarIndex() }
    }

    private func clampAvatarIndex() {
        let maxIdx = max(0, app.accounts.count - 1)
        if avatarIndex > maxIdx { avatarIndex = maxIdx }
    }

    private var loginBackground: some View {
        ZStack {
            if !bgImage.isEmpty {
                RemoteImage(path: bgImage, icon: "photo", mode: .fill)
                    .ignoresSafeArea()
                Color(.systemBackground).opacity(0.30).ignoresSafeArea()
            } else {
                Color(.systemBackground).ignoresSafeArea()
            }
        }
        .id(themeTick)
    }

    func loginWithWechat() {
        /* 微信登录 = 「设备确认登录」：新设备出**二维码 + 6 位数字**，
           已登录的手机扫一下（或输数字）就能确认，跟微信同一个动作。 */
        showPair = true
    }

    /// 没勾协议一律不让登：主按钮、手机号登录、账号密码登录、人脸、点头像快捷登录都走这里
    @discardableResult
    private func requireAgree() -> Bool {
        if isAgree { return true }
        error = "请先勾选并同意《用户协议》和《隐私政策》"
        return false
    }

    /// 等当前弹窗收完再执行（0.35s = 系统 sheet 收起动画）
    private func afterSheet(_ run: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { run() }
    }

    /// 从「更多登录方式」里选一种登录：**先把那个弹窗关掉**，再开目标页。
    /// 不这么做的话，sheet 叠 sheet 会被系统丢掉 —— 表现就是「点了没反应」。
    private func openWay(_ w: Way) {
        guard requireAgree() else { return }
        showMoreWays = false
        afterSheet { sheet = w }
    }

    /// 这台设备上有没有可以「一键登录」的登录态
    private var hasSavedLogin: Bool {
        !API.shared.token.isEmpty || !app.lastAvatar.isEmpty
    }

    /// 点头像一键登录：用保存的令牌直接进去；过期了就提示重新输密码
    /// 人脸识别登录：系统 Face ID 过了以后，用「当前选中的那个账号」的登录态进去
    private func faceLogin() {
        guard !quickBusy else { return }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else {
            error = "这台设备还不能用人脸识别（要先在密码登录里登过一次，且手机支持 Face ID）"
            return
        }
        let list = app.accounts
        guard !list.isEmpty else {
            error = "先用密码或手机号登录一次，之后就能刷脸进"
            return
        }
        let acc = list[min(avatarIndex, list.count - 1)]
        quickBusy = true
        error = nil
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                           localizedReason: "刷脸登录 CHRIS") { ok, _ in
            DispatchQueue.main.async {
                quickBusy = false
                if ok { quickLogin(account: acc) }
                else { error = "人脸没认出来，或者你取消了" }
            }
        }
    }

    private func quickLogin(account: SavedAccount? = nil) {
        guard requireAgree() else { return }
        guard !quickBusy else { return }
        quickBusy = true
        error = nil
        Task {
            let saved = account.map { AccountStore.token(for: $0.username) } ?? ""
            let ok = await app.quickLogin(token: saved.isEmpty ? nil : saved)
            quickBusy = false
            if !ok { error = "登录状态已过期，请重新输入密码登录" }
        }
    }

    /* ---------------- 声音锁登录（和微信一个逻辑） ----------------
       ① 先看这台手机开通了没有、有没有能用的登录态
       ② 读出屏幕上的随机数字 → 数字对 + 声纹像开通时那个人 → 才放行
       ③ 过了就用这台手机记住的登录态进去（和点头像一键登录走同一条路） */
    private func voiceLogin() {
        guard !quickBusy else { return }
        guard VoiceLockStore.enabled else {
            error = "这台手机还没开通声音锁：先用密码登录一次，再到 我 → 设置 → 账号与安全 → 声音锁 里开通"
            return
        }
        guard !app.accounts.isEmpty else {
            error = "先用密码登录一次，之后就能用声音锁进"
            return
        }
        error = nil
        showVoiceLock = true
    }

    /// 声音锁验过了：登在「这把锁绑定的那个账号」上（绑定的账号不在列表里就用当前选中的）
    private func voiceLoginPassed() {
        let list = app.accounts
        guard !list.isEmpty else { return }
        let bound = VoiceLockStore.boundUser
        let acc = list.first(where: { $0.username == bound }) ?? list[min(avatarIndex, list.count - 1)]
        if let i = list.firstIndex(where: { $0.username == acc.username }) { avatarIndex = i }
        quickLogin(account: acc)
    }
}

/* ---------- 手机号登录 / 账号密码登录（点开后的表单页） ---------- */
struct AccountLoginSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focus: Field?

    private enum Field: Hashable { case phone, code, user, pass }

    var mode: LoginView.Way

    @State private var phone = ""
    @State private var code = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showReg = false
    @State private var showUnban = false
    /// 账号被冻结后的「解冻账号」弹层（AccountSafety.swift）
    @State private var showUnfreeze = false
    @State private var showReset = false
    /// 登录滑动验证换来的一次性通行证 + 换题用的 key
    @State private var sliderTicket = ""
    @State private var captchaKey = 0
    /// 安全验证的滑块是不是要「弹出来」（默认藏着，服务端判定有风险才弹 —— 微信就是这个体验）
    @State private var showSlider = false
    /// 密码右边那颗「眼睛」：点一下在**看得见 / 隐藏**之间切
    /// （默认隐藏 —— 也就是 SecureField，和以前一样；点了才用 TextField 明文显示）
    @State private var showPassword = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    if mode == .phone {
                        row { TextField("手机号", text: $phone).keyboardType(.numberPad).focused($focus, equals: .phone)
                            .foregroundColor(LoginTheme.ink(colorScheme)) }
                        HairLine(color: C.navLine)
                        row {
                            TextField("验证码", text: $code).keyboardType(.numberPad).focused($focus, equals: .code)
                                .foregroundColor(LoginTheme.ink(colorScheme))
                            Button(Tr("获取验证码")) { sendCode() }
                                .font(.system(size: 14)).foregroundColor(C.loginGreen)
                        }
                    } else {
                        row { TextField("账号 / 用户名", text: $username).focused($focus, equals: .user)
                            .foregroundColor(LoginTheme.ink(colorScheme))
                            .textInputAutocapitalization(.never).autocorrectionDisabled(true) }
                        HairLine(color: C.navLine)
                        /* 密码框 + 右边那颗眼睛：点一下能看见 / 隐藏。
                           隐藏时走系统安全输入框（SecureField，第三方输入法拿不到按键）；
                           点开才切成明文。切换时把焦点留在密码框上，光标不跳。 */
                        row {
                            Group {
                                if showPassword {
                                    TextField("密码", text: $password)
                                } else {
                                    SecureField("密码", text: $password)
                                }
                            }
                            .focused($focus, equals: .pass)
                            .autocorrectionDisabled(true)
                            .textInputAutocapitalization(.never)
                            .privacySensitive()
                            .foregroundColor(LoginTheme.ink(colorScheme))

                            Button {
                                let wasFocus = (focus == .pass)
                                showPassword.toggle()
                                if wasFocus {
                                    DispatchQueue.main.async { focus = .pass }
                                }
                            } label: {
                                Image(systemName: showPassword ? "eye.slash" : "eye")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(LoginTheme.ink(colorScheme).opacity(0.45))
                                    .frame(width: 34, height: 34)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if let e = error {
                        Text(e).font(.system(size: 13)).foregroundColor(C.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 12)
                    }
                    /* 滑块**不常驻**在这一页上（微信也不是）：正常点登录就进去了，
                       只有服务端判定这次有风险（新设备 / 密码错得多）才回 428，
                       那时再把滑块以弹层形式滑出来 —— 见 submit() 和下面的 .sheet */
                    // 账号被禁用：直接给一个自助解封入口（填身份证号，服务器校验合法就解开）
                    if isBanned {
                        Button {
                            showUnban = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "person.text.rectangle")
                                Text(Tr("账号被禁用了？用身份证自助解封"))
                            }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(LoginTheme.accent2)
                            .cornerRadius(14)
                        }
                        .padding(.top, 12)
                    }
                    /* 账号被冻结（本人冻的 / 管理冻的）：登录页直接给「解冻账号」入口
                       —— 和微信一样，冻了以后在登录页点一下就能自己解开 */
                    if isFrozen {
                        Button {
                            showUnfreeze = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "snowflake")
                                Text(Tr("账号被冻结了？点这里自助解冻"))
                            }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(LoginTheme.accent2)
                            .cornerRadius(14)
                        }
                        .padding(.top, 12)
                    }
                    Button { submit() } label: {
                        HStack(spacing: 8) {
                            if busy { ProgressView().progressViewStyle(.circular).tint(.white) }
                            Text(busy ? "请稍候…" : "登 录").font(.system(size: 16, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(LoginTheme.accent)
                        .cornerRadius(16)
                    }
                    .disabled(busy)
                    .padding(.top, 20)

                    if mode == .password {
                        HStack(spacing: 16) {
                            /* 密码找回：手机号 + 验证码 + 新密码（功能清单里的「密码找回」） */
                            Button(Tr("忘记密码？")) { showReset = true }
                            Text("·").foregroundColor(C.subLabel)
                            Button(Tr("还没有账号？去注册")) { showReg = true }
                        }
                        .font(.system(size: 13)).foregroundColor(LoginTheme.accent2)
                        .padding(.top, 16)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
            }
            .background(Color(.systemBackground).ignoresSafeArea())
            .navigationTitle(mode == .phone ? "手机号登录" : "账号密码登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button(Tr("取消")) { dismiss() } }
            }
            .sheet(isPresented: $showReg) { RegisterSheet() }
            /* 服务端说「这次要验证」时滑出来的安全验证（平时不占地方） */
            .sheet(isPresented: $showSlider) {
                SliderSheet(freshKey: captchaKey, onPass: { t in
                    sliderTicket = t
                    error = nil
                    submit()            // 拿到票自动重试一次登录，不让用户再点一次
                })
            }
            .sheet(isPresented: $showReset) { ResetPasswordSheet() }
        .sheet(isPresented: $showUnban) {
                UnbanSheet(preUser: username, prePass: password)
            }
            /* 账号被冻结：登录页自助解冻（账号 + 密码，可补身份证号）—— AccountSafety.swift */
            .sheet(isPresented: $showUnfreeze) {
                UnfreezeSheet().environmentObject(app)
            }
        }
    }

    private var isBanned: Bool {
        let e = error ?? ""
        return e.contains("禁用") || e.contains("封禁")
    }
    /// 服务器回的「该账号已被冻结…」→ 登录页把「解冻账号」入口露出来
    private var isFrozen: Bool {
        (error ?? "").contains("冻结")
    }

    private func row<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 8) { c() }
            .font(.system(size: 15))
            .frame(height: 54).padding(.horizontal, 14)
            .background(Color.dyn(0xFFFFFF, 0x1C1C1E))
    }

    private func sendCode() {
        let p = phone.trimmingCharacters(in: .whitespaces)
        if p.count < 5 { error = "请填写手机号"; return }
        error = nil
        Task {
            do {
                if let dev = try await API.shared.phoneCode(phone: p) {
                    code = dev; app.show("验证码：\(dev)")
                } else { app.show(Tr("验证码已发送")) }
            } catch { self.error = (error as? APIError)?.errorDescription ?? "发送失败" }
        }
    }

    private func submit() {
        busy = true; error = nil
        Task {
            do {
                if mode == .phone {
                    let p = phone.trimmingCharacters(in: .whitespaces)
                    if p.isEmpty || code.isEmpty { throw APIError.message("请填写手机号和验证码") }
                    try await app.login(phone: p, code: code)
                } else {
                    let u = username.trimmingCharacters(in: .whitespaces)
                    if u.isEmpty || password.isEmpty { throw APIError.message("请填写账号和密码") }
                    /* 先直接登：上一次滑出来的票还在就带上，没有就空着 ——
                       服务端默认放行，只有判定有风险才回 428（needSlider）。 */
                    try await app.login(username: u, password: password, sliderTicket: sliderTicket)
                }
                dismiss()
            } catch APIError.needSlider {
                /* 服务端判定这次登录有风险 → 把滑块「滑出来」，滑完自动重试 */
                sliderTicket = ""
                captchaKey += 1
                showSlider = true
                error = nil
            } catch {
                let msg = (error as? APIError)?.errorDescription ?? "登录失败"
                self.error = msg
                /* 通行证是一次性的：这次没用上/过期了，就换一道新题重新滑 */
                if msg.contains("滑动验证") || msg.contains("安全验证") {
                    sliderTicket = ""
                    captchaKey += 1
                }
            }
            busy = false
        }
    }
}

/* ---------- 注册（图形验证码用 CaptchaView 画） ---------- */
/* ---------- 身份证自助解封 ---------- */
struct UnbanSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    let preUser: String
    let prePass: String

    @State private var username = ""
    @State private var password = ""
    @State private var idCard = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Tr("账号被管理员禁用后，可以在这里用身份证号自己解开。号码要真实合法（18 位，最后一位可能是 X）。同一张身份证只能绑定一个账号，解封动作会写进后台审计日志。"))
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                        .padding(.bottom, 14)

                    field { TextField("被封的账号（用户名 / 手机号）", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled(true) }
                    HairLine(color: C.navLine)
                    field { SecureField("该账号的密码", text: $password)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                        .privacySensitive() }
                    HairLine(color: C.navLine)
                    field { TextField("身份证号（18 位）", text: $idCard)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled(true) }

                    if let e = error {
                        Text(e).font(.system(size: 13)).foregroundColor(C.red)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
                    }

                    Button { submit() } label: {
                        HStack(spacing: 8) {
                            if busy { ProgressView().progressViewStyle(.circular).tint(.white) }
                            Text(busy ? "正在核验…" : "提交并解封").font(.system(size: 16, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(LoginTheme.accent)
                        .cornerRadius(16)
                    }
                    .disabled(busy)
                    .padding(.top, 20)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
            }
            .background(Color(.systemBackground).ignoresSafeArea())
            .navigationTitle(Tr("身份证自助解封"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button(Tr("取消")) { dismiss() } }
            }
        }
        .onAppear {
            if username.isEmpty { username = preUser }
            if password.isEmpty { password = prePass }
        }
    }

    private func field<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 8) { c() }
            .font(.system(size: 15))
            .frame(height: 54).padding(.horizontal, 14)
            .background(Color.dyn(0xFFFFFF, 0x1C1C1E))
    }

    private func submit() {
        let u = username.trimmingCharacters(in: .whitespaces)
        let idc = idCard.trimmingCharacters(in: .whitespaces).uppercased()
        if u.isEmpty { error = "请填写被封的账号"; return }
        if password.isEmpty { error = "请填写账号密码"; return }
        if idc.count != 18 { error = "身份证要 18 位，最后一位可以是 X"; return }
        busy = true; error = nil
        Task {
            do {
                let user = try await API.shared.unban(username: u, password: password, idCard: idc)
                await app.finishLogin(user)
                app.show(Tr("解封成功，已登录"))
                dismiss()
            } catch { self.error = (error as? APIError)?.errorDescription ?? "解封失败" }
            busy = false
        }
    }
}

struct RegisterSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var nickname = ""
    @State private var password = ""
    @State private var cap = ""
    @State private var capId = ""
    @State private var capSvg = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                /* ⚠ 2026-10-16 用户：「注册不要星言号设置，按微信那样给随机的」——
                   注册页**不再让用户填星言号**（服务端会随机发一个 xy 开头的号，
                   注册完在「我 → 个人信息 → 星言号」里一年能改一次）。 */
                TextField("昵称", text: $nickname).frame(height: 54).padding(.horizontal, 14)
                HairLine(color: C.navLine)
                SecureField("密码（至少 6 位）", text: $password)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    .privacySensitive()
                    .frame(height: 54).padding(.horizontal, 14)
                HairLine(color: C.navLine)
                HStack(spacing: 10) {
                    TextField("图形验证码", text: $cap).autocorrectionDisabled(true)
                    CaptchaView(svg: capSvg)
                        .frame(width: 96, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.navLine, lineWidth: 0.5))
                        .onTapGesture { loadCaptcha() }
                }
                .font(.system(size: 15))
                .frame(height: 54).padding(.horizontal, 14)

                if let e = error {
                    Text(e).font(.system(size: 13)).foregroundColor(C.red)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
                }
                Button { submit() } label: {
                    HStack(spacing: 8) {
                        if busy { ProgressView().progressViewStyle(.circular).tint(.white) }
                        Text(busy ? "请稍候…" : "注 册").font(.system(size: 16, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(LoginTheme.accent).cornerRadius(16)
                }
                .disabled(busy)
                .padding(.top, 20)
                Spacer()
            }
            .background(Color(.systemBackground).ignoresSafeArea())
            .navigationTitle(Tr("注册"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button(Tr("取消")) { dismiss() } } }
        }
        .onAppear { loadCaptcha() }
    }

    private func loadCaptcha() {
        Task {
            if let c = try? await API.shared.captcha() { capId = c.id; capSvg = c.svg }
        }
    }
    private func submit() {
        if password.count < 6 { error = "密码至少 6 位"; return }
        if cap.isEmpty { error = "请填写图形验证码"; return }
        busy = true; error = nil
        Task {
            do {
                /* 星言号留空 → 服务端随机给一个（微信那样） */
                let u = try await API.shared.register(username: "",
                                                     nickname: nickname.isEmpty ? "新用户" : nickname,
                                                     password: password, captchaId: capId, captcha: cap)
                /* 注册接口已经把登录态发下来了（Set-Cookie → App 收进 token），
                   直接把自己的资料挂上就行，不用再走一次登录（那条路要过滑动验证）。 */
                await app.adoptRegistered(u)
                app.show(Tr("注册成功"))
                dismiss()
            } catch {
                self.error = (error as? APIError)?.errorDescription ?? "注册失败"
                loadCaptcha()
            }
            busy = false
        }
    }
}

/* ---------- 二维码（「设备确认登录」那张码用的；不引第三方库） ---------- */
/// 把一段文字画成二维码图；画不出来返回 nil（界面就只显示 6 位数字兜底）
func qrImage(_ text: String, size: CGFloat) -> UIImage? {
    guard !text.isEmpty, let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    f.setValue(Data(text.utf8), forKey: "inputMessage")
    f.setValue("M", forKey: "inputCorrectionLevel")
    guard let out = f.outputImage else { return nil }
    let scale = size / max(out.extent.width, 1)
    let scaled = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let ctx = CIContext(options: nil)
    guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
    return UIImage(cgImage: cg)
}

/* ---------- 「微信登录」→ 设备确认登录（出二维码 + 6 位数字，在已登录设备上确认） ---------- */
struct PairSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var status = "正在生成…"
    @State private var fail = false
    @State private var timer: Timer?

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text(Tr("用已登录的手机确认，这台设备就能进入"))
                    .font(.system(size: 14)).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).padding(.top, 20)

                /* 微信那张码：已登录的手机「扫一扫」一下就出「登录确认」卡片，
                   不用手输数字。二维码内容就是 xingyan://pair?code=123456 这一串。 */
                if let q = qrImage("xingyan://pair?code=" + code, size: 190) {
                    Image(uiImage: q)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 190, height: 190)
                        .padding(10)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.black.opacity(0.08), lineWidth: 0.5))
                        .opacity(code.isEmpty || fail ? 0.22 : 1)
                } else {
                    ProgressView().frame(width: 190, height: 190)
                }

                Text(code.isEmpty ? "······" : code)
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .tracking(6)

                Text(fail
                     ? "这个码过期了，点下面重新生成"
                     : "另一台已登录的手机：星言 → 扫一扫；或者 我 → 设置 → 登录设备管理 → 确认新设备登录，把这 6 位数字填进去")
                    .font(.system(size: 12.5)).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)

                if fail {
                    Button(Tr("重新生成")) { start() }
                        .font(.system(size: 15, weight: .semibold)).foregroundColor(C.loginGreen)
                } else {
                    ProgressView()
                    Text(status).font(.system(size: 12)).foregroundColor(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(Color(.systemBackground).ignoresSafeArea())
            .navigationTitle(Tr("星言登录"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button(Tr("取消")) { stop(); dismiss() } } }
        }
        .onAppear { start() }
        .onDisappear { stop() }
    }

    private func start() {
        fail = false; status = "正在生成…"
        Task {
            do {
                /* 报一下这是台什么设备：对方手机上「登录确认」那张卡片会写（微信也写设备名） */
                let dev = UIDevice.current.model + " · iOS " + UIDevice.current.systemVersion
                let r = try await API.shared.pairStart(device: dev)
                code = r.code; status = "等待确认…"
                timer?.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in poll() }
            } catch {
                fail = true
                status = (error as? APIError)?.errorDescription ?? "生成失败"
            }
        }
    }
    private func poll() {
        guard !code.isEmpty else { return }
        Task {
            guard let r = try? await API.shared.pairStatus(code: code) else { return }
            switch r.status {
            case "approved":
                stop()
                if let t = r.token, !t.isEmpty { API.shared.setToken(t) }
                await app.refreshAll(); Realtime.shared.start(); dismiss()
            case "expired":
                stop(); fail = true
            default:
                status = "等待确认…"
            }
        }
    }
    private func stop() { timer?.invalidate(); timer = nil }
}

/* ---------- 用户协议 / 隐私政策 ---------- */
struct TermsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var kind: Int

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(kind == 0 ? "用户协议" : "隐私政策").font(.system(size: 19, weight: .semibold))
                    /* 内容由后台「🎨 登录页 → 用户协议 / 隐私政策」配置 */
                    Text(LoginTheme.text(kind: kind))
                    .font(.system(size: 14)).lineSpacing(6)
                }
                .padding(20)
            }
            .background(Color(.systemBackground).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button(Tr("好")) { dismiss() } } }
        }
    }
}

/* ============================================================
   手机号登录（按你给的 PhoneLoginView 代码原样实现）
   同样只有两处 iOS 上不能用、做了同款外观的等价替换：
     · .toggleStyle(.checkbox) 是 macOS 专有 → 同外观方框勾选
     · Text.rich(TextSpan{...}) 不是 SwiftUI 类型 → 等价富文本写法
   业务动作接的是真的接口：发验证码 → 服务器；点登录 → 登录并进入 App
   ============================================================ */

/// 手机号登录的「国家 / 地区」（方案 2：单独一行，可点开选）
struct DialRegion: Identifiable, Hashable {
    let id: String      // ISO 两位代码
    let flag: String
    let name: String
    let dial: String    // 区号，不带 +
}

let dialRegions: [DialRegion] = [
    .init(id: "CN", flag: "🇨🇳", name: "中国大陆", dial: "86"),
    .init(id: "HK", flag: "🇭🇰", name: "中国香港", dial: "852"),
    .init(id: "MO", flag: "🇲🇴", name: "中国澳门", dial: "853"),
    .init(id: "US", flag: "🇺🇸", name: "美国 / 加拿大", dial: "1"),
    .init(id: "JP", flag: "🇯🇵", name: "日本", dial: "81"),
    .init(id: "KR", flag: "🇰🇷", name: "韩国", dial: "82"),
    .init(id: "SG", flag: "🇸🇬", name: "新加坡", dial: "65"),
    .init(id: "MY", flag: "🇲🇾", name: "马来西亚", dial: "60"),
    .init(id: "TH", flag: "🇹🇭", name: "泰国", dial: "66"),
    .init(id: "GB", flag: "🇬🇧", name: "英国", dial: "44"),
    .init(id: "AU", flag: "🇦🇺", name: "澳大利亚", dial: "61")
]

/// 选国家 / 地区（带搜索，能搜名字也能搜区号）
struct CountryPickerView: View {
    @Environment(\.dismiss) var dismiss
    @Binding var index: Int
    @State private var q = ""

    /// 命中的下标（搜索能匹配名称 / 区号 / 代码）
    private var list: [Int] {
        dialRegions.indices.filter { i in
            let r = dialRegions[i]
            return q.isEmpty
                || r.name.contains(q)
                || r.dial.contains(q)
                || r.id.lowercased().contains(q.lowercased())
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(list, id: \.self) { i in
                    let r = dialRegions[i]
                    Button {
                        index = i
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Text(r.flag).font(.system(size: 20))
                            Text(r.name).foregroundColor(C.label)
                            Spacer(minLength: 0)
                            Text("+" + r.dial).foregroundColor(C.subLabel)
                            if i == index {
                                Image(systemName: "checkmark").foregroundColor(C.green)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .searchable(text: $q, prompt: Tr("搜索国家或区号"))
            .navigationTitle(Tr("选择国家和地区"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button(Tr("取消")) { dismiss() } } }
        }
    }
}

struct PhoneLoginView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    /// 提示文字要用它取「浅色/深色」那套配色
    @Environment(\.colorScheme) private var colorScheme
    @State private var phone = ""
    @State private var code = ""
    @State private var isAgree = false
    @State private var countDown = 0
    @State private var timer: Timer?
    @State private var error: String?
    @State private var busy = false
    @State private var showTerms = false
    @State private var termsKind = 0
    @FocusState private var focused: Bool
    /// 方案 2：国家/地区（单独一行，点开可选）
    @State private var showCountryPicker = false
    @State private var dialIdx = 0
    private var dial: DialRegion { dialRegions[min(max(dialIdx, 0), dialRegions.count - 1)] }
    /// 真正提交的号码：中国大陆还是原来的 11 位（老逻辑一点不动），其它地方带区号
    private var fullPhone: String { dial.dial == "86" ? phone : ("+" + dial.dial + phone) }
    /// 号码位数够不够（中国 11 位；其它 5~15 位）
    private var phoneLenOK: Bool {
        dial.dial == "86" ? phone.count == 11 : (phone.count >= 5 && phone.count <= 15)
    }
    private var hairline: some View {
        Rectangle().fill(Color.dyn(0xE2E2E6, 0x2C2C2E)).frame(height: 1.2)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Spacer(minLength: 30)
                    Text(Tr("手机号登录"))
                        .font(.system(size: 24, weight: .semibold))

                    /* 方案 2（用户选的）· **无框版**：
                       ① 国家/地区单独一行（点开是国家列表）
                       ② 手机号、验证码都是「一条细下划线」，不要灰色圆角框
                       ③「获取验证码」从实心按钮改成右边的文字按钮 */
                    VStack(spacing: 0) {
                        Button { showCountryPicker = true } label: {
                            HStack(spacing: 10) {
                                Text(dial.flag).font(.system(size: 19))
                                Text(dial.name)
                                    .font(.system(size: 16.5))
                                    .foregroundColor(C.label)
                                Spacer(minLength: 0)
                                Text("+" + dial.dial)
                                    .font(.system(size: 15.5))
                                    .foregroundColor(C.subLabel)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(Color.dyn(0xC0C0C6, 0x6B6B70))
                            }
                            .frame(height: 54)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .bottom) { hairline }

                        TextField("请输入手机号", text: $phone)
                            .keyboardType(.numberPad)
                            .font(.system(size: 16.5))
                            .frame(height: 54)
                            .focused($focused)
                            .overlay(alignment: .bottom) { hairline }

                        HStack(spacing: 10) {
                            TextField("请输入验证码", text: $code)
                                .keyboardType(.numberPad)
                                .font(.system(size: 16.5))
                            Button { sendCode() } label: {
                                Text(countDown > 0 ? "\(countDown)s" : Tr("获取验证码"))
                                    .font(.system(size: 14.5, weight: .semibold))
                                    .foregroundColor(countDown > 0 || !phoneLenOK
                                                     ? LoginTheme.disabledGray : LoginTheme.accent2)
                            }
                            .buttonStyle(.plain)
                            .disabled(countDown > 0 || !phoneLenOK)
                        }
                        .frame(height: 54)
                        .overlay(alignment: .bottom) { hairline }
                    }

                    Text(Tr("获取验证码后会收到一条短信，把 6 位数字填在上面"))
                        .font(.system(size: 12))
                        .foregroundColor(LoginTheme.inkSub(colorScheme))

                    // 登录按钮
                    Button {
                        phoneLogin()
                    } label: {
                        HStack(spacing: 8) {
                            if busy { ProgressView().progressViewStyle(.circular).tint(.white) }
                            Text(Tr("登录"))
                                .font(.system(size: 16, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(canSubmit ? LoginTheme.accent2 : LoginTheme.disabledGray)
                        .cornerRadius(16)
                    }
                    .disabled(!canSubmit)

                    if let e = error {
                        Text(e).font(.system(size: 13)).foregroundColor(C.red)
                    }

                    // 协议勾选
                    HStack(alignment: .top, spacing: 8) {
                        Button { isAgree.toggle() } label: {
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(isAgree ? LoginTheme.accent2 : LoginTheme.disabledGray, lineWidth: 1.4)
                                .background(RoundedRectangle(cornerRadius: 3)
                                    .fill(isAgree ? LoginTheme.accent2 : Color.clear))
                                .frame(width: 16, height: 16)
                                .overlay(isAgree
                                         ? Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                                         : nil)
                        }
                        .padding(.top, 1)

                        Text(.init("我已阅读并同意 [《用户协议》](terms://0) 和 [《隐私政策》](terms://1)"))
                            .font(.system(size: 12))
                            .tint(LoginTheme.accent2)
                            .environment(\.openURL, OpenURLAction { url in
                                if url.scheme == "terms" {
                                    termsKind = Int(url.host ?? "0") ?? 0
                                    showTerms = true
                                }
                                return .handled
                            })
                    }

                    Spacer()
                }
                .padding(.horizontal, 20)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "chevron.left") }
                }
            }
        }
        .sheet(isPresented: $showTerms) { TermsSheet(kind: termsKind) }
        .sheet(isPresented: $showCountryPicker) { CountryPickerView(index: $dialIdx) }
        .onDisappear {
            timer?.invalidate()
        }
    }

    var canSubmit: Bool {
        isAgree && phoneLenOK && code.count >= 4 && !busy
    }

    func sendCode() {
        error = nil
        Task {
            do {
                if let dev = try await API.shared.phoneCode(phone: fullPhone) {
                    code = dev
                    app.show("验证码：\(dev)")
                } else {
                    app.show(Tr("验证码已发送"))
                }
            } catch {
                self.error = (error as? APIError)?.errorDescription ?? "发送失败"
            }
        }
        countDown = 60
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            if countDown > 0 {
                countDown -= 1
            } else {
                t.invalidate()
            }
        }
    }

    func phoneLogin() {
        busy = true
        error = nil
        Task {
            do {
                try await app.login(phone: fullPhone, code: code)
                dismiss()
            } catch {
                self.error = (error as? APIError)?.errorDescription ?? "登录失败"
            }
            busy = false
        }
    }
}

