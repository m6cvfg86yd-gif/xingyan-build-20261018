import Foundation

/* ============================================================
   经典表情（微信 / QQ 那套 [微笑] [撇嘴] [色] …）

   做的事：
     · 表情面板第一屏就是这一套（105 个），点一下直接进输入框
     · 打字打 [微笑] 这种码，发出去的时候自动变成对应的表情
     · 别人发来（或历史里）带这种码的文字，显示的时候也自动变表情

   ⚠ 这里用的是系统自带的 emoji 字符，不是腾讯那张脸的图 ——
     那套图是腾讯的版权素材，成套装进包里就是「盗图」，
     上架/内测被投诉就是下架的由头（用户自己也在意这个）。
     真要那张脸的图，后台「表情」里上传一套自己的表情包（我的表情）就行，
     码表这套逻辑不用动。
   ============================================================ */

struct ClassicEmoji {
    /// 带方括号的码：[微笑]
    let code: String
    /// 对应显示的表情
    let glyph: String
}

enum ClassicEmojiSet {
    /// 全部经典表情（顺序照微信表情面板那一屏一屏排：8 个一行）
    static let all: [ClassicEmoji] = [
        ClassicEmoji(code: "[微笑]", glyph: "🙂"),
        ClassicEmoji(code: "[撇嘴]", glyph: "😕"),
        ClassicEmoji(code: "[色]", glyph: "😍"),
        ClassicEmoji(code: "[发呆]", glyph: "😳"),
        ClassicEmoji(code: "[得意]", glyph: "😏"),
        ClassicEmoji(code: "[流泪]", glyph: "😢"),
        ClassicEmoji(code: "[害羞]", glyph: "☺️"),
        ClassicEmoji(code: "[闭嘴]", glyph: "🤐"),

        ClassicEmoji(code: "[睡]", glyph: "😴"),
        ClassicEmoji(code: "[大哭]", glyph: "😭"),
        ClassicEmoji(code: "[尴尬]", glyph: "😅"),
        ClassicEmoji(code: "[发怒]", glyph: "😡"),
        ClassicEmoji(code: "[调皮]", glyph: "😛"),
        ClassicEmoji(code: "[呲牙]", glyph: "😁"),
        ClassicEmoji(code: "[惊讶]", glyph: "😲"),
        ClassicEmoji(code: "[难过]", glyph: "😔"),

        ClassicEmoji(code: "[酷]", glyph: "😎"),
        ClassicEmoji(code: "[冷汗]", glyph: "😰"),
        ClassicEmoji(code: "[抓狂]", glyph: "😫"),
        ClassicEmoji(code: "[吐]", glyph: "🤢"),
        ClassicEmoji(code: "[偷笑]", glyph: "🤭"),
        ClassicEmoji(code: "[可爱]", glyph: "😊"),
        ClassicEmoji(code: "[白眼]", glyph: "🙄"),
        ClassicEmoji(code: "[傲慢]", glyph: "😤"),

        ClassicEmoji(code: "[饥饿]", glyph: "🤤"),
        ClassicEmoji(code: "[困]", glyph: "😪"),
        ClassicEmoji(code: "[惊恐]", glyph: "😱"),
        ClassicEmoji(code: "[流汗]", glyph: "😅"),
        ClassicEmoji(code: "[憨笑]", glyph: "😃"),
        ClassicEmoji(code: "[大兵]", glyph: "🫡"),
        ClassicEmoji(code: "[奋斗]", glyph: "💪"),
        ClassicEmoji(code: "[咒骂]", glyph: "🤬"),

        ClassicEmoji(code: "[疑问]", glyph: "🤔"),
        ClassicEmoji(code: "[嘘]", glyph: "🤫"),
        ClassicEmoji(code: "[晕]", glyph: "😵"),
        ClassicEmoji(code: "[折磨]", glyph: "😩"),
        ClassicEmoji(code: "[衰]", glyph: "😞"),
        ClassicEmoji(code: "[骷髅]", glyph: "💀"),
        ClassicEmoji(code: "[敲打]", glyph: "🔨"),
        ClassicEmoji(code: "[再见]", glyph: "👋"),

        ClassicEmoji(code: "[擦汗]", glyph: "😓"),
        ClassicEmoji(code: "[抠鼻]", glyph: "🤧"),
        ClassicEmoji(code: "[鼓掌]", glyph: "👏"),
        ClassicEmoji(code: "[糗大了]", glyph: "😳"),
        ClassicEmoji(code: "[坏笑]", glyph: "😏"),
        ClassicEmoji(code: "[左哼哼]", glyph: "😤"),
        ClassicEmoji(code: "[右哼哼]", glyph: "😤"),
        ClassicEmoji(code: "[哈欠]", glyph: "🥱"),

        ClassicEmoji(code: "[鄙视]", glyph: "😒"),
        ClassicEmoji(code: "[委屈]", glyph: "🥺"),
        ClassicEmoji(code: "[快哭了]", glyph: "😢"),
        ClassicEmoji(code: "[阴险]", glyph: "😏"),
        ClassicEmoji(code: "[亲亲]", glyph: "😘"),
        ClassicEmoji(code: "[吓]", glyph: "😨"),
        ClassicEmoji(code: "[可怜]", glyph: "🥺"),
        ClassicEmoji(code: "[菜刀]", glyph: "🔪"),

        ClassicEmoji(code: "[西瓜]", glyph: "🍉"),
        ClassicEmoji(code: "[啤酒]", glyph: "🍺"),
        ClassicEmoji(code: "[篮球]", glyph: "🏀"),
        ClassicEmoji(code: "[乒乓]", glyph: "🏓"),
        ClassicEmoji(code: "[咖啡]", glyph: "☕"),
        ClassicEmoji(code: "[饭]", glyph: "🍚"),
        ClassicEmoji(code: "[猪头]", glyph: "🐷"),
        ClassicEmoji(code: "[玫瑰]", glyph: "🌹"),

        ClassicEmoji(code: "[凋谢]", glyph: "🥀"),
        ClassicEmoji(code: "[示爱]", glyph: "😘"),
        ClassicEmoji(code: "[爱心]", glyph: "❤️"),
        ClassicEmoji(code: "[心碎]", glyph: "💔"),
        ClassicEmoji(code: "[蛋糕]", glyph: "🎂"),
        ClassicEmoji(code: "[闪电]", glyph: "⚡"),
        ClassicEmoji(code: "[炸弹]", glyph: "💣"),
        ClassicEmoji(code: "[刀]", glyph: "🗡️"),

        ClassicEmoji(code: "[足球]", glyph: "⚽"),
        ClassicEmoji(code: "[瓢虫]", glyph: "🐞"),
        ClassicEmoji(code: "[便便]", glyph: "💩"),
        ClassicEmoji(code: "[月亮]", glyph: "🌙"),
        ClassicEmoji(code: "[太阳]", glyph: "☀️"),
        ClassicEmoji(code: "[礼物]", glyph: "🎁"),
        ClassicEmoji(code: "[拥抱]", glyph: "🤗"),
        ClassicEmoji(code: "[强]", glyph: "👍"),

        ClassicEmoji(code: "[弱]", glyph: "👎"),
        ClassicEmoji(code: "[握手]", glyph: "🤝"),
        ClassicEmoji(code: "[胜利]", glyph: "✌️"),
        ClassicEmoji(code: "[抱拳]", glyph: "🙏"),
        ClassicEmoji(code: "[勾引]", glyph: "😉"),
        ClassicEmoji(code: "[拳头]", glyph: "👊"),
        ClassicEmoji(code: "[差劲]", glyph: "👎"),
        ClassicEmoji(code: "[爱你]", glyph: "🥰"),

        ClassicEmoji(code: "[NO]", glyph: "🙅"),
        ClassicEmoji(code: "[OK]", glyph: "👌"),
        ClassicEmoji(code: "[爱情]", glyph: "💑"),
        ClassicEmoji(code: "[飞吻]", glyph: "😘"),
        ClassicEmoji(code: "[跳跳]", glyph: "🕺"),
        ClassicEmoji(code: "[发抖]", glyph: "🥶"),
        ClassicEmoji(code: "[怄火]", glyph: "😤"),
        ClassicEmoji(code: "[转圈]", glyph: "🌀"),

        ClassicEmoji(code: "[磕头]", glyph: "🙇"),
        ClassicEmoji(code: "[回头]", glyph: "🔄"),
        ClassicEmoji(code: "[跳绳]", glyph: "🏃"),
        ClassicEmoji(code: "[挥手]", glyph: "👋"),
        ClassicEmoji(code: "[激动]", glyph: "🤩"),
        ClassicEmoji(code: "[街舞]", glyph: "🕺"),
        ClassicEmoji(code: "[献吻]", glyph: "😘"),
        ClassicEmoji(code: "[饭团]", glyph: "🍙"),

        ClassicEmoji(code: "[左太极]", glyph: "☯️"),
        ClassicEmoji(code: "[右太极]", glyph: "☯️"),

        /* 微信后来加的几个常用的，一起给上（不占上面那一屏） */
        ClassicEmoji(code: "[奸笑]", glyph: "😏"),
        ClassicEmoji(code: "[机智]", glyph: "🤓"),
        ClassicEmoji(code: "[耶]", glyph: "✌️"),
        ClassicEmoji(code: "[加油]", glyph: "💪"),
        ClassicEmoji(code: "[汗]", glyph: "😅"),
        ClassicEmoji(code: "[皱眉]", glyph: "🙁"),
        ClassicEmoji(code: "[吃瓜]", glyph: "🍉"),
        ClassicEmoji(code: "[握手言和]", glyph: "🤝"),

        /* 微信后来那一批（捂脸 / 旺柴 / 裂开 …）：主要是让「打字打码」也认得 */
        ClassicEmoji(code: "[捂脸]", glyph: "🤦"),
        ClassicEmoji(code: "[嘿哈]", glyph: "😆"),
        ClassicEmoji(code: "[旺柴]", glyph: "🐶"),
        ClassicEmoji(code: "[让我看看]", glyph: "👀"),
        ClassicEmoji(code: "[叹气]", glyph: "😮‍💨"),
        ClassicEmoji(code: "[裂开]", glyph: "🫠"),
        ClassicEmoji(code: "[无语]", glyph: "😑"),
        ClassicEmoji(code: "[哇]", glyph: "😮"),
        ClassicEmoji(code: "[打脸]", glyph: "😖"),
        ClassicEmoji(code: "[哇塞]", glyph: "🤩"),
        ClassicEmoji(code: "[Emm]", glyph: "🤨"),
        ClassicEmoji(code: "[社会社会]", glyph: "🫡"),
        ClassicEmoji(code: "[好的]", glyph: "👌"),
        ClassicEmoji(code: "[666]", glyph: "💯"),
        ClassicEmoji(code: "[冲鸭]", glyph: "🏃"),
        ClassicEmoji(code: "[庆祝]", glyph: "🎉"),
        ClassicEmoji(code: "[烟花]", glyph: "🎆"),
        ClassicEmoji(code: "[破涕为笑]", glyph: "😂"),
        ClassicEmoji(code: "[思考]", glyph: "🤔"),
        ClassicEmoji(code: "[比心]", glyph: "🫶"),
        ClassicEmoji(code: "[一起加油]", glyph: "✊"),
        ClassicEmoji(code: "[苦涩]", glyph: "😣"),
        ClassicEmoji(code: "[睡啦]", glyph: "😴"),
        ClassicEmoji(code: "[摊手]", glyph: "🤷"),
        ClassicEmoji(code: "[握草]", glyph: "😱"),
        ClassicEmoji(code: "[赞]", glyph: "👍"),
        ClassicEmoji(code: "[踩]", glyph: "👎"),
        ClassicEmoji(code: "[给力]", glyph: "💪"),
        ClassicEmoji(code: "[no]", glyph: "🙅"),
        ClassicEmoji(code: "[ok]", glyph: "👌"),
        ClassicEmoji(code: "[呵呵]", glyph: "🙂"),
        ClassicEmoji(code: "[哈哈]", glyph: "😄"),
        ClassicEmoji(code: "[微笑脸]", glyph: "🙂"),
        ClassicEmoji(code: "[躺平]", glyph: "🛌"),
        ClassicEmoji(code: "[溜了]", glyph: "🏃"),
        ClassicEmoji(code: "[石化]", glyph: "😵"),
        ClassicEmoji(code: "[灵魂出窍]", glyph: "👻"),
        ClassicEmoji(code: "[我酸了]", glyph: "🍋"),
        ClassicEmoji(code: "[吃柠檬]", glyph: "🍋"),
        ClassicEmoji(code: "[菜]", glyph: "🥬"),
        ClassicEmoji(code: "[卑微]", glyph: "🙇"),
        ClassicEmoji(code: "[快跑]", glyph: "🏃"),
        ClassicEmoji(code: "[委屈巴巴]", glyph: "🥺")
    ]

    private static let byCode: [String: String] = {
        var m: [String: String] = [:]
        for e in all { m[e.code] = e.glyph }
        return m
    }()

    /// [微笑] → 🙂（不认识的码返回 nil）
    static func glyph(for code: String) -> String? { byCode[code] }

    /// 把一段文字里所有认识的 [xx] 换成表情，别的原样保留
    static func expand(_ text: String) -> String {
        guard text.contains("["), text.contains("]") else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "[",
               let close = text[i...].firstIndex(of: "]"),
               text.distance(from: i, to: close) <= 6,
               let glyph = byCode[String(text[i...close])] {
                out += glyph
                i = text.index(after: close)
                continue
            }
            out.append(text[i])
            i = text.index(after: i)
        }
        return out
    }
}

/* ============================================================
   系统表情按主题分组：腾讯那套表情多，光一屏平铺翻起来累 ——
   这里分成心情 / 手势 / 人物 / 动物 / 美食 / 节日 / 符号，一屏一屏滑。
   （用的都是系统自带的 emoji 字体，不涉及别人的图）
   ============================================================ */

enum EmojiThemes {
    struct Theme {
        let name: String
        let list: [String]
    }

    static let all: [Theme] = [
        Theme(name: "心情", list: [
            "😀", "😃", "😄", "😁", "😆", "😅", "😂", "🤣", "🥲", "☺️", "😊", "😇", "🙂", "🙃", "😉", "😌",
            "😍", "🥰", "😘", "😗", "😙", "😚", "😋", "😛", "😝", "😜", "🤪", "🤨", "🧐", "🤓", "😎", "🥸",
            "🤩", "🥳", "😏", "😒", "😞", "😔", "😟", "😕", "🙁", "☹️", "😣", "😖", "😫", "😩", "🥺", "😢",
            "😭", "😤", "😠", "😡", "🤬", "🤯", "😳", "🥵", "🥶", "😱", "😨", "😰", "😥", "😓", "🤗", "🤔",
            "🤭", "🤫", "🤥", "😶", "😐", "😑", "😬", "🙄", "😯", "😦", "😧", "😮", "😲", "🥱", "😴", "🤤",
            "😪", "😵", "🤐", "🥴", "🤢", "🤮", "🤧", "😷", "🤒", "🤕", "🤑", "🤠", "😈", "👿", "💩", "👻"
        ]),

        Theme(name: "手势", list: [
            "👋", "🤚", "🖐", "✋", "🖖", "👌", "🤌", "🤏", "✌️", "🤞", "🫰", "🤟", "🤘", "🤙", "👈", "👉",
            "👆", "👇", "☝️", "👍", "👎", "✊", "👊", "🤛", "🤜", "👏", "🫶", "🙌", "👐", "🤲", "🤝", "🙏",
            "✍️", "💅", "🤳", "💪", "🦾", "🦵", "🦶", "👂", "👃", "🫀", "🦷", "🦴", "👀", "👁", "👅", "👄"
        ]),

        Theme(name: "人物", list: [
            "👶", "🧒", "👦", "👧", "🧑", "👱", "👨", "🧔", "👩", "🧓", "👴", "👵", "🙍", "🙎", "🙅", "🙆",
            "💁", "🙋", "🧏", "🙇", "🤦", "🤷", "👮", "🕵", "💂", "👷", "🤴", "👸", "👳", "👲", "🧕", "🤵",
            "👰", "🤰", "🤱", "🎅", "🤶", "🦸", "🦹", "🧙", "🧚", "🧛", "🧜", "🧝", "🧞", "🧟", "💆", "💇",
            "🚶", "🧍", "🧎", "🏃", "💃", "🕺", "👯", "🧖", "🧗", "🏇", "🏂", "🏄", "🚣", "🏊", "🏋", "🚴"
        ]),

        Theme(name: "动物", list: [
            "🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼", "🐨", "🐯", "🦁", "🐮", "🐷", "🐽", "🐸", "🐵",
            "🙈", "🙉", "🙊", "🐒", "🐔", "🐧", "🐦", "🐤", "🐣", "🐥", "🦆", "🦅", "🦉", "🦇", "🐺", "🐗",
            "🐴", "🦄", "🐝", "🐛", "🦋", "🐌", "🐞", "🐜", "🦗", "🕷", "🦂", "🐢", "🐍", "🦎", "🦖", "🦕",
            "🐙", "🦑", "🦐", "🦞", "🦀", "🐡", "🐠", "🐟", "🐬", "🐳", "🐋", "🦈", "🐊", "🐅", "🐆", "🦓"
        ]),

        Theme(name: "美食", list: [
            "🍏", "🍎", "🍐", "🍊", "🍋", "🍌", "🍉", "🍇", "🍓", "🫐", "🍈", "🍒", "🍑", "🥭", "🍍", "🥥",
            "🥝", "🍅", "🥑", "🥦", "🥬", "🥒", "🌶", "🌽", "🥕", "🧄", "🧅", "🥔", "🍞", "🥐", "🥨", "🧀",
            "🥚", "🍳", "🥞", "🥓", "🥩", "🍗", "🍖", "🌭", "🍔", "🍟", "🍕", "🥪", "🌮", "🌯", "🥗", "🍝",
            "🍜", "🍲", "🍛", "🍣", "🍱", "🥟", "🍤", "🍙", "🍚", "🍘", "🍥", "🍢", "🍡", "🍧", "🍨", "🍦",
            "🥧", "🧁", "🍰", "🎂", "🍮", "🍭", "🍬", "🍫", "🍿", "🍩", "🍪", "🌰", "🥜", "🍯", "🥛", "🍼",
            "☕", "🍵", "🧃", "🥤", "🧋", "🍶", "🍺", "🍻", "🥂", "🍷", "🥃", "🍸", "🍹", "🍾", "🧊", "🍽"
        ]),

        Theme(name: "节日", list: [
            "🎉", "🎊", "🎈", "🎁", "🎀", "🎂", "🕯", "🎃", "🎄", "🎋", "🎍", "🎑", "🧧", "🎇", "🎆", "✨",
            "🎐", "🎏", "🎎", "🧨", "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎", "💔", "💕", "💞",
            "💓", "💗", "💖", "💘", "💝", "💟", "☮️", "🕉", "☸️", "✡️", "🔯", "🕎", "☯️", "⛎", "♈", "♉",
            "♊", "♋", "♌", "♍", "♎", "♏", "♐", "♑", "♒", "♓", "🆔", "⚛️", "🉑", "💮", "🉐", "㊙️"
        ]),

        Theme(name: "符号", list: [
            "➕", "➖", "➗", "✖️", "♾️", "💲", "💱", "™️", "©️", "®️", "〰️", "➰", "➿", "🔚", "🔙", "🔛",
            "🔝", "🔜", "✔️", "☑️", "🔘", "🔴", "🟠", "🟡", "🟢", "🔵", "🟣", "⚫", "⚪", "🟤", "🔺", "🔻",
            "🔸", "🔹", "🔶", "🔷", "🔳", "🔲", "▪️", "▫️", "◾", "◽", "◼️", "◻️", "🟥", "🟧", "🟨", "🟩",
            "🟦", "🟪", "⬛", "⬜", "🟫", "🔈", "🔇", "🔉", "🔊", "🔔", "🔕", "📣", "📢", "💬", "💭", "🗯",
            "♠️", "♣️", "♥️", "♦️", "🃏", "🎴", "🀄", "❌", "⭕", "🛑", "⛔", "📛", "🚫", "💯", "❗", "❓"
        ])
    ]
}

/* ============================================================
   内置表情包（「我的」那一屏里一包一包摆的）
   都是系统 emoji 组的包，一包 16~30 个；想加图片表情包就走表情商店。
   ============================================================ */

struct BuiltinPack {
    let id: String
    let name: String
    let icon: String
    let stickers: [String]
}

enum BuiltinPacks {
    static let all: [BuiltinPack] = [
        BuiltinPack(id: "b1", name: "小黄脸", icon: "😀", stickers: [
            "😀", "😃", "😄", "😁", "😆", "😅", "😂", "🤣", "😊", "😇", "🙂", "😉", "😍", "🥰", "😘", "😋",
            "😜", "🤪", "🤗", "🤔", "🤨", "😐", "😏", "😒", "🙄", "😴", "😷", "🤒", "🥳", "😎", "🤓", "😭"
        ]),
        BuiltinPack(id: "b2", name: "手势", icon: "👍", stickers: [
            "👍", "👎", "👌", "✌️", "🤞", "🤟", "🤘", "👏", "🙌", "🙏", "💪", "👊", "✊", "🤝", "👋", "☝️",
            "👆", "👇", "👈", "👉", "🖐️", "✋", "🤙", "🫰"
        ]),
        BuiltinPack(id: "b3", name: "爱心", icon: "❤️", stickers: [
            "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "💔", "❣️", "💕", "💞", "💓", "💗", "💖", "💘",
            "💝", "💟", "😻", "🫶"
        ]),
        BuiltinPack(id: "b4", name: "动物", icon: "🐱", stickers: [
            "🐱", "🐶", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼", "🐨", "🐯", "🦁", "🐮", "🐷", "🐸", "🐵", "🐔",
            "🐧", "🐦", "🦄", "🐝"
        ]),
        BuiltinPack(id: "b5", name: "猫猫狗狗", icon: "🐶", stickers: [
            "🐶", "🐱", "🐕", "🐈", "🐩", "🦮", "🐾", "🐇", "🐹", "🐭", "🐿️", "🦔", "🐻", "🐼", "🐨", "🦊"
        ]),
        BuiltinPack(id: "b6", name: "开心日常", icon: "🎉", stickers: [
            "🎉", "🎊", "🎁", "🎂", "🍰", "🍺", "🥳", "🍀", "🌈", "☀️", "🌙", "⚡", "🔥", "✨", "💯", "🆗",
            "🙆", "🙅", "💃", "🕺"
        ]),
        BuiltinPack(id: "b7", name: "美食", icon: "🍜", stickers: [
            "🍜", "🍲", "🍛", "🍣", "🍱", "🥟", "🍤", "🍙", "🍚", "🍘", "🍥", "🍢", "🍡", "🍧", "🍨", "🍦",
            "🥧", "🧁", "🍭", "🍬", "🍫", "🍿", "🍩", "🍪"
        ]),
        BuiltinPack(id: "b8", name: "饮料甜点", icon: "🧋", stickers: [
            "🧋", "🥛", "🍼", "🍵", "☕", "🧃", "🥤", "🍶", "🍺", "🍻", "🥂", "🍷", "🥃", "🍸", "🍹", "🍾",
            "🧊", "🍽", "🥄", "🍴"
        ]),
        BuiltinPack(id: "b9", name: "天气自然", icon: "⛅", stickers: [
            "☀️", "🌤", "⛅", "🌥", "☁️", "🌦", "🌧", "⛈", "🌩", "🌨", "❄️", "☃️", "⛄", "🌬", "💨", "🌈",
            "☔", "💧", "🌊", "⭐"
        ]),
        BuiltinPack(id: "b10", name: "节日", icon: "🎄", stickers: [
            "🎄", "🎃", "🎋", "🎍", "🎑", "🧧", "🎇", "🎆", "🎐", "🎏", "🎎", "🧨", "🕯", "🎈", "🎀", "🥮"
        ]),
        BuiltinPack(id: "b11", name: "星座", icon: "♈", stickers: [
            "♈", "♉", "♊", "♋", "♌", "♍", "♎", "♏", "♐", "♑", "♒", "♓", "⛎", "🔮", "🌠", "🌌"
        ]),
        BuiltinPack(id: "b12", name: "运动", icon: "⚽", stickers: [
            "⚽", "🏀", "🏈", "⚾", "🎾", "🏐", "🏉", "🎱", "🏓", "🏸", "🥊", "🥋", "⛳", "⛸", "🎿", "🛷",
            "🏂", "🏋️", "🤸", "🚴", "🏊", "🏃", "🧘", "🤺"
        ]),
        BuiltinPack(id: "b13", name: "职业人物", icon: "👮", stickers: [
            "👮", "🕵️", "💂", "👷", "🧑‍⚕️", "🧑‍🍳", "🧑‍🏫", "🧑‍🎓", "🧑‍💻", "🧑‍🔧", "🧑‍🌾", "🧑‍✈️", "🧑‍🚀", "🧑‍🚒", "🤴", "👸",
            "🦸", "🦹", "🧙", "🧚"
        ]),
        BuiltinPack(id: "b14", name: "表情符号", icon: "💯", stickers: [
            "💯", "❗", "❓", "‼️", "⁉️", "✅", "❌", "⭕", "🚫", "⚠️", "🔔", "📢", "📣", "💬", "💭", "🎵",
            "🎶", "💤", "♨️", "🔰"
        ])
    ]
}
