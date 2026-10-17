import SwiftUI

/* ============================================================
   搜一搜（照着微信那套）：
   · 顶部搜索框 + 取消；没输入时显示「最近搜索」（可清空）
   · 一串「搜索指定内容」：全部 / 联系人 / 群聊 / 朋友圈 / 视频号 / 聊天记录
   · 输入后按分类分组给结果（带条数、命中文字高亮）
   · 点结果：联系人进资料页、群聊开会话、聊天记录跳到那个会话、朋友圈去朋友圈、视频号去视频
   ============================================================ */

struct SearchAllData: Decodable {
    struct Person: Decodable, Hashable, Identifiable { var id: String; var name: String?; var username: String?; var avatar: String? }
    struct Group: Decodable, Hashable, Identifiable { var id: String; var name: String?; var avatar: String?; var members: Int? }
    struct Post: Decodable, Hashable, Identifiable { var id: String; var author: String?; var content: String?; var images: [String]?; var createdAt: String? }
    struct Video: Decodable, Hashable, Identifiable { var id: String; var title: String?; var cover: String?; var author: String? }
    struct ChatHit: Decodable, Hashable, Identifiable {
        var chatId: String
        var isGroup: Bool?
        var chatTitle: String?
        var peerId: String?
        var messageId: String
        var sender: String?
        var text: String?
        var at: String?
        var id: String { messageId }
    }
    var people: [Person]?
    var groups: [Group]?
    var moments: [Post]?
    var videos: [Video]?
    var messages: [ChatHit]?
}

struct SearchAllView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var q = ""
    @State private var scope = "all"
    @State private var data: SearchAllData?
    @State private var searching = false
    @State private var history: [String] = ContactSearchHistory.load()
    @FocusState private var focused: Bool
    @State private var task: Task<Void, Never>?
    /// 点结果要去的地方（都在这个页面里弹出，避免和发现页的导航栈打架）
    @State private var pickedUser: User?
    @State private var showMoments = false
    @State private var showChannels = false

    private let scopes: [(String, String)] = [
        ("all", "全部"), ("people", "联系人"), ("groups", "群聊"),
        ("moments", "朋友圈"), ("videos", "视频号"), ("messages", "聊天记录")
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    SVGIcon(markup: I.searchSmall, size: 16, color: C.searchIcon)
                    TextField("", text: $q, prompt: Text(Tr("搜索")).foregroundColor(C.searchIcon))
                        .font(pf(16)).foregroundColor(C.label)
                        .focused($focused)
                        .submitLabel(.search)
                        .onSubmit { remember() }
                    if !q.isEmpty {
                        Button { q = ""; data = nil } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundColor(C.searchIcon)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(C.searchBg))
                Button(Tr("取消")) { dismiss() }
                    .font(pf(16)).foregroundColor(C.label).buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, L.safeTop)
            .padding(.bottom, 8)
            .background(C.chatsTopBg.ignoresSafeArea(edges: .top))

            /* 搜索指定内容：横向一排，点一下就切范围（微信就是这排） */
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(scopes, id: \.0) { s in
                        Button {
                            scope = s.0
                            runSearch()
                        } label: {
                            Text(Tr(s.1))
                                .font(pf(13))
                                .foregroundColor(scope == s.0 ? .white : C.label)
                                .padding(.horizontal, 12)
                                .frame(height: 28)
                                .background(Capsule().fill(scope == s.0 ? C.green : C.cardBg))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.vertical, 8)

            ScrollView {
                VStack(spacing: 0) {
                    if q.isEmpty {
                        if history.isEmpty {
                            VStack(spacing: 8) {
                                SVGIcon(markup: I.searchBig, size: 42, color: C.subLabel)
                                Text(Tr("搜聊天记录、联系人、群聊、朋友圈、视频号")).font(pf(14)).foregroundColor(C.subLabel)
                            }
                            .frame(maxWidth: .infinity).padding(.top, 60)
                        } else {
                            HStack {
                                Text(Tr("最近搜索")).font(pf(13)).foregroundColor(C.subLabel)
                                Spacer(minLength: 0)
                                Button {
                                    ContactSearchHistory.clear(); history = []
                                } label: { Text(Tr("清空")).font(pf(13)).foregroundColor(C.subLabel) }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 16).frame(height: 34)
                            ForEach(history, id: \.self) { h in
                                Button { q = h; runSearch() } label: {
                                    HStack(spacing: 8) {
                                        SVGIcon(markup: I.searchSmall, size: 15, color: C.subLabel)
                                        Text(h).font(pf(15)).foregroundColor(C.label)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 16).frame(height: 46)
                                    .background(C.cardBg).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                HairLine(inset: 16)
                            }
                        }
                    } else if searching {
                        ProgressView().padding(.top, 40)
                    } else {
                        results
                    }
                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.chatsTopBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .onAppear { focused = true }
        .onChange(of: q) { _ in runSearch() }
        .sheet(item: $pickedUser) { u in
            NavigationView {
                ContactCardView(user: u,
                                onOpenChat: { chat in
                                    pickedUser = nil
                                    app.openChatViaList(chat)
                                },
                                onOpenMoments: { _ in
                                    pickedUser = nil
                                    showMoments = true
                                })
            }
            .environmentObject(app)
        }
        .fullScreenCover(isPresented: $showMoments) { MomentsView().environmentObject(app) }
        .fullScreenCover(isPresented: $showChannels) { ChannelsView().environmentObject(app) }
    }

    @ViewBuilder private var results: some View {
        let d = data
        let people = d?.people ?? []
        let groups = d?.groups ?? []
        let moments = d?.moments ?? []
        let videos = d?.videos ?? []
        let msgs = d?.messages ?? []
        if people.isEmpty && groups.isEmpty && moments.isEmpty && videos.isEmpty && msgs.isEmpty {
            VStack(spacing: 8) {
                SVGIcon(markup: I.searchBig, size: 42, color: C.subLabel)
                Text(Tr("没有找到") + "「" + q + "」" + Tr("相关的内容")).font(pf(14)).foregroundColor(C.subLabel)
            }
            .frame(maxWidth: .infinity).padding(.top, 60)
        }
        if !people.isEmpty {
            header(Tr("联系人"), people.count)
            ForEach(people) { p in
                row(tap: { pickedUser = User(id: p.id) }) {
                    Avatar(path: p.avatar ?? "", size: 40, radius: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        highlightMatch(p.name ?? "", q).font(pf(15.5)).foregroundColor(C.label)
                        if let u = p.username, !u.isEmpty {
                            highlightMatch(u, q).font(pf(13)).foregroundColor(C.subLabel)
                        }
                    }
                }
            }
        }
        if !groups.isEmpty {
            header(Tr("群聊"), groups.count)
            ForEach(groups) { g in
                row(tap: { openChat(g.id) }) {
                    Avatar(path: g.avatar ?? "", size: 40, radius: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        highlightMatch(g.name ?? "", q).font(pf(15.5)).foregroundColor(C.label)
                        Text(Tr("\((g.members ?? 0)) 人")).font(pf(12.5)).foregroundColor(C.subLabel)
                    }
                }
            }
        }
        if !msgs.isEmpty {
            header(Tr("聊天记录"), msgs.count)
            ForEach(msgs) { m in
                row(tap: { openChat(m.chatId) }) {
                    Avatar(path: "", size: 40, radius: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(m.chatTitle ?? "").font(pf(15)).foregroundColor(C.label).lineLimit(1)
                            if (m.isGroup ?? false) { Text(Tr("群")).font(pf(11)).foregroundColor(C.subLabel) }
                            Spacer(minLength: 0)
                            Text(shortDate(m.at)).font(pf(12)).foregroundColor(C.subLabel)
                        }
                        highlightMatch(m.text ?? "", q).font(pf(13.5)).foregroundColor(C.subLabel).lineLimit(1)
                    }
                }
            }
        }
        if !moments.isEmpty {
            header(Tr("朋友圈"), moments.count)
            ForEach(moments) { p in
                row(tap: { showMoments = true }) {
                    Avatar(path: "", size: 40, radius: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.author ?? "").font(pf(14)).foregroundColor(C.label)
                        highlightMatch(p.content ?? "", q).font(pf(13.5)).foregroundColor(C.subLabel).lineLimit(2)
                    }
                }
            }
        }
        if !videos.isEmpty {
            header(Tr("视频号"), videos.count)
            ForEach(videos) { v in
                row(tap: { showChannels = true }) {
                    Avatar(path: v.cover ?? "", size: 40, radius: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        highlightMatch(v.title ?? "", q).font(pf(15)).foregroundColor(C.label).lineLimit(1)
                        Text(v.author ?? "").font(pf(12.5)).foregroundColor(C.subLabel)
                    }
                }
            }
        }
    }

    private func header(_ t: String, _ n: Int) -> some View {
        HStack {
            Text(t + "（\(n)）").font(pf(13)).foregroundColor(C.subLabel)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).frame(height: 32).background(C.pageBg)
    }

    /* 注意：泛型别叫 C —— 会把颜色调色板 C 遮蔽掉（C.cardBg 就取不到了，编译直接报错） */
    private func row<Content: View>(tap: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                content()
                Spacer(minLength: 0)
                Chevron(size: 8, line: 1.4)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .background(C.cardBg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func shortDate(_ s: String?) -> String {
        guard let s = s, s.count >= 16 else { return "" }
        return String(s.prefix(10))
    }

    private func remember() {
        guard !q.isEmpty else { return }
        ContactSearchHistory.add(q)
        history = ContactSearchHistory.load()
    }

    /// 打开一个会话（搜到的是 chatId，本地 chats 里查一下再打开）
    private func openChat(_ id: String) {
        if let c = app.chats.first(where: { $0.id == id }) {
            app.openChatViaList(c)
        } else {
            app.show(Tr("这个会话不在你的列表里"))
        }
    }

    private func runSearch() {
        task?.cancel()
        let key = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { data = nil; return }
        searching = true
        task = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)     // 打字防抖
            if Task.isCancelled { return }
            let got = try? await API.shared.searchAll(key, scope: scope)
            if Task.isCancelled { return }
            await MainActor.run {
                data = got
                searching = false
            }
        }
    }
}
