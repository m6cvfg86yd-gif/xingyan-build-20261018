import SwiftUI
import UIKit

/* ============================================================
   通讯录右侧 A-Z 索引条上的触摸层（UIKit）
     · 轻点某个字母 → 跳到那一段
     · **按住上下滑** → 手指滑过哪个字母就跳到哪一段（微信就是这样）
   为什么用 UIKit：这一小条上的滑动要由我们接管（不能让列表跟着滚），
   同时又不能影响列表其他地方的正常滚动 —— UIKit 手势只落在这条上，别处完全不碰。
   ============================================================ */
struct IndexBarTouch: UIViewRepresentable {
    /// 手指的纵坐标（相对索引条本身）
    var onMove: (CGFloat) -> Void
    var onEnd: () -> Void

    final class Coord: NSObject {
        var onMove: (CGFloat) -> Void = { _ in }
        var onEnd: () -> Void = { }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let v = g.view else { return }
            switch g.state {
            case .began, .changed:
                onMove(g.location(in: v).y)
            case .ended, .cancelled, .failed:
                onEnd()
            default:
                break
            }
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard g.state == .ended, let v = g.view else { return }
            onMove(g.location(in: v).y)
            onEnd()
        }
    }

    func makeCoordinator() -> Coord { Coord() }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = true
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coord.handlePan(_:)))
        v.addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coord.handleTap(_:)))
        v.addGestureRecognizer(tap)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onMove = onMove
        context.coordinator.onEnd = onEnd
    }
}

struct ContactSection: Identifiable {
    var id: String { letter }
    let letter: String
    let users: [User]
}

struct ContactsView: View {
    /// 列表滚了多少：顶栏那层玻璃靠它淡入（和会话页同一个组件）
    @State private var navScrolled: CGFloat = 0
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState

    @State private var keyword = ""
    @State private var path = NavigationPath()
    @State private var bubble: String?
    @State private var bubbleTask: Task<Void, Never>?
    @State private var plusMenu = false
    @State private var showScan = false
    /// 顶栏那颗放大镜：进「搜索」整页（列表里的搜索框已按用户要求取消）
    @State private var showSearch = false
    @ObservedObject private var realtime = Realtime.shared
    /// 右侧 A-Z 索引条：手指正停在哪个字母（只在换字母时跳一次，别重复滚）
    @State private var idxLetter = ""
    /// 每换一个字母轻震一下（微信那种手感）
    private let idxHaptic = UISelectionFeedbackGenerator()
    /// ★ 星标朋友的 id（服务端上「星标」的那几个），通讯录顶上单独一组
    @State private var starIds: [String] = []

    /* 头部（顶栏 + 那条常驻搜索框）的总高：搜索框上下各留 ctSearchGap，
       所以它**不贴着**上面那条遮罩；列表顶部的留白和上提量都用这一个数，改一处就同步 */
    /* ⚠ 2026-10-16：常驻搜索框去掉了（换成顶栏那颗放大镜），
       所以头部只剩顶栏那么高 —— 列表顶上留白跟着收掉这一条。 */
    private var listHeadH: CGFloat { L.navH }

/* 6 个图标底色统一加深一档（原来偏粉嫩，深色更有质感）：
   琥珀 / 石板灰 / 靛蓝 / 靛蓝 / 松绿 / 松绿
   文案走 L()：切成英文时显示英文，中文时显示中文（所以这里是计算属性，不是常量） */
private var funcs: [(String, String, Color, String)] {
    [
        (Tr("新的朋友"), I.newFriends, Color(hex: 0xF5A23D), "newFriends"),
        (Tr("群聊"), I.groups, Color(hex: 0x22AC8B), "groups"),
        (Tr("仅聊天的朋友"), I.chatOnly, Color(hex: 0x8E8E99), "chatOnly"),
        (Tr("标签"), I.tag, Color(hex: 0x4C93DD), "tags"),
        (Tr("公众号"), I.service, Color(hex: 0x4C93DD), "officialAccounts"),
        (Tr("企业联系人"), I.workMate, Color(hex: 0x35A87E), "work"),
        (Tr("我的企业"), I.myWork, Color(hex: 0x35A87E), "myWork")
    ]
}

    private var filtered: [User] {
        let sorted = app.contacts.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        guard !keyword.isEmpty else { return sorted }
        return sorted.filter { $0.name.contains(keyword) || ($0.username ?? "").contains(keyword) }
    }

    /// ★ 星标朋友（按服务端给的顺序，去联系人里取完整资料）
    private var starUsers: [User] {
        guard !starIds.isEmpty else { return [] }
        return starIds.compactMap { id in app.contacts.first { $0.id == id } }
    }

    private var sections: [ContactSection] {
        var order: [String] = []
        var map: [String: [User]] = [:]
        for u in filtered {
            let k = pinyinInitial(u.name)
            if map[k] == nil { order.append(k) }
            map[k, default: []].append(u)
        }
        return order.sorted { a, b in
            if a == "#" { return false }
            if b == "#" { return true }
            return a < b
        }.map { ContactSection(letter: $0, users: map[$0] ?? []) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                /* 方案 3（用户选的）：顶栏不再放放大镜，改成**下面常驻一个搜索框** ——
                   一眼就能看到"可以搜"，也少一次点击；标题和 ＋ 保持原来的浮动玻璃。 */
                /* 顶栏 + 搜索框合成一块「头部」，压在列表上面（列表从它后面穿过去才"透"） */
                VStack(spacing: 0) {
                /* ⚠ 2026-10-16 用户：「把通讯录搜索框也换成会话页的一个放大镜」——
                   以前这里下面常驻一条方形搜索框，现在按会话页那样：
                   **顶栏左边一颗玻璃圆放大镜**（同一套 GlassBackground、同一个图标大小），
                   点一下进「搜索」整页；下面那条常驻搜索框整块去掉。 */
                NavBar(title: C.tabText1,
                       leftExtra: AnyView(
                        Button {
                            plusMenu = false
                            showSearch = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(C.label)
                                .frame(width: 36, height: 36)
                                .background { GlassBackground(shape: Circle(), shadow: true, seed: 0.40) }
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Tr("搜索"))
                       ),
                       floating: true,
                       leftExtraGlass: false) {
                    Button {
                        /* 弹出的手感：弹簧带动一点回弹（和会话页一致） */
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) { plusMenu = true }
                    } label: {
                        Text("＋")
                            /* 和会话页那个 ＋ 完全同一套后台键：大小 navPlusSize、
                               胶囊 navPlusW/navPlusH、底色 navPlusBg、加号颜色 navPlusInk */
                            .font(pf(UIConfig.num("navPlusSize", 20)))
                            .foregroundColor(UIConfig.color("navPlusInk", 0xFFFFFF, 0xFFFFFF))
                            .frame(width: UIConfig.num("navPlusW", 44),
                                   height: UIConfig.num("navPlusH", 36))
                            .background(Capsule(style: .continuous)
                                .fill(UIConfig.color("navPlusBg", 0x0F5A3C, 0x0F5A3C)))
                    }
                    /* 和会话页那个 ＋ 一样：按下去亮一下（同一个 ButtonStyle） */
                    .buttonStyle(NavPlusPressStyle())
                }
                /* 和会话页同一套顶栏玻璃：不滚时和页面连成一片，滚起来才浮出磨砂（微信那种质感） */
                /* 通讯录顶栏**常显**那条遮罩（微信就是这样） */
                /* 用户要求通讯录关闭顶部遮罩：只保留页面同色背景。 */
                .background(C.pageBg.ignoresSafeArea(edges: .top))

                }
                .zIndex(1)

                ScrollViewReader { proxy in
                    ZStack(alignment: .trailing) {
                        ScrollView {
                            /* 2026-10-15「通讯录重新做一版」：分组字母改成**吸顶**（滚到哪一组，
                               字母就贴在顶栏下面），这也是微信那种质感。 */
                            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                                /* 探针挂在整块内容上（和会话页一样，别挂第一行，否则会被回收） */
                                TopScrollProbe(space: "contactsScroll")
                                    .frame(height: 0)
                                /* 顶上给头部留位：第一条联系人还是从搜索框下面开始 */
                                Color.clear.frame(height: listHeadH)
                                if keyword.isEmpty {
                                    /* 方案 3：7 个功能不再一人一行（原来 56×7=392pt），
                                       压成**一行横滑的大图标**，联系人立刻顶上来。 */
                                    funcStrip
                                    Color.clear.frame(height: 8)
                                }

                                /* ★ 星标朋友（横滑一排在卡片里；不是微信那种塞进字母名单最上面） */
                                if keyword.isEmpty, !starUsers.isEmpty {
                                    starStrip
                                    Color.clear.frame(height: 8)
                                }

                                ForEach(sections) { section in
                                    Section {
                                      ForEach(section.users.indices, id: \.self) { i in
                                        let user = section.users[i]
                                        VStack(spacing: 0) {
                                            NavigationLink(value: user) {
                                                contactRow(user)
                                            }
                                            .buttonStyle(.plain)
                                            /* 用户要求：**每条联系人下面都有一条分割线**
                                               （以前是"组内相邻两条之间"才有，最后一个没有，
                                               好友少、字母分得散时看着就只剩几条）。 */
                                            /* 分割线缩进按专业 App 的做法：只留 16（左右同宽），
                                               不是微信那种缩到文字那一列（68） */
                                            HairLine(inset: 16)
                                        }
                                        .background(C.contactsBg)
                                        .id(user.id)
                                      }
                                    } header: {
                                        /* 字母分组头：吸顶 + 一条玻璃（iOS 26 那套），
                                           右边带这一组的人数 */
                                        HStack(spacing: 6) {
                                            Text(section.letter)
                                                .font(pf(L.ctHeadSize))
                                                .foregroundColor(Color(hex: 0x737373))
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.leading, 16)
                                        .frame(height: L.ctHeadH)
                                        .background {
                                            ZStack {
                                                C.contactsBg
                                                if UIConfig.num("contactsStickyGlass", 1) > 0 {
                                                    Rectangle().fill(.ultraThinMaterial).opacity(0.55)
                                                }
                                            }
                                        }
                                        .id("letter-\(section.letter)")
                                    }
                                }

                                /* 底部按微信那套：有联系人显示「N位联系人」，
                                   一个都没有时给一句提示（微信这一页空着，但那样让人不知道去哪加）。 */
                                Group {
                                    if filtered.isEmpty {
                                        Text(Tr("还没有联系人，点右上角 ＋ 添加"))
                                            .font(pf(16))
                                            .foregroundColor(C.subLabel)
                                            .frame(maxWidth: .infinity)
                                            .padding(.top, 40)
                                    } else {
                                        Text("\(filtered.count)位联系人")
                                            /* 用户要求：这行字大一点（原来是 13 号） */
                                            .font(pf(16))
                                            .foregroundColor(C.subLabel)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 20)
                                    }
                                }
                                .background(C.contactsBg)
                            }
                        }
                        .background(C.contactsBg)
                        .topScrollTracking($navScrolled, space: "contactsScroll")
                        .refreshable { await app.loadContacts() }

                        if keyword.isEmpty && !sections.isEmpty {
                            ContactIndexBar(
                                available: Set(sections.map { $0.letter }),
                                onPick: { L in
                                    withAnimation(.easeOut(duration: 0.12)) {
                                        proxy.scrollTo("letter-\(L)", anchor: .top)
                                    }
                                    showBubble(L)
                                },
                                onSearch: {
                                    showSearch = true
                                }
                            )
                            .padding(.trailing, 8)
                            .frame(maxHeight: .infinity, alignment: .center)
                        }

                        if let b = bubble {
                            LetterBubble(letter: b)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                                .offset(y: -56)
                        }
                    }
                }
                /* 列表整体上提一个头部的高度：内容从顶栏/搜索框**后面**穿过去（微信那种透） */
                .padding(.top, -listHeadH)
            }
            .background(C.pageBg.ignoresSafeArea(edges: .bottom))
            /* 顶部（状态栏那一条）跟页面用同一个底色：深色下导航色比页面底色浅，
               不这样会看到顶上一条明显的浅色带（用户要求「颜色要到顶一致」） */
            .background(C.pageBg.ignoresSafeArea(edges: .top))
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: User.self) { user in
                ContactCardView(user: user,
                                onOpenChat: { chat in path.append(chat) },
                                onOpenMoments: { id in path.append("moments:" + id) })
            }
            .navigationDestination(for: Chat.self) { chat in
                ChatDetailView(chat: chat)
            }
            .navigationDestination(for: String.self) { key in
                if key.hasPrefix("moments:") {
                    let uid = String(key.dropFirst(8))
                    MomentsView(target: app.contacts.first { $0.id == uid })
                } else if key == "newFriends" {
                    NewFriendsView()
                } else if key == "addFriend" {
                    AddFriendView()
                } else if key == "newGroup" {
                    GroupCreateView { chat in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { path.append(chat) }
                    }
                } else if key == "myQR" {
                    MyQRView()
                } else if key == "groupList" {
                    GroupListView(onOpenChat: { chat in path.append(chat) })
                } else if key == "officialAccounts" {
                    OfficialAccountsView()
                } else {
                    ComingSoonView(title: key)
                }
            }
        }
        /* 右上角那个「＋」：和会话页同一张下拉小卡片（毛玻璃 + 彩色图标） */
        .navPlusOverlay($plusMenu, items: [
            NavPlusItem(title: Tr("发起群聊"), symbol: "person.2.fill",
                        colors: [C.green, C.green.opacity(0.78)]) { path.append("newGroup") },
            NavPlusItem(title: Tr("添加朋友"), symbol: "person.badge.plus",
                        colors: [Color(hex: 0x64B5F6), Color(hex: 0x2A6BC4)]) { path.append("addFriend") },
            NavPlusItem(title: Tr("扫一扫"), symbol: "qrcode.viewfinder",
                        colors: [Color(hex: 0xFFB627), Color(hex: 0xF08600)]) { showScan = true }
        ])
        .fullScreenCover(isPresented: $showScan) {
            ScannerView { text in handleScanned(text, app: app) }
        }
        /* 放大镜 → 搜索整页（点人会进名片，点会话进聊天） */
        .fullScreenCover(isPresented: $showSearch) {
            SearchPage(onOpenChat: { c in path.append(c) },
                       onOpenUser: { u in path.append(u) },
                       /* 通讯录这条搜索：键盘起来时，键盘正上方居中一颗语音球
                          （2026-10-16 用户要求；键盘消失它跟着消失） */
                       voiceBall: true)
                .environmentObject(app)
        }
        .task {
            await app.loadContacts()
            /* ★ 星标朋友：进页面拉一次（在别人资料页设/取消星标后，回来也会重新拉） */
            if let ids = try? await API.shared.starredFriends() { starIds = ids }
            /* 兜底：长连接万一漏推了「有人加你」，最多 10 秒也会自己刷新出来 */
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { break }
                await app.loadContacts()
            }
        }
        // 有人加你 / 改资料 / 上下线 → 通讯录立刻刷新
        .onChange(of: realtime.event) { ev in
            if ev.type == "friend" || ev.type == "presence" || ev.type == "profile" || ev.user != nil {
                Task { await app.loadContacts() }
            }
        }
    }

    private func showBubble(_ letter: String) {
        bubble = letter
        bubbleTask?.cancel()
        bubbleTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if !Task.isCancelled { bubble = nil }
        }
    }

    /* ---------------------------------------------------------- 顶部功能行 */

    /* ---------------------------------------------------------- 方案 3：功能横滑条 */

    /// 一行横滑的大图标（新的朋友 / 群聊 / 标签 / …）—— 代替原来"一人一行"的 7 行列表
    private var funcStrip: some View {
        /* 2026-10-16：用户「通信录还是不行，你去 github 上学习下专业布局 app」。
           读了 Signal-iOS（SignalUI/RecipientPickers）那套之后的结论：
             · 列表顶上的"动作"就是**普通的行**（小图标 + 标题 + 箭头），
               图标是**彩色圆底 + SF Symbol**，不是微信那种大色块方图标；
             · 行高压到 52、分割线只缩进 16；
             · 行内头像 36~38、名字 17、副标题 12。
           所以这一块改成 4 个紧凑行（圆底图标 34 + 16.5pt 标题 + 箭头），
           整块放进一张 14 圆角的白卡里 —— 既专业又完全不像微信那一页。 */
        VStack(spacing: 0) {
            ForEach(Array(ctFuncs.enumerated()), id: \.offset) { i, item in
                Button { openFunc(item.3) } label: { proRow(item) }
                    .buttonStyle(MenuPressStyle())
                if i < ctFuncs.count - 1 { HairLine(inset: 62) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(C.cardBg))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(C.hairline, lineWidth: 0.6))
        .shadow(color: Color.black.opacity(0.05), radius: 8, y: 2)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    /// 专业 App 那套动作行：彩色圆底 SF Symbol（34）+ 标题 16.5 + 右侧红点/箭头
    private func proRow(_ item: (String, String, Color, String)) -> some View {
        let sym: String
        switch item.3 {
        case "newFriends":      sym = "person.badge.plus"
        case "groups":          sym = "person.3.fill"
        case "tags":            sym = "tag.fill"
        default:                sym = "dot.radiowaves.left.and.right"
        }
        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(item.2.opacity(0.14))
                    .frame(width: 34, height: 34)
                /* ⚠ 2026-10-16 用户：「后台更换图标又写死了吗」——对，上一版这里写死了
                   SF Symbol，把后台「UI 图标」里换图标的能力弄没了。
                   现在：**后台配了 SVG 就用后台的**（item.1），没配才退回内置那个符号。 */
                if !item.1.isEmpty {
                    SVGIcon(markup: item.1, size: 17, color: item.2)
                        .frame(width: 17, height: 17)
                } else {
                    Image(systemName: sym)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(item.2)
                }
            }
            Text(item.0)
                .font(pf(16.5))
                .foregroundColor(C.label)
            Spacer(minLength: 8)
            if item.3 == "newFriends" && app.showDot("newFriends", auto: app.friendRequests > 0) {
                Text(app.friendRequests > 99 ? "99+" : "\(app.friendRequests)")
                    .font(pf(12, .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, app.friendRequests > 9 ? 6 : 0)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Capsule().fill(C.red))
            }
            Chevron(size: 9, line: 1.6)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .contentShape(Rectangle())
    }

    /// 顶上这 4 个入口（不是微信那 5 行：只留真正做得出来的四个，
    /// 其余几个「仅聊天的朋友 / 企业联系人」以前点了只弹一句提示，不如不放）
    private var ctFuncs: [(String, String, Color, String)] {
        let want = ["newFriends", "groups", "tags", "officialAccounts"]
        var out: [(String, String, Color, String)] = []
        for k in want {
            if let f = funcs.first(where: { $0.3 == k }) { out.append(f) }
        }
        return out
    }

    /// ★ 星标朋友：横滑一排头像（只有设过星标才出现）。
    /// 微信是把星标塞进字母名单最上面；我们单独做成一张卡，一眼就能找到常联系的人。
    private var starStrip: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 6) {
                Image(systemName: "star.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: 0xE8A33D))
                Text(Tr("星标朋友"))
                    .font(pf(13.5, .medium))
                    .foregroundColor(C.label)
                Spacer(minLength: 0)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(starUsers) { u in
                        NavigationLink(value: u) {
                            VStack(spacing: 6) {
                                Avatar(path: u.avatarPath, size: 46, radius: 23,
                                       /* 2026-10-16 用户：「通讯录每条上面怎么都有个 1」——
                                          那个 1 是头像上的等级角标。1 级几乎是所有人，不画。 */
                                       level: (u.qqLevel ?? 0) > 1 ? (u.qqLevel ?? 0) : 0)
                                Text(u.name)
                                    .font(pf(11.5))
                                    .foregroundColor(C.subLabel)
                                    .lineLimit(1)
                                    .frame(width: 56)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(C.cardBg))
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private func funcCell(_ item: (String, String, Color, String)) -> some View {
        Button {
            openFunc(item.3)
        } label: {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    FuncIcon(markup: item.1, bg: item.2, size: 52)
                    /* 「新的朋友」右上角：有待处理申请就挂红点数字（和原来一样） */
                    if item.3 == "newFriends" && app.showDot("newFriends", auto: app.friendRequests > 0) {
                        Text(app.friendRequests > 99 ? "99+" : "\(app.friendRequests)")
                            .font(pf(11, .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, app.friendRequests > 9 ? 4 : 0)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Capsule().fill(C.red))
                            .offset(x: 6, y: -5)
                    }
                }
                Text(item.0)
                    .font(pf(13))
                    .foregroundColor(C.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuPressStyle())
    }

    /// 功能项的跳转（和原来那行长列表用的是同一套逻辑）
    private func openFunc(_ key: String) {
        switch key {
        case "newFriends": path.append("newFriends")
        case "groups": path.append("groupList")
        case "chatOnly": app.show(Tr("仅聊天的朋友：只有聊天记录、没加好友的人会出现在这里"))
        case "tags": app.show(Tr("标签：还没建过标签"))
        case "officialAccounts": path.append("officialAccounts")
        case "service": path.append("officialAccounts")
        case "work": app.show(Tr("企业联系人：还没绑定企业"))
        default: app.show(Tr("我的企业：还没创建企业"))
        }
    }

    private func funcRow(_ item: (String, String, Color, String)) -> some View {
        Button {
            switch item.3 {
            case "newFriends": path.append("newFriends")
            case "groups": path.append("groupList")
            case "chatOnly": app.show(Tr("仅聊天的朋友：只有聊天记录、没加好友的人会出现在这里"))
            case "tags": app.show(Tr("标签：还没建过标签"))
            /* 公众号：进公众号列表（我们自己的那套，服务号 + 订阅号） */
            case "officialAccounts": path.append("officialAccounts")
            case "service": path.append("officialAccounts")
            case "work": app.show(Tr("企业联系人：还没绑定企业"))
            default: app.show(Tr("我的企业：还没创建企业"))
            }
        } label: {
            HStack(spacing: L.ctGap) {
                FuncIcon(markup: item.1, bg: item.2, size: L.ctIcon)
                Text(item.0)
                    .font(pf(L.ctNameSize))
                    .foregroundColor(C.label)
                Spacer(minLength: 0)
                /* 「新的朋友」右边：有待处理的好友申请就显示微信同款红点数字 */
                if item.3 == "newFriends" && app.showDot("newFriends", auto: app.friendRequests > 0) {
                    Text(app.friendRequests > 99 ? "99+" : "\(app.friendRequests)")
                        .font(pf(12.5, .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, app.friendRequests > 9 ? 6 : 0)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(C.red))
                        .padding(.trailing, 16)
                }
            }
            .padding(.leading, L.ctPadL)
            .frame(height: L.ctRowH)
            .background(C.contactsBg)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuPressStyle())
    }

    private func contactRow(_ user: User) -> some View {
        HStack(spacing: L.ctGap) {
            /* 头像用**圆形**、尺寸收到 38：Signal / Telegram / Element 这些专业 App
               的联系人行全是圆头像 + 17pt 名字，行高压到 ~52（原来是 40 圆角方 + 56 高）。
               后台 ctAvatar / ctRowH 还能再调，这里只改默认观感。 */
            Avatar(path: user.avatarPath, size: min(L.ctAvatar, 38), radius: 19,
                   level: (user.qqLevel ?? 0) > 1 ? (user.qqLevel ?? 0) : 0)
            Text(user.name)
                .font(pf(min(L.ctNameSize, 16.5)))
                .foregroundColor(C.label)
                .lineLimit(1)
            /* 等级图标（QQ 那套）：后台「显示在通讯录」开着才显示 */
            /* ⚠ 2026-10-16 用户：「通讯录每条线上多出来的那个 1 是啥，去掉」——
               那是等级图标（QQ 那套）。**1 级不给画**（几乎所有人都是 1 级，
               一行一个"1"就是纯噪声），2 级往上照旧显示。 */
            if (user.qqLevel ?? 0) > 1, GrowthFlags.showInContacts != false {
                QQLevelBadge(level: user.qqLevel ?? 0, size: L.v(14, 4, 16), maxIcons: 3)
                    .fixedSize()
            }
            /* 会员徽章（好友开了会员就挂一个） */
            MemberBadge(tier: user.memberTier,
                        short: user.memberShort,
                        color: user.memberColor,
                        color2: user.memberColor2,
                        height: L.v(12, 3.4, 14))
                .fixedSize()
            Spacer(minLength: 0)
        }
        .padding(.leading, L.ctPadL)
        .frame(height: min(L.ctRowH, 52))
        .contentShape(Rectangle())
    }

    /* ---------------------------------------------------------- 右侧 A-Z */

    private func indexBar(_ proxy: ScrollViewProxy) -> some View {
        let rowH = max(1, L.ctIdxItemH)
        return VStack(spacing: 0) {
            ForEach(sections) { section in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo("letter-\(section.letter)", anchor: .top)
                    }
                } label: {
                    Text(section.letter)
                        /* 默认加粗（用户要求）；后台 ctIdxBold = 0 可以改回细体 */
                        .font(pf(L.ctIdxSize, ctIdxWeight()))
                        // 字号 / 颜色 / 行距都能在后台「界面文字」里调
                        /* 2026-10-17 用户：「索引选中的圈也拿我们自己的按钮颜色」——
                           手指正压着的那个字母：白字 + 一颗**品牌色实心圆**
                           （另一处索引 ContactIndexBar 也改成同一套，颜色都跟着 greenColor 走）。 */
                        .foregroundColor(idxLetter == section.letter
                                         ? .white
                                         : UIConfig.color("ctIdxColor", 0x555555, 0x8E8E93))
                        .frame(width: 22, height: rowH)
                        .background {
                            if idxLetter == section.letter {
                                Circle()
                                    .fill(UIConfig.colorIfSet("ctIdxActiveBg") ?? C.green)
                                    .frame(width: max(15, rowH + 1.5))
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        /* 触摸层：点一下跳那个字母；**按住上下滑**，滑过哪个字母就跳到那一段
           （微信就是这样，手指全程跟手）。滑的时候不要动画 —— 动画会跟手指打架。 */
        .overlay {
            IndexBarTouch(onMove: { y in
                guard !sections.isEmpty else { return }
                let i = min(sections.count - 1, max(0, Int(y / rowH)))
                let letter = sections[i].letter
                guard letter != idxLetter else { return }      // 只在换字母时跳一次
                idxLetter = letter
                idxHaptic.selectionChanged()
                proxy.scrollTo("letter-\(letter)", anchor: .top)
            }, onEnd: {
                idxLetter = ""
            })
        }
        .padding(.trailing, 5.7)
        .frame(maxHeight: .infinity, alignment: .center)
        /* 右侧 A-Z 也套一层玻璃（苹果那套：淡玻璃 + 圆角胶囊，不额外描边） */
        .padding(.vertical, 6)
        .padding(.horizontal, 3)
        .background {
            ZStack {
                /* 玻璃本体：给足强度，不然 iOS 26 的原生玻璃叠上透明度就看不见了
                   （用户反馈的"A-Z 没拿玻璃框起来"） */
                GlassBackground(shape: Capsule(style: .continuous),
                                opacity: UIConfig.num("indexGlassAlpha", 1),
                                edgeAlpha: UIConfig.num("indexGlassEdge", 0.45),
                                shadow: true,
                                seed: 0.90)
                /* 再垫一层很淡的底色：和输入框一样 —— 光有玻璃在某些壁纸/浅色背景下
                   还是"看不见"，垫一点底色就一眼看得出是一块圆角玻璃框。
                   想回到完全透明：后台写 indexGlassTint = 0。 */
                Capsule(style: .continuous)
                    .fill(C.cardBg.opacity(UIConfig.num("indexGlassTint", 0.35)))
            }
        }
        .padding(.trailing, 4)
    }
}

/* ============================================================
   个人名片 —— 照网页版 #cardScreen 一条条量出来的（不是原生那套）：
   头部内边距 27/16/29.5 · 头像 64 圆角 6 · 名字 20 · 三行资料 15/行高 22
   标签列 80 · 行高 22 · 行距 8 · 缩略图 48 圆角 3 · 底部按钮两行各 55.6 字 17
   尺寸都能在服务器 data/ui.json 里调（cd 开头那几个键），改完重开 App 就生效。
   ============================================================ */

struct ContactCardView: View {
    let user: User
    var onOpenChat: (Chat) -> Void
    var onOpenMoments: (String) -> Void

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var full: User?
    @State private var thumbs: [String] = []
    @State private var hasMoments = false
    @State private var busy = false
    @State private var showMore = false
    @State private var showInfo = false
    @State private var showPhone = false
    @State private var showApply = false
    /* 朋友资料（微信「设置备注和标签」那套） */
    @State private var meta: API.FriendMeta?
    @State private var showRemark = false
    @State private var showPerm = false
    @State private var confirmDelete = false
    /// 好友的「状态」（名片上那一小条，点开看大图）
    @State private var showStatus = false
    /// 机器人（AI 助手 / 腾讯新闻）：点「语音通话」走 AI 通话，不是真人 WebRTC
    @State private var aiCall: Chat?
    /// 点名片上的头像 → 放大看（微信那样）
    @State private var showBigAvatar = false
    /// 「推荐给朋友」那一张「发送给」页
    @State private var showShare = false
    /// 名片页进来那一下的入场动效（只动透明度/位移，不动布局）
    @State private var cardIn = false

    private var avatarPath: String { u.avatarPath }

    private var u: User { full ?? user }
    /// 好友有状态才显示那一小条
    private var statusAlive: Bool {
        !((u.moodIcon ?? "").isEmpty && (u.moodText ?? "").isEmpty)
    }
    /// 名片上显示的名字：有备注用备注，没有用昵称
    private var displayName: String {
        if let r = meta?.remark, !r.trimmingCharacters(in: .whitespaces).isEmpty { return r }
        return u.name
    }
    private var phone: String { (u.phone ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isBot: Bool { u.bot == true }
    /// 顶栏那只小眼睛对应的 AI（管家）—— 名片上也用会动的眼睛当头像
    private var isEyesBot: Bool { (u.username ?? "").lowercased() == "housekeeper" }
    private var relation: String {
        if let r = u.relation, !r.isEmpty { return r }
        return u.id == app.me?.id ? "self" : "none"
    }

    /* 名片这一页的颜色（参考图上取的原值） */
    private var sheetBg: Color { scheme == .dark ? Color(hex: 0x1C1C1E) : .white }
    private var scrollBg: Color { C.pageBg }
    private var ink: Color { scheme == .dark ? Color(hex: 0xEDEDED) : Color(hex: 0x1A1A1A) }
    private var gray: Color { scheme == .dark ? Color(hex: 0x8E8E93) : Color(hex: 0x737373) }
    private var link: Color { scheme == .dark ? Color(hex: 0x7D90B8) : Color(hex: 0x576B95) }
    private var lineColor: Color { scheme == .dark ? Color(white: 1, opacity: 0.09) : Color(hex: 0xE5E5E5) }

    /// 名片页的三种长相（后台 data/ui.json 里 cardStyle 决定，改完重开 App 生效）：
    ///   old    = 原来那版（默认）
    ///   new    = 畅聊 / HarmonyOS 设计语言那版
    ///   wechat = 照微信「详细资料」页重做的那版
    /// 老的两版一个字没动，随时能切回去。
    var body: some View {
        ZStack {
            Group {
                if UIConfig.text("cardStyle", "old") == "new" {
                    ContactCardNew(name: displayName,
                                   idLine: "账号 " + (u.username ?? ""),
                                   avatarPath: u.avatarPath,
                                   isEyes: isEyesBot,
                                   remark: meta?.remark ?? "",
                                   phone: phone,
                                   momentCount: thumbs.count,
                                   momentsRange: u.momentsRange ?? "all",
                                   onClose: { dismiss() },
                                   onMessage: { openChat() },
                                   onVoice: { startCall(video: false) },
                                   onVideo: { startCall(video: true) },
                                   onMoments: hasMoments ? { onOpenMoments(u.id) } : nil)
                } else if UIConfig.text("cardStyle", "old") == "wechat" {
                    wechatCard
                } else {
                    cardBody
                }
            }
            /* 右上「⋯」那张面板三版共用（new / wechat 也要能改备注、加黑名单、删好友） */
            if showMore { morePanel.transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.18), value: showMore)
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .confirmationDialog(Tr("删除好友？"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(Tr("删除"), role: .destructive) { removeFriend() }
            Button(Tr("取消"), role: .cancel) { }
        }
        /* 二级页一律**整页 push**（微信就是这样）：设置备注和标签 / 朋友权限 / 状态 */
        .navigationDestination(isPresented: $showRemark) {
            FriendRemarkSheet(user: u, meta: meta) { await load() }
                .environmentObject(app)
        }
        .navigationDestination(isPresented: $showPerm) {
            FriendPermSheet(user: u, meta: meta) { await load() }
                .environmentObject(app)
        }
        /* 好友的「状态」：点名片上那一小条，看大的（微信也是这个动作） */
        .navigationDestination(isPresented: $showStatus) {
            FriendStatusView(user: u)
                .environmentObject(app)
        }
        /* 点名片上的头像 → 整页放大（微信那样，可缩放/长按保存） */
        .fullScreenCover(isPresented: $showBigAvatar) {
            PhotoPager(paths: [avatarPath], startIndex: 0) { showBigAvatar = false }
        }
        .confirmationDialog("", isPresented: $showInfo, titleVisibility: .hidden) {
            if isBot {
                Button("昵称：\(u.name)") { }
                Button("账号：\(u.username ?? "—")") { }
                if let b = u.bio, !b.isEmpty { Button("简介：\(b)") { } }
            } else {
                Button("昵称：\(u.name)") { }
                Button("账号：\(u.username ?? "—")") { }
                /* 微信「朋友资料」里也有个性签名这一行 */
                if let b = u.bio, !b.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("个性签名：\(b)") { }
                }
                Button("地区：\((u.region?.isEmpty == false) ? u.region! : "未知")") { }
            }
            Button(Tr("取消"), role: .cancel) { }
        }
        .confirmationDialog("", isPresented: $showPhone, titleVisibility: .hidden) {
            Button("拨打 \(phone)") { dial() }
            Button(Tr("取消"), role: .cancel) { }
        }
        .task { await load() }
        .fullScreenCover(item: $aiCall) { c in
            AICallView(chat: c).environmentObject(app)
        }
        /* 「添加到通讯录」→ 微信那个申请页（可以写验证消息，默认「我是XXX」） */
        .navigationDestination(isPresented: $showApply) {
            FriendApplySheet(user: u) {
                Task {
                    await app.loadContacts()
                    await load()
                }
            }
            .environmentObject(app)
        }
        /* 推荐给朋友：微信那张「发送给」页；点发送就把名片（名字 + 微信号 + 头像）
           作为一条 kind = "card" 的消息发给选中的聊天。 */
        .sheet(isPresented: $showShare) {
            CardShareView(user: u) { chats in
                Task {
                    /* 名片内容就是对方的名字 / 微信号 / 头像；收端按微信那张卡渲染。
                       ⚠ 只编码一次（以前这层编码叠加导致收端乱码）。 */
                    /* ⚠ 键必须是 userId：服务端按 userId 去找那个人、
                       再用服务端最新资料把名字/微信号/头像补一遍
                       （写成 id 的话服务端找不到人，收端就只剩一句「[名片]」）。 */
                    let payload = [
                        "userId": u.id,
                        "name": u.name,
                        "username": u.username ?? "",
                        "avatar": u.avatar ?? ""
                    ]
                    let text = (try? JSONSerialization.data(withJSONObject: payload))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    for c in chats {
                        _ = try? await API.shared.send(chatId: c.id, kind: "card", content: text)
                    }
                    if !chats.isEmpty { app.show(Tr("已发送")) }
                }
            }
            .environmentObject(app)
        }
    }

    /// 微信那版名片：数据在这儿凑齐（头像 / 微信号 / 地区 / 三张缩略图 / 那张句提示）
    private var wechatCard: some View {
        ContactCardWechat(name: displayName,
                          wxId: "微信号：" + ((u.username?.isEmpty == false) ? u.username! : "—"),
                          region: regionText,
                          avatarPath: avatarPath,
                          isEyes: isEyesBot,
                          remarkLine: tagText,
                          permLine: permText,
                          moreLine: moreText,
                          momentsHint: momentsHint,
                          thumbs: thumbs,
                          isBot: isBot,
                          relation: relation,
                          onClose: { dismiss() },
                          onAvatar: { if !avatarPath.isEmpty { showBigAvatar = true } },
                          onMessage: { openChat() },
                          onVoice: { startCall(video: false) },
                          onVideo: { startCall(video: true) },
                          onAICall: { startAICall() },
                          onMoments: { onOpenMoments(u.id) },
                          onRemark: { showRemark = true },
                          onPerm: { showPerm = true },
                          onMore: { showInfo = true },
                          onMenu: { showMore = true },
                          onApply: { showApply = true },
                          onAgree: { run(CardAct(title: "同意好友申请", key: "agree")) })
    }

    /// 名片上的地区那一行
    private var regionText: String {
        (u.region?.isEmpty == false) ? u.region! : Tr("未知")
    }

    /// 朋友圈那一行要说的那句话：好友设了「最近三天 / 最近半年」、这区间里又没动态时，
    /// 微信写的是「朋友仅展示最近三天的朋友圈」（不是「暂无朋友圈动态」）。
    private var momentsHint: String {
        if !thumbs.isEmpty { return "" }
        switch u.momentsRange ?? "all" {
        case "3d": return "朋友仅展示最近三天的朋友圈"
        case "6m": return "朋友仅展示最近半年的朋友圈"
        default:   return ""
        }
    }

    /// 打真人语音 / 视频通话（WebRTC）
    private func startCall(video: Bool) {
        if CallCenter.shared.phase != .idle {
            app.show(Tr("正在通话中"))
            return
        }
        CallCenter.shared.start(peerId: u.id,
                                name: u.nickname ?? u.username ?? "对方",
                                avatar: u.avatar ?? "",
                                video: video)
    }

    private var cardBody: some View {
        ZStack {
            VStack(spacing: 0) {
                nav
                ScrollView {
                    VStack(spacing: 12) {
                        hero
                        infoCard
                        if hasMoments { momentsCard }
                        acts
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 24)
                    /* 进来时轻轻上浮一下（0.3 秒）：卡片"落"下来，比硬邦邦地出现更有质感。
                       只动 opacity / offset，布局一点没变。 */
                    .opacity(cardIn ? 1 : 0)
                    .offset(y: cardIn ? 0 : 8)
                }
                .background(scrollBg)
            }
            .background(sheetBg.ignoresSafeArea())
        }
        .onAppear { withAnimation(.easeOut(duration: 0.30)) { cardIn = true } }
    }

    /* ---------------------------------------------------------- 导航 */

    /// 右上「⋯」那块面板：暗底 + 一张身份卡 + 一组图标行 + 「取消」。
    /// 条目和以前那张系统动作表一字不差，只是换了个长相。
    private var morePanel: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.36)
                .ignoresSafeArea()
                .onTapGesture { showMore = false }
                .transition(.opacity)

            VStack(spacing: 10) {
                /* 顶部先确认「在操作谁」：头像 + 名字 + 星言号 */
                HStack(spacing: 10) {
                    if isEyesBot {
                        JarvisEyesAvatar(size: 34)
                            .frame(width: 40, height: 40)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(sheetBg))
                    } else {
                        Avatar(path: avatarPath, size: 40, radius: 10,
                               level: (u.qqLevel ?? 0) > 1 ? (u.qqLevel ?? 0) : 0)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(displayName)
                            .font(pf(15.5, .medium))
                            .foregroundColor(C.label)
                            .lineLimit(1)
                        Text(Tr("星言号") + "：" + (u.username ?? "-"))
                            .font(pf(12))
                            .foregroundColor(C.subLabel)
                            .lineLimit(1)
                            /* 2026-10-17 用户：「星言号要长按可以复制」 */
                            .copyOnLongPress(u.username ?? "") { app.show($0) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background { CardGlassBox(radius: 14) }
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(C.hairline, lineWidth: 0.6))

                PanelCard {
                    if isBot {
                        PanelRow(symbol: "message.fill", colors: PanelTint.green,
                                 title: Tr("发消息")) { closeMore { openChat() } }
                        PanelDivider()
                        PanelRow(symbol: "phone.fill", colors: PanelTint.blue,
                                 title: Tr("语音通话")) { closeMore { startAICall() } }
                    } else {
                        /* 和微信那一列一样：设置备注和标签 / 朋友权限 / 星标 / 黑名单 / 投诉 / 删除 */
                        PanelRow(symbol: "tag.fill", colors: PanelTint.green,
                                 title: Tr("设置备注和标签")) { closeMore { showRemark = true } }
                        PanelDivider()
                        /* 微信「…」里也有这一条：把这个人推荐给别的聊天（发一张名片消息过去） */
                        PanelRow(symbol: "square.and.arrow.up", colors: PanelTint.blue,
                                 title: Tr("推荐给朋友")) { closeMore { showShare = true } }
                        PanelDivider()
                        PanelRow(symbol: "lock.shield.fill", colors: PanelTint.blue,
                                 title: Tr("朋友权限")) { closeMore { showPerm = true } }
                        PanelDivider()
                        PanelRow(symbol: meta?.star == true ? "star.slash.fill" : "star.fill",
                                 colors: PanelTint.orange,
                                 title: meta?.star == true ? Tr("取消星标朋友") : Tr("设为星标朋友")) {
                            closeMore { toggleStar() }
                        }
                        PanelDivider()
                        PanelRow(symbol: meta?.block == true ? "hand.raised.slash.fill" : "hand.raised.fill",
                                 colors: PanelTint.purple,
                                 title: meta?.block == true ? Tr("移出黑名单") : Tr("加入黑名单")) {
                            closeMore { toggleBlock() }
                        }
                        PanelDivider()
                        PanelRow(symbol: "exclamationmark.bubble.fill", colors: PanelTint.gray,
                                 title: Tr("投诉")) {
                            closeMore { app.show(Tr("已收到你的投诉，我们会尽快处理")) }
                        }
                        PanelDivider()
                        PanelDangerRow(symbol: "person.badge.minus", title: Tr("删除好友")) {
                            closeMore { confirmDelete = true }
                        }
                    }
                }

                Button { showMore = false } label: {
                    Text(Tr("取消"))
                        .font(pf(16))
                        .foregroundColor(C.label)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background { CardGlassBox(radius: 14) }
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(C.hairline, lineWidth: 0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// 先把面板收起来，再做动作（不然弹出的 sheet 会被压在面板底下）
    private func closeMore(_ then: @escaping () -> Void) {
        showMore = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { then() }
    }

    private var nav: some View {
        NavBar(title: "", back: { dismiss() }) {
            Button { showMore = true } label: {
                FlexIcon(custom: IconOverrides.custom("nav.more"), size: 22,
                         color: ink, symbol: "ellipsis")
                    .frame(width: 44, height: L.navH)
            }
            .buttonStyle(.plain)
        }
        .background(sheetBg)
    }

    /* ---------------------------------------------------------- 头部资料 */

    private var hero: some View {
        /* 高级版：一张深色英雄卡（渐变底 + 右上角金色柔光），头像是描金边的圆角方块 */
        PanelHeroCard(glow: Color(hex: 0xF0C24B)) {
            HStack(alignment: .top, spacing: L.cdHeroGap) {
                avatarHead
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        /* 设了备注名就显示备注（微信就是这样），真昵称挪到下面一行 */
                        Text(displayName)
                            .font(pf(L.cdNameSize, .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .layoutPriority(1)          // 名字优先，别被等级图标挤成省略号
                        /* 等级图标（QQ 那套）：挂在名字后面 */
                        if (u.qqLevel ?? 0) > 0, GrowthFlags.showInProfile != false {
                            QQLevelBadge(level: u.qqLevel ?? 0, size: L.v(15, 4.2, 17), maxIcons: 4)
                                .fixedSize()
                        }
                        /* 性别：直接画个小人（男 = 长裤，女 = 裙子） */
                        GenderMark(gender: u.gender, size: max(15, L.cdGender))
                        Spacer(minLength: 0)
                    }

                    /* 好友设了状态：名字下面挂一小条（图标 + 状态名），点开能看大的 */
                    if statusAlive { statusChip }

                    VStack(alignment: .leading, spacing: 5) {
                        heroLine("昵称：" + ((u.realNickname?.isEmpty == false) ? u.realNickname! : u.name))
                        heroLine("账号：" + ((u.username?.isEmpty == false) ? u.username! : "—"))
                        if isBot {
                            heroLine("简介：" + ((u.bio?.isEmpty == false) ? u.bio! : "您的私人助理"))
                        } else {
                            heroLine("地区：" + ((u.region?.isEmpty == false) ? u.region! : "未知"))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// 名字左边那个大头像：点一下放大看（微信那样，可以保存 / 转发）
    private var avatarHead: some View {
        Group {
            if isEyesBot {
                JarvisEyesAvatar(size: L.cdAvatar * 0.84)
                    .frame(width: L.cdAvatar, height: L.cdAvatar)
                    .background(RoundedRectangle(cornerRadius: max(12, L.cdAvatarRadius), style: .continuous)
                        .fill(Color.white.opacity(0.1)))
            } else {
            Avatar(path: u.avatarPath, size: L.cdAvatar, radius: max(12, L.cdAvatarRadius),
                   level: (u.qqLevel ?? 0) > 1 ? (u.qqLevel ?? 0) : 0)
                    .contentShape(Rectangle())
                    .onTapGesture { if !avatarPath.isEmpty { showBigAvatar = true } }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: max(12, L.cdAvatarRadius), style: .continuous)
            /* 头像描一圈**金色渐变环**（以前是一道灰白的死边）——
               同一张卡里，环亮一点整个人像就"立"起来了 */
            .stroke(LinearGradient(colors: [Color.white.opacity(0.85),
                                            Color(hex: 0xF0C24B).opacity(0.75),
                                            Color.white.opacity(0.25)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1.6))
        .shadow(color: Color.black.opacity(0.38), radius: 12, y: 5)
        .shadow(color: Color(hex: 0xF0C24B).opacity(0.18), radius: 14, y: 2)
    }

    private func heroLine(_ text: String) -> some View {
        /* 资料行拆成「标签 : 值」两段：标签压暗、值提亮 —— 一眼能扫，
           比整行一个灰度的白更"高级"（布局一个字没动） */
        let parts = text.split(separator: "：", maxSplits: 1).map(String.init)
        return HStack(spacing: 3) {
            if parts.count == 2 {
                Text(parts[0] + "：")
                    .foregroundColor(.white.opacity(0.48))
                Text(parts[1])
                    .foregroundColor(.white.opacity(0.9))
            } else {
                Text(text).foregroundColor(.white.opacity(0.82))
            }
        }
        .font(pf(12.5))
        .lineLimit(1)
    }

    /// 好友状态那一小条：图标 + 状态名（点开是大的状态卡）
    private var statusChip: some View {
        let c = MoodColor.clean(u.moodColor)
        let cap = (u.moodCaption ?? "").trimmingCharacters(in: .whitespaces)
        let lab = (u.moodLabel ?? "").trimmingCharacters(in: .whitespaces)
        let text = cap.isEmpty ? (lab.isEmpty ? (u.moodText ?? "") : lab) : cap
        return Button { showStatus = true } label: {
            HStack(spacing: 4) {
                Text(u.moodIcon ?? "🙂")
                Text(text).lineLimit(1)
            }
            .font(pf(12))
            .foregroundColor(.white)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(c.isEmpty ? Color.white.opacity(0.16) : Color(hexString: c)))
            .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.7))
        }
        .buttonStyle(.plain)
    }

    /* ---------------------------------------------------------- 朋友资料 / 电话 */

    private var infoCard: some View {
        PanelCard {
            PanelRow(symbol: "person.text.rectangle.fill", colors: PanelTint.blue,
                     title: Tr("朋友资料")) { showInfo = true }

            if !phone.isEmpty {
                PanelDivider()
                PanelRow(symbol: "phone.fill", colors: PanelTint.green,
                         title: Tr("电话"), value: phone) { showPhone = true }
            }

            if !isBot && relation == "friend" {
                /* 标签（微信在这一栏显示你给他打的标签） */
                PanelDivider()
                PanelRow(symbol: "tag.fill", colors: PanelTint.orange,
                         title: Tr("标签"), value: tagText) { showRemark = true }

                /* 朋友权限（聊天 / 朋友圈 / 黑名单） */
                PanelDivider()
                PanelRow(symbol: "lock.shield.fill", colors: PanelTint.purple,
                         title: Tr("朋友权限"), value: permText) { showPerm = true }

                /* 更多信息：共同群聊 / 来源 / 添加时间（微信在「朋友资料」里给这几行） */
                PanelDivider()
                PanelRow(symbol: "info.circle.fill", colors: PanelTint.gray,
                         title: Tr("更多信息"), value: moreText) { showInfo = true }
            }
        }
    }

    /* ---------------------------------------------------------- 朋友圈那一行 */

    private var momentsCard: some View {
        PanelCard {
            Button { onOpenMoments(u.id) } label: {
                HStack(spacing: 11) {
                    PanelIcon(symbol: "photo.on.rectangle.angled", colors: PanelTint.teal)
                    Text(Tr("朋友圈"))
                        .font(pf(16))
                        .foregroundColor(C.label)
                    Spacer(minLength: 8)
                    /* 缩略图只是让你扫一眼，点了不弹大图 —— 整行都是「进朋友圈」（微信就是这样） */
                    HStack(spacing: 6) {
                        ForEach(thumbs.prefix(3).indices, id: \.self) { i in
                            RemoteImage(path: thumbs[i])
                                .frame(width: 38, height: 38)
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                    }
                    Chevron(size: 9, line: 1.6)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 62)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /* ---------------------------------------------------------- 底部按钮 */

    private struct CardAct {
        var title: String
        var key: String
    }

    private var actList: [CardAct] {
        /* 机器人（AI 助手 / 腾讯新闻）：发消息 + AI 语音通话，别的按钮对它们没意义 */
        if isBot {
            return [CardAct(title: "发消息", key: "msg"),
                    CardAct(title: "语音通话", key: "aicall")]
        }
        switch relation {
        case "friend", "self":
            return [CardAct(title: "发消息", key: "msg"),
                    CardAct(title: "音视频通话", key: "call")]
        case "incoming":
            return [CardAct(title: "同意好友申请", key: "agree"),
                    CardAct(title: "发消息", key: "msg")]
        case "requested":
            return [CardAct(title: "已发送好友申请", key: "pending")]
        default:
            return [CardAct(title: "添加到通讯录", key: "add")]
        }
    }

    private var acts: some View {
        PanelCard {
            ForEach(actList.indices, id: \.self) { i in
                if i > 0 { PanelDivider() }
                actRow(actList[i])
            }
        }
    }

    /// 底部那颗大按（发消息 / 音视频通话 / 添加好友…）：图标 + 文字，第一项是主操作
    private func actRow(_ act: CardAct) -> some View {
        let symbol: String
        let colors: [Color]
        switch act.key {
        case "msg":     symbol = "message.fill";        colors = PanelTint.green
        case "call":    symbol = "video.fill";          colors = PanelTint.blue
        case "aicall":  symbol = "phone.fill";          colors = PanelTint.blue
        case "agree":   symbol = "person.badge.plus";   colors = PanelTint.green
        case "add":     symbol = "person.badge.plus";   colors = PanelTint.green
        default:        symbol = "clock.fill";          colors = PanelTint.gray
        }
        let pending = act.key == "pending"
        return Button { run(act) } label: {
            HStack(spacing: 11) {
                PanelIcon(symbol: symbol, colors: colors)
                Text(act.title)
                    .font(pf(16, .medium))
                    .foregroundColor(pending ? C.subLabel : C.label)
                Spacer(minLength: 0)
                if !pending { Chevron(size: 9, line: 1.6) }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(pending)
    }

    /* ---------------------------------------------------------- 干活 */

    private func run(_ act: CardAct) {
        switch act.key {
        case "msg":
            openChat()
        case "aicall":
            startAICall()
        case "call":
            /* 真人语音通话（WebRTC）。id 就是对方的用户 id，直接呼叫 */
            if CallCenter.shared.phase != .idle {
                app.show(Tr("正在通话中"))
            } else {
                CallCenter.shared.start(peerId: u.id, name: u.nickname ?? u.username ?? "对方",
                                        avatar: u.avatar ?? "", video: false)
            }
        case "add":
            showApply = true
        case "agree":
            busy = true
            Task {
                /* 直接按 userId 同意 —— 以前这里要先拉一遍整份通讯录（手机上 500 多 KB）
                   才能从里面找到 requestId，点一下要等两个来回，所以才觉得慢 */
                let res = await API.shared.respondFriend(userId: u.id, accept: true)
                if res.ok {
                    app.show(Tr("已同意，现在可以聊天了"))
                    if let n = res.pending { app.friendRequests = n }
                    await app.loadContacts()
                    await load()
                } else {
                    app.show(Tr("到「通讯录 → 新的朋友」里同意"))
                }
                busy = false
            }
        default:
            app.show(Tr("已经发过申请了，等对方通过"))
        }
    }

    private func openChat(then after: (() -> Void)? = nil) {
        busy = true
        Task {
            if let chat = try? await API.shared.openDirect(userId: u.id) {
                onOpenChat(chat)
                after?()
            } else {
                app.show(Tr("打不开聊天"))
            }
            busy = false
        }
    }

    private var tagText: String {
        let tags = (meta?.tags ?? []).filter { !$0.isEmpty }
        return tags.isEmpty ? Tr("未设置") : tags.joined(separator: "、")
    }

    private var permText: String {
        if meta?.block == true { return Tr("已加入黑名单") }
        if meta?.noMoments == true { return Tr("不看他的朋友圈") }
        if meta?.hideMyMoments == true { return Tr("不让他看我的朋友圈") }
        return Tr("聊天、朋友圈")
    }

    private var moreText: String {
        var bits: [String] = []
        if let g = u.mutualGroups, g > 0 { bits.append("共同群聊 \(g) 个") }
        if let s = meta?.source, !s.isEmpty { bits.append(s == "me" ? "我添加的" : "他添加的我") }
        bits.append("添加时间 " + (addedText.isEmpty ? "—" : addedText))
        return bits.joined(separator: " · ")
    }

    /// 添加时间：2026-09-22T05:50:45.320Z → 2026年9月22日
    private var addedText: String {
        guard let s = meta?.addedAt, s.count >= 10 else { return "" }
        let y = s.prefix(4), m = s.dropFirst(5).prefix(2), d = s.dropFirst(8).prefix(2)
        return "\(Int(y) ?? 0)年\(Int(m) ?? 0)月\(Int(d) ?? 0)日"
    }

    /// 跟机器人打电话：先找到（或建好）和它的会话，再打开 AI 通话界面
    private func startAICall() {
        busy = true
        Task {
            if let chat = try? await API.shared.openDirect(userId: u.id) {
                aiCall = chat
            } else {
                app.show(Tr("打不开对话"))
            }
            busy = false
        }
    }

    private func dial() {
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        guard !digits.isEmpty, let url = URL(string: "tel://\(digits)") else { return }
        UIApplication.shared.open(url)
    }

    private func load() async {
        if let fresh = try? await API.shared.user(id: user.id) { full = fresh }
        /* 朋友资料：备注名 / 标签 / 星标 / 朋友权限（微信「设置备注和标签」那套） */
        if relation == "friend" || relation == "self" {
            if let m = try? await API.shared.friendMeta(userId: user.id) { meta = m }
        }
        if let list = try? await API.shared.moments(limit: 6, userId: user.id) {
            var images: [String] = []
            for m in list {
                for src in (m.images ?? []) where images.count < 5 {
                    images.append(src)
                }
                /* 视频动态没有 images：用封面顶上（朋友圈/名片上那几格缩略图） */
                if let c = m.videoCover, !c.isEmpty, images.count < 5 {
                    images.append(c)
                }
            }
            thumbs = images
            hasMoments = !list.isEmpty
        }
    }

    /* ---------------------------------------------------------- 朋友资料的几个动作 */

    private func toggleStar() {
        let next = !(meta?.star == true)
        Task {
            await API.shared.setFriendMeta(userId: u.id, star: next)
            await load()
            app.show(next ? Tr("已设为星标朋友") : Tr("已取消星标"))
        }
    }

    private func toggleBlock() {
        let next = !(meta?.block == true)
        Task {
            await API.shared.setFriendMeta(userId: u.id, block: next)
            await load()
            app.show(next ? Tr("已加入黑名单，他发不了消息给你") : Tr("已移出黑名单"))
        }
    }

    private func removeFriend() {
        Task {
            if let err = await API.shared.removeFriend(userId: u.id) {
                app.show(err)
                return
            }
            /* 先退回去、再刷通讯录：反过来的话这个人的数据先从列表里没了，
               这一页的路径值就失效了，dismiss() 会退不动（用户反馈的「删除后不跳转」）。 */
            dismiss()
            await app.loadContacts()
            /* 微信那套：删了好友，**这个会话也从我的列表里消失**
               （服务端会把它对我隐藏，这里立刻把会话列表刷一遍） */
            await app.loadChats()
            app.show(Tr("已删除好友"))
        }
    }
}

/* 性别图标：微信那对蓝色小图标（男 ♂ / 女 ♀），照网页版的 SVG 画 */
struct GenderMark: View {
    let gender: String?
    var size: CGFloat = 14

    var body: some View {
        Group {
            if gender == "male" {
                figure(male: true)
            } else if gender == "female" {
                figure(male: false)
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        }
    }

    /* 男 / 女不再用 ♂ ♀ 那两个箭头，改成「小人」：
       男 = 圆头 + 方肩长裤（中间开一条腿缝）；女 = 圆头 + A 字裙。
       先在 24×24 的画布上按坐标画好，再整体缩到要用的尺寸，所以放到多大都清晰。 */
    private func figure(male: Bool) -> some View {
        let tint = male ? Color(hex: 0x10AEFF) : Color(hex: 0xFF7BA9)
        return ZStack {
            Path { p in
                p.addEllipse(in: CGRect(x: 8.1, y: 1.8, width: 7.8, height: 7.8))
            }
            .fill(tint)

            Path { p in
                if male {
                    p.move(to: CGPoint(x: 5.6, y: 22.2))
                    p.addLine(to: CGPoint(x: 8.1, y: 11.4))
                    p.addLine(to: CGPoint(x: 15.9, y: 11.4))
                    p.addLine(to: CGPoint(x: 18.4, y: 22.2))
                    p.addLine(to: CGPoint(x: 14.2, y: 22.2))
                    p.addLine(to: CGPoint(x: 12.0, y: 16.6))
                    p.addLine(to: CGPoint(x: 9.8, y: 22.2))
                } else {
                    p.move(to: CGPoint(x: 12.0, y: 11.0))
                    p.addLine(to: CGPoint(x: 18.8, y: 22.2))
                    p.addLine(to: CGPoint(x: 5.2, y: 22.2))
                }
                p.closeSubpath()
            }
            .fill(tint)
        }
        .frame(width: 24, height: 24)
        .scaleEffect(size / 24, anchor: .center)
        .frame(width: size, height: size)
    }
}


