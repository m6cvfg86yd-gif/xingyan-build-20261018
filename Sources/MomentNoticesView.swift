import SwiftUI

/// 朋友圈 →「消息列表」：微信右上角那个小信封点开的样子 ——
/// 谁赞了我的动态、谁评论了我，一条一条列着（头像 + 名字 + 做了什么 + 时间 + 那条动态的缩略图）。
/// 点某一条 → 交给朋友圈页去把那条动态打开（打不开就提示一句）。
struct MomentNoticesView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    /// 点一条通知：把这条交回朋友圈页（能定位就定位，不能就提示）
    var onOpen: ((MomentNotice) -> Void)? = nil

    @State private var items: [MomentNotice] = []
    @State private var loading = true
    /// 2026-10-15 用户：「朋友圈的消息列表怎么没有清空按钮」——
    /// 加一个「清空」（右上角）+ 确认；清掉之后**本机记住这个时间点**，
    /// 比它早的消息不再显示（服务器那边没有删除接口，所以是本机清空）。
    @State private var confirmClear = false
    @AppStorage("momentNoticesClearedAt") private var clearedAt: Double = 0

    var body: some View {
        ZStack {
            C.pageBg.ignoresSafeArea()
            VStack(spacing: 0) {
                NavBar(title: Tr("消息列表"), back: { dismiss() }) {
                    if !items.isEmpty {
                        Button { confirmClear = true } label: {
                            Text(Tr("清空")).font(pf(15)).foregroundColor(C.subLabel)
                                .frame(height: 40).padding(.horizontal, 10)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                if loading && items.isEmpty {
                    Spacer(minLength: 0)
                    ProgressView()
                    Spacer(minLength: 0)
                } else if items.isEmpty {
                    Spacer(minLength: 0)
                    VStack(spacing: 12) {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 34))
                            .foregroundColor(C.time)
                        Text(Tr("还没有人赞过或评论过你的朋友圈"))
                            .font(pf(14))
                            .foregroundColor(C.subLabel)
                    }
                    Spacer(minLength: 0)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(items) { n in row(n) }
                        }
                        .padding(.bottom, 24)
                    }
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack(onBack: { dismiss() })
        .task { await load() }
        .alert(Tr("清空消息列表？"), isPresented: $confirmClear) {
            Button(Tr("取消"), role: .cancel) { }
            Button(Tr("清空"), role: .destructive) {
                clearedAt = Date().timeIntervalSince1970
                withAnimation(.easeOut(duration: 0.2)) { items = [] }
                app.show(Tr("消息列表已清空"))
            }
        } message: {
            Text(Tr("清空后这一页不再显示之前那些赞和评论；新的消息还会照常进来。"))
        }
    }

    private func row(_ n: MomentNotice) -> some View {
        Button {
            /* 那条动态还在 → 交给朋友圈页定位；已经删了 → 照微信，点不开 */
            if n.deleted == true {
                app.show(Tr("这条动态已经删除了"))
            } else {
                onOpen?(n)
            }
        } label: {
            HStack(alignment: .top, spacing: 11) {
                RemoteImage(path: n.avatar ?? "", mode: .fill, maxSide: 200)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(n.name ?? "")
                            .font(pf(15, .medium))
                            .foregroundColor(C.link)
                            .lineLimit(1)
                        Text(actionText(n))
                            .font(pf(14))
                            .foregroundColor(C.label)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(TimeFmt.ago(n.at))
                            .font(pf(12))
                            .foregroundColor(C.time)
                            .fixedSize()
                    }
                    if let t = n.text, !t.isEmpty {
                        /* 评论内容（微信里就是「名字 评论了你的朋友圈：内容」那条评论本身） */
                        Text(t)
                            .font(pf(14))
                            .foregroundColor(C.label)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let p = n.preview, !p.isEmpty {
                        Text(p)
                            .font(pf(12.5))
                            .foregroundColor(C.subLabel)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }

                /* 被赞/被评论的那条动态：带第一张图的缩略图（微信也是这样） */
                if let thumb = n.thumb, !thumb.isEmpty {
                    RemoteImage(path: thumb, mode: .fill, maxSide: 260)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(C.cardBg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(C.hairline).frame(height: 0.5).padding(.leading, 67)
        }
    }

    private func actionText(_ n: MomentNotice) -> String {
        switch n.kind ?? "" {
        case "like": return Tr("赞了你的朋友圈")
        case "reply": return Tr("回复了你")
        default: return Tr("评论了你的朋友圈")
        }
    }

    private func load() async {
        let r = await API.shared.momentNotices()
        /* 清空过：只显示清空之后新来的（解析不出时间的照旧显示，别把人消息藏了） */
        items = clearedAt > 0
            ? r.items.filter { let t = atSeconds($0.at); return t == 0 || t > clearedAt }
            : r.items
        loading = false
        app.momentNoticeUnread = 0
        /* 打开这一页 = 看过了（微信一样，红点立刻清掉） */
        await API.shared.markMomentNoticesSeen()
    }

    /// 通知的 at 是字符串（毫秒时间戳或 ISO 时间都认）；认不出来返回 0
    private func atSeconds(_ s: String?) -> Double {
        guard let s = s, !s.isEmpty else { return 0 }
        if let v = Double(s) { return v > 1e11 ? v / 1000 : v }
        if let d = ISO8601DateFormatter().date(from: s) { return d.timeIntervalSince1970 }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: s)?.timeIntervalSince1970 ?? 0
    }
}
