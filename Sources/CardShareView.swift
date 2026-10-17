import SwiftUI

/* ============================================================
   推荐给朋友（微信那张「发送给」页）—— 桌面 安全 文件夹截图 1 的样子：
     · 顶栏：「发送给」+ 右上「取消」
     · 一个搜索框
     · 「最近聊天」：头像 + 名字，点一下选中（可多选）
     · 中间「创建聊天」入口
     · 底下挂一张**个人名片**预览卡（头像 + 名字 + 微信号 + 「个人名片」底条）
     · 卡片下面一排小操作 + 右下角绿色「发送」
   发出去的是名片消息（kind = card），收端按微信那张卡渲染。
   ⚠ 名字 / 微信号都要先解码再显示（收端乱码就是漏了这一步）。
   ============================================================ */
struct CardShareView: View {
    /// 要推荐出去的那个人
    let user: User
    /// 选中以后点「发送」：把名片发给这几个会话
    var onSend: ([Chat]) -> Void

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var picked: Set<String> = []

    private var rows: [Chat] {
        let list = app.chats.filter { ($0.type ?? "direct") != "group" || true }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return list }
        return list.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private var pickedChats: [Chat] { app.chats.filter { picked.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("发送给"), back: { dismiss() }) {
                Button { dismiss() } label: {
                    Text(Tr("取消")).font(pf(17)).foregroundColor(C.label)
                        .frame(height: L.navH).padding(.trailing, 16)
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                VStack(spacing: 0) {
                    searchBar
                    HStack {
                        Text(Tr("最近聊天")).font(pf(13)).foregroundColor(C.subLabel)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 6)

                    GroupCard {
                        ForEach(Array(rows.prefix(30).enumerated()), id: \.offset) { i, c in
                            if i > 0 { HairLine(inset: 60) }
                            chatRow(c)
                        }
                    }

                    /* 中间：创建聊天 */
                    Button { app.show(Tr("选人建群下一步接")) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.badge.plus")
                                .font(.system(size: 17)).foregroundColor(C.subLabel)
                                .frame(width: 40, height: 40)
                            Text(Tr("创建聊天")).font(pf(16)).foregroundColor(C.label)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16).frame(height: 56)
                        .background(C.cardBg).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)

                    Spacer().frame(height: 18)

                    /* 底下那张名片预览卡（微信就是「个人名片」那张） */
                    cardPreview
                    actionRow

                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
    }

    /* ---------------------------------------------------------- 零件 */

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 14.5)).foregroundColor(C.searchIcon)
            TextField(Tr("搜索"), text: $query).font(pf(15))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15)).foregroundColor(C.searchIcon2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(C.searchBg))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(C.hairline, lineWidth: 0.6))
        .padding(.horizontal, 14).padding(.top, 10)
    }

    private func chatRow(_ c: Chat) -> some View {
        let on = picked.contains(c.id)
        return Button {
            if on { picked.remove(c.id) } else { picked.insert(c.id) }
        } label: {
            HStack(spacing: 12) {
                Avatar(path: c.avatar ?? "", size: 40, radius: c.type == "group" ? 8 : 20)
                Text(c.name).font(pf(16)).foregroundColor(C.label).lineLimit(1)
                Spacer(minLength: 8)
                if on {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 19)).foregroundColor(C.green)
                }
            }
            .padding(.horizontal, 16).frame(height: 60)
            .background(C.cardBg).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 名片预览卡：微信那张（头像 + 名字 + 微信号 + 下面「个人名片」底条）
    private var cardPreview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Avatar(path: user.avatarPath, size: 48, radius: 4)
                VStack(alignment: .leading, spacing: 5) {
                    Text(decode(user.name)).font(pf(16)).foregroundColor(C.label).lineLimit(1)
                    Text(Tr("微信号") + "：" + decode(user.username ?? "—"))
                        .font(pf(13)).foregroundColor(C.subLabel).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 10)

            HairLine(inset: 12)

            HStack(spacing: 6) {
                Image(systemName: "person.crop.square")
                    .font(.system(size: 12)).foregroundColor(C.subLabel)
                Text(Tr("个人名片")).font(pf(12.5)).foregroundColor(C.subLabel)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).frame(height: 28)
        }
        .frame(width: 250)
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(C.hairline, lineWidth: 0.6))
    }

    /// 卡片下面那排小操作 + 右下角绿色发送
    private var actionRow: some View {
        HStack(spacing: 16) {
            Text(Tr("发消息")).font(pf(13)).foregroundColor(C.subLabel)
            Text(Tr("其他应用")).font(pf(13)).foregroundColor(C.subLabel)
            Spacer(minLength: 0)
            Button {
                guard !picked.isEmpty else { app.show(Tr("先选一个聊天")); return }
                onSend(pickedChats)
                dismiss()
            } label: {
                Text(Tr("发送") + (picked.isEmpty ? "" : "（\(picked.count)）"))
                    .font(pf(15, .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18).frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(picked.isEmpty ? C.green.opacity(0.5) : C.green))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.top, 10)
        .frame(width: 250)
    }

    /// 显示前先解码（客户端存的可能是百分号编码 —— 不解码就是收端看到的乱码）
    private func decode(_ s: String) -> String {
        s.removingPercentEncoding ?? s
    }
}
