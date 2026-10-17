import SwiftUI

/* ============================================================
   设置里那三段（账号 / 通用 / 功能）点进去的二级页 —— 照微信那几页做：
     · 账号 → 个人信息与权限（SelfPermView）
     · 通用 → 更多（MoreSettingsView）
     · 功能 → 聊天（ChatSettingsView）/ 音视频通话（CallSettingsView）
   这些页都挂在「我」页那条 navigationDestination 上（key: selfperm / more / setchat / setcall），
   一律**整页 push**（不是 sheet / 半屏），和微信一样。
   ============================================================ */

/// 「设置」里那种一行一项：左边标题、右边小字值、右箭头，点进下一整页
struct SettingRowLink: View {
    let title: String
    var value: String = ""
    let key: String

    var body: some View {
        NavigationLink(value: key) {
            SettingRowLabel(title: title, value: value)
        }
        .buttonStyle(MenuPressStyle())
    }
}

/// 同上一行，但点下去不是跳页（弹窗 / 打开 iOS 设置）
struct SettingRowButton: View {
    let title: String
    var value: String = ""
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            SettingRowLabel(title: title, value: value)
        }
        .buttonStyle(MenuPressStyle())
    }
}

struct SettingRowLabel: View {
    let title: String
    var value: String = ""

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(pf(17)).foregroundColor(C.label)
            Spacer(minLength: 0)
            if !value.isEmpty {
                Text(value).font(pf(15)).foregroundColor(C.subLabel).lineLimit(1)
            }
            Chevron(size: 9, line: 1.6).padding(.trailing, 3)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(C.meCardBg)
        .contentShape(Rectangle())
    }
}

/* ---------------- 账号 → 个人信息与权限 ---------------- */

struct SelfPermView: View {
    @ObservedObject private var lang = LangStore.shared
    /// 商城授权（照微信：设置 → 个人信息与权限 → 授权管理）
    @ObservedObject private var mallAuth = MallAuthStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showMallAuth = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("个人信息与权限"), back: { dismiss() })
            ScrollView {
                VStack(spacing: 0) {
                    GroupCard {
                        SettingRowLink(title: Tr("个人资料"), key: "profile")
                        HairLine(inset: 16)
                        /* 微信这一行点下去就是跳到 iOS 设置里那个 App 的权限页 */
                        SettingRowButton(title: Tr("系统权限管理"), value: Tr("相册 / 相机 / 麦克风")) {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        HairLine(inset: 16)
                        /* 微信那套「授权管理」：这里列出你授权过的第三方（现在只有商城），
                           可以一键解除；解除后下次进商城会重新问一次 */
                        SettingRowButton(title: Tr("授权管理"),
                                         value: mallAuth.grantedTo.isEmpty ? Tr("无") : Tr("商城")) {
                            showMallAuth = true
                        }
                        HairLine(inset: 16)
                        SettingRowLink(title: Tr("隐私"), key: "privacy")
                    }
                    .padding(.top, 8)

                    Text(Tr("App 只在你同意之后才会用相册、相机、麦克风、位置这些权限，随时可以在 iOS 设置里改。"))
                        .font(pf(12))
                        .foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.top, 10)
                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .sheet(isPresented: $showMallAuth) { MallAuthManageSheet() }
    }
}

/// 授权管理：列出授权过的应用，可以解除授权（和微信一样）
struct MallAuthManageSheet: View {
    @ObservedObject private var auth = MallAuthStore.shared
    @ObservedObject private var store = DDStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("授权管理"), back: { dismiss() })
            ScrollView {
                VStack(spacing: 0) {
                    if auth.grantedTo.isEmpty {
                        Text(Tr("还没有授权任何应用"))
                            .font(pf(14.5)).foregroundColor(C.subLabel)
                            .padding(.top, 60)
                    } else {
                        GroupCard {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(DDColor.gradBtn)
                                    .frame(width: 44, height: 44)
                                    .overlay(Image(systemName: "bag.fill")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundColor(.white))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(store.mallName).font(pf(16)).foregroundColor(C.label)
                                    Text(Tr("获取你的公开信息（昵称、头像、星言号）"))
                                        .font(pf(12)).foregroundColor(C.subLabel)
                                }
                                Spacer(minLength: 0)
                                Button {
                                    auth.revoke()
                                } label: {
                                    Text(Tr("解除授权"))
                                        .font(pf(14)).foregroundColor(Color(hex: 0xFA5151))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 66)
                        }
                        .padding(.top, 8)
                    }
                    Text(Tr("解除授权后，下次进商城会重新问一次。"))
                        .font(pf(12)).foregroundColor(C.subLabel)
                        .padding(.horizontal, 22).padding(.top, 10)
                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .hidesTabBar()
    }
}

/* ---------------- 通用 → 更多 ---------------- */

struct MoreSettingsView: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showDiag = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("更多"), back: { dismiss() })
            ScrollView {
                VStack(spacing: 0) {
                    GroupCard {
                        SettingRowLink(title: Tr("未成年人模式"), key: "teen")
                        HairLine(inset: 16)
                        SettingRowLink(title: Tr("关怀模式"),
                                       value: CareMode.on ? Tr("已开启") : Tr("未开启"),
                                       key: "care")
                        HairLine(inset: 16)
                        SettingRowLink(title: Tr("我的等级"), key: "level")
                        HairLine(inset: 16)
                        SettingRowLink(title: Tr("安全分"), key: "score")
                        HairLine(inset: 16)
                        SettingRowLink(title: Tr("登录设备管理"), key: "devices")
                        HairLine(inset: 16)
                        /* 微信那套「故障修复」：一列检查项，每项先检测、能修的当场修 */
                        SettingRowLink(title: Tr("故障修复"), key: "health")
                        HairLine(inset: 16)
                        /* 诊断工具（用户要求「在设置里加入全套诊断工具」）：
                           版本 / 机型 / 内存 / 缓存 / 网络 / 上次崩溃 / 聊天页打点，
                           进这一页就能一键上报给开发者 —— 以后出问题不用再靠猜。 */
                        SettingRowButton(title: Tr("诊断工具")) { showDiag = true }
                    }
                    .padding(.top, 8)
                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .sheet(isPresented: $showDiag) {
            DiagView().environmentObject(app)
        }
        /* 小星那一档现在挪到「我 → 插件」里了（2026-10-15 用户要求），设置里不再拉它 */
    }
}

/* ---------------- 功能 → 聊天 ---------------- */

struct ChatSettingsView: View {
    @ObservedObject private var lang = LangStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("聊天"), back: { dismiss() })
            ScrollView {
                VStack(spacing: 0) {
                    GroupCard {
                        SettingRowLink(title: Tr("聊天背景"), key: "g.chatbg")
                        HairLine(inset: 16)
                        SettingRowLink(title: Tr("语音变声"), key: "g.voice")
                        HairLine(inset: 16)
                        SettingRowLink(title: Tr("聊天记录管理"), key: "g.history")
                        HairLine(inset: 16)
                        SettingRowLink(title: Tr("存储空间"), key: "g.storage")
                    }
                    .padding(.top, 8)

                    Text(Tr("聊天记录只存在这台手机上，也能在「存储空间」里按会话清理。"))
                        .font(pf(12))
                        .foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.top, 10)
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
}

/* ---------------- 功能 → 音视频通话 ---------------- */

struct CallSettingsView: View {
    @ObservedObject private var lang = LangStore.shared
    @Environment(\.dismiss) private var dismiss
    /* 视频清晰度 / 本地镜像 / 美颜（对齐微信这三样）：存本机，改完正在进行的通话立刻生效 */
    @State private var quality = CallPrefs.quality
    @State private var mirror = CallPrefs.mirror
    @State private var beauty = CallPrefs.beauty
    @State private var pickQuality = false
    @State private var pickBeauty = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("音视频通话"), back: { dismiss() })
            ScrollView {
                VStack(spacing: 0) {
                    GroupCard {
                        SettingRowLink(title: Tr("新消息通知"), key: "notify")
                        HairLine(inset: 16)
                        SettingRowLink(title: Tr("语音变声"), key: "g.voice")
                        HairLine(inset: 16)
                        /* 视频清晰度：标清 360p / 高清 720p / 超清 1080p（微信也是这三档） */
                        Button { pickQuality = true } label: {
                            SettingRowLabel(title: Tr("视频清晰度"), value: Tr(CallPrefs.qualityName))
                        }
                        .buttonStyle(MenuPressStyle())
                        HairLine(inset: 16)
                        /* 本地画面镜像（前置照镜子那样，默认开） */
                        HStack(spacing: 12) {
                            Text(Tr("本地画面镜像")).font(pf(17)).foregroundColor(C.label)
                            Spacer(minLength: 0)
                            Toggle("", isOn: Binding(
                                get: { mirror },
                                set: { v in mirror = v; CallPrefs.mirror = v }))
                                .labelsHidden().tint(C.green)
                        }
                        .padding(.horizontal, 16).frame(height: 56)
                        HairLine(inset: 16)
                        /* 视频美颜：关 / 低 / 中 / 高 */
                        Button { pickBeauty = true } label: {
                            SettingRowLabel(title: Tr("视频美颜"), value: Tr(CallPrefs.beautyName))
                        }
                        .buttonStyle(MenuPressStyle())
                        HairLine(inset: 16)
                        SettingRowLink(title: Tr("登录设备管理"), key: "devices")
                    }
                    .padding(.top, 8)

                    Text(Tr("语音通话默认走听筒，通话中点一下扬声器就外放；视频通话默认外放。清晰度、镜像、美颜改完，正在进行的通话会立刻生效。"))
                        .font(pf(12))
                        .foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.top, 10)
                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .confirmationDialog(Tr("视频清晰度"), isPresented: $pickQuality, titleVisibility: .visible) {
            Button(Tr("标清（省流量）")) { quality = 0; CallPrefs.quality = 0 }
            Button(Tr("高清（推荐）")) { quality = 1; CallPrefs.quality = 1 }
            Button(Tr("超清（最清晰）")) { quality = 2; CallPrefs.quality = 2 }
            Button(Tr("取消"), role: .cancel) { }
        } message: {
            Text(Tr("清晰度越高越吃流量：标清约 0.6Mbps、高清约 1.5Mbps、超清约 2.6Mbps。"))
        }
        .confirmationDialog(Tr("视频美颜"), isPresented: $pickBeauty, titleVisibility: .visible) {
            Button(Tr("关")) { beauty = 0; CallPrefs.beauty = 0 }
            Button(Tr("低")) { beauty = 1; CallPrefs.beauty = 1 }
            Button(Tr("中")) { beauty = 2; CallPrefs.beauty = 2 }
            Button(Tr("高")) { beauty = 3; CallPrefs.beauty = 3 }
            Button(Tr("取消"), role: .cancel) { }
        }
    }
}
