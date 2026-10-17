import SwiftUI

/* ============================================================
   群聊信息页（微信「聊天信息」那一页）
   · 顶部是群头像（就是服务器用成员头像拼的九宫格）+ 群名 + 人数
   · 群聊成员：5 个一行铺开，顺序和九宫格头像一致
   · 群聊名称 / 群公告 / 群主
   · 置顶聊天开关、删除该聊天
   ============================================================ */
struct GroupInfoView: View {
    @ObservedObject private var lang = LangStore.shared
    let chat: Chat

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var members: [User] = []
    @State private var ownerId = ""
    @State private var createdAt = ""
    @State private var loading = true
    @State private var pinned = false
    @State private var saving = false
    /* 补齐的那几项：群公告、群名称（群主可改）、群屏蔽、清空记录、退群/解散 */
    @State private var muted = false
    /// 阅后即焚：开着的时候这个群里发的消息，读过 8 秒后自动消失
    @State private var burn = false
    /// 2026-10-16 用户：「开启阅后即焚必须人脸识别，用我们自己那套」——开之前先走人脸核身
    @State private var faceForBurn = false
    @State private var announce = ""
    @State private var showAnnounce = false
    @State private var announceDraft = ""
    @State private var showRename = false
    @State private var nameDraft = ""
    @State private var showSearch = false
    /// 群里的「设置当前聊天背景」（微信那个「选择背景图」）
    @State private var showGroupBg = false
    @State private var confirmClear = false
    @State private var confirmQuit = false
    @State private var kickTarget: User?
    @State private var showQR = false
    @State private var muteAll = false
    @State private var kickMode = "kick"          // kick = 移出群聊，mute = 禁言
    /// 加人：选人面板 + 删除成员模式（微信群管理那个「＋ / －」）
    @State private var showAdd = false
    @State private var removing = false
    /* 群昵称（微信「设置群昵称」）：改了以后群里显示的就是它 */
    @State private var showAlias = false
    @State private var aliasDraft = ""
    @State private var aliasTarget: User?      // nil = 改我自己的（我在本群的昵称）
    @State private var aliasTitle = "设置群昵称"
    /// 点群成员看他的资料
    @State private var cardUser: User?

    private var isOwner: Bool { !ownerId.isEmpty && ownerId == app.me?.id }

    /// 我在本群的昵称（没设就是空串）
    private var myAlias: String {
        members.first(where: { $0.id == app.me?.id })?.alias ?? ""
    }

    private let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 5)

    private var ownerName: String {
        if let u = members.first(where: { $0.id == ownerId }) { return u.name }
        return "群主"
    }

    /// 建群时间：2026-09-21 → 2026年9月21日
    private var createdText: String {
        guard createdAt.count >= 10 else { return "" }
        let y = createdAt.prefix(4)
        let m = createdAt.dropFirst(5).prefix(2)
        let d = createdAt.dropFirst(8).prefix(2)
        return "\(Int(y) ?? 0)年\(Int(m) ?? 0)月\(Int(d) ?? 0)日"
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("聊天信息"), back: { dismiss() })

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    headCard
                    /* 群成员这一节的小标题右边还挂着「＋ / －」（群管理） */
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Text(Tr("群成员") + "（\(members.count)）")
                                .font(pf(12.5, .medium))
                                .foregroundColor(C.subLabel)
                            Spacer(minLength: 0)
                            /* 微信群管理那套：一个「＋」加人、一个「－」切到删除模式（群主才有） */
                            PanelCircleButton(symbol: "plus") { showAdd = true }
                            if isOwner {
                                PanelCircleButton(symbol: removing ? "checkmark" : "minus",
                                                  tint: removing ? C.green : C.label) {
                                    withAnimation(.easeOut(duration: 0.15)) { removing.toggle() }
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.top, 14)
                        .padding(.bottom, 6)
                        memberCard
                    }
                    PanelSectionTitle(text: Tr("群聊设置"))
                    infoCard
                    switchCard
                    PanelSectionTitle(text: Tr("危险操作"))
                    dangerCard
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 30)
            }
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task {
            /* ⚠ 取**会话列表里最新那份**，不能用传进来的快照：
               这个页面的 `chat` 是进聊天页那一刻的拷贝，别人（或自己在聊天页里）
               改过阅后即焚之后，快照里还是旧的 —— 用户反馈的
               「阅后即焚按钮还勾着」就是这个。 */
            let live = app.chats.first { $0.id == chat.id } ?? chat
            pinned = live.pinned == true
            muted = live.muted == true
            burn = live.burn == true
            muteAll = live.muteAll == true
            if let r = try? await API.shared.chatMembers(chatId: chat.id) {
                members = r.members
                ownerId = r.ownerId
                createdAt = r.createdAt
            }
            announce = chatAnnounceFromList()
            loading = false
        }
        /* 群公告：**单独一整页**（不再是半屏 sheet），和微信一致 */
        .navigationDestination(isPresented: $showAnnounce) { announceEditor }
        .sheet(isPresented: $showRename) { renameEditor }
        .sheet(isPresented: $showAlias) { aliasEditor }
        /* 三级页也统一改成 push 整页（查找聊天记录 / 群二维码 / 加人 / 群成员名片） */
        .navigationDestination(isPresented: Binding(
            get: { cardUser != nil },
            set: { if !$0 { cardUser = nil } }
        )) {
            if let u = cardUser {
                ContactCardView(user: u,
                                onOpenChat: { _ in cardUser = nil },
                                onOpenMoments: { _ in cardUser = nil })
                    .environmentObject(app)
            }
        }
        .navigationDestination(isPresented: $showSearch) { ChatSearchView(chat: chat) }
        .sheet(isPresented: $showGroupBg) {
            ChatBackgroundSheet(chatId: chat.id).environmentObject(app)
        }
        .navigationDestination(isPresented: $showQR) { GroupQRView(chat: chat) }
        .navigationDestination(isPresented: $showAdd) {
            GroupAddMembersView(chat: chat, existing: members.map { $0.id }) { names in
                app.show(names.isEmpty ? Tr("没有新增成员") : (Tr("已邀请 ") + names.joined(separator: "、") + Tr(" 进群")))
                Task {
                    if let r = try? await API.shared.chatMembers(chatId: chat.id) { members = r.members }
                    await app.loadChats()
                }
            }
        }
        /* 清空聊天记录：也是自己画的确认框（和「移出群聊」同一套，字看得清） */
        .overlay {
            if confirmClear {
                PanelConfirmDialog(title: Tr("确定要清空这个聊天的记录吗？"),
                                   okText: Tr("清空"), danger: true,
                                   onOk: { confirmClear = false; clearHistory() },
                                   onCancel: { confirmClear = false })
            }
        }
        /* 退出/解散群聊：同样用自己画的确认框（红字看得清） */
        .overlay {
            if confirmQuit {
                PanelConfirmDialog(title: isOwner ? "解散并退出该群聊？" : "退出该群聊？",
                                   okText: isOwner ? Tr("解散并退出") : Tr("退出"),
                                   danger: true,
                                   onOk: { confirmQuit = false; quitGroup() },
                                   onCancel: { confirmQuit = false })
            }
        }
        /* 移出群聊 / 禁言：用**我们自己画的确认框**（微信那种白卡 + 红字）
           —— 系统 confirmationDialog 的标题又小又灰，用户反馈「移出群聊看不清」。 */
        .overlay {
            if let target = kickTarget {
                PanelConfirmDialog(
                    title: kickMode == "kick"
                        ? ("确定要将「" + target.name + "」移出群聊吗？")
                        : ("确定要将「" + target.name + "」禁言吗？"),
                    okText: kickMode == "kick" ? Tr("移出群聊") : Tr("禁言"),
                    danger: true,
                    onOk: { if kickMode == "kick" { kick() } else { muteMember() } },
                    onCancel: { kickTarget = nil })
            }
        }
    }

    private func muteMember() {
        guard let target = kickTarget else { return }
        Task {
            if let err = await API.shared.setMemberMuted(chatId: chat.id, userId: target.id, muted: true) {
                app.show(err)
            } else {
                app.show("已禁言 \(target.name)")
            }
            kickTarget = nil
        }
    }

    /// 群公告从会话列表数据里取（chat.announce），不用再发一次请求
    private func chatAnnounceFromList() -> String { chat.announce ?? "" }

    private var announceEditor: some View {
        /* 照微信：**一整页**的编辑器 —— 顶栏「群公告」+ 右上「发布」，
           下面一整块可以随便写的输入区（不是那种卡片式表单）。 */
        GroupAnnounceEditor(text: $announceDraft, editable: isOwner,
                            onClose: { closeEditors() },
                            onPublish: { saveAnnounce() })
    }

    private var renameEditor: some View {
        editorSheet(title: "修改群名称",
                    icon: "pencil", colors: PanelTint.blue,
                    placeholder: "群名称（最多 30 字）",
                    hint: "群名会显示在所有成员的会话列表里",
                    limit: 30, singleLine: true,
                    text: $nameDraft, editable: true) {
            saveName()
        }
    }

    /* 群昵称（微信「设置群昵称」）：一行输入 + 保存 */
    private var aliasEditor: some View {
        editorSheet(title: aliasTitle,
                    icon: "character.cursor.ibeam", colors: PanelTint.purple,
                    placeholder: "最多 16 个字",
                    hint: "群昵称只在这个群里显示；留空就是取消",
                    limit: 16, singleLine: true,
                    text: $aliasDraft, editable: true) {
            saveAlias()
        }
    }

    /// 打开群昵称编辑：target 传 nil 就是改我自己的
    private func editAlias(_ target: User?) {
        aliasTarget = target
        aliasTitle = (target == nil || target?.id == app.me?.id)
            ? Tr("我在本群的昵称") : Tr("设置群昵称")
        aliasDraft = target?.alias ?? members.first(where: { $0.id == app.me?.id })?.alias ?? ""
        showAlias = true
    }

    private func saveAlias() {
        let target = aliasTarget?.id ?? (app.me?.id ?? "")
        let text = aliasDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let ok = await API.shared.setGroupAlias(chatId: chat.id, userId: target, alias: text)
            showAlias = false
            guard ok else { app.show(Tr("没保存上，再试一次")); return }
            /* 本地立刻生效（别的成员那边服务端会推给他们） */
            if let i = members.firstIndex(where: { $0.id == target }) { members[i].alias = text }
            app.show(text.isEmpty ? Tr("群昵称已取消") : Tr("群昵称已设置"))
        }
    }

    /// 群名称 / 群公告 / 群昵称这三页共用的一张「高级版」编辑页：
    /// 顶上一条导航（取消 + 绿色胶囊保存），下面一张圆角卡 —— 卡头是图标 + 说明 + 字数，
    /// 卡身就是输入框（单行 / 多行两套），底下再挂一句提示。逻辑和以前一模一样。
    private func editorSheet(title: String, icon: String, colors: [Color],
                             placeholder: String, hint: String, limit: Int,
                             singleLine: Bool,
                             text: Binding<String>, editable: Bool,
                             onSave: @escaping () -> Void) -> some View {
        let count = text.wrappedValue.count
        let over = count > limit
        return VStack(spacing: 0) {
            NavBar(title: title, back: { closeEditors() }) {
                if editable {
                    Button { onSave() } label: {
                        Text(Tr("保存"))
                            .font(pf(14.5, .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 15)
                            .frame(height: 32)
                            .background(Capsule().fill(over
                                ? AnyShapeStyle(C.subLabel.opacity(0.5))
                                : AnyShapeStyle(LinearGradient(colors: PanelTint.green,
                                                                startPoint: .topLeading,
                                                                endPoint: .bottomTrailing))))
                            .padding(.trailing, 14)
                    }
                    .buttonStyle(.plain)
                    .disabled(over)
                }
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    PanelCard {
                        /* 卡头：图标 + 在改什么 + 已经写了几个字 */
                        HStack(spacing: 11) {
                            PanelIcon(symbol: icon, colors: colors)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(title)
                                    .font(pf(16, .medium))
                                    .foregroundColor(C.label)
                                Text(hint)
                                    .font(pf(12))
                                    .foregroundColor(C.subLabel)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            Text("\(count)/\(limit)")
                                .font(pf(12.5, .medium))
                                .foregroundColor(over ? C.red : C.subLabel)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)

                        PanelDivider()

                        /* 卡身：真正写东西的地方 */
                        if singleLine {
                            ZStack(alignment: .leading) {
                                if text.wrappedValue.isEmpty {
                                    Text(placeholder)
                                        .font(pf(16))
                                        .foregroundColor(C.subLabel.opacity(0.8))
                                }
                                TextField("", text: text)
                                    .font(pf(16))
                                    .foregroundColor(C.label)
                                    .disabled(!editable)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 58)
                        } else {
                            ZStack(alignment: .topLeading) {
                                if text.wrappedValue.isEmpty {
                                    Text(placeholder)
                                        .font(pf(15))
                                        .foregroundColor(C.subLabel.opacity(0.8))
                                        .padding(.horizontal, 16)
                                        .padding(.top, 14)
                                }
                                TextEditor(text: text)
                                    .font(pf(15))
                                    .scrollContentBackground(.hidden)
                                    .padding(.horizontal, 11)
                                    .padding(.top, 6)
                                    .disabled(!editable)
                            }
                            .frame(height: 168)
                        }
                    }

                    if !editable {
                        Text(Tr("你不是群主，这里只能看。"))
                            .font(pf(12))
                            .foregroundColor(C.subLabel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 30)
            }
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { closeEditors() }
    }

    /// 这三个编辑页共用一套开关，取消 / 下滑返回都走这里
    private func closeEditors() {
        showAnnounce = false
        showRename = false
        showAlias = false
    }

    private func saveAnnounce() {
        let text = announceDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { app.show(Tr("群公告不能为空")); return }
        Task {
            if let err = await API.shared.updateChatInfo(chatId: chat.id, name: chat.name, announce: text) {
                app.show(err)
            } else {
                announce = text
                /* 微信那套：发了群公告，**群里也要出一条**，所有成员在聊天里都看得到。
                   这条是 kind = "announce" 的公告卡片消息。 */
                _ = try? await API.shared.send(chatId: chat.id, kind: "announce", content: text)
                await app.loadChats()
                showAnnounce = false
                app.show(Tr("群公告已发布"))
            }
        }
    }

    private func saveName() {
        let n = nameDraft.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { app.show(Tr("群名称不能为空")); return }
        Task {
            if let err = await API.shared.updateChatInfo(chatId: chat.id, name: n, announce: announce) {
                app.show(err)
            } else {
                showRename = false
                await app.loadChats()
                app.show(Tr("群名称已修改"))
            }
        }
    }

    private func clearHistory() {
        Task {
            if let err = await API.shared.clearChat(chatId: chat.id) {
                app.show(err)
            } else {
                app.show(Tr("聊天记录已清空"))
            }
        }
    }

    private func quitGroup() {
        Task {
            let err = isOwner ? await API.shared.dismissGroup(chatId: chat.id)
                              : await API.shared.leaveGroup(chatId: chat.id)
            if let err = err {
                app.show(err)
            } else {
                await app.loadChats()
                dismiss()
                app.show(isOwner ? "群已解散" : "已退出群聊")
            }
        }
    }

    private func kick() {
        guard let target = kickTarget else { return }
        Task {
            if let err = await API.shared.kickMember(chatId: chat.id, userId: target.id) {
                app.show(err)
            } else {
                app.show("已把 \(target.name) 移出群聊")
                kickTarget = nil
                if let r = try? await API.shared.chatMembers(chatId: chat.id) { members = r.members }
                await app.loadChats()
            }
        }
    }

    /* ---------------------------------------------------------- 顶部：群头像 + 群名 */

    private var headCard: some View {
        PanelHeroCard(glow: C.green) {
            HStack(spacing: 14) {
                Avatar(path: chat.avatar ?? "", size: 64, radius: 14)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.35), lineWidth: 0.8))
                    .shadow(color: Color.black.opacity(0.3), radius: 8, y: 3)
                VStack(alignment: .leading, spacing: 6) {
                    Text(chat.name)
                        .font(pf(18, .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(memberLine)
                        .font(pf(12.5))
                        .foregroundColor(.white.opacity(0.62))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            /* 两个快捷胶囊：群二维码 / 查找记录（这两项原来是卡里的行） */
            HStack(spacing: 9) {
                PanelPill(symbol: "qrcode", title: Tr("群二维码"), colors: PanelTint.teal) { showQR = true }
                PanelPill(symbol: "magnifyingglass", title: Tr("查找记录"), colors: PanelTint.blue) { showSearch = true }
                Spacer(minLength: 0)
            }
        }
    }

    private var memberLine: String {
        if members.isEmpty { return Tr("群聊") }
        var s = "\(members.count) 位成员"
        if !createdText.isEmpty { s += " · " + createdText + "创建" }
        return s
    }

    /* ---------------------------------------------------------- 群聊成员 */

    private var memberCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if loading && members.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 22)
            } else {
                LazyVGrid(columns: gridColumns, spacing: 14) {
                    ForEach(members) { u in
                        VStack(spacing: 6) {
                            ZStack(alignment: .topLeading) {
                                Avatar(path: u.avatarPath, size: 52, radius: 10, level: u.qqLevel ?? 0)
                                /* 删除模式：群主以外的人左上角挂一个红「－」，点它就移出 */
                                if removing && isOwner && u.id != app.me?.id {
                                    Button {
                                        kickMode = "kick"
                                        kickTarget = u
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .font(.system(size: 20))
                                            .foregroundColor(C.red)
                                            .background(Circle().fill(Color.white))
                                            .overlay(Circle().stroke(Color.white, lineWidth: 1.2))
                                            .shadow(color: Color.black.opacity(0.18), radius: 2, y: 1)
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: -6, y: -6)
                                }
                            }
                            /* 设了群昵称就显示群昵称（微信的成员列表就是这样） */
                            HStack(spacing: 3) {
                                Text(u.groupName)
                                    /* 成员名字按微信那样加深一点、放大一点（原来 10.5pt 的浅灰，
                                       在浅色底上几乎看不清） */
                                    .font(pf(11))
                                    .foregroundColor(Color.dyn(0x4A4A4A, 0xD8D8D8))
                                    .lineLimit(1)
                                /* 名字旁边挂等级图标（QQ 那套） */
                                if let lv = u.qqLevel, lv > 0, GrowthFlags.showInContacts != false {
                                    QQLevelBadge(level: lv, size: 10, maxIcons: 2).fixedSize()
                                }
                            }
                            .frame(width: 56)
                        }
                        /* 点成员 = 看他的资料（微信就是这样）；长按 = 群主那套管理动作 */
                        .contentShape(Rectangle())
                        .onTapGesture { cardUser = u }
                        .contextMenu {
                            Button { cardUser = u } label: { Label(Tr("查看资料"), systemImage: "person.crop.circle") }
                            if u.id == app.me?.id || isOwner {
                                Button {
                                    editAlias(u.id == app.me?.id ? nil : u)
                                } label: { Label(Tr(u.id == app.me?.id ? "我在本群的昵称" : "设置群昵称"),
                                                 systemImage: "character.cursor.ibeam") }
                            }
                            if isOwner && u.id != app.me?.id {
                                /* 「移出群聊」按微信那样标成红色（destructive）——
                                   以前是普通墨色，在浅色菜单里那片灰字确实看不清 */
                                Button(role: .destructive) {
                                    kickMode = "kick"
                                    kickTarget = u
                                } label: { Label(Tr("移出群聊"), systemImage: "person.badge.minus") }
                                Button {
                                    kickMode = "mute"
                                    kickTarget = u
                                } label: { Label(Tr("禁言"), systemImage: "speaker.slash") }
                                Button {
                                    Task { _ = await API.shared.setMemberMuted(chatId: chat.id, userId: u.id, muted: false) }
                                } label: { Label(Tr("取消禁言"), systemImage: "speaker.wave.2") }
                            } else {
                                Button { } label: { Label(Tr("只有群主能管理成员"), systemImage: "info.circle") }
                            }
                        }
                    }
                    /* 最后一个格子是「＋」：拉人进群（微信就是这样排的） */
                    VStack(spacing: 6) {
                        Button { showAdd = true } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(C.hairline, lineWidth: 1)
                                    .frame(width: 52, height: 52)
                                Image(systemName: "plus")
                                    .font(.system(size: 20, weight: .light))
                                    .foregroundColor(C.subLabel)
                            }
                        }
                        .buttonStyle(.plain)
                        Text(Tr("加人")).font(pf(10.5)).foregroundColor(C.subLabel)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { CardGlassBox(radius: 14) }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(C.hairline, lineWidth: 0.6))
        .shadow(color: Color.black.opacity(0.05), radius: 8, y: 2)
    }

    /* ---------------------------------------------------------- 群名 / 公告 / 群主 */

    private var infoCard: some View {
        PanelCard {
            PanelRow(symbol: "pencil", colors: PanelTint.blue,
                     title: Tr("群聊名称"), value: chat.name) {
                nameDraft = chat.name
                if isOwner { showRename = true }
                else { app.show(Tr("只有群主能改群名称")) }
            }
            PanelDivider()
            /* 我在本群的昵称（微信也放在这一块） */
            PanelRow(symbol: "character.cursor.ibeam", colors: PanelTint.purple,
                     title: Tr("我在本群的昵称"),
                     value: myAlias.isEmpty ? Tr("未设置") : myAlias) {
                editAlias(nil)
            }
            PanelDivider()
            PanelRow(symbol: "megaphone.fill", colors: PanelTint.orange,
                     title: Tr("群公告"),
                     subtitle: announce.isEmpty ? nil : announce,
                     value: announce.isEmpty ? Tr("未设置") : nil) {
                announceDraft = announce
                showAnnounce = true
            }
            PanelDivider()
            PanelRow(symbol: "crown.fill", colors: PanelTint.orange,
                     title: Tr("群主"), value: ownerName, chevron: false) { }

            /* 群语音通话（多人）：微信在「聊天信息」里也有这一条 */
            PanelDivider()
            PanelRow(symbol: "phone.arrow.up.right.fill", colors: PanelTint.green,
                     title: Tr("群语音通话"),
                     value: Tr("和群里的人一起语音")) {
                CallCenter.shared.startGroupCall(chatId: chat.id, title: chat.name ?? "")
                dismiss()
            }
            /* 群视频通话（多人画面）：2026-10-12 补 —— 走腾讯云 TRTC，每人一路画面 */
            PanelDivider()
            PanelRow(symbol: "video.fill", colors: PanelTint.green,
                     title: Tr("群视频通话"),
                     value: Tr("和群里的人一起视频")) {
                CallCenter.shared.startGroupCall(chatId: chat.id, title: chat.name ?? "", video: true)
                dismiss()
            }
        }
    }

    /* ---------------------------------------------------------- 置顶聊天 */

    private var switchCard: some View {
        PanelCard {
            PanelToggleRow(symbol: "pin.fill", colors: PanelTint.orange,
                           title: Tr("置顶聊天"),
                           subtitle: pinned ? Tr("已置顶，会排在会话列表最上面") : nil,
                           isOn: pinned) { v in
                pinned = v
                Task {
                    let now = await API.shared.setPinned(chatId: chat.id, pinned: v)
                    pinned = now
                    await app.loadChats()
                }
            }
            PanelDivider()
            /* 微信群聊信息里也有这一条：只改这个群的背景（微信「设置当前聊天背景」） */
            PanelRow(symbol: "photo.on.rectangle.angled", colors: PanelTint.purple,
                     title: Tr("设置当前聊天背景")) { showGroupBg = true }
            if isOwner {
                PanelDivider()
                /* 群禁言：开了以后只有群主能说话（对应清单里的「群禁言」） */
                PanelToggleRow(symbol: "speaker.slash.fill", colors: PanelTint.red,
                               title: Tr("全员禁言"),
                               subtitle: muteAll ? Tr("已开启，群里只有你能发言") : nil,
                               isOn: muteAll) { v in
                    muteAll = v
                    Task {
                        if let err = await API.shared.setMuteAll(chatId: chat.id, on: v) {
                            app.show(err)
                            muteAll = !v
                        }
                    }
                }
            }
            PanelDivider()
            /* 群屏蔽：消息免打扰（每个人自己设） */
            PanelToggleRow(symbol: "bell.slash.fill", colors: PanelTint.gray,
                           title: Tr("消息免打扰"),
                           subtitle: muted ? Tr("这个群来消息不响也不弹") : nil,
                           isOn: muted) { v in
                muted = v
                Task {
                    let now = await API.shared.setMuted(chatId: chat.id, muted: v)
                    muted = now
                    await app.loadChats()
                }
            }
            PanelDivider()
            /* 阅后即焚（2026-10-12 用户要求）：开着的时候这个群里的消息，对方看过 8 秒后自动消失 */
            PanelToggleRow(symbol: "flame.fill", colors: PanelTint.orange,
                           title: Tr("阅后即焚"),
                           subtitle: burn ? Tr("群里发的消息，看过 20 秒后自动消失") : nil,
                           isOn: burn) { v in
                /* 2026-10-16 用户：「开阅后即焚要人脸」——开之前先走我们那套核身 */
                if v {
                    /* 开必须过人脸（我们自己那套核身；过了才真写服务端） */
                    faceForBurn = true
                } else {
                    burn = false
                    Task {
                        _ = await API.shared.setChatBurn(chatId: chat.id, on: false)
                        await app.loadChats()
                    }
                }
            }
            .sheet(isPresented: $faceForBurn) {
                FaceVerifyFlowView { ok in
                    faceForBurn = false
                    if ok {
                        burn = true
                        Task {
                            burn = await API.shared.setChatBurn(chatId: chat.id, on: true)
                            await app.loadChats()
                            app.show(Tr("人脸验证通过，阅后即焚已打开"))
                        }
                    } else {
                        app.show(Tr("人脸验证没通过，阅后即焚先保持关闭"))
                    }
                }
                .environmentObject(app)
            }
        }
    }

    /* ---------------------------------------------------------- 记录 / 退群 */

    /* ---------------------------------------------------------- 删除该聊天 */

    private var dangerCard: some View {
        PanelCard {
            PanelDangerRow(symbol: "eraser.fill", title: Tr("清空聊天记录")) { confirmClear = true }
            PanelDivider()
            PanelDangerRow(symbol: "trash.fill", title: Tr("删除该聊天")) {
                Task {
                    saving = true
                    if let err = await API.shared.hideChat(chatId: chat.id) {
                        app.show(err)
                        saving = false
                        return
                    }
                    await app.loadChats()
                    saving = false
                    dismiss()
                    app.show(Tr("已删除该聊天"))
                }
            }
            PanelDivider()
            /* 群主 = 解散并退出；普通成员 = 退出群聊 */
            PanelDangerRow(symbol: "rectangle.portrait.and.arrow.right",
                           title: isOwner ? "解散并退出群聊" : "退出群聊") { confirmQuit = true }
        }
    }
}

/* ============================================================
   群公告（**一整页**）
   · 群主进去是编辑器：顶栏「群公告」+ 右上「发布」，下面一整块随便写
   · 别人点群里那条公告进来就是看全文（只读）
   ============================================================ */

struct GroupAnnounceEditor: View {
    @Binding var text: String
    var editable = true
    var onClose: () -> Void
    var onPublish: () -> Void

    private let limit = 500
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var over: Bool { text.count > limit }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("群公告"), back: { onClose() }) {
                if editable {
                    Button { onPublish() } label: {
                        Text(Tr("发布"))
                            .font(pf(14.5, .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 15)
                            .frame(height: 32)
                            .background(Capsule().fill(over
                                ? AnyShapeStyle(C.subLabel.opacity(0.5))
                                : AnyShapeStyle(LinearGradient(colors: PanelTint.green,
                                                                startPoint: .topLeading,
                                                                endPoint: .bottomTrailing))))
                            .padding(.trailing, 14)
                    }
                    .buttonStyle(.plain)
                    .disabled(trimmed.isEmpty || over)
                }
            }

            ZStack(alignment: .topLeading) {
                if editable {
                    TextEditor(text: $text)
                        .font(pf(16.5))
                        .foregroundColor(C.label)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .onChange(of: text) { v in
                            if v.count > limit { text = String(v.prefix(limit)) }
                        }
                    if text.isEmpty {
                        Text(Tr("写点什么，群里所有人都能看到"))
                            .font(pf(16.5))
                            .foregroundColor(C.subLabel.opacity(0.7))
                            .padding(.horizontal, 17)
                            .padding(.top, 18)
                            .allowsHitTesting(false)
                    }
                } else {
                    /* ⚠ 只读（**别人**看公告）千万不能用 disabled 的 TextEditor：
                       禁用的输入框收不到手势、滑不动，公告长了下面那段就永远看不到
                       （用户报的「别人看群公告看不到下面的不能滚动」就是这个）。
                       换成普通 Text + ScrollView，随便滑。 */
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(text.isEmpty ? Tr("群主还没发公告") : text)
                                .font(pf(16.5))
                                .foregroundColor(C.label)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                            Spacer().frame(height: 30)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(C.cardBg)

            HStack(spacing: 8) {
                Text(editable ? Tr("发布后群里会收到一条公告") : Tr("群公告只有群主能改"))
                    .font(pf(12)).foregroundColor(C.subLabel)
                Spacer(minLength: 0)
                Text("\(text.count)/\(limit)")
                    .font(pf(12)).foregroundColor(over ? C.red : C.subLabel)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(C.cardBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { onClose() }
        .hidesTabBar()
    }
}

/// 只看公告（群里点那条公告卡片进来）
struct GroupAnnounceView: View {
    let text: String
    var groupName: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("群公告"), back: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !groupName.isEmpty {
                        Text(groupName).font(pf(13)).foregroundColor(C.subLabel)
                    }
                    Text(text)
                        .font(pf(16.5))
                        .foregroundColor(C.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer().frame(height: 24)
                }
                .padding(16)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
    }
}

/* ============================================================
   单聊的「聊天信息」页 —— 微信里点右上「⋯」出来的就是这一页：
   · 顶上是对方：头像 + 昵称 + 星言号（点一下进名片）
   · 消息免打扰、置顶聊天
   · 音视频通话 / 查找聊天记录 / 设置当前聊天背景
   · 清空聊天记录
   · 删除该聊天
   ============================================================ */
struct DirectChatInfoView: View {
    @ObservedObject private var lang = LangStore.shared
    let chat: Chat
    /// 2026-10-16：单聊开阅后即焚也要先过人脸（和群信息页同一套）
    @State private var faceForBurn = false

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var peer: User?
    @State private var pinned = false
    @State private var muted = false
    /// 阅后即焚：开着的时候这个人发的消息，读过 8 秒后自动消失
    @State private var burn = false
    @State private var showSearch = false
    @State private var showCard = false
    /// 「⋯ → 设置当前聊天背景」：微信那个「选择背景图」窗口
    @State private var showChatBg = false
    @State private var confirmClear = false
    @State private var confirmDelete = false
    /// 「星言团队」那两行（自助工具 / 联系客服）点出来的页。
    /// ⚠ 不放在聊天页里 —— 在聊天页那个巨型视图上加 sheet / 加一层 VStack 会让
    /// 「一进聊天就被系统杀掉」（2026-10-11 B127/B129/B133 都踩过）。放这一页最稳。
    @State private var sysPage: SysPage? = nil
    /// AI 助手（「眼睛」那个号）在这一页顶上的首页卡片：点一条推荐 = 直接发进会话。
    /// ⚠ 同理，这是它没被放在聊天页里的原因（B144 放聊天页里 = 一进聊天就闪）。
    @State private var aiCall = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("聊天信息"), back: { dismiss() })

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    peerCard
                    if chat.bot == "ai" {
                        PanelSectionTitle(text: Tr("AI 助手"))
                        aiHomeCard
                    }
                    if chat.sysTeam == true {
                        PanelSectionTitle(text: Tr("星言团队"))
                        sysCard
                    }
                    PanelSectionTitle(text: Tr("聊天设置"))
                    switchCard
                    PanelSectionTitle(text: Tr("常用"))
                    toolCard
                    PanelSectionTitle(text: Tr("危险操作"))
                    dangerCard
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 30)
            }
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task {
            /* 同群信息页：阅后即焚要按会话列表里最新那份显示（快照会过时） */
            let live = app.chats.first { $0.id == chat.id } ?? chat
            pinned = live.pinned == true
            muted = live.muted == true
            burn = live.burn == true
            if let r = try? await API.shared.chatMembers(chatId: chat.id) {
                peer = r.members.first { $0.id != app.me?.id }
            }
            /* 会话列表里没带成员时（比如从搜索进来的），按 id 再捞一次 */
            if peer == nil, let other = chat.memberIds?.first(where: { $0 != app.me?.id }) {
                peer = try? await API.shared.user(id: other)
            }
        }
        /* 三级页统一 push 整页 */
        .navigationDestination(isPresented: $showSearch) { ChatSearchView(chat: chat) }
        /* AI 助手「打电话」：和聊天页那颗电话走的是同一个页面（AICallView） */
        .fullScreenCover(isPresented: $aiCall) {
            AICallView(chat: chat)
        }
        /* 「星言团队」：自助工具 / 联系客服 / 账号与安全 / 登录设备（一个 sheet 装下四个页） */
        .sheet(item: $sysPage) { p in
            switch p {
            case .tools:
                SysToolsView { key in
                    sysPage = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        sysPage = (key == "pwd") ? .security
                                : (key == "devices") ? .devices : .kefu
                    }
                }
            case .kefu:
                KefuPage().environmentObject(app)
            case .security:
                AccountSecurityView().environmentObject(app)
            case .devices:
                LoginDevicesView().environmentObject(app)
            }
        }
        .sheet(isPresented: $showChatBg) {
            ChatBackgroundSheet(chatId: chat.id).environmentObject(app)
        }
        .navigationDestination(isPresented: $showCard) {
            if let p = peer {
                ContactCardView(user: p,
                                onOpenChat: { _ in showCard = false },
                                onOpenMoments: { _ in showCard = false })
                    .environmentObject(app)
            }
        }
        /* 清空 / 删除：都换成自己画的确认框（白卡 + 红字，比系统那个清楚） */
        .overlay {
            if confirmClear {
                PanelConfirmDialog(title: Tr("确定要清空这个聊天的记录吗？"),
                                   okText: Tr("清空"), danger: true,
                                   onOk: { confirmClear = false; clearHistory() },
                                   onCancel: { confirmClear = false })
            }
        }
        .overlay {
            if confirmDelete {
                PanelConfirmDialog(title: Tr("确定要删除这个聊天吗？"),
                                   okText: Tr("删除"), danger: true,
                                   onOk: { confirmDelete = false; deleteChat() },
                                   onCancel: { confirmDelete = false })
            }
        }
    }

    /* ---------------------------------------------------------- 对方 */

    private var peerCard: some View {
        PanelHeroCard(glow: C.green) {
            HStack(spacing: 12) {
                Avatar(path: peer?.avatarPath ?? "", size: 60, radius: 14, level: peer?.qqLevel ?? 0)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.35), lineWidth: 0.8))
                    .shadow(color: Color.black.opacity(0.3), radius: 8, y: 3)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(peer?.name ?? chat.name)
                            .font(pf(18, .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        if let lv = peer?.qqLevel, lv > 0 {
                            QQLevelBadge(level: lv, size: 13, maxIcons: 2).fixedSize()
                        }
                    }
                    if let un = peer?.username, !un.isEmpty {
                        Text(Tr("星言号") + "：" + un)
                            .font(pf(12.5))
                            .foregroundColor(.white.opacity(0.62))
                            .lineLimit(1)
                            /* 2026-10-17 用户：「星言号要长按可以复制」 */
                            .copyOnLongPress(un) { app.show($0) }
                    }
                }
                Spacer(minLength: 0)
                Chevron(size: 9, line: 1.6, color: .white.opacity(0.45))
            }
            .contentShape(Rectangle())
            /* 点这一条 = 看他的名片（和以前一样） */
            .onTapGesture { if peer != nil { showCard = true } }

            /* 打语音 / 视频：原来是卡里一行、点开还要再选一次，现在直接两颗胶囊 */
            HStack(spacing: 9) {
                PanelPill(symbol: "phone.fill", title: Tr("语音通话"), colors: PanelTint.green) { start(video: false) }
                PanelPill(symbol: "video.fill", title: Tr("视频通话"), colors: PanelTint.blue) { start(video: true) }
                Spacer(minLength: 0)
            }
        }
    }

    /* ---------------------------------------------------------- 开关 */

    private var switchCard: some View {
        PanelCard {
            PanelToggleRow(symbol: "bell.slash.fill", colors: PanelTint.gray,
                           title: Tr("消息免打扰"),
                           subtitle: muted ? Tr("这个人来消息不响也不弹") : nil,
                           isOn: muted) { v in
                muted = v
                Task {
                    muted = await API.shared.setMuted(chatId: chat.id, muted: v)
                    await app.loadChats()
                }
            }
            PanelDivider()
            /* 阅后即焚（2026-10-12 用户要求） */
            PanelToggleRow(symbol: "flame.fill", colors: PanelTint.orange,
                           title: Tr("阅后即焚"),
                           subtitle: burn ? Tr("这个人发的消息，看过 20 秒后自动消失") : nil,
                           isOn: burn) { v in
                if v {
                    faceForBurn = true
                } else {
                    burn = false
                    Task {
                        _ = await API.shared.setChatBurn(chatId: chat.id, on: false)
                        await app.loadChats()
                    }
                }
            }
            .sheet(isPresented: $faceForBurn) {
                FaceVerifyFlowView { ok in
                    faceForBurn = false
                    if ok {
                        burn = true
                        Task {
                            burn = await API.shared.setChatBurn(chatId: chat.id, on: true)
                            await app.loadChats()
                            app.show(Tr("人脸验证通过，阅后即焚已打开"))
                        }
                    } else {
                        app.show(Tr("人脸验证没通过，阅后即焚先保持关闭"))
                    }
                }
                .environmentObject(app)
            }
            PanelToggleRow(symbol: "pin.fill", colors: PanelTint.orange,
                           title: Tr("置顶聊天"),
                           subtitle: pinned ? Tr("已置顶，会排在会话列表最上面") : nil,
                           isOn: pinned) { v in
                pinned = v
                Task {
                    pinned = await API.shared.setPinned(chatId: chat.id, pinned: v)
                    await app.loadChats()
                }
            }
            PanelDivider()
        }
    }

    /* AI 助手首页卡片（只给服务端标了 bot = "ai" 的那个会话）：
       点一条推荐 = 直接以我的名义把这句话发进这个会话，然后退回聊天页。
       空串（点「对话」）= 什么都不发，回聊天页自己打字。 */
    private var aiHomeCard: some View {
        AIHomeCardView(chat: chat,
                       onSend: { text in sendToAI(text) },
                       onCall: { aiCall = true })
    }

    private func sendToAI(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { dismiss(); return }         // 「对话」：回聊天页自己打字
        Task {
            _ = try? await API.shared.send(chatId: chat.id, kind: "text", content: t)
            dismiss()
        }
    }

    /// 「星言团队」专用：自助工具 / 联系客服（照微信「微信团队」那一栏）
    private var sysCard: some View {
        PanelCard {
            PanelRow(symbol: "wrench.and.screwdriver.fill", colors: PanelTint.green,
                     title: Tr("自助工具"),
                     value: Tr("改密码 / 登录设备 / 找回密码")) { sysPage = .tools }
            PanelDivider()
            PanelRow(symbol: "headphones", colors: PanelTint.blue,
                     title: Tr("联系客服"),
                     value: Tr("常见问题 / 转人工")) { sysPage = .kefu }
        }
    }

    /* ---------------------------------------------------------- 功能行 */

    private var toolCard: some View {
        PanelCard {
            PanelRow(symbol: "magnifyingglass", colors: PanelTint.blue,
                     title: Tr("查找聊天记录")) { showSearch = true }
            PanelDivider()
            PanelRow(symbol: "photo.on.rectangle.angled", colors: PanelTint.purple,
                     title: Tr("设置当前聊天背景")) {
                showChatBg = true
            }
        }
    }

    /* ---------------------------------------------------------- 危险操作 */

    private var dangerCard: some View {
        PanelCard {
            PanelDangerRow(symbol: "eraser.fill", title: Tr("清空聊天记录")) { confirmClear = true }
            PanelDivider()
            PanelDangerRow(symbol: "trash.fill", title: Tr("删除该聊天")) { confirmDelete = true }
        }
    }

    /* ---------------------------------------------------------- 干活 */

    private func start(video: Bool) {
        let p = peer
        CallCenter.shared.start(peerId: p?.id ?? "",
                                name: p?.name ?? chat.name,
                                avatar: p?.avatarPath ?? "",
                                video: video)
        dismiss()
    }

    private func clearHistory() {
        Task {
            if let err = await API.shared.clearChat(chatId: chat.id) {
                app.show(err)
            } else {
                app.show(Tr("聊天记录已清空"))
            }
        }
    }

    private func deleteChat() {
        Task {
            if let err = await API.shared.hideChat(chatId: chat.id) {
                app.show(err)
                return
            }
            await app.loadChats()
            dismiss()
            app.show(Tr("已删除该聊天"))
        }
    }
}

/* ============================================================
   群加人：从好友里多选，勾完点「完成」就拉进群。
   已经在群里的人不显示（拉重复了服务端也会拒）。
   ============================================================ */

struct GroupAddMembersView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    let chat: Chat
    /// 已经在群里的人（不列出来）
    let existing: [String]
    /// 加完后回调（新进来的名字）
    var onDone: ([String]) -> Void

    @State private var keyword = ""
    @State private var picked: Set<String> = []
    @State private var busy = false

    private var candidates: [User] {
        let set = Set(existing)
        let base = app.contacts.filter { !set.contains($0.id) && $0.id != app.me?.id }
        guard !keyword.isEmpty else { return base }
        return base.filter { $0.name.contains(keyword) }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("加人"), back: { dismiss() }) {
                Button { submit() } label: {
                    Text(busy ? Tr("加入中…") : Tr("完成"))
                        .font(pf(17))
                        .foregroundColor(picked.isEmpty ? C.subLabel : C.green)
                        .frame(height: L.navH)
                        .padding(.trailing, 16)
                }
                .buttonStyle(.plain)
                .disabled(picked.isEmpty || busy)
            }

            SearchBoxCenter(text: $keyword)
                .padding(L.searchPad)

            if candidates.isEmpty {
                Text(Tr("没有可以邀请的好友了"))
                    .font(pf(14)).foregroundColor(C.subLabel)
                    .padding(.top, 40)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(candidates) { u in
                            Button {
                                if picked.contains(u.id) { picked.remove(u.id) } else { picked.insert(u.id) }
                            } label: {
                                HStack(spacing: 12) {
                                    Avatar(path: u.avatarPath, size: 40, radius: 4)
                                    Text(u.name).font(pf(17)).foregroundColor(C.label).lineLimit(1)
                                    Spacer(minLength: 0)
                                    Image(systemName: picked.contains(u.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 20))
                                        .foregroundColor(picked.contains(u.id) ? C.green : C.subLabel)
                                }
                                .padding(.horizontal, 16)
                                .frame(height: 60)
                                .background(C.cardBg)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            HairLine(inset: 68)
                        }
                    }
                }
                .background(C.pageBg)
            }
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
    }

    private func submit() {
        guard !picked.isEmpty, !busy else { return }
        busy = true
        let ids = Array(picked)
        Task {
            let r = await API.shared.addGroupMembers(chatId: chat.id, userIds: ids)
            busy = false
            if let err = r.error {
                app.show(err)
                return
            }
            onDone(r.added)
            dismiss()
        }
    }
}


