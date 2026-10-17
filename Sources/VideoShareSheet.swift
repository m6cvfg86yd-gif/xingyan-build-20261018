import SwiftUI

/* ============================================================
   视频转发面板（抖音那套）
   一排圆形图标：转发给朋友 / 朋友圈 / 收藏 / 复制链接 / 保存本地
   下面两行文字项：举报 / 不感兴趣，最下面「取消」
   ============================================================ */
struct VideoShareSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    let item: FeedItem
    /// 转发给朋友（外层打开好友选择器）
    var onForward: (() -> Void)? = nil
    var onToMoments: (() -> Void)? = nil
    var onFavorite: (() -> Void)? = nil
    var onSaveLocal: (() -> Void)? = nil
    var onHide: (() -> Void)? = nil

    private var link: String { item.video ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            Text(Tr("分享到"))
                .font(pf(13))
                .foregroundColor(C.subLabel)
                .padding(.top, 16)
                .padding(.bottom, 14)

            /* 圆形图标那一排（抖音就是这种：图标 + 下面的字） */
            HStack(alignment: .top, spacing: 0) {
                iconButton("转发给朋友", "paperplane.fill", Color(hex: 0x19A47A)) {
                    dismiss()
                    onForward?()
                }
                iconButton("朋友圈", "camera.fill", C.green) {      // 2026-10-17：跟主色走
                    dismiss()
                    onToMoments?()
                }
                iconButton("收藏", "star.fill", Color(hex: 0xE2A03C)) {
                    dismiss()
                    onFavorite?()
                }
                iconButton("复制链接", "link", Color(hex: 0x1180E0)) {
                    UIPasteboard.general.string = link
                    app.show(Tr("链接已复制，可以去聊天里粘贴"))
                    dismiss()
                }
                iconButton("保存本地", "arrow.down.to.line", Color(hex: 0x8A8A8E)) {
                    dismiss()
                    onSaveLocal?()
                }
            }
            .padding(.horizontal, 8)

            Rectangle().fill(C.hairline).frame(height: 0.5)
                .padding(.top, 18)
                .padding(.horizontal, 0)

            /* 文字项 */
            VStack(spacing: 0) {
                textRow("举报", "exclamationmark.bubble") { dismiss(); app.show(Tr("已提交举报，我们会尽快核实")) }
                HairLine(inset: 16)
                textRow("不感兴趣", "hand.thumbsdown") {
                    dismiss()
                    onHide?()
                }
            }
            .padding(.top, 4)

            Button { dismiss() } label: {
                Text(Tr("取消"))
                    .font(pf(16))
                    .foregroundColor(C.label)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(C.cardBg)
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
            Color.clear.frame(height: 6)
        }
        .background(C.pageBg.ignoresSafeArea())
        .presentationDetents([.height(320)])
    }

    private func iconButton(_ title: String, _ symbol: String, _ color: Color, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 7) {
                ZStack {
                    Circle().fill(color.opacity(0.14)).frame(width: 50, height: 50)
                    Image(systemName: symbol)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(color)
                }
                Text(Tr(title)).font(pf(11.5)).foregroundColor(C.label).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func textRow(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 16)).foregroundColor(C.subLabel).frame(width: 24)
                Text(Tr(title)).font(pf(16)).foregroundColor(C.label)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/* 转发给朋友：从通讯录里挑一个人，把视频链接发给他（抖音也是发一条消息） */
struct VideoForwardPicker: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    let link: String
    /// 转发**视频消息**用的正文（聊天里那条视频的 JSON）。
    /// 有它就按微信那套把这条视频原样转发过去（对方收到的是视频气泡），
    /// 没有才退回"发一条链接"（朋友圈那种用法）。
    var videoContent: String = ""

    @State private var q = ""
    @State private var sending = ""

    private var list: [User] {
        let key = q.trimmingCharacters(in: .whitespaces)
        let all = app.contacts
        if key.isEmpty { return all }
        return all.filter { ($0.nickname ?? "").localizedCaseInsensitiveContains(key) || ($0.username ?? "").localizedCaseInsensitiveContains(key) }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("转发给朋友"), back: { dismiss() })
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).foregroundColor(C.searchIcon)
                TextField(Tr("搜索"), text: $q).font(pf(14.5))
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(C.searchBg))
            .padding(.horizontal, 8)
            .padding(.vertical, 8)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(list) { u in
                        Button { send(to: u) } label: {
                            HStack(spacing: 12) {
                                Avatar(path: u.avatarPath, size: 40, radius: 6)
                                Text(u.name).font(pf(16)).foregroundColor(C.label)
                                Spacer(minLength: 6)
                                if sending == u.id { ProgressView().scaleEffect(0.7) }
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 60)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        HairLine(inset: 66)
                    }
                }
                .background(C.cardBg)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
    }

    private func send(to u: User) {
        if !sending.isEmpty { return }
        sending = u.id
        Task {
            do {
                let chat = try await API.shared.directChat(userId: u.id)
                /* 是聊天里的视频 → 原样转发这条**视频消息**（对方看到的是视频气泡）；
                   否则（朋友圈那套）还是发一条链接。 */
                if !videoContent.isEmpty {
                    _ = try await API.shared.send(chatId: chat.id, kind: "video", content: videoContent)
                } else {
                    _ = try await API.shared.send(chatId: chat.id, kind: "text", content: link)
                }
                app.show(Tr("已转发给 ") + u.name)
                dismiss()
            } catch {
                app.show((error as? LocalizedError)?.errorDescription ?? Tr("转发失败"))
            }
            sending = ""
        }
    }
}
