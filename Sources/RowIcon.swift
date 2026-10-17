import Foundation

/// 行图标：**用苹果自带的 SF Symbols**（不再用后台那套手画 SVG）。
/// 「我」页和发现页的行都走这里：先按后台给的 action 认，认不出再按中文标签认，
/// 最后给一个通用图标 —— 保证任何一行都有图标，不会空着。
enum RowIcon {
    /// action → SF Symbol
    private static let byAction: [String: String] = [
        "profile": "person.crop.circle.fill",
        "moments": "safari",
        "channels": "play.rectangle.fill",
        "feed": "play.rectangle.fill",
        "live": "dot.radiowaves.left.and.right",
        "nearby": "location.fill",
        "shake": "bolt.fill",
        "games": "gamecontroller.fill",
        "news": "newspaper.fill",
        "look": "eye.fill",
        /* 发现页的「听一听 / 音乐」和「小程序」（后台 discover.json 里配的 action） */
        "music": "music.note",
        "listen": "music.note",
        "miniapps": "square.grid.2x2.fill",
        "miniapp": "square.grid.2x2.fill",
        "search": "magnifyingglass",
        "scan": "qrcode.viewfinder",
        "wallet": "wallet.pass.fill",
        "pay": "yensign.circle.fill",
        "paycode": "yensign.circle.fill",
        "bills": "list.bullet.rectangle.fill",
        "balance": "yensign.circle.fill",
        "banks": "creditcard.fill",
        "paypassword": "lock.fill",
        "payscore": "star.circle.fill",
        "member": "crown.fill",
        "growth": "chart.bar.fill",
        "level": "chart.bar.fill",
        "security": "checkmark.shield.fill",
        "identity": "person.text.rectangle.fill",
        "storage": "internaldrive.fill",
        "status": "face.smiling.fill",
        "help": "questionmark.circle.fill",
        "about": "info.circle.fill",
        "settings": "gearshape.fill",
        "favorites": "star.fill",
        /* 我页两行：卡包 / 小店（2026-10-12 加的） */
        "cards": "wallet.pass.fill",
        "shop": "bag.fill",
        "officialAccounts": "envelope.fill",
        "officialaccounts": "envelope.fill",
        "tags": "tag.fill",
        "newFriends": "person.badge.plus",
        "groups": "person.3.fill",
        "chatOnly": "bubble.left.and.bubble.right.fill",
        "work": "briefcase.fill",
        "myWork": "briefcase.fill"
    ]

    /// 中文标签 → SF Symbol（后台没给 action 时的兜底）
    private static let byLabel: [String: String] = [
        "个人信息": "person.crop.circle.fill",
        "朋友圈": "safari",
        "视频号": "play.rectangle.fill",
        "直播": "dot.radiowaves.left.and.right",
        "看一看": "eye.fill",
        "听一听": "music.note",
        "音乐": "music.note",
        "小程序": "square.grid.2x2.fill",
        "小游戏": "gamecontroller.fill",
        "摇一摇": "bolt.fill",
        "公众号": "envelope.fill",
        "收藏": "star.fill",
        "卡包": "wallet.pass.fill",
        "小店": "bag.fill",
        /* 「小店与卡包」是 2026-10-12 后台 me-page.json 里那一行的 label，
           上面「卡包」那一行已经按用户要求去掉了，这里补上全称的兜底映射 */
        "小店与卡包": "bag.fill",
        "钱包": "wallet.pass.fill",
        "收付款": "yensign.circle.fill",
        "账单": "list.bullet.rectangle.fill",
        "零钱": "yensign.circle.fill",
        "银行卡": "creditcard.fill",
        "支付密码": "lock.fill",
        "支付分": "star.circle.fill",
        "会员中心": "crown.fill",
        "我的等级": "chart.bar.fill",
        "安全分": "checkmark.shield.fill",
        "实名认证": "person.text.rectangle.fill",
        "附近的人": "location.fill",
        "存储空间": "internaldrive.fill",
        "状态": "face.smiling.fill",
        "搜一搜": "magnifyingglass",
        "扫一扫": "qrcode.viewfinder",
        "帮助与反馈": "questionmark.circle.fill",
        "关于": "info.circle.fill",
        "设置": "gearshape.fill",
        "新的朋友": "person.badge.plus",
        "群聊": "person.3.fill",
        "仅聊天的朋友": "bubble.left.and.bubble.right.fill",
        "标签": "tag.fill",
        "企业联系人": "briefcase.fill",
        "我的企业": "briefcase.fill"
    ]

    static func sf(action: String?, label: String) -> String {
        if let a = action, let s = byAction[a] { return s }
        for (k, v) in byLabel where label.contains(k) { return v }
        return "circle.grid.2x2.fill"
    }
}
