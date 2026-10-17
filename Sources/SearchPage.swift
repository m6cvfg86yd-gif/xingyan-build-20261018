import SwiftUI
import UIKit

/* ============================================================
   搜索（微信点会话页那个搜索框进的就是这一页）
   · 顶部：搜索框（自动聚焦）+「取消」
   · 没输内容时：「搜索指定内容」一排（聊天记录 / 联系人 / 群聊 / 朋友圈 / 视频号）+「最近搜索」
   · 输了内容：分「聊天记录 / 联系人 / 群聊」三组出结果，点一条直接进聊天/名片
   ============================================================ */
struct SearchPage: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    var onOpenChat: ((Chat) -> Void)? = nil
    var onOpenUser: ((User) -> Void)? = nil
    /// 要不要那颗「语音球」（2026-10-16 用户：通讯录搜索框起来时，键盘上方居中一颗，
    /// 键盘消失跟着消失 —— 默认关，只有通讯录那条路传 true）
    var voiceBall: Bool = false

    @State private var q = ""
    @State private var scope = "all"
    /// 搜索历史：本机最多 20 条、自动去重、最近搜的在最前（SearchHistory 统一管着）
    @State private var history: [String] = []
    /// 猜你想搜：后台配的优先，拉不到/断网就用内置那组
    @State private var hot: [String] = SearchSuggest.shown
    @FocusState private var focused: Bool
    /// 语音搜索（复用聊天里那套 Dictation：说出来的字直接填进搜索框）
    @StateObject private var dictation = Dictation()
    /// 键盘现在多高（0 = 没起来）—— 语音球就挂在键盘正上方
    @State private var kbHeight: CGFloat = 0

    private let scopes: [(String, String, String)] = [
        ("all", "全部", "magnifyingglass"),
        ("chat", "聊天记录", "bubble.left.and.bubble.right"),
        ("user", "联系人", "person.crop.circle"),
        ("group", "群聊", "person.2"),
        ("moments", "朋友圈", "photo.on.rectangle.angled"),
        ("feed", "视频号", "play.rectangle")
    ]

    private var key: String { q.trimmingCharacters(in: .whitespaces) }

    private var chats: [Chat] {
        let base = app.chats.filter { $0.botRank != 0 }
        if key.isEmpty { return [] }
        return base.filter { c in
            chatTitle(c).localizedCaseInsensitiveContains(key)
        }
    }

    /// 会话标题：群聊用群名，单聊用对方的昵称（本地算，不依赖别的辅助函数）
    private func chatTitle(_ c: Chat) -> String {
        if let t = c.title, !t.isEmpty { return t }
        if let peerId = (c.memberIds ?? []).first(where: { $0 != (app.me?.id ?? "") }),
           let u = app.contact(for: peerId) {
            return u.name
        }
        return Tr("聊天")
    }

    /// 会话头像：群聊用群头像，单聊用对方头像
    private func chatAvatar(_ c: Chat) -> String {
        if let a = c.avatar, !a.isEmpty { return a }
        if let peerId = (c.memberIds ?? []).first(where: { $0 != (app.me?.id ?? "") }),
           let u = app.contact(for: peerId) {
            return u.avatarPath
        }
        return ""
    }
    private var groups: [Chat] { scope == "all" || scope == "group" ? chats.filter { $0.type == "group" } : [] }
    private var directChats: [Chat] { scope == "group" ? [] : chats.filter { $0.type != "group" } }
    private var contacts: [User] {
        if key.isEmpty || scope == "chat" || scope == "group" { return [] }
        return app.contacts.filter { ($0.nickname ?? "").localizedCaseInsensitiveContains(key)
            || ($0.username ?? "").localizedCaseInsensitiveContains(key) }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(C.searchIcon)
                    TextField(Tr("搜索"), text: $q)
                        .font(pf(14.5))
                        .focused($focused)
                        .submitLabel(.search)
                        .onSubmit { remember(key) }
                    if !key.isEmpty {
                        Button { q = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15)).foregroundColor(C.searchIcon)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(C.searchBg))

                Button { dismiss() } label: {
                    Text(Tr("取消")).font(pf(16)).foregroundColor(C.label)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    if key.isEmpty {
                        scopeRow
                        if !history.isEmpty { historyBlock }
                        if !hot.isEmpty { suggestBlock }
                        Text(Tr("输入关键词就能搜会话、联系人和群聊"))
                            .font(pf(12.5)).foregroundColor(C.subLabel)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30)
                    } else {
                        scopeRow
                        if !directChats.isEmpty { sectionBlock(Tr("聊天记录"), directChats, isGroup: false) }
                        if !groups.isEmpty { sectionBlock(Tr("群聊"), groups, isGroup: true) }
                        if !contacts.isEmpty { contactBlock }
                        if directChats.isEmpty && groups.isEmpty && contacts.isEmpty {
                            Text(Tr("没有找到 ") + "「\(key)」")
                                .font(pf(14)).foregroundColor(C.subLabel)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        }
                    }
                    Color.clear.frame(height: 24)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())

        /* ★ 语音球：键盘起来 → 出现在键盘正上方、水平居中；键盘一收就跟着没了。
           （这一层自己 ignoresSafeArea(.keyboard)，所以位置能按 kbHeight 精确算，
             不会被系统那套"把整页顶上去"的内缩二次平移。） */
        GeometryReader { g in
            if voiceBall, kbHeight > 1 {
                VoiceOrb(level: dictation.listening ? 0.55 : 0.16,
                         diameter: 92,
                         listening: dictation.listening)
                    .position(x: g.size.width / 2,
                              y: max(70, g.size.height - kbHeight - 62))
                    .transition(.opacity.combined(with: .scale(scale: 0.86)))
                    .onTapGesture {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        /* 点一下开始听、再点一下收工；识别到的字实时填进搜索框 */
                        dictation.toggle { t in q = t }
                    }
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .allowsHitTesting(voiceBall && kbHeight > 1)
        .animation(.easeOut(duration: 0.22), value: kbHeight)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            focused = true
            history = SearchHistory.all
        }
        /* 进页拉一次「猜你想搜」（后台配的）；拉不到就还用内置那组 */
        .task { await loadHot() }
        /* 键盘高度：起来 → 球出现；收起来 → 球消失 */
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { n in
            guard let f = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let h = max(0, UIScreen.main.bounds.height - f.minY)
            if abs(h - kbHeight) > 0.5 {
                withAnimation(.easeOut(duration: 0.22)) { kbHeight = h }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            if kbHeight != 0 {
                dictation.stop()
                withAnimation(.easeOut(duration: 0.22)) { kbHeight = 0 }
            }
        }
        .onDisappear { dictation.stop() }
    }

    private var scopeRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(scopes, id: \.0) { s in
                    let on = (scope == s.0)
                    Button { scope = s.0 } label: {
                        HStack(spacing: 5) {
                            Image(systemName: s.2).font(.system(size: 12, weight: .medium))
                            Text(Tr(s.1)).font(pf(13))
                        }
                        .foregroundColor(on ? .white : C.subLabel)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(Capsule().fill(on ? C.green : C.cardBg))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
    }

    /// 搜索历史：本机 20 条，最近的在最前；**每个词一个圆角框**、词与词之间留距离，
    /// 右边一个垃圾桶一键清空（用户要的排版）
    private var historyBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(Tr("搜索历史")).font(pf(13)).foregroundColor(C.subLabel)
                Spacer(minLength: 0)
                Button {
                    SearchHistory.clear()
                    withAnimation(.easeOut(duration: 0.18)) { history = [] }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(C.subLabel)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)

            ChipFlow(spacing: 10, lineSpacing: 10) {
                ForEach(history, id: \.self) { r in
                    chip(r, icon: "clock.arrow.circlepath") {
                        remember(r)                 // 点过的挪到最前
                        q = r                       // 直接搜
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
        }
        .background(C.cardBg)
        .padding(.top, 10)
    }

    /// 猜你想搜：后台配的词，每个也是**一个圆角框**，一行大概 3~4 个，点一下直接搜
    private var suggestBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Tr("猜你想搜"))
                .font(pf(13)).foregroundColor(C.subLabel)
                .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)
            ChipFlow(spacing: 10, lineSpacing: 10) {
                ForEach(hot, id: \.self) { w in
                    chip(w) {
                        remember(w)
                        q = w
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
        }
        .background(C.cardBg)
        .padding(.top, 10)
    }

    /// 一个词长什么样：圆角外框（浅色/深色两套底色 + 一圈细边），里面可带个小图标
    private func chip(_ text: String, icon: String? = nil, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 5) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(C.subLabel)
                }
                Text(text).font(pf(14)).foregroundColor(C.label).lineLimit(1)
            }
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.dyn(0xEDEDF0, 0x2C2C31)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.dyn(0xD5D5DA, 0x3A3A40), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }

    private func sectionBlock(_ title: String, _ list: [Chat], isGroup: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(pf(13)).foregroundColor(C.subLabel)
                .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 6)
            ForEach(list) { c in
                Button {
                    remember(key)
                    onOpenChat?(c)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Avatar(path: chatAvatar(c), size: 40, radius: isGroup ? 6 : 4)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(chatTitle(c)).font(pf(16)).foregroundColor(C.label)
                            if let p = c.lastMessage?.preview, !p.isEmpty {
                                Text(p).font(pf(12.5)).foregroundColor(C.subLabel).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14).frame(height: 60)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                HairLine(inset: 66)
            }
        }
        .background(C.cardBg)
        .padding(.top, 10)
    }

    private var contactBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Tr("联系人")).font(pf(13)).foregroundColor(C.subLabel)
                .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 6)
            ForEach(contacts) { u in
                Button {
                    remember(key)
                    onOpenUser?(u)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Avatar(path: u.avatarPath, size: 40, radius: 4)
                        Text(u.name).font(pf(16)).foregroundColor(C.label)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14).frame(height: 60)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                HairLine(inset: 66)
            }
        }
        .background(C.cardBg)
        .padding(.top, 10)
    }

    /// 记一条搜索历史（本机、自动去重、最多 20 条）
    private func remember(_ text: String) {
        SearchHistory.add(text)
        history = SearchHistory.all
    }

    /// 「猜你想搜」：后台配的优先，拉不到就用内置那组（界面照常有东西点）
    private func loadHot() async {
        if let words = try? await API.shared.searchHot(), !words.isEmpty {
            SearchSuggest.remote = words
            hot = SearchSuggest.shown
        }
    }
}

/* ============================================================
   一行摆不下就换行的「胶囊流」（微信那种灰底圆角小胶囊排版）
   ============================================================ */
struct ChipFlow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > maxW { x = 0; y += lineH + lineSpacing; lineH = 0 }
            x += sz.width + spacing
            lineH = max(lineH, sz.height)
        }
        return CGSize(width: maxW, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + sz.width > bounds.maxX {
                x = bounds.minX; y += lineH + lineSpacing; lineH = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            lineH = max(lineH, sz.height)
        }
    }
}
