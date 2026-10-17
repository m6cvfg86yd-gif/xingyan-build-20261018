import SwiftUI

/* ============================================================
   切换账号（我 → 设置 → 切换账号）

   2026-10-12 用户要求「对齐微信简洁的」，整页重画：
     · 去掉原来那张金边深色卡、绿色「切换」胶囊、圆角卡片边框和阴影；
     · 就是微信那种**一条一条的分组列表**：头像 56 方角 6 + 名字 17 + 星言号 13 灰，
       整行 84 高、左右 16、行与行之间一条细线（从文字左边开始）；
     · 标题下面一行居中灰字「轻触头像以切换账号」（微信截图里就有）；
     · 当前账号右边是「当前使用」四个字；头像下面那行就是光秃秃的星言号，没有前缀；
     · 不搞胶囊、不搞金圈、不搞圆角卡边框；
     · 点另一个账号直接切（不用重新输密码），右上「管理」切进移除模式；
     · 最下面「添加账号」和上面同一种行：一个灰底方角块里一个加号 + 「添加账号」。

   逻辑（切换 / 移除 / 添加）和以前完全一样，只换了画法。
   ============================================================ */
struct SwitchAccountView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var growth = GrowthStore.shared

    @State private var managing = false
    @State private var adding = false
    @State private var busy = ""
    @State private var note = ""

    private var me: String { app.me?.username ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            /* 左上角照微信用「关闭」两个字，不是返回箭头（用户发来的真机截图就是这样）。
               ⚠ 2026-10-12：以前这是给全站共用的 NavBar 加了一个 backText 分支实现的，
               结果那一改把**聊天页**也一起改了 —— 用户那台机器一进聊天就被系统杀掉
               （日志停在「8 准备打开」，和 B127~B144 那次一模一样）。
               NavBar 已经一字不差退回 B203 那版，这一页就自己画一条顶栏，
               再也不动那个公共组件。 */
            HStack(spacing: 0) {
                Button { dismiss() } label: {
                    Text(Tr("关闭"))
                        .font(pf(17))
                        .foregroundColor(C.label)
                        .frame(height: L.navH)
                        .padding(.horizontal, 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                Text(Tr("切换账号")).font(pf(17, .semibold)).foregroundColor(C.label)
                Spacer(minLength: 0)
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { managing.toggle() }
                } label: {
                    Text(Tr(managing ? "完成" : "管理"))
                        .font(pf(16))
                        .foregroundColor(managing ? C.green : C.label)
                        .frame(height: L.navH)
                        .padding(.horizontal, 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(height: L.navH)
            .background(C.navBg)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    /* 用户发来了微信真机截图，照它对齐：
                       ① 标题下面有一行**居中**的小灰字「轻触头像以切换账号」；
                       ② 当前账号右边确实有「当前使用」四个字；
                       ③ 头像下面那行就是**光秃秃的微信号**，没有「星言号：」这种前缀。 */
                    /* 照截图量：这行字是**居中**的（x 284~970，中心 627 ≈ 屏幕中心），
                       原文是「轻触头像以切换**账号**」。 */
                    Text(Tr("轻触头像以切换账号"))
                        .font(pf(13))
                        .foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 12)
                        .padding(.bottom, 10)

                    /* 用户指出微信这里是**一条条独立的卡片**（不是一个整块 + 细线）：
                       每个账号一张圆角卡（12）、卡与卡之间留 10pt 缝、最下面「添加账号」也是一张卡。 */
                    VStack(spacing: 10) {
                        ForEach(app.accounts) { acct in
                            accountRow(acct)
                        }
                        addRow
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)

                    if !note.isEmpty {
                        Text(note)
                            .font(pf(13))
                            .foregroundColor(Color(hexString: "#FA5151"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 22)
                            .padding(.top, 10)
                    }

                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .sheet(isPresented: $adding) {
            AccountLoginSheet(mode: .password)
                .environmentObject(app)
        }
    }

    /* ---------------------------------------------------------- 一行账号 */

    /// 微信那一行：头像 56（方角 6）+ 名字 17 + 星言号 13 灰，整行 84。
    /// 右边：当前账号写「当前使用」，管理模式下别的账号写红色「移除」，其余什么都不放。
    @ViewBuilder
    private func accountRow(_ a: SavedAccount) -> some View {
        let current = (a.username == me)
        Button {
            tap(a, current: current)
        } label: {
            /* 截图量出来：名字左边那条线在 x≈103pt（卡片内缩 12 + 内边距 16 + 头像 60 + 缝 15） */
            HStack(spacing: 15) {
                Avatar(path: a.avatar, size: 60, radius: 6, level: levelOf(a))
                    .frame(width: 60, height: 60)

                VStack(alignment: .leading, spacing: 5) {
                    Text(a.nickname.isEmpty ? a.username : a.nickname)
                        .font(pf(17))
                        .foregroundColor(C.label)
                        .lineLimit(1)
                    Text(a.username)
                        .font(pf(13))
                        .foregroundColor(C.subLabel)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if busy == a.username {
                    ProgressView()
                } else if managing, !current {
                    Text(Tr("移除"))
                        .font(pf(15))
                        .foregroundColor(C.red)
                } else if current {
                    Text(Tr("当前使用"))
                        .font(pf(13))
                        .foregroundColor(C.subLabel)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 84)
            /* 一张卡：圆角 12、实色，和下面「添加账号」同一种 */
            .background(C.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 最后一行「添加账号」：和上面同一种行，左边一个灰底方角块里一个加号。
    private var addRow: some View {
        Button { adding = true } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.dyn(0xEDEDED, 0x2C2C2E))
                        .frame(width: 56, height: 56)
                    Image(systemName: "plus")
                        .font(.system(size: 21, weight: .regular))
                        .foregroundColor(C.subLabel)
                }
                Text(Tr("添加账号"))
                    .font(pf(17))
                    .foregroundColor(C.label)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 84)
            .background(C.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /* ---------------------------------------------------------- 干活（和以前一样，没动） */

    /// 这个账号的等级：当前账号用成长系统里的；其他账号看通讯录（是好友才有）
    private func levelOf(_ a: SavedAccount) -> Int {
        if a.username == me { return max(1, growth.shownLevel) }
        if let lv = app.contacts.first(where: { $0.username == a.username })?.qqLevel, lv > 0 { return lv }
        return 0
    }

    private func tap(_ a: SavedAccount, current: Bool) {
        if managing {
            if !current { remove(a) }
            return
        }
        guard !current, busy.isEmpty else { return }
        switchTo(a)
    }

    private func switchTo(_ a: SavedAccount) {
        note = ""
        busy = a.username
        Task {
            let saved = AccountStore.token(for: a.username)
            let ok = await app.quickLogin(token: saved.isEmpty ? nil : saved)
            busy = ""
            if ok {
                dismiss()
            } else {
                note = Tr("这个账号的登录状态过期了，重新输一次密码就行")
                adding = true
            }
        }
    }

    private func remove(_ a: SavedAccount) {
        AccountStore.remove(username: a.username)
        app.accounts = AccountStore.load()
        app.show(Tr("已移除") + "「" + a.nickname + "」")
        if app.accounts.isEmpty { managing = false }
    }
}
