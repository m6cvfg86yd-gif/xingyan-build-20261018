import SwiftUI
import UIKit
import ImageIO          // 解码时缩小图片（防解压炸弹）

/// 朋友圈开关（设置 → 通用 → 朋友圈）
/// 2026-10-17 用户先要「和微信一样朋友圈要设置里面开启」，做完又问「朋友圈怎么没了 / 发现页朋友圈放出来」——
/// 所以现在默认就是**开**（和微信「发现页管理」一致：默认看得见，想藏的人自己去关）。
/// 判断「用户有没有动过这个开关」要用 object(forKey:)，不能用 bool(forKey:)：
/// 后者在没设过的时候返回 false，会把默认值也变成关。
enum MomentsPref {
    private static let key = "chris.momentsOn"
    /// 没设过 = 开；用户在设置里关过 = 关
    static var isOn: Bool {
        if UserDefaults.standard.object(forKey: key) == nil { return true }
        return UserDefaults.standard.bool(forKey: key)
    }
    static func set(_ v: Bool) {
        UserDefaults.standard.set(v, forKey: key)
        /* 本机会话里立刻生效：发现页收到这条就重新算一遍列表，
           不用等切后台/重开 App（和后台推 ui 事件走的是同一条刷新路径）。 */
        NotificationCenter.default.post(name: .chrisUIPrefsChanged, object: nil)
    }
}

extension Notification.Name {
    /// 本地 UI 开关变了（设置里开了/关了朋友圈这种）→ 相关页面重新加载列表
    static let chrisUIPrefsChanged = Notification.Name("chrisUIPrefsChanged")
}

extension View {
    /// 长按复制（2026-10-17 用户：「星言号要长按可以复制」）——
    /// 长按 0.4 秒 → 复制到剪贴板 + 轻震一下 + 可选弹一句提示（传 toast 才会弹）。
    /// 传进来的字符串为空就什么都不做（别把空串写进剪贴板）。
    func copyOnLongPress(_ text: String, toast: ((String) -> Void)? = nil) -> some View {
        self.onLongPressGesture(minimumDuration: 0.4) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            UIPasteboard.general.string = t
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            toast?(Tr("已复制"))
        }
    }
}

/// 打包时间：在「我 → 设置 → 关于」里能看到，用来确认手机上装的是哪一版
enum AppInfo {
    /// 版本号 / 构建号直接读打包时写进 Info.plist 的值（CI 每次打包都会写）
    static let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    static let build: String = {
        let n = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1"
        let d = (Bundle.main.infoDictionary?["BuildDate"] as? String) ?? ""
        return d.isEmpty ? ("B" + n) : ("B" + n + " · " + d)
    }()
    /// 这台设备的唯一标识：第一次跑就生成，存 Keychain（删 App 重装也还在）。
    /// 登录时随请求发给服务器（X-Device-Id），服务器用它判断「是不是换了设备」——
    /// 只有换设备时才弹滑动验证（微信就是这么认设备的，比拿 UA/IP 猜准得多）。
    static let deviceId: String = {
        let key = "chris.device.id"
        if let v = Keychain.get(key), !v.isEmpty { return v }
        let v = UUID().uuidString
        Keychain.set(v, for: key)
        return v
    }()

    /* ---------- 「登录设备管理」要的那三样（随请求头报给服务器） ---------- */

    /// 设备名（「张三的 iPhone」这种）。HTTP 头只能放 ASCII，
    /// 所以中文名字先按百分号编码，App 显示前再解回来。
    static let deviceName: String =
        UIDevice.current.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    /// 机型的机器号（iPhone17,1 这种）
    static let deviceMachine: String = {
        var sys = utsname()
        uname(&sys)
        let id = withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return id.isEmpty ? UIDevice.current.model : id
    }()
    /// 机型（给人看的）：iPhone 16 Pro 这种 —— 登录设备管理那一页要显示的就是它。
    /// 表里没有的机器号就退回「iPhone」，不会空着。
    static let deviceModel: String = friendlyModel(deviceMachine)
    private static func friendlyModel(_ id: String) -> String {
        let map: [String: String] = [
            "iPhone14,6": "iPhone SE3", "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
            "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
            "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,5": "iPhone 16e",
            "iPhone18,3": "iPhone 17", "iPhone18,4": "iPhone Air",
            "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max",
            "iPad14,8": "iPad Air 11", "iPad14,9": "iPad Air 13", "iPad16,5": "iPad Pro 13"
        ]
        if let v = map[id] { return v }
        return id.lowercased().hasPrefix("ipad") ? "iPad" : "iPhone"
    }
    /// 系统版本：iOS 19.1
    static let deviceOs: String = "iOS " + UIDevice.current.systemVersion

    /// 端类型：随每个请求发给服务器（X-Device-Kind: phone / tablet / desktop）。
    /// 规则是「A 方案」——手机单点登录（同一账号在新手机上登录，旧手机立刻下线），
    /// 平板 / 电脑可以和手机并存，互不顶下线。老客户端不带这个头，服务器按手机处理。
    static let deviceKind: String = {
        switch UIDevice.current.userInterfaceIdiom {
        case .pad: return "tablet"
        case .mac: return "desktop"
        default:   return "phone"
        }
    }()
    /// 给人看的端类型名字（「已在别处登录」那张卡片上用）
    static let deviceKindName: String = {
        switch deviceKind {
        case "tablet":  return "平板"
        case "desktop": return "电脑"
        default:        return "手机"
        }
    }()
}

/* ============================================================
   界面配置：服务器上 data/ui.json 里能改字号、行高、头像大小、颜色。
   改完把 App 从后台划掉重新打开就生效 —— 不用重新装包。
   ============================================================ */
enum UIConfig {
    private static var numbers: [String: CGFloat] = [:]
    private static var strings: [String: String] = [:]
    static var scale: CGFloat = 0.94

    static func num(_ key: String, _ def: CGFloat) -> CGFloat { numbers[key] ?? def }
    /// 读后台配的文字（空 = 用默认）
    static func text(_ key: String, _ def: String) -> String {
        if let v = strings[key], !v.trimmingCharacters(in: .whitespaces).isEmpty { return v }
        return def
    }

    static func color(_ key: String, _ light: UInt32, _ dark: UInt32) -> Color {
        guard let raw = strings[key] else { return Color.dyn(light, dark) }
        let parts = raw.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }
        func hex(_ s: String) -> UInt32? { UInt32(s.replacingOccurrences(of: "#", with: ""), radix: 16) }
        let l = parts.count > 0 ? (hex(parts[0]) ?? light) : light
        let d = parts.count > 1 ? (hex(parts[1]) ?? l) : l
        return Color.dyn(l, d)
    }

    /// 后台配了这个键就返回配的颜色，**没配返回 nil**。
    /// 用在「默认值本身要从别的地方算出来」的场景（比如小星眼睛的颜色：
    /// 后台 eyesColor 没配就跟右上角 ＋ 同色）。
    static func colorIfSet(_ key: String) -> Color? {
        guard let raw = strings[key], !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let parts = raw.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }
        func hex(_ s: String) -> UInt32? { UInt32(s.replacingOccurrences(of: "#", with: ""), radix: 16) }
        guard let first = parts.first, let l = hex(first) else { return nil }
        let d = parts.count > 1 ? (hex(parts[1]) ?? l) : l
        return Color.dyn(l, d)
    }

    static func apply(_ json: [String: Any]) {
        var n: [String: CGFloat] = [:]
        var s: [String: String] = [:]
        for (k, v) in json {
            if let d = v as? Double { n[k] = CGFloat(d) }
            else if let i = v as? Int { n[k] = CGFloat(i) }
            else if let b = v as? Bool { n[k] = b ? 1 : 0 }
            else if let t = v as? String { s[k] = t }
        }
        numbers = n
        strings = s
        if let sc = n["fontScale"], sc > 0.5, sc < 1.6 { scale = sc }
    }
}

/* ============================================================
   尺寸：照网页版 m.css 里的 clamp(min, vw, max) 一条条搬过来，
   所以任何机型宽度下都和网页版算出来的一样。
   ============================================================ */

enum L {
    /// 屏幕逻辑宽度（根视图量到以后会写进来，等价于网页的 100vw）
    static var width: CGFloat = {
        if let w = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .windows.first?.bounds.width, w > 0 { return w }
        return UIScreen.main.bounds.width
    }()

    /// clamp(min, vw%, max)
    static func v(_ lo: CGFloat, _ vw: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(max(lo, width * vw / 100), hi)
    }

    /// 服务器上 data/ui.json 里的覆盖值（改这个文件 + 重开 App 就生效，不用重装）
    static func o(_ key: String, _ def: CGFloat) -> CGFloat { UIConfig.num(key, def) }

    static var safeTop: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .windows.first?.safeAreaInsets.top ?? 20
    }
    static var safeBottom: CGFloat {
        max(0, (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .windows.first?.safeAreaInsets.bottom ?? 0)
    }

    // 导航栏：网页里 398~425 宽时固定 48，其余走 clamp
    static var navH: CGFloat {
        let def: CGFloat = (width >= 398 && width <= 425) ? 48 : v(42, 11.4, 50)
        return o("navH", def)
    }
    static var tabH: CGFloat { o("tabH", 56) }
    static var tabIcon: CGFloat { o("tabIcon", 23) }
    static var tabIconBox: CGFloat { o("tabIconBox", 24) }
    static var tabLabel: CGFloat { o("tabLabel", 11) }

    // 会话列表（微信页）：12 + 48 + 12 = 72
    /* 会话列表一行：按 vx 参考图重新量的 —— 行高 72（行与行之间就靠这条细线分开）、
       头像 48 圆角 4、头像左 16、头像与文字间 12、名字 17、预览 14、时间 12、未读徽标 18。
       文字块（名字+预览）在行里是居中的：上留白 15、下留白 16 */
    static var rowH: CGFloat { o("chatRowH", 72) }
    static var avatar: CGFloat { o("chatAvatar", v(44, 12.3, 48)) }
    static var rowPadL: CGFloat { o("chatPadL", 16) }
    static var rowPadR: CGFloat { o("chatPadR", 16) }
    static var rowGap: CGFloat { o("chatGap", 12) }
    /// 名字离行顶的距离（微信名字不在正中，稍微靠上）
    static var rowPadTop: CGFloat { o("chatPadTop", 15) }
    /// 名字和预览之间
    static var rowTextGap: CGFloat { o("chatTextGap", 5) }
    static var rowNameSize: CGFloat { o("chatNameSize", 17) }
    static var rowPreviewSize: CGFloat { o("chatPreviewSize", 14) }
    static var rowTimeSize: CGFloat { o("chatTimeSize", 12) }
    static var searchBoxH: CGFloat { o("searchBoxH", 36) }
    static var searchPad: CGFloat { o("searchPad", 8) }
    /// 参考图量出来：会话行分隔线从 x=76 开始
    static var dividerLeft: CGFloat { o("dividerLeft", 76) }

    // 通讯录（按 vx 参考图：行 56、头像 40、左 16、间距 12、文字 x=68）
    static var ctRowH: CGFloat { o("ctRowH", 56) }
    static var ctAvatar: CGFloat { o("ctAvatar", 40) }
    static var ctPadL: CGFloat { o("ctPadL", 16) }
    static var ctGap: CGFloat { o("ctGap", 12) }
    static var ctIcon: CGFloat { o("ctIcon", 40) }
    static var ctNameSize: CGFloat { o("ctNameSize", 16) }
    static var ctHeadH: CGFloat { o("ctHeadH", 28) }
    static var ctHeadSize: CGFloat { o("ctHeadSize", 15) }
    static var ctIdxSize: CGFloat { o("ctIdxSize", 12.5) }
    static var ctIdxItemH: CGFloat { o("ctIdxItemH", 16.5) }
    /// 通讯录那条常驻搜索框：上下留白（**不贴着顶栏那条遮罩**），
    /// 以及放大镜和「搜索」两个字的字号（用户要：都不要贴着遮罩、字大一点、一起居中）
    static var ctSearchGap: CGFloat { o("contactsSearchGap", 10) }
    static var ctSearchIcon: CGFloat { o("contactsSearchIcon", 18) }
    static var ctSearchText: CGFloat { o("contactsSearchText", 17) }
    static var ctTextX: CGFloat { ctPadL + ctAvatar + ctGap }

    // 发现页 / 我页（按 vx 参考图：行 56、图标 x18、文字 x58、组间线从 x56 开始）
    static var menuH: CGFloat { o("menuH", 56) }
    static var menuPadL: CGFloat { o("menuPadL", 18) }
    static var menuPadR: CGFloat { o("menuPadR", 16) }
    static var menuGap: CGFloat { o("menuGap", 18) }
    static var menuIcon: CGFloat { o("menuIcon", 22) }
    static var menuTextSize: CGFloat { o("menuTextSize", 17) }
    static var groupGap: CGFloat { o("groupGap", 8) }
    static var menuTextX: CGFloat { menuPadL + menuIcon + menuGap }
    /// 我页/发现页行内那条细线的左端
    static var menuLineInset: CGFloat { o("menuLineInset", 56) }

    // 聊天页
    /* 以下尺寸照 iPhone 上的微信量：头像 40、头像与气泡间距 9、气泡内边距 12/10、
       正文 16（微信标准字号）、时间 12.5、气泡最宽约占屏幕 69% */
    static var msgPad: CGFloat { v(12, 3.1, 14) }
    /// 聊天页头像：微信不管什么机型都是 40（以前大屏会被放大到 44，比微信大一圈）
    static var chatAvatar: CGFloat { o("chatAvatar2", 40) }
    /// 头像和气泡之间那条缝：微信是 9。
    /// （会话列表那条缝走 chatGap，两个用途分开，后台调一个不会连带动另一个）
    static var chatGapMsg: CGFloat { o("chatMsgGap", 9) }
    /// 头像和气泡之间那条缝（老键名，只有会话列表在用）
    static var chatGap: CGFloat { o("chatGap", 10) }
    static var bubblePadH: CGFloat { o("bubblePadH", 12) }
    static var bubblePadV: CGFloat { o("bubblePadV", 10) }
    /// 药丸气泡的左右内边距：两端是圆弧，比圆角气泡多留 3pt，字不会贴到弧线上
    static var bubblePadHPill: CGFloat { bubblePadH + 3 }
    /// 正文行距：微信 16 号字、行高约 22 —— 系统 16 号默认 19，补 3 正好
    static var msgLineSpacing: CGFloat { o("msgLineSpacing", 3) }
    /// 气泡最大宽度（微信里长消息也占不到满屏）。
    /// 下限 240 是为了让转账 / 文件那种固定宽度的卡片在小屏上也放得下。
    static var bubbleMaxW: CGFloat { o("bubbleMaxW", min(310, max(240, width * 0.69))) }
    static var composerH: CGFloat { o("composerH", 56) }
    static var composerIconBox: CGFloat { o("composerIconBox", 33) }
    static var composerIcon: CGFloat { o("composerIcon", 28) }
    static var inputH: CGFloat { o("inputH", 39) }
    /// 聊天正文字号：微信「标准」是 16（以前 17，比微信大一号）
    static var chatFontSize: CGFloat { o("chatFontSize", 16) }
    static var msgTimeSize: CGFloat { o("msgTimeSize", 12.5) }

    // 朋友圈
    static var coverH: CGFloat { o("coverH", 380) }
    static var coverAvatar: CGFloat { v(52, 17.1, 72) }
    static var momentPadH: CGFloat { o("momentPadH", 22) }
    static var momentAvatar: CGFloat { o("momentAvatar", 44) }

    /* ---------------- 个人名片（照网页版 #cardScreen 逐条量）----------------
       头像 64×64 圆角 6 · 头部内边距 27/16/29.5 · 名字 20 · 三行资料 15/行高 22
       行内标签宽 80 · 缩略图 48 圆角 3 · 底部按钮两行各 55.6、字 17 */
    static var cdAvatar: CGFloat { o("cdAvatar", 64) }
    static var cdAvatarRadius: CGFloat { o("cdAvatarRadius", 6) }
    static var cdHeroPadTop: CGFloat { o("cdHeroPadTop", 27) }
    static var cdHeroPadBottom: CGFloat { o("cdHeroPadBottom", 29.5) }
    static var cdHeroPadH: CGFloat { o("cdHeroPadH", 16) }
    static var cdHeroGap: CGFloat { o("cdHeroGap", 16) }
    static var cdNameSize: CGFloat { o("cdNameSize", 20) }
    static var cdNameRowH: CGFloat { o("cdNameRowH", 22) }
    static var cdGender: CGFloat { o("cdGender", 14) }
    static var cdLineSize: CGFloat { o("cdLineSize", 15) }
    static var cdLineH: CGFloat { o("cdLineH", 22) }
    static var cdLineGap: CGFloat { o("cdLineGap", 6) }
    static var cdLabelW: CGFloat { o("cdLabelW", 80) }
    static var cdRowH: CGFloat { o("cdRowH", 22) }
    static var cdRowGap: CGFloat { o("cdRowGap", 8) }
    static var cdRowsPadV: CGFloat { o("cdRowsPadV", 13.5) }
    static var cdPadH: CGFloat { o("cdPadH", 16) }
    static var cdCardGap: CGFloat { o("cdCardGap", 8) }
    static var cdThumbRowTop: CGFloat { o("cdThumbRowTop", 15) }
    static var cdThumbRowBottom: CGFloat { o("cdThumbRowBottom", 15.5) }
    static var cdThumb: CGFloat { o("cdThumb", 48) }
    static var cdThumbGap: CGFloat { o("cdThumbGap", 8) }
    static var cdActH: CGFloat { o("cdActH", 55.6) }
    static var cdActSize: CGFloat { o("cdActSize", 17) }
    static var cdActGap: CGFloat { o("cdActGap", 6.5) }
    static var cdIcChatW: CGFloat { o("cdIcChatW", 19) }
    static var cdIcChatH: CGFloat { o("cdIcChatH", 19.7) }
    static var cdIcVideoW: CGFloat { o("cdIcVideoW", 20) }
    static var cdIcVideoH: CGFloat { o("cdIcVideoH", 21) }

    /* ---------------- 转账页（照网页版 .tf-* 逐条量）---------------- */
    static var tfPadRowH: CGFloat { o("tfPadRowH", v(50, 13.6, 58)) }
    static var tfKeySize: CGFloat { o("tfKeySize", v(20, 6, 24)) }
    static var tfSendSize: CGFloat { o("tfSendSize", v(15, 4.3, 17)) }
    static var tfCnySize: CGFloat { o("tfCnySize", v(26, 7.6, 32)) }
    static var tfDigitSize: CGFloat { o("tfDigitSize", v(34, 10, 42)) }
    static var tfCellW: CGFloat { o("tfCellW", v(21, 6.6, 28)) }
    static var tfUnitSize: CGFloat { o("tfUnitSize", v(10.5, 3, 12.5)) }
    static var tfCaretH: CGFloat { o("tfCaretH", v(30, 9.4, 40)) }
    static var tfCaretW: CGFloat { o("tfCaretW", 2.5) }
    static var tfAvatar: CGFloat { o("tfAvatar", v(30, 9, 34)) }

    /* ---------------- 支付 / 付款方式 半屏面板（照网页版 .pay-* .pm-*）---------------- */
    static var payHeadH: CGFloat { o("payHeadH", v(46, 12.9, 54)) }
    static var payPadH: CGFloat { o("payPadH", v(46, 13.1, 55)) }
    static var payPadFont: CGFloat { o("payPadFont", v(20, 5.7, 24)) }
    static var paySheetRadius: CGFloat { o("paySheetRadius", v(10, 3.2, 14)) }
    static var payPwdW: CGFloat { o("payPwdW", v(238, 70.8, 297)) }
    static var payPwdH: CGFloat { o("payPwdH", v(46, 12.4, 52)) }
    static var safeStripH: CGFloat { o("safeStripH", max(34, safeBottom)) }
}

/* ============================================================ 颜色 */

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1
        )
    }
    static func dyn(_ light: UInt32, _ dark: UInt32) -> UIColor {
        UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        }
    }
}

extension Color {
    init(hex: UInt32) { self = Color(UIColor(hex: hex)) }

    /// "#6F8A38" 这种字符串颜色
    init(hexString: String, fallback: UInt32 = 0x6F8A38) {
        let s = hexString.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
        self = Color(UIColor(hex: UInt32(s, radix: 16) ?? fallback))
    }
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color { Color(UIColor.dyn(light, dark)) }
}

/// 后台某个模块配的颜色（比如零钱页的底色）：当作**浅色**值用，深色模式给一个对应的深色。
/// 想在后台自己把深浅色都定死，就写 "#FFFFFF|#0B0B0D"。
func colorDyn(_ raw: String?, light: UInt32, dark: UInt32) -> Color {
    let s = (raw ?? "").trimmingCharacters(in: .whitespaces)
    if s.isEmpty { return Color.dyn(light, dark) }
    let parts = s.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    func hex(_ t: String) -> UInt32? {
        UInt32(t.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces), radix: 16)
    }
    let l = hex(parts[0]) ?? light
    if parts.count > 1, let d = hex(parts[1]) { return Color.dyn(l, d) }
    return Color.dyn(l, dark)
}

/// 逐个色号对着网页版量出来的（浅色 / 深色）
enum C {
    // 颜色也能在 data/ui.json 里改（写成 "#浅色|#深色"）
    static var pageBg      : Color { UIConfig.color("pageBg", 0xEDEDED, 0x0B0B0D) }
    static var navBg       : Color { UIConfig.color("navBg", 0xEDEDED, 0x18181A) }
    static var tabBg       : Color { UIConfig.color("tabBg", 0xF7F7F7, 0x18181A) }
    static var cardBg      : Color { UIConfig.color("cardBg", 0xFFFFFF, 0x1C1C1E) }
    static var chatRowBg   : Color { UIConfig.color("chatRowBg", 0xFFFFFF, 0x2A2A2A) }
    static var pinnedBg    : Color { UIConfig.color("pinnedBg", 0xF2F2F2, 0x333335) }
    static var searchBg    : Color { UIConfig.color("searchBg", 0xFFFFFF, 0x26272B) }
    /// 输入框内底色（状态面板那种"说点什么"的输入框）：后台也能改
    static var fieldBg     : Color { UIConfig.color("fieldBg", 0xF2F2F2, 0x28292D) }
    static var searchIcon  : Color { UIConfig.color("searchIcon", 0xB2B2B2, 0x9A9A9E) }
    static var searchIcon2 : Color { UIConfig.color("searchIcon2", 0x8C8C8C, 0x9A9A9E) }
    static let searchBorder = Color(UIColor { t in
        t.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.12) : UIColor(hex: 0xF0F0F0)
    })
    /// 微信页那条白框：浅色下没有描边（就是一块纯白），深色下才有一条很淡的亮边
    static let searchBorderChats = Color(UIColor { t in
        t.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.12) : UIColor.clear
    })
    static var name        : Color { UIConfig.color("nameColor", 0x1C1C1E, 0xF2F2F7) }
    static var label       : Color { UIConfig.color("labelColor", 0x191919, 0xF2F2F7) }
    static var preview     : Color { UIConfig.color("previewColor", 0xB2B2B2, 0xB2B2B2) }
    static var time        : Color { UIConfig.color("timeColor", 0xC7C7CC, 0xC7C7CC) }
    /// 通讯录右侧 A-Z 索引的字母颜色（后台「界面文字」里可以改）
    static var ctIdxColor  : Color { UIConfig.color("ctIdxColor", 0x555555, 0x8E8E93) }
    static var subLabel    : Color { UIConfig.color("subLabelColor", 0x999999, 0xA0A0A5) }
    static var hairline    : Color { UIConfig.color("lineColor", 0xE5E5E5, 0x2E2F34) }
    static var navLine     : Color { UIConfig.color("navLineColor", 0xE8E8E8, 0x2A2B2F) }
    /* 默认就是微信那个绿 #07C160（以前是偏青的 #19A47A，用户要求跟微信一致；
       后台 ui.json 里的 greenColor 仍可覆盖） */
    static var green       : Color { UIConfig.color("greenColor", 0x07C160, 0x07C160) }
    static var red         : Color { UIConfig.color("redColor", 0xFA5151, 0xFA5151) }
    static var orange      : Color { UIConfig.color("orangeColor", 0xFF9500, 0xFF9500) }
    static var tabInk      : Color { UIConfig.color("tabInkColor", 0x191919, 0xBCBCC1) }
    /// 会话列表页顶部（导航栏 + 搜索框那一块）的底色：按你给的 #F7F7F7
    static var chatsTopBg  : Color { UIConfig.color("chatsTopBg", 0xF7F7F7, 0x18181A) }
    /* 会话列表（第一页面）自己的两个底色：默认和通讯录一致（页面底色 / 卡片底色）。
       想让它和通讯录不一样，就在后台「界面文字 → 颜色」里单独改这两项，不用重新打 App。 */
    static var chatsPageBg : Color { UIConfig.color("chatsPageBg", 0xEDEDED, 0x0B0B0D) }
    static var chatsRowBg  : Color { UIConfig.color("chatsRowBg", 0xFFFFFF, 0x1C1C1E) }
    /// 星联（通讯录）整页的底色：和会话页每行一个色（后台 contactsBg 可单独调）。
    /// 以前这一页用的是 cardBg，所以后台改 pageBg 对它没用 —— 用户反馈的
    /// 「星联页底色怎么改不了」就是这个。
    static var contactsBg  : Color { UIConfig.color("contactsBg", 0xFFFFFF, 0x141419) }
    /// 视界（发现）页整页底色：比其它页可以单独调（后台 discoverBg）。
    /// 默认和页面底色一样，用户想让它「淡一点」就改这个键。
    static var discoverBg  : Color { UIConfig.color("discoverBg", 0xEDEDED, 0x141419) }
    /// 视界页每一行那张卡片（后台 discoverCardBg，默认跟 cardBg）
    static var discoverCardBg: Color { UIConfig.color("discoverCardBg", 0xFFFFFF, 0x141419) }
    /// 「我」页（含设置页）那些卡片的底色：后台 meCardBg 可以单独调，
    /// 默认跟会话页每行一致（暗色 #141419）。
    static var meCardBg    : Color { UIConfig.color("meCardBg", 0xFFFFFF, 0x141419) }
    /* 自己发的气泡：以前用的是微信那个标志性气泡绿（#95EC69），
       审核/投诉都会盯着这个颜色，换成我们自己品牌的浅绿。 */
    /* 聊天气泡：底色和字色都能在后台「界面文字 → 颜色」里改
       （以前这三项是写死的，所以后台找不到「聊天字的颜色」） */
    static var bubbleMine  : Color { UIConfig.color("bubbleMineColor", 0xD8F2E4, 0x1DC9BD) }
    static var bubbleOther : Color { UIConfig.color("bubbleOtherColor", 0xFFFFFF, 0x27282C) }
    static var bubbleText  : Color { UIConfig.color("bubbleTextColor", 0x191919, 0xEDEDED) }
    /// 系统提示 / 撤回 / 拍一拍那几行灰字
    static var msgTime     : Color { UIConfig.color("msgTimeColor", 0xAEAEB2, 0xAEAEB2) }
    /// 聊天里那行时间的小框（后台「界面文字」里配：底色/文字色）
    static var chatTimeBg  : Color { UIConfig.color("chatTimeBg", 0xE5E5E5, 0x292A2E) }
    static var chatTimeInk : Color { UIConfig.color("chatTimeColor", 0x8A8A8E, 0x8A8A8E) }
    /// 消息里的链接和 @ 高亮色
    static var link        : Color { UIConfig.color("linkColor", 0x576B95, 0x7D90A9) }
    static let arrow       = Color.dyn(0xB2B2B2, 0x8A8A8E)
    static let ringInk     = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 1, blue: 1, alpha: 0.78)
            : UIColor(red: 25 / 255, green: 25 / 255, blue: 26 / 255, alpha: 0.62)
    })
    static let iconGray    = Color.dyn(0x6F6F6F, 0x9A9A9A)
    /// 聊天页底部那一排按钮（麦克风 / 喇叭 / 表情 / ＋）的颜色，后台「界面文字」里能改：
    /// 写「#浅色|#深色」两份，比如浅色模式想深一点就写 "#333333|#9A9A9A"
    static var chatBarIcon : Color { UIConfig.color("chatBarIcon", 0x6F6F6F, 0x9A9A9A) }
    /* 四个首页顶栏文字：后台「界面文字」里能改（tabTitle0 微信 / 1 通讯录 / 2 发现 / 3 我） */
    static var tabTitle0: String { UIConfig.text("tabTitle0", "聊天") }
    static var tabTitle1: String { UIConfig.text("tabTitle1", "通讯录") }
    static var tabTitle2: String { UIConfig.text("tabTitle2", "发现") }
    static var tabTitle3: String { UIConfig.text("tabTitle3", "我") }

    // 登录页（网页版永远是深色那一套）
    static let loginBg     = Color(hex: 0x111111)
    static let loginCard   = Color(hex: 0x191919)
    static let loginText   = Color(hex: 0xEDEDED)
    static let loginGray   = Color(hex: 0x7F7F7F)
    static let loginLink   = Color(hex: 0x7D90A9)
    static let loginGreen  = Color(hex: 0x1DC9BD)
}

/* ============================================================
   字体：全站一律苹方（PingFang SC）。
   数字和英文也走苹方，不再落到 SF Pro 上，和手机微信一模一样。
   万一系统里没有苹方，自动退回系统字体，不会变成方框。
   ============================================================ */
/// 全站字号统一小一号（用户要求）：17→16、15→14、14→13、12→11
var fontScale: CGFloat { UIConfig.scale }

/// 苹方字体名（按字重挑）
func pfName(_ weight: Font.Weight) -> String? {
    var want = "PingFangSC-Regular"
    if weight == .medium {
        want = "PingFangSC-Medium"
    } else if weight == .semibold || weight == .bold || weight == .heavy || weight == .black {
        want = "PingFangSC-Semibold"
    } else if weight == .light || weight == .thin || weight == .ultraLight {
        want = "PingFangSC-Light"
    }
    if UIFont(name: want, size: 12) != nil { return want }
    for family in UIFont.familyNames where family.lowercased().contains("pingfang") {
        let names = UIFont.fontNames(forFamilyName: family)
        if names.contains(want) { return want }
        if let fallback = names.first { return fallback }
    }
    return nil
}

/// 带全站缩放的字号（界面文字都用这个）
func pf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    /* 关怀模式：本机开关一开，全站字号整体放大（微信的关怀模式也是这个思路） */
    pfExact(max(9, (size * fontScale * CareMode.scale).rounded()), weight)
}

/// 关怀模式（设置 → 关怀模式）：只存在本机，开了全站字号放大
enum CareMode {
    static var on: Bool { UserDefaults.standard.bool(forKey: "chris.careMode") }
    static var scale: CGFloat { on ? 1.18 : 1.0 }
    static func set(_ v: Bool) { UserDefaults.standard.set(v, forKey: "chris.careMode") }
    /// 「听文字消息」（微信关怀模式里的那一项）：开启后点一下聊天里的文字就念出来
    static var speakText: Bool { UserDefaults.standard.bool(forKey: "chris.careSpeak") }
    static func setSpeak(_ v: Bool) { UserDefaults.standard.set(v, forKey: "chris.careSpeak") }
}

/// 不给缩放的字号（少数要严格对齐网页版数值的地方）
func pfExact(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    if let name = pfName(weight), UIFont(name: name, size: size) != nil {
        /* ⚠ 这里**必须**用 fixedSize（2026-10-11 B147 用户反馈「文字也差点意思」）：
           SwiftUI 的 `.custom(name, size:)` 默认会跟着系统「设置 → 显示与亮度 → 文字大小」
           一起缩放（等于 relativeTo: .body）。微信的列表/正文是**固定 17pt**，不跟系统字号跑
           （它自己有「微信 → 设置 → 通用 → 字体大小」那根滑杆）。
           以前整站都跟系统字号飘，用户换台手机、或者系统字号不是"标准"，文字就会整体偏大/
           偏小，行高也跟着变 —— 看着就是"差点意思"。改成 fixedSize 之后，字号就是设计值本身。 */
        return .custom(name, fixedSize: size)
    }
    return .system(size: size, weight: weight)
}

/// 金额专用字体：**SF Pro Display Medium**（所有金融数字统一走这个）
/// 大字号系统会自动用 SF Pro Display；小字号如果拿不到 Display 就退回系统中等字重。
/* ============================================================
   金额数字的字体（全站金额都走这里）—— 银行 App 那套「金融数字」：

   · 首选 iOS 自带的 **DIN Alternate**（德国工业标准体，银行和支付类 App
     普遍用它：数字方正、辨识度高，看着更像"钱"而不是正文）；
     大金额用 Bold 有分量，小字号用 Regular，不然会糊成一团。
   · 拿不到就退回苹果的 SF Pro Display（原来那套）。
   · **一律带 monospacedDigit（等宽数字）** —— 这是金融排版最硬的一条：
     金额上下对齐、数字跳动时宽度不变。不然余额每秒刷新会左右抖。
   · 想整体调大调小：后台 ui.json 的 fontScale（原来就有）。
   ============================================================ */
func pfMoney(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
    let s = max(9, (size * fontScale).rounded())
    /* ① 金融数字字体。首选 **Avenir Next** —— 它数字有几何感、`¥` 和 `.` 都是标准字形，
       符号集完整；DIN Alternate 虽然方正，但缺 `¥`、句点也不规矩（会触发系统补字，
       大小和基线对不上，用户反馈的"符号不精准"就是它）。DIN 退到第二档。 */
    let din = s >= 20 ? ["AvenirNext-Bold", "AvenirNext-DemiBold", "DINAlternate-Bold", "DINAlternate"]
                      : ["AvenirNext-Medium", "AvenirNext-Regular", "DINAlternate", "DINAlternate-Bold"]
    for name in din {
        if let f = UIFont(name: name, size: s) { return Font(f).monospacedDigit() }
    }
    /* ② 退回苹果自己的显示字体 */
    if weight == .medium {
        for name in ["SFProDisplay-Medium", "SF Pro Display", ".SFUI-Display-Medium"] {
            if let f = UIFont(name: name, size: s) { return Font(f).monospacedDigit() }
        }
    }
    return .system(size: s, weight: weight, design: .default).monospacedDigit()
}

/* ============================================================
   金额统一格式化（全站金额都走这里）

   微信的金额是带**千分位**的：10,082,845.78。
   以前只有一个 String(format: "%.2f")，上千万的余额看着就是一长串数字，
   和微信对不上。这里统一成「千分位 + 固定两位小数」，
   小数点是「.」、逗号用英文逗号（微信就是这个写法）。
   ============================================================ */
private let moneyFmtter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.locale = Locale(identifier: "en_US_POSIX")   // 固定用 . 和 , 不受系统语言影响
    f.usesGroupingSeparator = true
    f.groupingSeparator = ","
    f.groupingSize = 3
    f.minimumFractionDigits = 2
    f.maximumFractionDigits = 2
    return f
}()

/// 金额文本（不含 ¥）：10,082,845.78 / 0.00 / 12.30
func moneyFmt(_ v: Double) -> String {
    let n = v.isFinite ? v : 0
    return moneyFmtter.string(from: NSNumber(value: n)) ?? String(format: "%.2f", n)
}

/// 金额拼成一段 Text：**¥ 可以单独用自己的字号**（微信那样比数字小）。
/// curSize <= 0 就整段一个字号。
/// exact = true 时不吃全站 fontScale（要严格对齐参考图数值的页面用）。
/// 货币符号（¥ / $ / €）的字体 —— **一律系统字体**。
/// 金融数字字体（DIN Alternate 那类）里通常没有 ¥ 这个字形，混在数字里写，
/// 系统会拿别的字体去补，补出来的大小和基线都对不上（用户说的"符号不精准"）。
/// 数字用金融字体、符号用系统字体，两边才都干净。
func moneySymbolFont(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
    .system(size: size, weight: weight, design: .default)
}

func moneyText(_ text: String, size: CGFloat, curSize: CGFloat = 0, topAlign: Bool = false,
               weight: Font.Weight = .medium, exact: Bool = false) -> Text {
    let f: (CGFloat) -> Font = { s in exact ? pfMoneyExact(s, weight) : pfMoney(s, weight) }
    guard let r = text.range(of: "¥") else {
        return Text(text).font(f(size))
    }
    let prefix = String(text[text.startIndex..<r.lowerBound])
    let rest = String(text[r.upperBound...])
    /* ⚠ 货币符号（¥）**一律用系统字体**，不能用那套金融数字字体：
       DIN Alternate 里根本没有 ¥ 这个字形，混着写会被系统拿别的字体去补 ——
       补出来的大小、基线都和数字对不上，看着就是"符号不精准"（用户反馈）。 */
    let curFont = moneySymbolFont(curSize > 0 ? curSize : size, weight)
    var out = Text(prefix).font(f(size))
    var cur = Text("¥").font(curFont)
    /* 左上角对齐（和微信一样）：把钱号往上抬，抬多少 ≈ 两者字高差的 0.72 */
    if topAlign, curSize > 0, curSize < size {
        cur = cur.baselineOffset((size - curSize) * 0.72)
    }
    out = out + cur
    return out + Text(rest).font(f(size))
}

/// 和 pfMoney 同一套「金融数字」字体，但**不缩放、不取整**（详情页大字用）
func pfMoneyExact(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
    let din = size >= 20 ? ["AvenirNext-Bold", "AvenirNext-DemiBold", "DINAlternate-Bold", "DINAlternate"]
                         : ["AvenirNext-Medium", "AvenirNext-Regular", "DINAlternate", "DINAlternate-Bold"]
    for name in din {
        if let f = UIFont(name: name, size: size) { return Font(f).monospacedDigit() }
    }
    if weight == .medium {
        for name in ["SFProDisplay-Medium", "SF Pro Display", ".SFUI-Display-Medium"] {
            if let f = UIFont(name: name, size: size) { return Font(f).monospacedDigit() }
        }
    }
    return .system(size: size, weight: weight, design: .default).monospacedDigit()
}

/// 金额显示：**方形小数点** + 可单独设大小的「¥」（微信那种金融样式）。
/// 用法和 Text 差不多，外面照样能叠 .foregroundColor / .monospacedDigit。
struct MoneyLabel: View {
    let text: String
    let size: CGFloat
    var curSize: CGFloat = 0
    var topAlign: Bool = false
    var color: Color = C.label
    var weight: Font.Weight = .medium
    /// 不吃全站 fontScale（严格对齐参考图时用）
    var exact: Bool = false

    var body: some View {
        let parts = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let head = String(parts.first ?? "")
        let tail = parts.count > 1 ? String(parts[1]) : ""
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            moneyText(head, size: size, curSize: curSize, topAlign: topAlign, weight: weight, exact: exact)
                .foregroundColor(color)
            if !tail.isEmpty || text.contains(".") {
                Rectangle()
                    .fill(color)
                    .frame(width: size * 0.16, height: size * 0.16)
                    .padding(.horizontal, size * 0.04)
            }
            if !tail.isEmpty {
                Text(tail).font(exact ? pfMoneyExact(size, weight) : pfMoney(size, weight))
                    .foregroundColor(color)
            }
        }
        .monospacedDigit()
    }
}

enum AppIconImage {
    static var image: UIImage? {
        for name in ["AppIcon60x60@3x", "AppIcon60x60@2x", "AppIcon60x60"] {
            if let p = Bundle.main.path(forResource: name, ofType: "png"), let img = UIImage(contentsOfFile: p) {
                return img
            }
        }
        return UIImage(named: "AppIcon60x60")
    }
}

/* ============================================================ 图片 */

/// 手指正在滑动时，先别**开始**新的图片加载 / 解码（微信就是这么干的）。
/// 滑动中启动的解码会和手势抢主线程，滑起来就一顿一顿；
/// 内存里已经有的图不受影响（直接返回，根本走不到这儿）。
/// 滚动停下 0.4 秒后自动放行。
@MainActor
final class ScrollGate {
    static let shared = ScrollGate()
    private(set) var busy = false
    private var release: Task<Void, Never>?

    /// 每次滚动回调里调一下
    func touch() {
        busy = true
        release?.cancel()
        release = Task { @MainActor in
            /* ⚠ 2026-10-14 用户反馈「图片/视频要等一会才出来，之前是秒出」：
               这道门原来锁 400ms —— 一滚动就让所有图片加载等 400ms，
               体感就是"停下来还得等半秒"。用户要求改回原来的体感 → 缩到 120ms
               （仍然比"滚动中直接解图"稳，但几乎感觉不到等待）。 */
            try? await Task.sleep(nanoseconds: 120_000_000)
            if Task.isCancelled { return }
            busy = false
        }
    }

    /// 滚动中就先等一等（最多等 0.5 秒，免得一直滑就永远不加载）
    /// 2026-10-14：上限 1.2s → 0.5s（配合 touch 的 400ms→120ms，恢复"秒出"体感）
    func waitUntilIdle() async {
        var waited = 0
        while busy && waited < 5 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
    }
}

final class ImageStore {
    static let shared = ImageStore()
    private var cache: [String: UIImage] = [:]
    /// 内存里近似占用（UIImage 的位图 ≈ 宽×高×4）
    private var bytes = 0
    /// 内存上限：96MB。以前是只进不出 —— 一晚上刷下来能堆到几百 MB，
    /// 系统一告警就把 App 干掉（表现就是"用着用着闪一下回到桌面"）。
    private let memoryCap = 96 * 1024 * 1024
    private let lock = NSLock()
    func get(_ key: String) -> UIImage? {
        lock.lock(); defer { lock.unlock() }
        return cache[key]
    }
    func put(_ key: String, _ img: UIImage) {
        lock.lock(); defer { lock.unlock() }
        if cache[key] != nil { return }
        cache[key] = img
        bytes += Int(img.size.width * img.size.height * 4)
        /* 字典是按插入顺序遍历的：超了就从最早放进来的开始丢（够用，也不用 LRU 那套） */
        while bytes > memoryCap, cache.count > 8 {
            let first = cache.keys.first!
            if let old = cache[first] { bytes -= Int(old.size.width * old.size.height * 4) }
            cache.removeValue(forKey: first)
        }
    }
    /// 清空图片缓存（设置 → 通用 → 存储空间 里「清理缓存」用）
    func clear() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll(keepingCapacity: false)
        bytes = 0
    }

    /* ---------------------------------------------------------- 二级缓存：磁盘
       内存缓存一关 App 就没了，重启以后每张图都得重新下载解码（弱网下就是一片灰块）。
       这里把下载到的原始字节存一份到 Caches 目录，下次直接读盘 + 缩放解码。
       文件名用稳定的 FNV-1a 哈希（String.hashValue 每次启动都不一样，不能当文件名）。 */
    /* 目录在 init 里建好：读写在后台线程，lazy var 不是线程安全的 */
    private let diskDir: URL?
    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let d = base?.appendingPathComponent("imgcache", isDirectory: true)
        if let d = d { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        diskDir = d
    }

    func diskFile(_ key: String) -> URL? {
        guard let dir = diskDir, !key.isEmpty else { return nil }
        var h: UInt64 = 0xcbf29ce484222325
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return dir.appendingPathComponent(String(format: "%016llx", h) + ".img")
    }

    /// 读磁盘缓存（后台线程调用）
    func diskRead(_ key: String) -> Data? {
        guard let f = diskFile(key) else { return nil }
        return try? Data(contentsOf: f, options: .mappedIfSafe)
    }

    /// 写磁盘缓存（后台线程调用）
    func diskWrite(_ key: String, _ data: Data) {
        guard let f = diskFile(key), !data.isEmpty else { return }
        try? data.write(to: f, options: .atomic)
        /* 目录太大就顺手清一批（按修改时间从最早的删） */
        guard let dir = diskDir else { return }
        let list = (try? FileManager.default.contentsOfDirectory(at: dir,
                    includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        if list.count > 600 {
            let sorted = list.sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a < b
            }
            for f2 in sorted.prefix(200) { try? FileManager.default.removeItem(at: f2) }
        }
    }

    /// 磁盘缓存占多大（存储空间页要显示）
    func diskBytes() -> Int {
        guard let dir = diskDir else { return 0 }
        let list = (try? FileManager.default.contentsOfDirectory(at: dir,
                    includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return list.reduce(0) { sum, u in
            sum + ((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}

struct RemoteImage: View {
    let path: String
    var icon: String = "photo"
    var mode: ContentMode = .fill
    /// 当「模板图」渲染：只取形状，颜色由外面的 foregroundColor 决定
    /// （底栏那些自己上传的图标就是这么跟着选中状态变色的）
    var template: Bool = false
    /// 解码上限（默认 1600，防大图解压把内存打爆）。
    /// 封面这种大图单独放宽（见 coverView 传 2560），不然会被压到 1600 看着糊。
    var maxSide: CGFloat = 1600
    /// 图加载出来以后回一下（聊天页的图片气泡按原比例算缩略图尺寸要用）
    var onLoaded: ((UIImage) -> Void)? = nil

    @State private var image: UIImage?
    @State private var started = false

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image = image {
                    Image(uiImage: image)
                        .renderingMode(template ? .template : .original)
                        .resizable()
                        .aspectRatio(contentMode: mode)
                } else {
                    ZStack {
                        Color.dyn(0xE9E9E9, 0x2C2C2E)
                        Image(systemName: icon)
                            .font(pf(max(10, min(geo.size.width, geo.size.height) * 0.40)))
                            .foregroundColor(Color.dyn(0xC4C4C4, 0x636366))
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .onAppear { if !started { started = true; Task { await load() } } }
        // 换过头像/封面/聊天背景：path 变了要重新加载，不然一直显示旧图
        .onChange(of: path) { _ in
            image = nil
            started = true
            Task { await load() }
        }
    }

    private func load() async {
        if path.isEmpty { return }
        /* 一级缓存：内存（这一步永远最先做，滚动中也能命中） */
        if let hit = ImageStore.shared.get(path) { image = hit; onLoaded?(hit); return }
        /* ⚠ 2026-10-14 用户明确要求「直接取消这道门」：
           原来这里会等滚动停下（400ms，最多 1.2 秒）才开始加载图片/视频，
           体感就是"停下来还得等一会才出"。现在**不再等待**，立刻加载
           （回到旧版行为；代价是快速猛滑时可能掉几帧，用户接受）。 */
        let side = max(64, maxSide)
        /* 二级缓存：磁盘。读盘 + 缩放解码都在后台线程做。 */
        let diskBytes: Data? = await Task.detached(priority: .userInitiated) { () -> Data? in
            ImageStore.shared.diskRead(path)
        }.value
        if let diskBytes = diskBytes {
            let diskImg: UIImage? = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                RemoteImage.downsampled(diskBytes, maxSide: side)
            }.value
            if let diskImg = diskImg {
                ImageStore.shared.put(path, diskImg)
                image = diskImg
                onLoaded?(diskImg)
                return
            }
        }
        /* 先把要解码的字节拿到手（网络那步本来就是异步的） */
        let data: Data
        if path.hasPrefix("data:") {
            guard let comma = path.firstIndex(of: ","),
                  let d = Data(base64Encoded: String(path[path.index(after: comma)...]),
                               options: .ignoreUnknownCharacters) else { return }
            data = d
        } else {
            guard let url = API.shared.assetURL(path) else { return }
            do { data = try await API.shared.imageData(url) } catch { return }
        }
        /* ⚠ 解码必须放到后台线程。
           CGImageSource 解一张 1280px 的图要几十毫秒，以前是在主线程上解的 ——
           聊天页一屏六七张图、边滚边解，主线程就被堵住了（实测最长卡 4.2 秒，
           正是"刷起来不丝滑"的另一半原因）。
           顺便保留"解码时就缩小"：一张 20000×20000 的图（文件才 1MB）直接 UIImage(data:)
           会解出 1.5GB 内存、手机当场被杀，这里始终只出 maxSide 大小的位图。 */
        let img = await Task.detached(priority: .userInitiated) {
            RemoteImage.downsampled(data, maxSide: side)
        }.value
        guard let img = img else { return }
        ImageStore.shared.put(path, img)
        image = img
        onLoaded?(img)
        /* 原始字节再存一份到磁盘（后台写，不挡 UI）：下次开 App 就不用重新下了 */
        Task.detached(priority: .background) { ImageStore.shared.diskWrite(path, data) }
        /* 再留一份到**长期目录**（Documents/Local/Media）：Caches 会被系统清掉，
           这里的意思就是"我下载过的图/视频，本机一直留着"（本地优先存储） */
        if path.hasPrefix("/uploads/") || path.hasPrefix("/emoji/") {
            Task.detached(priority: .background) { LocalStore.keep(path, data: data) }
        }
    }

    /// 边解码边缩小：不管原图多大，内存里最多只有 maxSide 边长的位图
    static func downsampled(_ data: Data, maxSide: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)                  // 兜底
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
            return UIImage(cgImage: cg)
        }
        return UIImage(data: data)
    }
}

struct Avatar: View {
    let path: String
    var size: CGFloat = 48
    var radius: CGFloat = 6
    var circle = false
    /// 等级（QQ 那套）：月亮=细银圈、太阳=金色光环、皇冠=华丽金框 + 流光 + 小皇冠
    var level: Int = 0

    var body: some View {
        Group {
            if Avatar.isEyesBot(path) {
                /* AI 助手（原贾维斯）的头像：不是图片，是一只**真的会动**的小脸
                   —— 眨眼、左右瞟、呼吸。会话列表 / 通讯录 / 聊天里 / 名片 / 通话页都是它。 */
                JarvisEyesAvatar(size: size * 0.86)
                    .frame(width: size, height: size)
                    .background(shape.fill(Color.white))
            } else if path.isEmpty {
                /* 没头像时按微信来（2026-10-14 用户要求）：浅灰底 + 白色人形剪影。
                   微信里没设头像就是这个观感 —— 不是空白、也不是首字母色块。
                   深色模式换成深灰底 + 浅灰剪影，保证夜里也看得清。 */
                ZStack {
                    shape.fill(Color.dyn(0xEDEDED, 0x2C2C2E))
                    Image(systemName: "person.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: size * 0.56, height: size * 0.56)
                        .foregroundColor(Color.dyn(0xFFFFFF, 0x8E8E93))
                        .offset(y: size * 0.04)
                }
                .frame(width: size, height: size)
                .clipShape(shape)
            } else {
                RemoteImage(path: path, icon: "person.fill")
                    .id(path)                 // 换了头像立刻生效（不然会一直显示旧图）
                    .frame(width: size, height: size)
                    .clipShape(shape)
            }
        }
        .overlay(shape.stroke(Color.black.opacity(0.05), lineWidth: 0.5))
        /* 圆形头像：外面套一圈**玻璃倒角**（上缘一道高光、往下渐淡，
           边缘再压一条极淡暗边 + 一圈柔光）—— 不是"描一条白线"，
           是像一块真的玻璃压在头像上，所以看着是有厚度、立起来的。
           想整体关掉：后台 ui.json 写 avatarGlassRing = 0。 */
        .overlay {
            if circle, UIConfig.num("avatarGlassRing", 1) > 0 {
                let w = max(1.3, size * 0.045)
                ZStack {
                    /* ① 玻璃环本体：上亮、中透、下暗 */
                    Circle()
                        .stroke(LinearGradient(
                            colors: [Color.white.opacity(0.92),
                                     Color.white.opacity(0.42),
                                     Color.white.opacity(0.16),
                                     Color.black.opacity(0.12)],
                            startPoint: .top, endPoint: .bottom), lineWidth: w)
                    /* ② 里面再收一条极淡的暗边 —— 玻璃的"厚度"就出在这一笔 */
                    Circle()
                        .inset(by: w * 0.92)
                        .stroke(Color.black.opacity(0.07), lineWidth: 0.6)
                    /* ③ 上缘一小段更亮的镜面反光（苹果玻璃那一道） */
                    Circle()
                        .trim(from: 0.06, to: 0.30)
                        .stroke(Color.white.opacity(0.75),
                                style: StrokeStyle(lineWidth: w * 0.72, lineCap: .round))
                        .blur(radius: w * 0.35)
                }
                .allowsHitTesting(false)
                /* 外面一圈柔光：头像像是"浮"在玻璃上 */
                .shadow(color: Color.white.opacity(0.40), radius: w * 1.8, y: -w * 0.5)
            }
        }
        .overlay {
            if level >= 4, GrowthFlags.avatarFrame != false {
                QQAvatarFrame(level: level, size: size, circle: circle, radius: radius)
            }
        }
    }

    /// 服务器给 AI 助手用的那张会动的眼睛头像（bot-ai-eyes.png）→ 换成真的动画
    static func isEyesBot(_ p: String) -> Bool {
        p.contains("bot-ai-eyes")
    }

    private var shape: AnyShape {
        if circle { return AnyShape(Circle()) }
        return AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/* ------------------------------------------------------------ 等级头像框 */

/// 等级头像框（高级版）：
/// · 月亮（4 级起）：细银蓝金属环 + 一道很淡的银光缓慢扫过
/// · 太阳（16 级起）：金色环 + **环上一道金光缓慢游走**（像金属反光扫过，不是整圈在转）
///   + 背后柔光一呼一吸
/// · 皇冠（64 级起）：浓金双环 + 高光更亮 + 右上角小皇冠轻轻上下浮动
/// 三个动作都很慢、幅度也小 —— 一排头像放在列表里也不会觉得"都在动"。
struct QQAvatarFrame: View {
    var level: Int
    var size: CGFloat
    var circle: Bool = true
    var radius: CGFloat = 6

    @State private var breathe = false
    @State private var sweep = false
    @State private var floaty = false
    @State private var rays = false

    /// 0 = 没有 · 1 = 月亮 · 2 = 太阳 · 3 = 皇冠
    private var tier: Int {
        if level >= 64 { return 3 }
        if level >= 16 { return 2 }
        if level >= 4 { return 1 }
        return 0
    }

    /// 跑不跑动效（旋转光束 / 滑光 / 呼吸 / 闪星）。
    /// 小头像不跑 —— 列表和聊天页一屏十几个，全都在动就没法丝滑了；
    /// 大尺寸（名片、我的等级页）才跑全套。
    private var motionOn: Bool { size >= 52 }

    /// 环带宽度：月亮细一点、皇冠最厚
    private var band: CGFloat {
        switch tier {
        case 1:  return max(2.0, size * 0.055)
        case 2:  return max(2.8, size * 0.078)
        case 3:  return max(3.2, size * 0.094)
        default: return 0
        }
    }

    private var ring: AvatarRing { AvatarRing(circle: circle, radius: radius) }

    /// 金属带的颜色：一段亮、一段暗交替，看着像抛过光的金属，
    /// 不是一圈纯色（用户说以前那版"太平"）。
    private var metal: AngularGradient {
        let stops: [Gradient.Stop]
        switch tier {
        case 1:
            stops = [
                .init(color: Color(hex: 0xF7FBFF), location: 0.00),
                .init(color: Color(hex: 0xAFC7E8), location: 0.14),
                .init(color: Color(hex: 0x6D8CBE), location: 0.30),
                .init(color: Color(hex: 0xD6E4F9), location: 0.48),
                .init(color: Color(hex: 0x8BA6CE), location: 0.66),
                .init(color: Color(hex: 0x5B78A9), location: 0.84),
                .init(color: Color(hex: 0xF7FBFF), location: 1.00)
            ]
        case 2:
            stops = [
                .init(color: Color(hex: 0xFFF9DC), location: 0.00),
                .init(color: Color(hex: 0xFFD25A), location: 0.16),
                .init(color: Color(hex: 0xD98A08), location: 0.32),
                .init(color: Color(hex: 0xFFF0B4), location: 0.50),
                .init(color: Color(hex: 0xE8A61E), location: 0.68),
                .init(color: Color(hex: 0xB06F04), location: 0.86),
                .init(color: Color(hex: 0xFFF9DC), location: 1.00)
            ]
        default:
            stops = [
                .init(color: Color(hex: 0xFFFCEC), location: 0.00),
                .init(color: Color(hex: 0xFFE07A), location: 0.14),
                .init(color: Color(hex: 0xCE8B09), location: 0.30),
                .init(color: Color(hex: 0xFFF6CE), location: 0.46),
                .init(color: Color(hex: 0xF0B72B), location: 0.62),
                .init(color: Color(hex: 0xA96806), location: 0.80),
                .init(color: Color(hex: 0xFFF1B0), location: 1.00)
            ]
        }
        return AngularGradient(gradient: Gradient(stops: stops), center: .center)
    }

    /// 环上游走的那道光（转的是光，不是整圈环）
    private func sweepArc(_ alpha: Double) -> AngularGradient {
        AngularGradient(
            gradient: Gradient(stops: [
                .init(color: Color.white.opacity(0), location: 0.00),
                .init(color: Color.white.opacity(0), location: 0.62),
                .init(color: Color.white.opacity(alpha * 0.40), location: 0.72),
                .init(color: Color.white.opacity(alpha), location: 0.79),
                .init(color: Color.white.opacity(alpha * 0.30), location: 0.87),
                .init(color: Color.white.opacity(0), location: 0.96),
                .init(color: Color.white.opacity(0), location: 1.00)
            ]),
            center: .center
        )
    }

    private var glowColor: Color { tier >= 3 ? Color(hex: 0xFFD34B) : (tier >= 2 ? Color(hex: 0xFFC93C) : Color(hex: 0xBBD4FF)) }

    var body: some View {
        ZStack {
            /* 柔光只贴着环外一圈（以前那层撑到 1.6 倍，看着像外面套了个大圆圈。
               用户要求去掉大圆圈 → 收成紧紧贴着环的一点点光晕） */
            if tier >= 2 {
                Circle()
                    .fill(RadialGradient(colors: [glowColor.opacity(breathe ? 0.30 : 0.14), Color.clear],
                                         center: .center,
                                         startRadius: size * 0.46,
                                         endRadius: size * 0.62))
                    .frame(width: size * 1.24, height: size * 1.24)
                    .scaleEffect(breathe ? 1.02 : 0.98)
                    .allowsHitTesting(false)
            }

            /* 太阳/皇冠：环带里叠一圈慢慢转的光束 */
            if tier >= 2, motionOn {
                SunBurstShape(rays: tier >= 3 ? 14 : 12)
                    .fill(Color.white.opacity(0.85))
                    .frame(width: size * 1.16, height: size * 1.16)
                    .rotationEffect(.degrees(rays ? 360 : 0))
                    .opacity(breathe ? 0.34 : 0.18)
                    .mask(ring.stroke(style: StrokeStyle(lineWidth: band * 1.5)).frame(width: size, height: size))
                    .allowsHitTesting(false)
            }

            /* 金属带本体 */
            if tier >= 1 {
                ring.stroke(metal, lineWidth: band)
                    /* 小头像不打投影：投影要离屏渲染，一屏十几个就是一笔可观的开销 */
                    .shadow(color: glowColor.opacity(tier >= 2 ? 0.45 : 0.30), radius: motionOn ? band * 0.9 : 0)
                    .allowsHitTesting(false)
            }

            /* 环内侧一条极细的暗线 + 外侧一条亮边：让头像从环里"浮"出来 */
            if tier >= 1 {
                ring.stroke(Color.black.opacity(0.16), lineWidth: 0.7)
                    .padding(band * 0.52)
                    .allowsHitTesting(false)
                ring.stroke(Color.white.opacity(tier >= 2 ? 0.5 : 0.36), lineWidth: 0.8)
                    .padding(-band * 0.55)
                    .allowsHitTesting(false)
            }

            /* 环上游走的高光 */
            if tier >= 1 {
                ring.stroke(sweepArc(tier >= 3 ? 0.95 : (tier >= 2 ? 0.85 : 0.55)),
                            lineWidth: band * 1.05)
                    .rotationEffect(.degrees(sweep ? 360 : 0))
                    .shadow(color: (tier >= 2 ? Color(hex: 0xFFE9A6) : Color(hex: 0xDCEBFF)).opacity(0.9),
                            radius: motionOn ? band * 1.4 : 0)
                    .allowsHitTesting(false)
            }

            /* 左上永远挂一道玻璃高光（静止，不转） */
            if tier >= 1 {
                ring.trim(from: 0.54, to: 0.80)
                    .stroke(Color.white.opacity(tier >= 2 ? 0.8 : 0.62),
                            style: StrokeStyle(lineWidth: band * 0.42, lineCap: .round))
                    .blur(radius: motionOn ? 0.5 : 0)
                    .allowsHitTesting(false)
            }

            /* 头像右上角那顶小皇冠：用户说「把头像上的皇冠去掉」——去掉了。
               皇冠档的框现在只有：厚金双环 + 环上流光 + 背后柔光 + 三颗小星。
               （等级图标里那个皇冠还挂在昵称后面，不受影响。） */

            /* 月亮：左下角一枚很淡的月牙（冷银蓝，不抢头像） */
            if tier == 1 {
                QQGlyph(kind: .moon, size: max(10, size * 0.28))
                    .offset(x: -size * 0.33, y: size * 0.34 + (floaty ? -0.8 : 0.6))
                    .allowsHitTesting(false)
            }

            /* 小星星：太阳/皇冠各三颗，错开闪 */
            if tier >= 2, motionOn {
                TwinkleStar(side: max(5, size * 0.16), color: glowColor, duration: 0.80)
                    .offset(x: -size * 0.44, y: -size * 0.20)
                TwinkleStar(side: max(4, size * 0.12), color: glowColor, duration: 1.10)
                    .offset(x: size * 0.22, y: size * 0.44)
                TwinkleStar(side: max(4, size * 0.13), color: glowColor, duration: 0.95)
                    .offset(x: -size * 0.24, y: size * 0.46)
            }
        }
        /* ⚠ 这一句不能少：ZStack 会被里面那个 1.6 倍大的柔光撑大，
           环就会按 1.6 倍画、飘到头像外面（用户反馈"怎么没有特效"就是这个）。
           钉回头像本身的尺寸，环才正好压在头像边上。 */
        .frame(width: size, height: size)
        .onAppear {
            guard tier >= 1 else { return }
            /* 小头像（会话列表 / 聊天页里 40 来点）不跑动效：
               一屏十几个头像都在转光束、闪星星、呼吸，滚动时全是掉帧的来源。
               名片、我的等级页这种大头像（≥52）才跑全套动效。 */
            guard motionOn else { return }
            /* 高光沿着环慢慢扫一圈（3.6 秒） */
            withAnimation(.linear(duration: 3.6).repeatForever(autoreverses: false)) { sweep = true }
            if tier >= 2 {
                /* 环带里的光束慢慢转（24 秒一圈，很慢，不晃眼） */
                withAnimation(.linear(duration: 24).repeatForever(autoreverses: false)) { rays = true }
            }
            if tier >= 2 {
                /* 背后柔光一呼一吸 */
                withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { breathe = true }
            }
            if tier >= 1 {
                /* 小徽章轻轻上下浮动 */
                withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true)) { floaty = true }
            }
        }
    }

}

/// 一颗会眨眼的小星（每颗时长不一样，看着才像自然闪）
struct TwinkleStar: View {
    var side: CGFloat
    var color: Color
    var duration: Double

    @State private var on = false

    var body: some View {
        SparkleShape()
            .fill(Color.white)
            .frame(width: side, height: side)
            .shadow(color: color.opacity(0.9), radius: 2.5)
            .opacity(on ? 0.95 : 0.10)
            .scaleEffect(on ? 1 : 0.5)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

/// 头像框的环（圆 / 圆角方）——做成 Shape 才能 trim 出那段玻璃高光
struct AvatarRing: Shape {
    var circle: Bool
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        circle ? Path(ellipseIn: rect)
               : Path(roundedRect: rect, cornerRadius: radius + 1.5, style: .continuous)
    }
}

/// 太阳那圈光束（叠在环带里，慢慢转）
struct SunBurstShape: Shape {
    var rays: Int = 12

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let m = min(rect.width, rect.height)
        let r0 = m * 0.36
        let r1 = m * 0.56
        for i in 0..<max(3, rays) {
            let a = Double(i) * 2 * Double.pi / Double(max(3, rays))
            let half = Double.pi / Double(max(3, rays)) * 0.40
            p.move(to: CGPoint(x: c.x + CGFloat(cos(a - half)) * r0, y: c.y + CGFloat(sin(a - half)) * r0))
            p.addLine(to: CGPoint(x: c.x + CGFloat(cos(a)) * r1, y: c.y + CGFloat(sin(a)) * r1))
            p.addLine(to: CGPoint(x: c.x + CGFloat(cos(a + half)) * r0, y: c.y + CGFloat(sin(a + half)) * r0))
            p.closeSubpath()
        }
        return p
    }
}

/// 四角小星（闪烁的亮点）
struct SparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        let k = 0.12
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY),
                       control: CGPoint(x: rect.midX + w * k, y: rect.midY - h * k))
        p.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY),
                       control: CGPoint(x: rect.midX + w * k, y: rect.midY + h * k))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.midY),
                       control: CGPoint(x: rect.midX - w * k, y: rect.midY + h * k))
        p.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY),
                       control: CGPoint(x: rect.midX - w * k, y: rect.midY - h * k))
        p.closeSubpath()
        return p
    }
}

/// QQ 那种皇冠的形状：五尖冠身 + 底带（可以只要其中一部分，方便分色画）
struct CrownShape: Shape {
    enum Part { case body, band, both }
    var part: Part = .both

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        if part != .band {
            /* 冠身：左外尖 → 左内尖 → 中间最高 → 右内尖 → 右外尖，谷底都收圆 */
            p.move(to: CGPoint(x: rect.minX + w * 0.06, y: rect.minY + h * 0.72))
            p.addLine(to: CGPoint(x: rect.minX + w * 0.06, y: rect.minY + h * 0.30))
            p.addQuadCurve(to: CGPoint(x: rect.minX + w * 0.27, y: rect.minY + h * 0.54),
                           control: CGPoint(x: rect.minX + w * 0.10, y: rect.minY + h * 0.13))
            p.addQuadCurve(to: CGPoint(x: rect.minX + w * 0.38, y: rect.minY + h * 0.38),
                           control: CGPoint(x: rect.minX + w * 0.31, y: rect.minY + h * 0.48))
            p.addQuadCurve(to: CGPoint(x: rect.minX + w * 0.50, y: rect.minY + h * 0.18),
                           control: CGPoint(x: rect.minX + w * 0.42, y: rect.minY + h * 0.42))
            p.addQuadCurve(to: CGPoint(x: rect.minX + w * 0.62, y: rect.minY + h * 0.38),
                           control: CGPoint(x: rect.minX + w * 0.58, y: rect.minY + h * 0.42))
            p.addQuadCurve(to: CGPoint(x: rect.minX + w * 0.73, y: rect.minY + h * 0.54),
                           control: CGPoint(x: rect.minX + w * 0.69, y: rect.minY + h * 0.48))
            p.addQuadCurve(to: CGPoint(x: rect.minX + w * 0.94, y: rect.minY + h * 0.30),
                           control: CGPoint(x: rect.minX + w * 0.90, y: rect.minY + h * 0.13))
            p.addLine(to: CGPoint(x: rect.minX + w * 0.94, y: rect.minY + h * 0.72))
            p.closeSubpath()
        }
        if part != .body {
            p.addRoundedRect(in: CGRect(x: rect.minX + w * 0.03, y: rect.minY + h * 0.68,
                                        width: w * 0.94, height: h * 0.30),
                             cornerSize: CGSize(width: w * 0.12, height: h * 0.15))
        }
        return p
    }
}

/// 皇冠小徽章（照 QQ 那顶做）：五尖金冠 + 底带 + 一颗红宝石 + 顶部光泽 + 柔光
struct CrownBadge: View {
    var size: CGFloat
    @State private var glint = false
    @State private var floaty = false
    @State private var tilt = false

    private var depth: CGFloat { max(0.8, size * 0.10) }

    var body: some View {
        ZStack {
            /* 贴着皇冠的一点点金光（不是外面套个大圆盘） */
            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0xFFD34B).opacity(glint ? 0.38 : 0.20), Color.clear],
                                     center: .center, startRadius: size * 0.24, endRadius: size * 0.62))
                .frame(width: size * 1.30, height: size * 1.30)

            /* 3D：先垫一层"厚度"（挤出的侧面）+ 落在下面的影子 */
            CrownShape(part: .both)
                .fill(Color.black.opacity(0.20))
                .frame(width: size, height: size)
                .blur(radius: max(0.8, size * 0.10))
                .offset(y: depth * 1.8)
            CrownShape(part: .both)
                .fill(LinearGradient(colors: [Color(hex: 0xB87C08), Color(hex: 0x7E5204)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: size, height: size)
                .offset(y: depth)

            /* 冠身：三段金渐变，上亮下深 */
            CrownShape(part: .body)
                .fill(LinearGradient(colors: [Color(hex: 0xFFFCE8), Color(hex: 0xFFD24A), Color(hex: 0xC8890C)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: size, height: size)

            /* 冠身顶部一层白光泽（看着像抛过光的金属） */
            CrownShape(part: .body)
                .fill(LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.0)],
                                     startPoint: .top, endPoint: .center))
                .frame(width: size, height: size)

            /* 底带：比冠身亮一点，上沿压一条暗金线 */
            CrownShape(part: .band)
                .fill(LinearGradient(colors: [Color(hex: 0xFFF6C4), Color(hex: 0xF0B72B), Color(hex: 0xA96806)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: size, height: size)
            Rectangle()
                .fill(Color(hex: 0x9A6400).opacity(0.45))
                .frame(width: size * 0.90, height: max(0.5, size * 0.035))
                .offset(y: -size * 0.155)

            /* 底带正中一颗红宝石（QQ 那顶就是这儿一颗红宝石） */
            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0xFF9A9A), Color(hex: 0xE23B3B), Color(hex: 0x8E1412)],
                                     center: UnitPoint(x: 0.35, y: 0.3),
                                     startRadius: 0, endRadius: size * 0.13))
                .frame(width: size * 0.22, height: size * 0.22)
                .offset(y: size * 0.16)
            Circle()
                .fill(Color.white.opacity(0.9))
                .frame(width: size * 0.055, height: size * 0.055)
                .offset(x: -size * 0.035, y: size * 0.125)

            /* 整体描边：浅底上也看得清轮廓 */
            CrownShape(part: .both)
                .stroke(Color(hex: 0x8E5E06).opacity(0.5), lineWidth: max(0.5, size * 0.05))
                .frame(width: size, height: size)

            SparkleShape()
                .fill(Color.white)
                .frame(width: size * 0.30, height: size * 0.30)
                .offset(x: size * 0.38, y: -size * 0.30)
                .opacity(glint ? 0.95 : 0)
                .scaleEffect(glint ? 1 : 0.4)
        }
        .frame(width: size, height: size)   // 柔光比皇冠大，必须钉住尺寸
        /* 像个小模型一样左右微微转一下（幅度很小，不晃眼） */
        .rotation3DEffect(.degrees(tilt ? 9 : -7), axis: (x: 0.15, y: 1, z: 0), perspective: 0.55)
        .offset(y: floaty ? -1.2 : 0.6)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { glint = true }
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) { floaty = true }
            withAnimation(.easeInOut(duration: 3.4).repeatForever(autoreverses: true)) { tilt = true }
        }
    }
}

/// 3D 质感的等级图标（星 / 月 / 日 / 冠）：垫一层"厚度"+ 正面金属渐变 + 顶面光泽 + 镜面亮点 + 投影。
/// 纯 SwiftUI 画的"假 3D"，但一排摆在昵称旁边就有厚度和立体感了。
struct Glyph3D: View {
    var kind: QQGlyphKind
    var size: CGFloat

    private var depth: CGFloat { max(0.6, size * 0.11) }
    private var eoFill: FillStyle { FillStyle(eoFill: kind == .moon) }

    private var front: [Color] {
        switch kind {
        case .star:  return [Color(hex: 0xFFF8CC), Color(hex: 0xFFD23F), Color(hex: 0xE39A00)]
        case .sun:   return [Color(hex: 0xFFF2AE), Color(hex: 0xFFB01F), Color(hex: 0xE17000)]
        case .moon:  return [Color(hex: 0xFFFFFF), Color(hex: 0xD8E6FA), Color(hex: 0x91AACF)]
        case .crown: return [Color(hex: 0xFFFBE2), Color(hex: 0xFFD24A), Color(hex: 0xC8890C)]
        }
    }

    private var side: Color {
        switch kind {
        case .star:  return Color(hex: 0xBC7C00)
        case .sun:   return Color(hex: 0xAC5600)
        case .moon:  return Color(hex: 0x6F87A8)
        case .crown: return Color(hex: 0x8E5E06)
        }
    }

    private var edge: Color {
        kind == .moon ? Color(hex: 0x5E7699).opacity(0.40) : Color(hex: 0x6B4400).opacity(0.40)
    }

    var body: some View {
        ZStack {
            /* 落在下面的影子 */
            QQGlyphShape(kind: kind)
                .fill(Color.black.opacity(0.20), style: eoFill)
                .frame(width: size, height: size)
                .blur(radius: max(0.7, size * 0.10))
                .offset(y: depth * 1.6)

            /* 厚度：把形状往下挪一点点画一层深色，看着就"有侧面" */
            QQGlyphShape(kind: kind)
                .fill(side, style: eoFill)
                .frame(width: size, height: size)
                .offset(y: depth)

            /* 正面：金属渐变 + 一圈描边 */
            QQGlyphShape(kind: kind)
                .fill(LinearGradient(colors: front, startPoint: .top, endPoint: .bottom), style: eoFill)
                .frame(width: size, height: size)
                .overlay {
                    if kind != .moon {
                        QQGlyphShape(kind: kind)
                            .stroke(edge, lineWidth: max(0.4, size * 0.045))
                    }
                }

            /* 顶面光泽（上白下透） */
            QQGlyphShape(kind: kind)
                .fill(LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.0)],
                                     startPoint: .top, endPoint: .center), style: eoFill)
                .frame(width: size, height: size)

            /* 镜面小亮点 */
            Ellipse()
                .fill(Color.white.opacity(0.88))
                .frame(width: size * 0.22, height: size * 0.12)
                .rotationEffect(.degrees(-25))
                .offset(x: -size * 0.15, y: -size * 0.22)
                .blur(radius: max(0.2, size * 0.02))
        }
        .frame(width: size, height: size)
    }
}

/// 月牙小徽章（冷银蓝，光很淡）—— 同样做成有厚度的小模型
struct MoonBadge: View {
    var size: CGFloat
    @State private var glow = false

    var body: some View {
        ZStack {
            /* 厚度 + 影子 */
            QQGlyphShape(kind: .moon)
                .fill(Color.black.opacity(0.18), style: FillStyle(eoFill: true))
                .frame(width: size, height: size)
                .blur(radius: max(0.6, size * 0.10))
                .offset(y: size * 0.16)
            QQGlyphShape(kind: .moon)
                .fill(Color(hex: 0x6F87A8), style: FillStyle(eoFill: true))
                .frame(width: size, height: size)
                .offset(y: size * 0.09)
            /* 正面 */
            QQGlyphShape(kind: .moon)
                .fill(LinearGradient(colors: [Color(hex: 0xFFFFFF), Color(hex: 0xD8E6FA), Color(hex: 0x91AACF)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing),
                      style: FillStyle(eoFill: true))
                .frame(width: size, height: size)
            /* 顶面亮点 */
            QQGlyphShape(kind: .moon)
                .fill(LinearGradient(colors: [Color.white.opacity(0.7), Color.white.opacity(0.0)],
                                     startPoint: .top, endPoint: .center),
                      style: FillStyle(eoFill: true))
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .shadow(color: Color(hex: 0xBBD4FF).opacity(glow ? 0.7 : 0.28), radius: size * 0.30)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { glow = true }
        }
    }
}

/* ============================================================ 时间 */

/// 手机号打码：138****8888（微信显示手机号就是这个样子）
func maskPhone(_ s: String) -> String {
    let digits = s.filter { $0.isNumber }
    guard digits.count >= 7 else { return s }
    let head = digits.prefix(3)
    let tail = digits.suffix(4)
    return "\(head)****\(tail)"
}

enum TimeFmt {
    static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /* ISO 字符串 → Date 的解析结果缓存。
       聊天页每一行都要判「跟上一条隔了 5 分钟没有」（时间线 + 气泡间距），
       每条消息每次布局都要解析一遍 ISO 串 —— 消息一多，这块就是滚动掉帧的主因之一。
       时间字符串是固定不变的，解析结果直接记住。 */
    private static var dateMemo: [String: Date] = [:]
    private static let dateMemoLock = NSLock()

    static func date(_ s: String?) -> Date? {
        guard let s = s, !s.isEmpty else { return nil }
        dateMemoLock.lock()
        if let hit = dateMemo[s] { dateMemoLock.unlock(); return hit }
        dateMemoLock.unlock()
        guard let d = isoFrac.date(from: s) ?? isoPlain.date(from: s) else { return nil }
        dateMemoLock.lock()
        if dateMemo.count > 4096 { dateMemo.removeAll(keepingCapacity: true) }
        dateMemo[s] = d
        dateMemoLock.unlock()
        return d
    }

    /* ⚠ 日期格式化器必须缓存：DateFormatter() 每建一个都要加载一次 locale 数据（很贵），
       会话列表一屏十几行、每行都要格式化一次时间，聊天页每个时间线也要 ——
       客户端反馈「消息一多就不丝滑」，这也是其中一条。只用来格式化是线程安全的。 */
    private static func make(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = format
        return f
    }
    private static let fHM24 = make("HH:mm")
    private static let fHM12 = make("h:mm")
    private static let fWeekday = make("EEEE")
    private static let fMonthDay = make("M月d日")
    private static let fYearMonthDay = make("yyyy年M月d日")
    /// 几点几分：**跟系统设置走** —— 手机是 24 小时制就出「15:24」，12 小时制出「下午3:24」。
    /// 以前这里写死成「上午 / 下午 + h:mm」，用户把手机设成 24 小时制时还是显示"下午"，
    /// 和微信（微信跟系统走）不一样。
    private static let fClock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = DateFormatter.dateFormat(fromTemplate: "jm", options: 0, locale: Locale.current) ?? "HH:mm"
        return f
    }()
    private static let fBill = make("yyyy年M月d日 H:mm:ss")

    static func list(_ s: String?) -> String {
        guard let d = date(s) else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(d) {
            return fClock.string(from: d)
        }
        if cal.isDateInYesterday(d) { return "昨天" }
        let days = cal.dateComponents([.day],
                                      from: cal.startOfDay(for: d),
                                      to: cal.startOfDay(for: Date())).day ?? 99
        /* 微信会话列表：今天 HH:mm → 昨天 → 前天 → 星期一~日 → M月d日 → yyyy年M月d日 */
        if days == 2 { return "前天" }
        if days < 7 { return fWeekday.string(from: d) }
        return cal.isDate(d, equalTo: Date(), toGranularity: .year)
            ? fMonthDay.string(from: d)
            : fYearMonthDay.string(from: d)
    }

    static func bubble(_ s: String?) -> String {
        guard let d = date(s) else { return "" }
        let cal = Calendar.current
        let clock = fClock.string(from: d)
        if cal.isDateInToday(d) {
            return clock
        }
        /* 微信聊天页那条时间线：今天 → 几点几分；昨天 → 昨天 几点几分；
           前天 → 前天 几点几分；一周内 → 星期X 几点几分；今年 → M月d日 几点几分；
           往年 → yyyy年M月d日 几点几分。（以前少了"前天 / 星期X"，2~6 天前直接显示成日期了） */
        let days = cal.dateComponents([.day],
                                      from: cal.startOfDay(for: d),
                                      to: cal.startOfDay(for: Date())).day ?? 99
        if days == 1 { return "昨天 " + clock }
        if days == 2 { return "前天 " + clock }
        if days < 7 { return fWeekday.string(from: d) + " " + clock }
        let day = cal.isDate(d, equalTo: Date(), toGranularity: .year)
            ? fMonthDay.string(from: d)
            : fYearMonthDay.string(from: d)
        return day + " " + clock
    }

    static func minutesBetween(_ a: String?, _ b: String?) -> Int {
        guard let d1 = date(a), let d2 = date(b) else { return 9999 }
        return abs(Int(d2.timeIntervalSince(d1) / 60))
    }

    /// 账单里的时间：2026年9月13日 13:11:57（不带前导 0）
    static func bill(_ s: String?) -> String {
        guard let d = date(s) else { return "" }
        return fBill.string(from: d)
    }

    private static let fMonthDayWeek = make("M月d日 EEEE")

    /// 账单列表里「日」那一行：`10月16日 星期五`
    /// （今天 / 昨天 就直接写「今天」「昨天」，跟微信一样）
    static func billDay(_ s: String?) -> String {
        guard let d = date(s) else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "今天" }
        if cal.isDateInYesterday(d) { return "昨天" }
        return fMonthDayWeek.string(from: d)
    }

    /// 账单列表里每一行的时刻：只到分（同样跟系统的 12/24 小时制走）
    static func billClock(_ s: String?) -> String {
        guard let d = date(s) else { return "" }
        return fClock.string(from: d)
    }

    static func ago(_ s: String?) -> String {
        guard let d = date(s) else { return "" }
        /* 微信朋友圈那套时间逻辑：
           1 分钟内「刚刚」→ 1 小时内「X分钟前」→ 今天内「X小时前」
           → 昨天 / 前天 → 7 天内「X天前」→ 本年「M月d日」→ 往年「yyyy年M月d日」 */
        let cal = Calendar.current
        let secs = Date().timeIntervalSince(d)
        if secs < 60 { return "刚刚" }
        if secs < 3600 { return "\(Int(secs / 60))分钟前" }
        if cal.isDateInToday(d) { return "\(max(1, Int(secs / 3600)))小时前" }
        if cal.isDateInYesterday(d) { return "昨天" }
        let days = cal.dateComponents([.day],
                                      from: cal.startOfDay(for: d),
                                      to: cal.startOfDay(for: Date())).day ?? 99
        if days == 2 { return "前天" }
        if days < 7 { return "\(days)天前" }
        let sameYear = cal.component(.year, from: d) == cal.component(.year, from: Date())
        return sameYear ? fMonthDay.string(from: d) : fYearMonthDay.string(from: d)
    }
}

/* ============================================================ 小零件 */

/// 名字 → 拼音首字母。算一次就记住：通讯录一千个人时，每次重绘都重新转拼音会卡
/// （搜索框每敲一个字都会重绘一遍）。
private var pinyinMemo: [String: String] = [:]

func pinyinInitial(_ text: String) -> String {
    if let hit = pinyinMemo[text] { return hit }
    let value = pinyinInitialRaw(text)
    if pinyinMemo.count > 4000 { pinyinMemo.removeAll(keepingCapacity: true) }
    pinyinMemo[text] = value
    return value
}

private func pinyinInitialRaw(_ text: String) -> String {
    guard !text.isEmpty else { return "#" }
    let first = String(text[text.startIndex])
    if first.range(of: "^[A-Za-z]$", options: .regularExpression) != nil {
        return first.uppercased()
    }
    var latin = first.applyingTransform(StringTransform.toLatin, reverse: false) ?? first
    latin = latin.applyingTransform(StringTransform.stripDiacritics, reverse: false) ?? latin
    latin = latin.trimmingCharacters(in: .whitespacesAndNewlines)
    if let c = latin.first, c.isLetter { return String(c).uppercased() }
    return "#"
}

/// 网页里是 1 个设备像素的发丝线
struct HairLine: View {
    var inset: CGFloat = 0
    var trailingInset: CGFloat = 0
    var color: Color = C.hairline
    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: 0.5)
            .padding(.leading, inset)
            .padding(.trailing, trailingInset)
    }
}

/// 微信那个「›」：方块只留上/右两条边，再转 45°
struct Chevron: View {
    var size: CGFloat = 9
    var line: CGFloat = 1.6
    var color: Color = C.arrow
    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: size, y: 0))
            p.addLine(to: CGPoint(x: size, y: size))
        }
        .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .square, lineJoin: .miter))
        .frame(width: size, height: size)
        .rotationEffect(.degrees(45))
        .frame(width: size * 1.4, height: size * 1.4)
    }
}

/* ============================================================ 富文本小工具 */

/// 长文里"像代码的那几行"用等宽字体显示。
/// 比例字体里缩进、括号、引号会挤成一团 —— AI 回复里的代码块就是这么显得"乱"的。
/// 聊天页（气泡）和小星的对话页都用这一套。
enum RichText {
    static func looksLikeCode(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return false }
        /* 一行里只要有中文（或全角标点、表情），一律按正文排 —— 正文必须是苹方。
           用户反馈「汽泡里的字不是苹方体」就是这一条：中文句子只要结尾带了分号、
           或者中间出现过 () ，就会被下面几条规则判成「代码行」，
           整行换成等宽字体，看着就不是苹方了。中文永远不该走等宽。 */
        if t.unicodeScalars.contains(where: { $0.value >= 0x2E80 }) { return false }
        if t.hasPrefix("```") { return true }                            // markdown 围栏
        if line.hasPrefix("  ") || line.hasPrefix("\t") { return true }   // 缩进行
        if t.hasSuffix(";") || t.hasSuffix("{") || t.hasSuffix("}") { return true }
        if t.contains("</") || t.contains("/>") || t.contains("()") { return true }
        return false
    }

    /// 多行文本 → AttributedString：代码行等宽，其余用外面的字号
    static func lines(_ raw: String, size: CGFloat) -> AttributedString {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let mono = Font.system(size: max(11, size - 1.5), design: .monospaced)
        /* 正文钉成苹方（和聊天页同一个道理），代码行才走等宽 */
        let base = pf(size)
        var out = AttributedString()
        let arr = s.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, sub) in arr.enumerated() {
            let line = String(sub)
            if looksLikeCode(line) {
                var seg = AttributedString(line)
                seg.font = mono
                out += seg
            } else {
                var seg = linkified(line)
                seg.font = base
                out += seg
            }
            if i < arr.count - 1 { out += AttributedString("\n") }
        }
        return out
    }

    /// 一行里的网址 → 蓝色可点。
    /// 微信不止认 http:// 开头的：「www.xxx.com」「taobao.com」「s.m.taobao.com/h5?q=…」
    /// 这种裸域名也会变成链接，所以用正则一次扫干净。
    static func linkified(_ s: String) -> AttributedString {
        var out = AttributedString()
        let src = s as NSString
        let pattern = "(?:https?://|www\\.)[^\\s，。、）)】」]+"
            + "|(?:[A-Za-z0-9-]+\\.)+(?:com|cn|net|org|io|cc|me|tv|xyz|top|vip|shop|info|edu|gov|co|app|dev)"
            + "(?:/[^\\s，。、）)】」]*)?"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return AttributedString(s)
        }
        var cursor = 0
        re.enumerateMatches(in: s, range: NSRange(location: 0, length: src.length)) { m, _, _ in
            guard let m = m else { return }
            if m.range.location > cursor {
                out += AttributedString(src.substring(with: NSRange(location: cursor,
                                                                    length: m.range.location - cursor)))
            }
            var token = src.substring(with: m.range)
            /* 句尾的英文标点不算网址的一部分（"看 https://a.com." 那个点） */
            let trailing = ".,;:!?)]}>\"'"
            var tail = ""
            while let last = token.last, trailing.contains(last) {
                tail = String(last) + tail
                token.removeLast()
            }
            let full = token.lowercased().hasPrefix("http") ? token : "http://" + token
            var seg = AttributedString(token)
            if let u = URL(string: full) {
                /* 黄赌毒/电诈特征的域名不给上色、也不给点（服务端本来就会拦，
                   这里是对"以前发出去的老消息"兜底） */
                if !looksBadLink(u) {
                    seg.link = u
                    seg.foregroundColor = Color.dyn(0x576B95, 0x7D90B8)
                }
            }
            out += seg
            if !tail.isEmpty { out += AttributedString(tail) }
            cursor = m.range.location + m.range.length
        }
        if cursor < src.length { out += AttributedString(src.substring(from: cursor)) }
        return out
    }

    /// 明显的黄赌毒 / 电诈域名（和服务端那份黑名单同源，尽量保守、不误伤正常站点）
    static func looksBadLink(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        let badInHost = ["casino", "poker", "baccarat", "roulette", "gambling", "lottery",
                         "jackpot", "porn", "xxx", "hentai", "onlyfans", "escort",
                         "cocaine", "heroin"]
        for w in badInHost where host.contains(w) { return true }
        for lb in host.split(separator: ".") {
            let s = String(lb)
            if ["bet", "sex", "xxx", "porn", "av", "jav", "toto", "adult"].contains(s) { return true }
            if s.range(of: #"^(18|91|av|jav)?(av|jav|porn|xxx|sex)\d*$"#,
                       options: .regularExpression) != nil { return true }
        }
        let path = (url.path + "?" + (url.query ?? "")).lowercased()
        for w in ["/casino", "/bet", "/poker", "/porn", "/xxx", "/sex", "/adult"] where path.contains(w) {
            return true
        }
        return false
    }
}

struct UnreadBadge: View {
    let count: Int
    /// 外面那一圈描边用**所在行的底色**（会话列表的行底色和卡片底色不是同一个色，
    /// 传错了会看出来一圈色差）
    var border: Color = C.cardBg
    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(pf(12, .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, count > 9 ? 5 : 0)
                .frame(minWidth: 18, minHeight: 18)
                /* 微信那枚徽标：红底白字，外面还有一圈和底色一样的描边，
                   压在头像右上角上才不会糊成一团 */
                .background(Capsule().fill(C.red))
                .overlay(Capsule().stroke(border, lineWidth: 1.2))
        }
    }
}

/// 免打扰会话的小红点：微信里被「消息免打扰」的会话，
/// 来新消息只点一个小红点，不给数字（数字留给重要的会话）
struct UnreadDot: View {
    var size: CGFloat = 10
    /// 同理：描边跟所在行的底色
    var border: Color = C.cardBg
    var body: some View {
        Circle()
            .fill(C.red)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(border, lineWidth: 1.2))
    }
}

/// 语音消息「听过没听过」：微信里没听过的语音上有个小红点，点开听过就消失。
/// 这个状态是「每台设备自己记」的（微信也是本机记），所以存在本地。
enum VoicePlayed {
    private static let key = "chris.voice.played"
    private static let cap = 500

    static func isPlayed(_ id: String) -> Bool {
        if id.isEmpty { return true }
        return list().contains(id)
    }

    static func markPlayed(_ id: String) {
        guard !id.isEmpty else { return }
        var arr = list()
        arr.removeAll { $0 == id }
        arr.append(id)
        if arr.count > cap { arr.removeFirst(arr.count - cap) }
        UserDefaults.standard.set(arr, forKey: key)
    }

    private static func list() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }
}

/// 语音转文字的结果：转过的那条，退出聊天再进来还看得见（微信也是这样）。
/// 识别本来就在本机跑，所以结果也只记在本机；最多留 300 条，超了丢最早的。
enum VoiceText {
    private static let key = "chris.voice.text"
    private static let orderKey = "chris.voice.text.order"
    private static let cap = 300

    static func get(_ id: String) -> String? {
        guard !id.isEmpty else { return nil }
        return map()[id]
    }

    static func set(_ id: String, _ text: String) {
        guard !id.isEmpty, !text.isEmpty else { return }
        var m = map()
        m[id] = text
        var order = UserDefaults.standard.stringArray(forKey: orderKey) ?? []
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > cap {
            let old = order.removeFirst()
            m.removeValue(forKey: old)
        }
        UserDefaults.standard.set(m, forKey: key)
        UserDefaults.standard.set(order, forKey: orderKey)
    }

    private static func map() -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
    }
}

/* ============================================================
   UI 图标：管理后台「UI 图标」页换过的图标，App 打开时拉一份下来，
   这里存着「标识 → 新的图标」。新图标可以是：
     ① 一段 <svg> 代码   ② 一张图片地址（/uploads/xxx.png）   ③ 一个 emoji
   标识写在每个内置 SVG 的 data-key 里（比如 i.moments、plus.photo），
   系统图标用 sf:xxx（比如 sf:message）。
   ============================================================ */

enum IconOverrides {
    static var map: [String: String] = [:]

    static func custom(_ key: String) -> String? {
        if let v = map[key], !v.isEmpty { return v }
        return nil
    }

    /// 从内置 SVG 里读 data-key
    private static func keyOf(_ markup: String) -> String? {
        guard let r = markup.range(of: "data-key=\"") else { return nil }
        let rest = markup[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let k = String(rest[rest.startIndex..<end])
        return k.isEmpty ? nil : k
    }

    /// 有自定义就用自定义的，没有就用内置那一段
    static func markup(_ builtin: String) -> String {
        if let k = keyOf(builtin), let v = custom(k) { return v }
        return builtin
    }
}

/// 能画四种东西：SVG / 图片 / 文字（emoji）/ 系统图标兜底
struct FlexIcon: View {
    var custom: String?
    var size: CGFloat
    var color: Color
    var symbol: String
    var weight: Font.Weight = .regular

    var body: some View {
        if let v = custom, !v.isEmpty {
            if v.hasPrefix("<svg") {
                /* direct: true —— v 已经是"后台换过的那一份"，原样画，
                   不要再按它里面的 data-key 映射一次（不然会画成别的图标）。 */
                SVGIcon(markup: v, size: size, color: color, direct: true)
            } else if v.hasPrefix("http") || v.hasPrefix("/uploads") || v.hasPrefix("data:") {
                RemoteImage(path: v).frame(width: size, height: size)
            } else {
                Text(v)
                    .font(.system(size: size * 0.86))
                    .foregroundColor(color)
                    .frame(width: size, height: size)
            }
        } else {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundColor(color)
                .frame(width: size, height: size)
        }
    }
}

/* ============================================================
   点图看大图：黑底、左右翻、点一下返回（和微信一样，不带那个 × ）
   聊天里的图、朋友圈的图、名片里的小图都用这一个。
   ============================================================ */

/* ============================================================
   点头像 → 名片（聊天页、朋友圈页都能用）
   名片里的「发消息 / 看他的朋友圈」还能继续往下走。
   ============================================================ */
/// 二级页面用：进来把底部 4 个 tab 收起来，返回时再放出来（微信就是这样）
struct HidesTabBar: ViewModifier {
    @EnvironmentObject var app: AppState

    func body(content: Content) -> some View {
        content
            .onAppear { app.tabBarDepth += 1 }
            .onDisappear { app.tabBarDepth = max(0, app.tabBarDepth - 1) }
    }
}

extension View {
    func hidesTabBar() -> some View { modifier(HidesTabBar()) }
}

struct TapAvatarCard: ViewModifier {
    @Binding var cardUser: User?

    @State private var nextChat: Chat?
    @State private var nextMoments: User?

    func body(content: Content) -> some View {
        content
            .navigationDestination(isPresented: Binding(
                get: { cardUser != nil },
                set: { if !$0 { cardUser = nil } }
            )) {
                if let u = cardUser {
                    ContactCardView(user: u,
                                    onOpenChat: { chat in
                                        cardUser = nil
                                        nextChat = chat
                                    },
                                    onOpenMoments: { _ in
                                        nextMoments = u
                                        cardUser = nil
                                    })
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { nextChat != nil },
                set: { if !$0 { nextChat = nil } }
            )) {
                if let c = nextChat { ChatDetailView(chat: c) }
            }
            .navigationDestination(isPresented: Binding(
                get: { nextMoments != nil },
                set: { if !$0 { nextMoments = nil } }
            )) {
                if let t = nextMoments { MomentsView(target: t) }
            }
    }
}

/* 能缩放的单张图（图片浏览器用）：双指放大 / 双击放大缩小 / 放大后单指拖拽。
   没放大时不抢手势 → TabView 的左右翻页照旧能用。 */
struct ZoomableRemoteImage: View {
    var path: String
    /// 双击了：告诉外面「这次是放大，不是单点返回」
    var onDoubleTap: (() -> Void)? = nil
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var dragStart: CGSize = .zero

    private var magnify: some Gesture {
        MagnificationGesture()
            .onChanged { v in scale = min(4, max(1, baseScale * v)) }
            .onEnded { _ in
                baseScale = scale
                if scale <= 1.02 {
                    withAnimation(.easeOut(duration: 0.2)) {
                        scale = 1; baseScale = 1; offset = .zero; baseOffset = .zero
                    }
                }
            }
    }
    private var doubleTap: some Gesture {
        TapGesture(count: 2).onEnded {
            onDoubleTap?()
            withAnimation(.easeOut(duration: 0.22)) {
                if scale > 1.02 {
                    scale = 1; baseScale = 1; offset = .zero; baseOffset = .zero
                } else {
                    scale = 2.5; baseScale = 2.5
                }
            }
        }
    }
    private var pan: some Gesture {
        DragGesture()
            .onChanged { v in
                guard scale > 1.02 else { return }
                offset = CGSize(width: dragStart.width + v.translation.width,
                                height: dragStart.height + v.translation.height)
            }
            .onEnded { _ in
                baseOffset = offset
                dragStart = offset
            }
    }

    var body: some View {
        GeometryReader { geo in
            RemoteImage(path: path, mode: .fit)
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(scale)
                .offset(offset)
        }
        .contentShape(Rectangle())
        .gesture(magnify)                 // 双指放大 / 缩小
        .simultaneousGesture(doubleTap)   // 双击：放大到 2.5 倍 / 再双击回到原样
        /* 放大后拖拽看图。注意 including:
           以前这里是无条件 simultaneousGesture —— 没放大时它虽然「什么都不做」，
           但依然参与手势识别，把横向的拖动算成自己的，外层 TabView 的左右翻页
           就抢不到（线上反馈的「大图打开了、群里的图片不能左滑」）。
           现在只有放大以后才让它参与；1 倍时左右滑 = 翻上一张/下一张。 */
        .simultaneousGesture(pan, including: scale > 1.02 ? .all : .none)
        .onChange(of: scale) { s in
            if s <= 1.02 { dragStart = .zero; baseOffset = .zero }
            else { dragStart = baseOffset }
        }
    }
}

struct PhotoPager: View {
    let paths: [String]
    let startIndex: Int

    /// 用 fullScreenCover 打开时需要的一个 Identifiable 包装
    struct Item: Identifiable {
        let id = UUID()
        var paths: [String]
        var index: Int
    }
    /// 底部要不要显示微信那排「转发 / 保存」（看聊天里的图、朋友圈的图要；看头像这种不要）
    var showActions: Bool = false
    /// 长按保存到相册时用
    var onLongPress: (() -> Void)? = nil
    var onClose: () -> Void

    @EnvironmentObject private var app: AppState
    @State private var index = 0
    @State private var saved = false
    @State private var showForward = false
    /// 系统分享（照片一样要有：微信大图底下是「转发 / 分享 / 保存」）
    @State private var shareItems: [Any] = []
    @State private var showShare = false
    /// 单点返回用的延时任务（要给双击放大让路：250ms 内来了第二下就不算单点）
    @State private var tapCloseTask: Task<Void, Never>? = nil

    /// 当前这张（越界就给 nil）
    private var currentPath: String? {
        (index >= 0 && index < paths.count) ? paths[index] : nil
    }

    var body: some View {
        GeometryReader { geo in
        ZStack {
            /* 背景：微信看大图不是纯黑底 —— 是**这张图自己的模糊版**铺满，
               中间再压一层黑，所以画面透出来的颜色和大图是一套（用户要求「和微信一样」）。
               模糊版单独用 600 的解码上限，别为了背景再解一张大图（省内存）。 */
            Color.black.ignoresSafeArea()
            if let p = currentPath {
                RemoteImage(path: p, mode: .fill, maxSide: 600)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .blur(radius: 34)
                    .opacity(0.55)
                    .overlay(Color.black.opacity(0.18))
                    .ignoresSafeArea()
                    .animation(.easeOut(duration: 0.2), value: index)
            }

            TabView(selection: $index) {
                ForEach(paths.indices, id: \.self) { i in
                    /* 每张图都能双指放大 / 双击放大 / 放大后拖拽（和微信一样） */
                    ZoomableRemoteImage(path: paths[i], onDoubleTap: {
                        /* 双击是放大：把「点一下返回」那次延时任务撤掉，别把页面关了 */
                        tapCloseTask?.cancel()
                    })
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            /* 点一下图片 = 返回（微信大图也是这样：点一下就退出去）。
               ⚠ 不能直接 onTapGesture：双击放大时第一下会先把页面关掉。
               所以延 0.25 秒 —— 这段时间里来了第二下（双击）就取消返回。 */
            .onTapGesture {
                tapCloseTask?.cancel()
                tapCloseTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if !Task.isCancelled { onClose() }
                }
            }

            VStack(spacing: 0) {
                /* 左上角返回（微信也是左上角那个箭头） */
                if showActions { topBar }
                Spacer(minLength: 0)
                Text(saved ? Tr("已保存到相册") : (paths.count > 1 ? "\(index + 1) / \(paths.count)" : ""))
                    .font(pfExact(showActions ? 13 : 14))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.bottom, showActions ? 10 : 26)
                if showActions { actionBar }
            }
        }
        .contentShape(Rectangle())
        /* 点一下关掉：只有「没有底部按钮」的那种（看头像）才这样；
           带「转发 / 保存」的大图页**不能**点哪都关 —— 不然点按钮会连页面一起关掉，
           微信也是用左上角那个箭头退出。 */
        .onTapGesture { if !showActions { onClose() } }
        .onLongPressGesture {
            if let cb = onLongPress { cb(); return }
            save(index)
        }
        .onAppear { index = min(max(0, startIndex), max(0, paths.count - 1)) }
        /* 转发：微信是先选一个聊天，这里用同一套「转发给」 */
        .sheet(isPresented: $showForward) {
            if let p = currentPath {
                ForwardPickerView(items: [ForwardItem(kind: "image", content: p)]) { }
                    .environmentObject(app)
            }
        }
        .sheet(isPresented: $showShare) { ShareSheet(items: shareItems) }
        }
    }

    /// 左上角那颗返回
    private var topBar: some View {
        HStack {
            Button { onClose() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.black.opacity(0.35)))
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    /// 底下那排：转发 / 保存（微信看大图就是这排）
    private var actionBar: some View {
        HStack(spacing: 0) {
            barButton(Tr("转发"), "arrowshape.turn.up.right") { showForward = true }
            barButton(Tr("分享"), "square.and.arrow.up") { shareCurrent() }
            barButton(saved ? Tr("已保存") : Tr("保存"),
                      saved ? "checkmark.circle" : "square.and.arrow.down") { save(index) }
        }
        .padding(.bottom, L.safeBottom)
        .background(
            LinearGradient(colors: [Color.black.opacity(0.0), Color.black.opacity(0.62)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func barButton(_ title: String, _ icon: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                Text(title).font(pfExact(11.5))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func save(_ i: Int) {
        guard i >= 0, i < paths.count else { return }
        let path = paths[i]
        Task {
            var image: UIImage? = ImageStore.shared.get(path)
            if image == nil, let url = API.shared.assetURL(path) {
                if let data = try? await API.shared.imageData(url) {
                    image = RemoteImage.downsampled(data, maxSide: 1600)
                }
            }
            guard let img = image else { return }
            UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
            saved = true
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            saved = false
        }
    }

    /// 分享这张图（系统那套：存到相册 / 发给微信好友 / 隔空投送…）
    private func shareCurrent() {
        guard let path = currentPath else { return }
        Task {
            var items: [Any] = []
            /* 分享**文件**最稳（微信、相册、隔空投送都认；直接塞 UIImage 有些 App 不接）：
               本机留底优先，没有就去服务器取一份，落到临时文件再分享。 */
            var data = LocalStore.read(path)
            if data == nil, let url = API.shared.assetURL(path) {
                data = try? await API.shared.imageData(url)
            }
            if let d = data, !d.isEmpty {
                let ext = (path as NSString).pathExtension.isEmpty ? "jpg" : (path as NSString).pathExtension
                let f = FileManager.default.temporaryDirectory
                    .appendingPathComponent("share-\(UUID().uuidString).\(ext)")
                if (try? d.write(to: f)) != nil { items = [f] }
            }
            if items.isEmpty, let img = ImageStore.shared.get(path) { items = [img] }
            if items.isEmpty, let url = API.shared.assetURL(path) { items = [url] }
            guard !items.isEmpty else {
                app.show(Tr("这张图暂时分享不了，先保存到相册再发"))
                return
            }
            shareItems = items
            showShare = true
        }
    }
}

/// 登录页用的颜色（后台可改，默认值就是设计稿里的那几个）
enum LoginTheme {
    static var accent = Color(hexString: "#19A47A")
    static var accent2 = Color(hexString: "#007AFF")
    static var disabledAccent = Color(hexString: "#B2E4C8")
    static var disabledGray = Color(hexString: "#C7C7CC")
    static var text: Color? = nil
    static var sub: Color? = nil
    /// 深色模式下的文字颜色（后台「深色·文字」）
    static var darkText: Color? = nil
    static var pageBg: Color? = nil
    /// 卡片底色（后台「登录页 → 卡片」）。以前老登录页写死 #191919，浅色模式下就是
    /// 白底上飘一块黑砖 —— 输入框连边都看不出来（用户说的「中间输入的位置还是黑的」）。
    static var card: Color? = nil
    /// 深色模式下的页面底色 / 卡片底色（后台「深色·背景」「深色·卡片」）
    static var darkBg: Color? = nil
    static var darkCard: Color? = nil

    /// 正文颜色：按当前深浅色取后台配的那个，没配就用系统默认
    static func ink(_ scheme: ColorScheme) -> Color {
        if scheme == .dark, let d = darkText { return d }
        if let t = text { return t }
        return Color.primary
    }
    /// 页面底色：后台配了就用它（浅色=背景色，深色=深色背景），没配就系统背景
    static func bg(_ scheme: ColorScheme) -> Color {
        if scheme == .dark, let d = darkBg { return d }
        if let b = pageBg { return b }
        return Color(.systemBackground)
    }
    /// 输入卡片底色：后台配了就用它，没配就跟着页面底色走（浅色下默认白卡）
    static func cardBg(_ scheme: ColorScheme) -> Color {
        if scheme == .dark, let d = darkCard { return d }
        if let c = card { return c }
        return scheme == .dark ? Color(hex: 0x1C1C1E) : Color.white
    }
    /// 铺在后台自定义底色上的文字（紫底上的说明文字不能再用灰，会糊）
    static func onBg(_ scheme: ColorScheme) -> Color {
        if scheme == .dark && darkBg != nil { return inkSub(scheme) }
        if pageBg != nil { return .white }
        return ink(scheme)
    }
    /// 铺在自定义底色上的次要文字
    static func onBgSub(_ scheme: ColorScheme) -> Color {
        if scheme == .dark && darkBg != nil { return inkSub(scheme) }
        if pageBg != nil { return Color.white.opacity(0.82) }
        return inkSub(scheme)
    }
    /// 次要文字（副标题、说明、版本号）：后台没单独配就按正文颜色淡一点
    static func inkSub(_ scheme: ColorScheme) -> Color {
        if let s = sub { return s }
        if text != nil || darkText != nil { return ink(scheme).opacity(0.62) }
        return Color.secondary
    }
    /// 登录页背景图（后台「🎨 登录页 → 背景图」）
    static var bgImage = ""
    /// 用户协议 / 隐私政策全文（后台可改）
    static var terms = ""
    static var privacy = ""

    static func text(kind: Int) -> String {
        let custom = (kind == 0 ? terms : privacy).trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        return kind == 0
            ? "1. 本应用是自建的即时通讯软件，账号与数据都保存在你自己的服务器上。\n2. 请勿传播违法违规内容；一经发现，管理员有权封禁账号。\n3. 你的资料仅用于本应用内展示，不会提供给第三方。\n4. 修改密码后，之前的登录令牌会立即失效。"
            : "1. 我们只收集昵称、头像、地区、个性签名和你主动发送的消息与图片。\n2. 这些信息仅用于在本应用内展示和在你的设备之间同步。\n3. 全部保存在你自己的服务器上，不会上传到第三方服务。\n4. 你可以随时修改资料、清空聊天记录，或让管理员删除账号。"
    }

    static func apply(_ b: BrandInfo?) {
        guard let l = b?.login else { return }
        if let v = l.accent, !v.isEmpty { accent = Color(hexString: v) }
        if let v = l.accent2, !v.isEmpty { accent2 = Color(hexString: v) }
        if let v = l.disabledAccent, !v.isEmpty { disabledAccent = Color(hexString: v) }
        if let v = l.disabledGray, !v.isEmpty { disabledGray = Color(hexString: v) }
        if let v = l.text, !v.isEmpty { text = Color(hexString: v) }
        if let v = l.sub, !v.isEmpty { sub = Color(hexString: v) }
        if let v = l.darkText, !v.isEmpty { darkText = Color(hexString: v) }
        if let v = l.bg, !v.isEmpty { pageBg = Color(hexString: v) }
        if let v = l.card, !v.isEmpty { card = Color(hexString: v) }
        if let v = l.darkBg, !v.isEmpty { darkBg = Color(hexString: v) }
        if let v = l.darkCard, !v.isEmpty { darkCard = Color(hexString: v) }
        bgImage = l.bgImage ?? ""
        terms = l.terms ?? ""
        privacy = l.privacy ?? ""
    }
}
/// 转账页颜色（默认 #007AFF / #34C759，后台「🎨 登录页」里改「手机号登录色」即可一起变）
enum TransferTheme {
    static var accent: Color { LoginTheme.accent2 }
    static var success: Color { Color(hexString: "#34C759") }
}

/// 登录过、可以一键切换的账号（最多 3 个）
/// 账号列表放 UserDefaults（昵称/头像，重装也能保留）；令牌单独放钥匙串，按账号分开存
struct SavedAccount: Codable, Identifiable, Hashable {
    var username: String
    var nickname: String
    var avatar: String
    var id: String { username }
}

enum AccountStore {
    private static let listKey = "chris.accounts"
    static let maxCount = 3

    static func load() -> [SavedAccount] {
        guard let raw = UserDefaults.standard.string(forKey: listKey),
              let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([SavedAccount].self, from: data) else { return [] }
        return Array(list.prefix(maxCount))
    }

    static func saveList(_ list: [SavedAccount]) {
        let trimmed = Array(list.prefix(maxCount))
        if let data = try? JSONEncoder().encode(trimmed), let s = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(s, forKey: listKey)
        }
    }

    /// 登录成功后记一条：列表放最前面，令牌放钥匙串
    @discardableResult
    static func upsert(username: String, nickname: String, avatar: String, token: String) -> [SavedAccount] {
        var list = load().filter { $0.username != username }
        list.insert(SavedAccount(username: username, nickname: nickname, avatar: avatar), at: 0)
        saveList(list)
        if !token.isEmpty { Keychain.set(token, for: "token." + username) }
        return Array(list.prefix(maxCount))
    }

    /// 取某个账号保存的登录令牌（没有就返回空）
    static func token(for username: String) -> String {
        return Keychain.get("token." + username) ?? ""
    }

    /// 从「切过的账号」里去掉一个（钥匙串里的令牌也一起清掉）
    static func remove(username: String) {
        saveList(load().filter { $0.username != username })
        Keychain.remove("token." + username)
    }
}
