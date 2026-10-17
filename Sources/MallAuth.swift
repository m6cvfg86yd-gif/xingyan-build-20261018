import SwiftUI

/* ============================================================
   进商城先授权（照微信：进「第三方」的商城，先弹一层授权卡）

   微信里点开一个小程序，会先弹：
       「拼多多」申请获取以下权限
        获取你的公开信息（昵称、头像等）
       [拒绝]            [允许]
   允许了才进去；拒绝了就退回上一页。这里照这套做：

   · 授权状态**按账号记**（换账号要重新授权），解除授权后下次进商城再问一次
   · 允许 → 进商城（商城「我的」页里显示的就是你的头像 / 昵称 / 星言号）
   · 拒绝 → 退回上一页，并提示一句

   入口共两处（`MeView` 的「我 → 商城」、`ShopView` 的「小店 → 商城」），
   都套一层 `MallAuthGate` 就行。
   解除授权在：设置 → 账号 → 个人信息与权限 → 授权管理。
   ============================================================ */

/// 商城授权状态（按账号；一个账号授权一次就够）
@MainActor
final class MallAuthStore: ObservableObject {
    static let shared = MallAuthStore()

    /// 已经授权给哪个账号（空 = 还没授权）
    @Published private(set) var grantedTo: String = ""
    /// 授权时间（毫秒），「授权管理」里显示用
    @Published private(set) var grantedAt: Double = 0

    private let kUser = "dd.mallAuth.user"
    private let kAt = "dd.mallAuth.at"

    private init() {
        grantedTo = UserDefaults.standard.string(forKey: kUser) ?? ""
        grantedAt = UserDefaults.standard.double(forKey: kAt)
    }

    func isGranted(_ uid: String) -> Bool { !uid.isEmpty && grantedTo == uid }

    func grant(_ uid: String) {
        guard !uid.isEmpty else { return }
        grantedTo = uid
        grantedAt = Date().timeIntervalSince1970 * 1000
        UserDefaults.standard.set(uid, forKey: kUser)
        UserDefaults.standard.set(grantedAt, forKey: kAt)
    }

    func revoke() {
        grantedTo = ""
        grantedAt = 0
        UserDefaults.standard.removeObject(forKey: kUser)
        UserDefaults.standard.removeObject(forKey: kAt)
    }
}

/* ---------------------------------------------------------- 授权卡 */

/// 微信那张授权卡：申请方 + 「申请获取以下权限」+ 权限块 + 拒绝/允许
struct MallAuthCard: View {
    /// 申请方名字（商城名，后台可改）
    var appName: String
    /// **本人**的头像 / 昵称 / 星言号 —— 授权卡上要真的把"会被获取的信息"显示出来
    /// （2026-10-16 用户：「获取你的公开信息那个应该是本人的头像」「或者是他真的会获取」）
    var myAvatar: String = ""
    var myName: String = ""
    var myId: String = ""
    var onAllow: () -> Void
    var onDeny: () -> Void

    var body: some View {
        ZStack {
            /* 压暗底下一层（微信也是把上一页压暗） */
            Color.black.opacity(0.35).ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: 9) {
                    /* 申请方图标：没有 logo 就用一个袋子图，底色跟着商城的红 */
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(DDColor.gradBtn)
                        .frame(width: 56, height: 56)
                        .overlay(Image(systemName: "bag.fill")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundColor(.white))
                    Text(appName.isEmpty ? Tr("商城") : appName)
                        .font(pf(17, .semibold)).foregroundColor(C.label)
                    Text(Tr("申请获取以下权限"))
                        .font(pf(13)).foregroundColor(C.subLabel)
                }
                .padding(.top, 24)
                .padding(.horizontal, 20)

                VStack(alignment: .leading, spacing: 5) {
                    Text(Tr("获取你的公开信息"))
                        .font(pf(15)).foregroundColor(C.label)
                    /* 这块不再是干巴巴一句"昵称、头像、星言号"，而是把**真的会给出去的东西**摆出来：
                       左边本人的头像，右边昵称 + 星言号（就是商城「我的」页会显示的那份） */
                    HStack(spacing: 10) {
                        Avatar(path: myAvatar, size: 40, circle: true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(myName.isEmpty ? Tr("（还没有昵称）") : myName)
                                .font(pf(14.5, .medium)).foregroundColor(C.label).lineLimit(1)
                            Text(myId.isEmpty ? Tr("昵称、头像、星言号")
                                              : (Tr("星言号 ") + myId))
                                .font(pf(12)).foregroundColor(C.subLabel).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .semibold)).foregroundColor(C.green)
                    }
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 10).fill(C.pageBg))
                .padding(.horizontal, 22)
                .padding(.top, 16)

                Text(Tr("同意后，商城里会用你的头像和昵称显示身份；随时可以在 设置 → 个人信息与权限 → 授权管理 里解除。"))
                    .font(pf(11.5)).foregroundColor(C.subLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.top, 10)

                HairLine().padding(.top, 18)
                HStack(spacing: 0) {
                    Button(action: onDeny) {
                        Text(Tr("拒绝"))
                            .font(pf(16.5)).foregroundColor(C.subLabel)
                            .frame(maxWidth: .infinity).frame(height: 50)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Rectangle().fill(C.hairline).frame(width: 0.5, height: 50)
                    Button(action: onAllow) {
                        /* 2026-10-17 用户：「所有带有微信绿的按钮换个颜色」——跟全 App 主色走 */
                        Text(Tr("允许"))
                            .font(pf(16.5, .medium)).foregroundColor(C.green)
                            .frame(maxWidth: .infinity).frame(height: 50)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 300)
            .background(C.meCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

/* ---------------------------------------------------------- 授权门 */

/// 把商城套在里面：没授权过就先弹授权卡，允许了才让商城出现。
struct MallAuthGate<Content: View>: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var auth = MallAuthStore.shared
    @ObservedObject private var store = DDStore.shared

    private let content: () -> Content

    /* 显式写一个 init：这个门在**别的文件**里用（MeView / ShopView），
       靠编译器合成的那个容易因为私有属性被判成 private 而编不过。 */
    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    private var uid: String { app.me?.id ?? "" }

    var body: some View {
        ZStack {
            /* 没登录（拿不到账号）就不用问，直接放行 */
            if uid.isEmpty || auth.isGranted(uid) {
                content()
            } else {
                C.pageBg.ignoresSafeArea()
                MallAuthCard(appName: store.mallName,
                             myAvatar: app.me?.avatarPath ?? "",
                             myName: app.me?.nickname ?? "",
                             myId: app.me?.username ?? "",
                             onAllow: { auth.grant(uid) },
                             onDeny: {
                                 app.show(Tr("已拒绝授权，暂时进不了商城"))
                                 dismiss()
                             })
            }
        }
        /* 商城名可能是后台改过的：没拉到就先拉一次，别把「星言商城」这种默认名报给用户 */
        .task { if store.mallName.isEmpty { await store.refresh() } }
    }
}
