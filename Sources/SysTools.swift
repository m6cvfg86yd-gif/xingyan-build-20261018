import SwiftUI

/// 「星言团队」那排菜单点出来的页（在最外层 MainTab 上弹，见 AppState.openSysPage）
enum SysPage: String, Identifiable {
    case tools, kefu, security, devices
    var id: String { rawValue }
}

/// 「星言团队」会话底部那排菜单（照微信「微信团队」：自助工具 / 联系客服）
struct SysTeamMenuBar: View {
    var onTools: () -> Void
    var onKefu: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            button(Tr("自助工具"), onTools)
            Rectangle().fill(C.hairline).frame(width: 0.5, height: 22)
            button(Tr("联系客服"), onKefu)
        }
        .frame(height: 44)
        .background(C.cardBg)
        .overlay(alignment: .top) { HairLine() }
    }

    private func button(_ t: String, _ tap: @escaping () -> Void) -> some View {
        Button { tap() } label: {
            Text(t)
                .font(pf(15))
                .foregroundColor(C.label)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/* ============================================================
   「星言团队」的自助工具（照微信「微信团队」那一页）
   在「星言团队」会话底下那排菜单里点「自助工具」进来的：
     · 改密码 / 登录设备管理 —— 直接进对应的页
     · 忘记密码 / 冻结 / 解冻 / 注销 / 反馈 —— 走在线客服
   ============================================================ */

struct SysToolsView: View {
    @Environment(\.dismiss) private var dismiss
    /// 点了哪一项：pwd（改密码）/ devices（登录设备）/ kefu（客服）
    var onPick: (String) -> Void

    private let items: [(key: String, icon: String, title: String, sub: String)] = [
        ("pwd",     "lock.rotation",        "修改登录密码",   "改完别的设备要重新登录"),
        ("devices", "iphone.gen3",          "登录设备管理",   "看有谁登录过你的号，可以踢掉"),
        ("kefu",    "questionmark.circle",  "找回密码",       "密码忘了？找客服帮你重置"),
        ("kefu",    "snowflake",            "冻结账号",       "怀疑被盗，先冻住不让别人登"),
        ("kefu",    "sun.max",              "解冻账号",       "已经冻结过的号，申请解冻"),
        ("kefu",    "xmark.circle",         "注销账号",       "不用了？注销前先看客服说明"),
        ("kefu",    "bubble.left",          "意见反馈",       "哪里不好用，直接跟客服说")
    ]

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("自助工具"), back: { dismiss() })

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    HStack {
                        Text(Tr("账号相关的事，在这儿自己办或者找客服"))
                            .font(pf(12.5)).foregroundColor(C.subLabel)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)

                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                            if i > 0 { HairLine(inset: 56) }
                            Button { onPick(it.key) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: it.icon)
                                        .font(.system(size: 17))
                                        .foregroundColor(C.green)
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(Tr(it.title)).font(pf(15.5)).foregroundColor(C.label)
                                        Text(Tr(it.sub)).font(pf(12)).foregroundColor(C.subLabel)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 6)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(C.subLabel)
                                }
                                .padding(.horizontal, 16).frame(height: 58)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(C.cardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 12)

                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
    }
}
