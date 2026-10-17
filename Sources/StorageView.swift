import SwiftUI

/* ============================================================
   存储空间（微信「设置 → 通用 → 存储空间」）
   · 上面一个大数字：已用空间（聊天记录 + 缓存）
   · 按类型分：图片 / 视频 / 文件 / 语音 各占多少
   · 清理缓存：清掉手机上的图片缓存和网络缓存（不动聊天记录，也不动服务器上的东西）
   · 会话列表：按占用从大到小排，点一个可以「清空这个会话的聊天记录」（只清我这边）
   ============================================================ */
struct StorageView: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var info: API.StorageInfo?
    @State private var cacheBytes = 0
    @State private var loading = true
    @State private var clearing = false
    @State private var confirmChat: API.StorageChat?

    private func mb(_ b: Int) -> String {
        let v = Double(b) / 1024 / 1024
        if v < 0.1 { return String(format: "%.0f KB", v * 1024) }
        if v < 1024 { return String(format: "%.1f MB", v) }
        return String(format: "%.2f GB", v / 1024)
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("存储空间"), back: { dismiss() })

            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 6) {
                        Text(loading ? "…" : mb((info?.total ?? 0) + cacheBytes))
                            .font(pfMoney(34, .medium))
                            .foregroundColor(C.label)
                        Text(Tr("已用空间（聊天记录 + 缓存）"))
                            .font(pf(13)).foregroundColor(C.subLabel)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
                    .background(C.cardBg)

                    Spacer().frame(height: 8)

                    /* 占用来路就按微信那套：一条**按比例分色的进度条** + 下面一行图例
                       （图片/视频/文件/语音/其他记录/手机缓存 各占多少，一眼看出来） */
                    storageBar
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                    legend
                        .padding(.top, 12)

                    Spacer().frame(height: 14)

                    /* 缓存：微信这一行右边就是「去清理」 */
                    GroupCard {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(Tr("缓存")).font(pf(16)).foregroundColor(C.label)
                                Text(Tr("图片缓存和网络缓存，随时可以清理"))
                                    .font(pf(12.5)).foregroundColor(C.subLabel)
                            }
                            Spacer(minLength: 8)
                            Text(mb(cacheBytes)).font(pf(14)).foregroundColor(C.subLabel)
                            Button { clearCache() } label: {
                                Text(clearing ? Tr("清理中…") : Tr("去清理"))
                                    .font(pf(13.5, .medium))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 13)
                                    .frame(height: 28)
                                    .background(Capsule().fill(C.green))
                            }
                            .buttonStyle(.plain)
                            .disabled(clearing)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 64)
                    }

                    Text(Tr("清理缓存只删手机上的图片缓存，不会删除聊天记录，也不影响服务器上的任何东西。"))
                        .font(pf(12.5))
                        .foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.top, 8)

                    /* 会话占用 */
                    HStack {
                        Text(Tr("聊天记录占用"))
                            .font(pf(13)).foregroundColor(C.subLabel)
                        Spacer()
                        Text(Tr("点一个可以清空它的记录"))
                            .font(pf(12)).foregroundColor(C.subLabel)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 6)

                    GroupCard {
                        ForEach((info?.chats ?? []).indices, id: \.self) { i in
                            let c = (info?.chats ?? [])[i]
                            if i > 0 { HairLine(inset: 68) }
                            Button { confirmChat = c } label: {
                                HStack(spacing: 12) {
                                    Avatar(path: c.avatar ?? "", size: 44, radius: 6)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(c.title).font(pf(16)).foregroundColor(C.label).lineLimit(1)
                                        Text("\(c.messages) " + Tr("条消息"))
                                            .font(pf(12.5)).foregroundColor(C.subLabel)
                                    }
                                    Spacer(minLength: 8)
                                    Text(mb(c.bytes)).font(pf(14)).foregroundColor(C.subLabel)
                                }
                                .padding(.horizontal, 16)
                                .frame(height: 64)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { await load() }
        .confirmationDialog(Tr("清空这个会话的聊天记录？"),
                            isPresented: Binding(get: { confirmChat != nil },
                                                 set: { if !$0 { confirmChat = nil } }),
                            titleVisibility: .visible) {
            Button(Tr("清空"), role: .destructive) {
                if let c = confirmChat { clearChat(c) }
                confirmChat = nil
            }
            Button(Tr("取消"), role: .cancel) { confirmChat = nil }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(title).font(pf(16)).foregroundColor(C.label)
            Spacer(minLength: 8)
            Text(value).font(pf(15)).foregroundColor(C.subLabel)
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
    }

    /* ---------------- 微信那条分色进度条 + 图例 ---------------- */

    /// 一段（一类占用）
    struct Seg {
        var title: String
        var bytes: Int
        var color: Color
    }

    private var segs: [Seg] {
        let k = info?.kinds
        let img = k?.image ?? 0, vid = k?.video ?? 0, fil = k?.file ?? 0, aud = k?.audio ?? 0
        let total = info?.total ?? 0
        let other = max(0, total - (img + vid + fil + aud))
        return [
            Seg(title: Tr("图片"), bytes: img, color: Color(hex: 0x4A90D9)),
            Seg(title: Tr("视频"), bytes: vid, color: Color(hex: 0x8E6BE8)),
            Seg(title: Tr("文件"), bytes: fil, color: Color(hex: 0xE8A33D)),
            Seg(title: Tr("语音"), bytes: aud, color: Color(hex: 0x3ED37F)),
            Seg(title: Tr("其他记录"), bytes: other, color: Color(hex: 0x9AA4B2)),
            Seg(title: Tr("手机缓存"), bytes: cacheBytes, color: Color(hex: 0xC9CDD4))
        ].filter { $0.bytes > 0 }
    }

    private var storageBar: some View {
        let list = segs
        let total = max(1, list.reduce(0) { $0 + $1.bytes })
        return GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(list.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(list[i].color)
                        .frame(width: max(4, geo.size.width * CGFloat(list[i].bytes) / CGFloat(total)))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 12)
        .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.dyn(0xEDEDF0, 0x2C2C31)))
    }

    private var legend: some View {
        let list = segs
        return LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                  GridItem(.flexible(), alignment: .leading)],
                         spacing: 10) {
            ForEach(list.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    Circle().fill(list[i].color).frame(width: 8, height: 8)
                    Text(list[i].title).font(pf(13)).foregroundColor(C.label).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(mb(list[i].bytes)).font(pf(13)).foregroundColor(C.subLabel)
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private func load() async {
        loading = true
        if let d = try? await API.shared.storage() { info = d }
        cacheBytes = Int(URLCache.shared.currentDiskUsage)
        loading = false
    }

    private func clearCache() {
        clearing = true
        URLCache.shared.removeAllCachedResponses()
        ImageStore.shared.clear()
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            cacheBytes = Int(URLCache.shared.currentDiskUsage)
            clearing = false
            app.show(Tr("缓存已清理"))
        }
    }

    private func clearChat(_ c: API.StorageChat) {
        Task {
            if let err = await API.shared.clearChat(chatId: c.chatId) {
                app.show(err)
            } else {
                app.show(Tr("这个会话的记录已清空"))
            }
            await load()
            await app.loadChats()
        }
    }
}
