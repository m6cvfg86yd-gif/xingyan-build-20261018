import SwiftUI

/* ============================================================
   「你的账号在另一台设备上登录」卡片（2026-10-12 加，手机单点登录 A 方案）

   规则：**手机单点**——同一个账号在新手机上登录，旧手机立刻下线；
   平板 / 电脑可以和手机并存，谁都不顶谁。

   服务器通过两条路告诉我们「你被顶下线了」：
     · 长连接推一条 { type: "kick", reason: "otherLogin", device, at }
     · 任何接口回 401 + details.code = "other_login"
   两条路都汇总到 OtherLogin.shared，最外层弹这张卡片。

   收到之后：停实时连接与同步（不再收新消息），**本地聊天记录一条不动**；
   用户点「退出」回登录页、点「我知道了」就关掉卡片（这一轮不再重复弹）。
   ============================================================ */

@MainActor
final class OtherLogin: ObservableObject {
    static let shared = OtherLogin()

    /// 卡片开着没有
    @Published var open = false
    /// 在哪台设备上登录的（服务器报的机型，认不出来就空着）
    @Published var device = ""
    /// 什么时候（用户的手机时间，服务器给的是它自己的时间，只用来显示个大概）
    @Published var at = Date()

    /// 用户点过「我知道了」：这一轮不再重复弹（不然每个请求 401 都弹一次）
    private var locked = false

    func trigger(device: String, atMillis: Double = 0) {
        guard !locked else { return }
        if !device.isEmpty { self.device = device }
        if atMillis > 0 { self.at = Date(timeIntervalSince1970: atMillis / 1000) }
        else { self.at = Date() }
        open = true
        /* 被顶下线了：实时连接停掉（本地聊天记录不动，只是不再收新消息）。
           HTTP 那一路还会不停拿到 401，所以这里也顺手停一次。 */
        Realtime.shared.stop()
        AppLog.error("被顶下线", "账号在「" + (self.device.isEmpty ? "另一台设备" : self.device) + "」上登录")
    }

    /// 「我知道了」：关卡片，但保持现在的状态（下次真被人顶下线还会再弹）
    func dismiss() {
        locked = true
        open = false
    }

    /// 重新登录 / 退出登录之后复位，下一次被顶下线还能弹
    func reset() {
        locked = false
        open = false
        device = ""
    }

    /// 卡片里显示的设备 + 时间
    var detailText: String {
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm"
        let d = device.isEmpty ? "另一台\(AppInfo.deviceKindName)" : device
        return "登录设备：" + d + "\n登录时间：" + df.string(from: at)
    }
}

/// 全局那张卡片：挂在最外层（MainTabView），任何页面被顶下线都能弹出来
struct OtherLoginCard: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var kick = OtherLogin.shared

    var body: some View {
        Group {
            if kick.open {
                ZStack {
                    Color.black.opacity(0.28).ignoresSafeArea()
                    VStack(spacing: 0) {
                        Text(Tr("你的账号在另一台设备上登录"))
                            .font(pf(17, .semibold))
                            .foregroundColor(C.label)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 22)
                            .padding(.top, 26)

                        Text(kick.detailText)
                            .font(pf(13.5))
                            .foregroundColor(C.subLabel)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 22)
                            .padding(.top, 10)

                        Text(Tr("如果不是你本人操作，请立刻修改密码。"))
                            .font(pf(13))
                            .foregroundColor(C.subLabel)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 22)
                            .padding(.top, 8)

                        Rectangle().fill(C.hairline).frame(height: 0.5).padding(.top, 20)

                        HStack(spacing: 0) {
                            Button {
                                kick.dismiss()
                            } label: {
                                Text(Tr("我知道了"))
                                    .font(pf(16))
                                    .foregroundColor(C.label)
                                    .frame(maxWidth: .infinity).frame(height: 50)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Rectangle().fill(C.hairline).frame(width: 0.5, height: 50)

                            /* 「退出」= 真的退出登录（回登录页），这样就不会再被 401 刷屏 */
                            Button {
                                kick.reset()
                                Task { await app.logout() }
                            } label: {
                                Text(Tr("退出"))
                                    .font(pf(16, .medium))
                                    .foregroundColor(C.red)
                                    .frame(maxWidth: .infinity).frame(height: 50)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(width: 280)
                    .background(C.cardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.22), radius: 22, y: 8)
                }
            }
        }
    }
}
