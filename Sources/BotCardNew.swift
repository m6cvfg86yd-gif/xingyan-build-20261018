import SwiftUI

/* ============================================================
   官方号名片 · 新版（畅聊 / HarmonyOS 设计语言）
   开关：后台 ui.json 里 agentCardStyle = "new" 才走这一版；默认 "old" = 原来那版
   ============================================================ */

private let aBlue   = Color(hex: 0x007DFF)
private let aBlueBg = Color(hex: 0xE8F3FF)
private let aInk    = Color(hex: 0x181818)
private let aInk3   = Color(hex: 0x999999)
private let aBg     = Color(hex: 0xF5F6F7)
private let aLine   = Color(hex: 0xE8EAED)

struct BotCardNew: View {
    let name: String
    let bio: String
    let avatarPath: String
    let isEyes: Bool
    let onClose: () -> Void
    let onMessage: () -> Void
    let onCall: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            aBg.ignoresSafeArea()
            VStack(spacing: 0) {
                nav
                ScrollView {
                    VStack(spacing: 0) {
                        hero
                        sectionTitle("服务状态")
                        card {
                            hRow("今日已服务", "128 次")
                            line
                            hRow("平均响应", "1.2 秒")
                            line
                            hRow("可代做", "发消息 · 提醒 · 总结")
                        }
                        sectionTitle("安全")
                        card {
                            hRow("发消息前确认", "已开启")
                            line
                            hRow("记忆与隐私", "管理")
                        }
                        Spacer(minLength: 24)
                    }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .hidesTabBar()
    }

    private var nav: some View {
        HStack {
            Button { onClose() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold)).foregroundColor(aInk)
            }
            .buttonStyle(.plain)
            Spacer()
            Text(name).font(pf(17, .semibold)).foregroundColor(aInk)
            Spacer()
            Image(systemName: "ellipsis").font(.system(size: 17)).foregroundColor(aInk)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color.white)
    }

    private var hero: some View {
        VStack(spacing: 0) {
            /* 官方号是「账号卡」：顶上一条品牌浅蓝 banner，logo 压在上面（跟好友人名卡区分开） */
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [aBlueBg, aBlueBg.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 84)
                ZStack {
                    Circle().fill(Color.white).frame(width: 92, height: 92)
                    if isEyes {
                        JarvisEyesAvatar(size: 60)
                    } else {
                        Avatar(path: avatarPath, size: 60, radius: 30)
                    }
                }
                .offset(y: 46)
            }
            .frame(height: 100)
            .padding(.bottom, 46)
            HStack(spacing: 6) {
                Text(name).font(pf(22, .medium)).foregroundColor(aInk)
                Image(systemName: "checkmark.seal.fill").font(.system(size: 15)).foregroundColor(aBlue)
            }
            .padding(.top, 16)
            Text(bio).font(pf(14)).foregroundColor(aInk3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24).padding(.top, 6)
            HStack(spacing: 12) {
                Button { onMessage() } label: {
                    Text("发消息").font(pf(17, .medium)).foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(Capsule().fill(aBlue))
                }
                .buttonStyle(.plain)
                Button { onCall() } label: {
                    Text("打电话").font(pf(17, .medium)).foregroundColor(aBlue)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(Capsule().stroke(aBlue, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: Color(hex: 0x20000000), radius: 8, x: 0, y: 2)
        .padding(.horizontal, 16).padding(.top, 12)
    }

    private func sectionTitle(_ t: String) -> some View {
        HStack { Text(t).font(pf(18, .medium)).foregroundColor(aInk); Spacer() }
            .padding(.horizontal, 16).padding(.top, 24).padding(.bottom, 8)
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: Color(hex: 0x20000000), radius: 8, x: 0, y: 2)
            .padding(.horizontal, 16)
    }

    private func hRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(pf(16)).foregroundColor(aInk)
            Spacer()
            Text(v).font(pf(14)).foregroundColor(aInk3)
        }
        .padding(.horizontal, 16).frame(height: 56)
    }

    private var line: some View { Rectangle().fill(aLine).frame(height: 1).padding(.leading, 16) }
}
