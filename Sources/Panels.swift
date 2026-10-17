import SwiftUI

var panelH: CGFloat { L.v(198, 53, 240) }

/* ============================================================ 表情面板 */

let emojiAll: [String] = [
    "😄", "😖", "😍", "😳", "😎", "😭", "😚", "🤐",
    "😴", "😢", "😅", "😡", "😛", "😁", "😲", "😔",
    "😎", "😰", "😫", "🤢", "🤭", "😊", "🙄", "😤",
    "🤤", "😪", "😱", "😅", "😃", "🫡", "💪", "🤬",

    "🤔", "🤫", "😵", "😩", "😞", "💀", "🔨", "👋",
    "😅", "🤧", "👏", "😳", "😏", "😤", "😤", "🥱",
    "😒", "🥺", "😢", "😏", "😘", "😨", "🥺", "🔪",
    "🍉", "🍺", "🏀", "🏓", "☕", "🍚", "🐷", "🌹",

    "🥀", "😘", "❤️", "💔", "🎂", "⚡", "💣", "🗡️",
    "⚽", "🐞", "💩", "🌙", "☀️", "🎁", "🤗", "👍",
    "👎", "🤝", "✌️", "🙏", "😉", "👊", "👌", "🕺",
    "🥶", "😤", "🌀", "🙇", "🔄", "🏃", "👋", "🤩",

    "👍", "👏", "🙏", "✌️", "❤️", "🌹", "🎁", "🎉",
    "🔥", "⭐", "🌈", "🎵", "☕", "🎂", "🧧", "☀️",
    "🌙", "☁️", "🌧️", "❄️", "🐱", "🐶", "🐼", "🐰",
    "🐷", "🐵", "🐯", "🐟", "🍎", "🍓", "🍉", "🍺"
]

/* ============================================================ 我们自己的表情（OpenMoji 那套，后台不用配） */
enum EmojiSet {
    static let names = ["smile", "grin", "laugh", "joy", "rofl", "wink", "love", "kiss",
                        "cool", "shy", "smirk", "think", "wow", "doubt", "sweat", "shh",
                        "cry", "sob", "angry", "sleep", "pray", "clap", "ok", "thumb",
                        "heart", "fire", "gift", "redpacket", "party", "money"]
    static var ours: [String] { names }
    static func url(_ i: Int) -> String { "/uploads/emj2-" + names[max(0, min(i, names.count - 1))] + ".png" }
}

/// 表情小图的内存缓存：一包两三百张，滑上滑下不该每次都重新下一遍
@MainActor
final class StickerImageCache {
    static let shared = StickerImageCache()
    private var store: [String: UIImage] = [:]
    func get(_ key: String) -> UIImage? { store[key] }
    func put(_ key: String, _ image: UIImage) {
        if store.count > 600 { store.removeAll() }   // 简单兜底，别把内存撑爆
        store[key] = image
    }
}

/// 表情小图（九宫格里的一个）
struct StickerThumb: View {
    let url: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            if let cached = StickerImageCache.shared.get(url) { image = cached; return }
            guard let u = API.shared.assetURL(url) else { return }
            if let data = try? await API.shared.assetData(u), let img = UIImage(data: data) {
                StickerImageCache.shared.put(url, img)
                image = img
            }
        }
    }
}

struct EmojiPanel: View {
    @Binding var draft: String
    var onSend: () -> Void
    var onDelete: () -> Void
    /// 文字表情要插到聊天输入框的光标处，不能直接追加到草稿末尾
    var onInsert: ((String) -> Void)? = nil
    /// 点我们自己的表情：以图片消息发出去（系统 emoji 那套一个都没动，只是多一页）
    var onSendSticker: ((String) -> Void)? = nil
    /// 「＋」：去表情商店加表情包（和微信面板里那个 ＋ 一样）
    var onOpenStore: (() -> Void)? = nil
    /// 「拍摄表情」：用相机拍一张，直接加进「我添加的表情」（微信那个拍摄表情）
    var onCaptureSticker: (() -> Void)? = nil
    /// 我在表情商店里添加过的表情包 / 单个表情（「我的」那一屏摆在最上面）
    var mine: StickerMine? = nil

    /// 现在在哪一屏：0 最近使用 / 1 经典表情 / 2 系统表情 / 3 我的表情
    @State private var tab = 1
    /// 最近用过的表情（存在本机；微信面板第一屏就是它）
    @State private var recent: [String] = EmojiPanel.loadRecent()
    /// 我添加过的表情包（内置的 + 图库里下载的）：面板底下那排一个包一个按钮
    @State private var installed: [PanelPack] = []
    /// 表情图库（服务器 /emoji/packs.json）
    @ObservedObject private var catalog = StickerCatalog.shared

    /// 「我的」那一屏排在第几个（前面是 最近 / 经典 / 系统 + 我装的每一包）
    private var mineTab: Int { 3 + installed.count }

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 0), count: 8)
    private static let recentKey = "emoji.recent"

    private static func loadRecent() -> [String] {
        (UserDefaults.standard.array(forKey: recentKey) as? [String]) ?? []
    }

    /// 用了一个表情：写进输入框 + 记一笔「最近使用」（最多留 24 个）
    private func use(_ glyph: String) {
        if let onInsert {
            onInsert(glyph)
        } else {
            draft += glyph
        }
        var list = recent.filter { $0 != glyph }
        list.insert(glyph, at: 0)
        if list.count > 24 { list = Array(list.prefix(24)) }
        recent = list
        UserDefaults.standard.set(list, forKey: Self.recentKey)
    }

    /// 九宫格里的一格
    private func tile(_ glyph: String) -> some View {
        Button { use(glyph) } label: {
            Text(glyph)
                .font(pf(L.v(23, 6.6, 28)))
                .frame(maxWidth: .infinity)
                .frame(height: panelH * 0.80 / 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 一屏表情：8 个一行，能上下滑
    private func emojiGrid(_ list: [String]) -> some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: cols, spacing: 0) {
                ForEach(list.indices, id: \.self) { i in tile(list[i]) }
            }
            .padding(.horizontal, L.v(6, 2, 10))
            .padding(.top, L.v(6, 2, 10))
            .padding(.bottom, 4)
        }
    }

    /// 经典表情（微信/QQ 那套 [微笑]…）
    private var classicPage: some View {
        var seen = Set<String>()
        let glyphs = ClassicEmojiSet.all.map { $0.glyph }.filter { seen.insert($0).inserted }
        return emojiGrid(glyphs)
    }

    /// 系统表情：按主题分块（心情 / 手势 / 人物 / 动物 / 美食 / 节日 / 符号）
    private var systemPage: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(EmojiThemes.all.indices, id: \.self) { t in
                    let theme = EmojiThemes.all[t]
                    Text(theme.name)
                        .font(pf(11.5))
                        .foregroundColor(C.subLabel)
                        .padding(.horizontal, L.v(10, 3.2, 14))
                        .padding(.top, t == 0 ? 8 : 12)
                        .padding(.bottom, 2)
                    LazyVGrid(columns: cols, spacing: 0) {
                        ForEach(theme.list.indices, id: \.self) { i in tile(theme.list[i]) }
                    }
                    .padding(.horizontal, L.v(6, 2, 10))
                }
            }
            .padding(.bottom, 6)
        }
    }

    /// 最近使用
    @ViewBuilder
    private var recentPage: some View {
        if recent.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 24, weight: .light))
                    .foregroundColor(C.subLabel)
                Text(Tr("用过的表情会出现在这里"))
                    .font(pf(12.5))
                    .foregroundColor(C.subLabel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            emojiGrid(recent)
        }
    }

    /// 我的表情：我在商店加的那些 + 内置的一包包 + 我们自己的图片表情 + 「＋」去商店
    private var minePage: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                /* 我在表情商店里加的表情包（有才显示） */
                if let packs = mine?.packList, !packs.isEmpty {
                    ForEach(packs.indices, id: \.self) { i in
                        packTitle(packs[i].icon ?? "😀", packs[i].name ?? Tr("表情包"))
                        stickerRow(packs[i].stickers ?? [])
                    }
                }
                /* 我自己加的单个表情 */
                if let singles = mine?.singleList, !singles.isEmpty {
                    packTitle("⭐", Tr("我添加的表情"))
                    stickerRow(singles)
                }
                /* 我们自己的图片表情 */
                packTitle("🖼", Tr("我们的表情"))
                imageStickerRow
                /* 最后是「＋」和「📷」：商店挑表情包 / 拍一张当表情（微信也是这样） */
                HStack(spacing: 14) {
                    Button { onOpenStore?() } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(C.hairline, lineWidth: 1)
                                .frame(width: L.v(46, 13, 50), height: L.v(46, 13, 50))
                            Image(systemName: "plus")
                                .font(.system(size: L.v(20, 5.6, 23), weight: .light))
                                .foregroundColor(C.subLabel)
                        }
                        .frame(height: panelH * 0.80 / 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    /* 「拍摄表情」以前就在这儿（「我的」那一屏最底下）—— 2026-10-16 挪到
                       底部标签栏了（任何一屏都看得见），这里不再重复放一个。 */
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, L.v(6, 2, 10))
                .padding(.top, 6)
            }
            .padding(.top, L.v(2, 0.6, 4))
            .padding(.bottom, 6)
        }
    }

    /// 一包表情的小标题（图标 + 名字）
    private func packTitle(_ icon: String, _ name: String) -> some View {
        HStack(spacing: 6) {
            Text(icon).font(pf(13))
            Text(name).font(pf(11.5)).foregroundColor(C.subLabel)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, L.v(10, 3.2, 14))
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    /// 纯 emoji 的一包（点一下进输入框）
    private func emojiRow(_ list: [String]) -> some View {
        LazyVGrid(columns: cols, spacing: 0) {
            ForEach(list.indices, id: \.self) { i in tile(list[i]) }
        }
        .padding(.horizontal, L.v(6, 2, 10))
    }

    /// 商店里来的表情：图片的发图片消息，emoji 的直接进输入框
    private func stickerRow(_ list: [String]) -> some View {
        LazyVGrid(columns: cols, spacing: 0) {
            ForEach(list.indices, id: \.self) { i in
                Button { tapSticker(list[i]) } label: {
                    Group {
                        if isImageSticker(list[i]) {
                            StickerThumb(url: list[i])
                        } else {
                            Text(list[i]).font(pf(L.v(23, 6.6, 28)))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: panelH * 0.80 / 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, L.v(6, 2, 10))
    }

    /// 我们自己的图片表情（5 个一行，点一下直接发）
    private var imageStickerRow: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 5), spacing: 0) {
            ForEach(EmojiSet.ours.indices, id: \.self) { i in
                Button { onSendSticker?(EmojiSet.url(i)) } label: {
                    StickerThumb(url: EmojiSet.url(i))
                        .frame(maxWidth: .infinity)
                        .frame(height: panelH * 0.80 / 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, L.v(6, 2, 10))
    }

    private func tapSticker(_ s: String) {
        guard isImageSticker(s) else { use(s); return }
        /* 服务器只认 /emoji/... 这种本站路径，图库里存的是 emoji/ap1/1.png，补个斜杠 */
        let path = (s.hasPrefix("http") || s.hasPrefix("/")) ? s : "/" + s
        onSendSticker?(path)
    }

    /// 这一条是不是图片表情（本站图库 /emoji/…、老的上传图 /uploads/…、或者外链）
    private func isImageSticker(_ s: String) -> Bool {
        s.hasPrefix("http") || s.hasPrefix("/uploads") || s.hasPrefix("/emoji") || s.hasPrefix("emoji/")
    }

    /// 底下那排标签里的一个（选中是绿色 + 一圈淡绿底）
    private func tabButton(_ i: Int, _ title: String, _ symbol: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) { tab = i }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: L.v(16, 4.6, 19), weight: .medium))
                .foregroundColor(tab == i ? C.green : C.subLabel)
                .frame(width: L.v(34, 10, 38), height: L.v(28, 8, 32))
                .background(Circle().fill(tab == i ? C.green.opacity(0.12) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    /// 底下那排里的一个「表情包」按钮（整张表情脸当图标，选中带绿圈）
    private func packTabButton(_ i: Int, _ pack: PanelPack) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) { tab = i }
        } label: {
            Group {
                if pack.isImage {
                    StickerThumb(url: pack.icon)
                } else {
                    Text(pack.icon).font(pf(L.v(17, 4.8, 20)))
                }
            }
                .frame(width: L.v(30, 9, 34), height: L.v(28, 8, 32))
                .background(Circle().fill(tab == i ? C.green.opacity(0.14) : Color.clear))
                .overlay(Circle().stroke(tab == i ? C.green.opacity(0.55) : Color.clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pack.name)
    }

    /// 某一包的表情：一包一屏（微信就是点底下哪包看哪包）
    private func packPage(_ pack: PanelPack) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if pack.isImage {
                    StickerThumb(url: pack.icon).frame(width: 18, height: 18)
                } else {
                    Text(pack.icon).font(pf(13))
                }
                Text(pack.name).font(pf(11.5)).foregroundColor(C.subLabel)
                Text("\(pack.stickers.count) 个")
                    .font(pf(11))
                    .foregroundColor(C.subLabel.opacity(0.8))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, L.v(10, 3.2, 14))
            .padding(.top, 8)
            .padding(.bottom, 2)
            if pack.isImage {
                /* 图片表情：点一下直接发出去。这一屏必须自带上下滑 ——
                   一包最多 240 张，不套 ScrollView 就全挤在一屏里，滑不动。 */
                ScrollView(showsIndicators: false) {
                    stickerRow(pack.stickers)
                }
            } else {
                emojiGrid(pack.stickers)
            }
        }
    }

    /// 我添加的表情包：内置的那些 + 图库里我下载的那些（顺序就是面板底下的顺序）
    private func buildInstalled() -> [PanelPack] {
        var out: [PanelPack] = []
        for b in StickerLib.mine {
            out.append(PanelPack(id: b.id, name: b.name, icon: b.icon,
                                 stickers: b.stickers, isImage: false))
        }
        for r in catalog.packs where StickerLib.isRemoteIn(r.id) {
            out.append(PanelPack(id: r.id, name: r.name, icon: r.icon,
                                 stickers: r.paths, isImage: true))
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $tab) {
                recentPage.tag(0)      // 最近使用
                classicPage.tag(1)     // 经典表情（[微笑] 那套）
                systemPage.tag(2)      // 系统表情
                /* 我装的每一包：一包一屏（微信就是这样，底下点哪包看哪包） */
                ForEach(installed.indices, id: \.self) { i in
                    packPage(installed[i]).tag(3 + i)
                }
                minePage.tag(mineTab)  // 我的（单个表情 + 我们的图片表情 + ＋）
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .onAppear {
                installed = buildInstalled()
                if tab > mineTab { tab = 1 }
            }

            HStack(spacing: 0) {
                /* 底下这一排就是微信面板底下那排：最近 / 经典 / 系统 / 我装的每一包 / 我的 / ＋ */
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: L.v(6, 2, 8)) {
                        tabButton(0, Tr("最近"), "clock")
                        tabButton(1, Tr("经典"), "face.smiling")
                        tabButton(2, Tr("系统"), "globe.asia.australia")
                        ForEach(installed.indices, id: \.self) { i in
                            packTabButton(3 + i, installed[i])
                        }
                        tabButton(mineTab, Tr("我的"), "star")
                        Button { onOpenStore?() } label: {
                            Image(systemName: "plus")
                                .font(.system(size: L.v(15, 4.4, 18), weight: .medium))
                                .foregroundColor(C.subLabel)
                                .frame(width: L.v(30, 9, 34), height: L.v(28, 8, 32))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Tr("表情商店"))

                        /* 2026-10-16 用户：「拍摄表情的那个选项放在表情最底部能点开的位置不要藏起来」——
                           以前它藏在「我的」那一屏的最底部（要滚到底才看得见），
                           现在直接摆在底部这一排标签里（「＋」右边）：**任何一屏都看得见、点得到**。
                           做成绿色小胶囊，一眼就知道能点。 */
                        Button { onCaptureSticker?() } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "camera.fill")
                                    .font(.system(size: L.v(13.5, 4.0, 16), weight: .medium))
                                Text(Tr("拍摄表情"))
                                    .font(pf(11.5, .medium))
                                    .lineLimit(1)
                            }
                            .foregroundColor(C.green)
                            .padding(.horizontal, 10)
                            .frame(height: L.v(28, 8, 32))
                            .background(Capsule().fill(C.green.opacity(0.12)))
                            .overlay(Capsule().stroke(C.green.opacity(0.38), lineWidth: 0.8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Tr("拍摄表情"))
                    }
                    .padding(.horizontal, 2)
                }
                Spacer()
                Button(action: onDelete) {
                    SVGIcon(markup: I.deleteKey, size: L.v(22, 6.4, 26), color: C.iconGray)
                        .frame(width: L.v(36, 10, 42), height: L.v(26, 7.4, 30))
                }
                .buttonStyle(.plain)
                Button(action: onSend) {
                    Text(Tr("发送"))
                        .font(pf(15))
                        .foregroundColor(draft.isEmpty ? C.subLabel : Color(hex: 0x0D0D0D))
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(draft.isEmpty ? Color.dyn(0xE8E8E8, 0x3A3A3C) : C.green)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, L.v(12, 3.8, 16))
            .frame(height: L.v(38, 10.4, 46))
        }
        .frame(height: panelH)
        .background(C.tabBg)
    }
}

/* ============================================================ ＋ 面板 */

struct PlusPanel: View {
    let items: [PlusItem]
    var onTap: (PlusItem) -> Void
    /// 长按某一个方块（返回 true = 这一下长按被接住了，那就不再触发点击）
    /// 目前只有「拍照」用它：长按 = 录一段视频（微信里长按拍照就是拍小视频）。
    var onLongPress: ((PlusItem) -> Bool)? = nil

    @State private var page = 0
    /// 手指正按在哪一格（画那个"按下缩小"的手感）
    @State private var pressed: String? = nil
    private let perPage = 8

    private var pages: [[PlusItem]] {
        stride(from: 0, to: max(1, items.count), by: perPage).map { start in
            Array(items[start..<min(start + perPage, items.count)])
        }
    }

    /// 每个动作一套主题色（后台没给颜色，就按动作分配；认不出来的用中性灰）
    private func tileColors(_ action: String?) -> [Color] {
        switch (action ?? "").lowercased() {
        case "photo":                    return [Color(hex: 0xFFB627), Color(hex: 0xF08600)]
        case "camera":                   return [C.green, C.green.opacity(0.78)]
        case "video", "videocall":       return [Color(hex: 0xFF8A73), Color(hex: 0xE2432E)]
        case "voice", "voicecall":       return [Color(hex: 0x64B5F6), Color(hex: 0x2A6BC4)]
        case "location":                 return [Color(hex: 0x4ECDC4), Color(hex: 0x1F8C86)]
        case "redpacket":                return [Color(hex: 0xF4634A), Color(hex: 0xC22A18)]
        case "gift":                     return [Color(hex: 0xFFC85C), Color(hex: 0xE09A18)]
        case "transfer":                 return [Color(hex: 0xFFC24B), Color(hex: 0xE08A0C)]
        case "file":                     return [Color(hex: 0x8A93FF), Color(hex: 0x4A55D6)]
        case "card":                     return [Color(hex: 0xA0A4AE), Color(hex: 0x6E7280)]
        case "favorite", "star":         return [Color(hex: 0xFFD34B), Color(hex: 0xE09A10)]
        case "coupon":                   return [Color(hex: 0xFF9F6B), Color(hex: 0xE0692A)]
        case "music":                    return [Color(hex: 0xB98CFF), Color(hex: 0x7A45D6)]
        case "screen":                   return [Color(hex: 0x7FA6E8), Color(hex: 0x3F66B8)]
        case "chain", "link":            return [Color(hex: 0x74C0FC), Color(hex: 0x2F7FD1)]
        case "vote":                     return [Color(hex: 0x6FD3A8), Color(hex: 0x1E9B6B)]
        default:                         return [Color(hex: 0xA8ACB6), Color(hex: 0x74788A)]
        }
    }

    private var tileH: CGFloat { L.v(54, 15, 58) }
    private var tileGap: CGFloat { L.v(7, 2.4, 9) }
    private var gridPad: CGFloat { L.v(14, 4.2, 18) }
    private var gridGap: CGFloat { L.v(10, 3.2, 14) }
    private var dotsH: CGFloat { L.v(22, 6, 26) }

    /// 这个面板到底需要多高：两行方块（图标 + 底下那行字）+ 行距 + 上下留白 + 页码点。
    /// 以前是写死 panelH 的，手机上字号一大，最下面那行的字就被切掉半个
    /// （用户反馈：加号面板底部把字遮挡了）。
    private var neededH: CGFloat {
        let rows = CGFloat(max(1, Int(ceil(Double(min(items.count, perPage)) / 4.0))))
        return gridPad * 2 + rows * (tileH + tileGap + 16) + max(0, rows - 1) * gridGap + dotsH
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { p in
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: L.v(10, 3.2, 14)), count: 4),
                              spacing: L.v(10, 3.2, 14)) {
                        ForEach(pages[p].indices, id: \.self) { i in
                            tile(pages[p][i])
                        }
                    }
                    .padding(.horizontal, gridPad)
                    .padding(.top, gridPad)
                    .padding(.bottom, gridPad * 0.5)
                    .tag(p)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            if pages.count > 1 {
                HStack(spacing: L.v(5, 1.6, 7)) {
                    ForEach(pages.indices, id: \.self) { i in
                        Capsule()
                            .fill(i == page ? C.green : Color.dyn(0xD6D6D6, 0x4A4A4C))
                            .frame(width: i == page ? L.v(14, 4, 16) : L.v(6, 1.8, 7),
                                   height: L.v(6, 1.8, 7))
                            .animation(.easeOut(duration: 0.18), value: page)
                    }
                }
                .frame(height: dotsH)
            } else {
                Color.clear.frame(height: L.v(10, 3, 12))
            }
        }
        .frame(height: max(panelH, neededH))
        .background(C.tabBg)
        .overlay(alignment: .top) { Rectangle().fill(C.hairline).frame(height: 0.5) }
    }

    /// 一格：点一下 = 正常动作；**长按**交给 onLongPress（拍照长按 = 录视频）。
    ///
    /// 这里**故意不用 Button**：Button 自带的手势会把同时挂上去的 LongPressGesture 吃掉，
    /// 真机上就是"长按十次九次没反应"（用户反馈「不能长按发视频」）。
    /// onTapGesture + onLongPressGesture 这套是 SwiftUI 里唯一稳的「点 / 长按」组合：
    /// 长按成立时那一下点击**不会**再触发，不用再拿标记去"吃掉"它。
    private func tile(_ item: PlusItem) -> some View {
        let c = tileColors(item.action)
        return VStack(spacing: tileGap) {
            /* 彩色圆角方块 + 白色线性图标 + 同色柔光 */
            ZStack {
                RoundedRectangle(cornerRadius: L.v(17, 5, 19), style: .continuous)
                    .fill(LinearGradient(colors: c,
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                    .frame(width: tileH, height: tileH)
                    .shadow(color: c[1].opacity(0.32), radius: 9, y: 4)
                SVGIcon(markup: I.plus(item.icon),
                        size: L.v(25, 7.4, 28),
                        color: .white)
            }
            Text(item.label ?? "")
                .font(pf(L.v(11.5, 3.2, 12.5)))
                .foregroundColor(C.label)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .opacity(item.enabled == false ? 0.45 : 1)
        /* 按下去轻微缩小（原来那个 ButtonStyle 的手感，这里自己画） */
        .scaleEffect(pressed == item.id ? 0.92 : 1)
        .animation(.easeOut(duration: 0.12), value: pressed)
        .contentShape(Rectangle())
        .onTapGesture { onTap(item) }
        /* 0.35 秒就算长按（再久一点用户会以为没反应）；
           手指允许飘 40 点（握着手机按住不放时手会轻微漂移，卡太紧会判定失败） */
        .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 40,
                            pressing: { p in pressed = p ? item.id : nil }) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            /* 没人接这一下长按（比如照片那一格）就照常当点击，别让手指白按 */
            if let lp = onLongPress, lp(item) { return }
            onTap(item)
        }
    }
}

/// ＋ 面板里彩色方块的手感：按下轻微缩小 + 变淡
private struct PlusTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/* ============================================================ 礼物面板 */

struct GiftPanel: View {
    let gifts: [Gift]
    var onTap: (Gift) -> Void

    @State private var page = 0
    private let perPage = 8

    private var pages: [[Gift]] {
        stride(from: 0, to: max(1, gifts.count), by: perPage).map { start in
            Array(gifts[start..<min(start + perPage, gifts.count)])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if gifts.isEmpty {
                Text(Tr("礼物还没配"))
                    .font(pf(14))
                    .foregroundColor(C.subLabel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { p in
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: L.v(8, 2.8, 13)), count: 4),
                                  spacing: L.v(8, 2.8, 13)) {
                            ForEach(pages[p].indices, id: \.self) { i in
                                let g = pages[p][i]
                                Button {
                                    onTap(g)
                                } label: {
                                    VStack(spacing: L.v(3, 1.2, 5)) {
                                        Text(g.icon ?? "🎁").font(pf(L.v(22, 6.4, 27)))
                                        Text(g.name ?? "礼物")
                                            .font(pf(L.v(10.5, 3, 12)))
                                            .foregroundColor(C.subLabel)
                                            .lineLimit(1)
                    Text("¥\(Int(g.price ?? 0))")
                        .font(pfMoney(L.v(10, 2.8, 11.5)))
                                            .foregroundColor(C.red)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .frame(height: (panelH - L.v(22, 6, 26) - L.v(24, 7.6, 32)) / 2)
                                    .background { CardGlassBox(radius: L.v(6, 2, 9)) }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, L.v(10, 3.2, 14))
                        .padding(.top, L.v(10, 3.2, 14))
                        .tag(p)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                HStack(spacing: L.v(5, 1.6, 7)) {
                    ForEach(pages.indices, id: \.self) { i in
                        Circle()
                            .fill(i == page ? Color.dyn(0xBFBFBF, 0xB8B8B8) : Color.dyn(0xCFCFCF, 0x4A4A4A))
                            .frame(width: L.v(5, 1.5, 7), height: L.v(5, 1.5, 7))
                    }
                }
                .frame(height: L.v(22, 6, 26))
            }
        }
        .frame(height: panelH)
        .background(C.tabBg)
    }
}

/* ============================================================ @ 群成员 */

/// 群里「@某人」的成员列表浮层（微信：输入框里打 @ 就弹出这一张，选完人继续打字）
struct MentionPanel: View {
    /// 候选成员（不含自己；服务端给的顺序和群头像九宫格一致）
    let members: [User]
    @Binding var query: String
    /// 群主才能 @所有人（微信的规矩）
    let canAtAll: Bool
    /// 显示名：和聊天页 / 服务端算出来的名字同一个（备注 → 昵称 → 微信号）
    let title: (User) -> String
    let onPick: (User) -> Void
    let onPickAll: () -> Void

    private var filtered: [User] {
        let k = query.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return members }
        return members.filter {
            title($0).contains(k)
                || ($0.nickname ?? "").contains(k)
                || ($0.username ?? "").contains(k)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            /* 上面一个搜索框：群里人多了靠它找人（微信的成员列表也是这个位置） */
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundColor(C.subLabel)
                TextField(Tr("搜索"), text: $query)
                    .font(pf(14))
                    .foregroundColor(C.label)
                    .frame(height: 30)
            }
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.dyn(0xF2F2F2, 0x2C2C2E)))
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 0) {
                    if canAtAll && query.trimmingCharacters(in: .whitespaces).isEmpty {
                        row(icon: "person.3.fill", user: nil, name: Tr("所有人")) { onPickAll() }
                    }
                    ForEach(filtered) { u in
                        row(icon: nil, user: u, name: title(u)) { onPick(u) }
                    }
                    if filtered.isEmpty && !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(Tr("没有找到这个人"))
                            .font(pf(13))
                            .foregroundColor(C.subLabel)
                            .padding(.top, 26)
                    }
                }
            }
            .frame(height: L.v(210, 60, 250))
        }
        .background(C.tabBg)
    }

    @ViewBuilder
    private func row(icon: String?, user: User?, name: String, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 10) {
                if let u = user {
                    Avatar(path: u.avatarPath, size: 36, radius: 4)
                } else {
                    Image(systemName: icon ?? "person.fill")
                        .font(.system(size: 15))
                        .foregroundColor(C.green)
                        .frame(width: 36, height: 36)
                }
                Text(name)
                    .font(pf(15))
                    .foregroundColor(C.label)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/* ============================================================ 位置 */

struct LocationSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onSend: (String) -> Void

    @State private var name = "我的位置"
    @State private var lat = "31.491200"
    @State private var lng = "120.311900"
    @State private var addr = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(Tr("位置名称"))) {
                    TextField("我的位置", text: $name)
                }
                Section(header: Text(Tr("经纬度（北纬 / 东经）"))) {
                    HStack {
                        Text(Tr("纬度")).foregroundColor(.secondary)
                        TextField("31.4912", text: $lat).keyboardType(.numbersAndPunctuation)
                    }
                    HStack {
                        Text(Tr("经度")).foregroundColor(.secondary)
                        TextField("120.3119", text: $lng).keyboardType(.numbersAndPunctuation)
                    }
                    if !addr.isEmpty {
                        Text(addr).font(pf(13)).foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle(Tr("发送位置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button(Tr("取消")) { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(Tr("发送")) {
                        let payload = "{\"lat\":\(Double(lat) ?? 0),\"lng\":\(Double(lng) ?? 0),\"name\":\"\(name)\",\"addr\":\"\(addr)\"}"
                        onSend(payload)
                        dismiss()
                    }
                }
            }
        }
    }
}
