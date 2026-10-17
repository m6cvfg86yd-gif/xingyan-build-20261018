import SwiftUI

/* ============================================================
   隐私 / 消息通知（照微信那两页的逻辑和排布做）
   · 隐私：加我时需要验证、允许陌生人看朋友圈、添加我的方式（微信号/手机号/群聊/二维码）
   · 消息通知：新消息通知、声音、振动、显示消息详情、免打扰时段
   ============================================================ */

struct PrivacyView: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var p = PrivacySettings()
    @State private var showRange = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("隐私"), back: { dismiss() })
            ScrollView {
                VStack(spacing: 8) {
                    GroupCard {
                        row(Tr("加我为朋友时需要验证"), $p.needVerify, "needVerify")
                        HairLine(inset: 16)
                        row(Tr("允许陌生人查看朋友圈"), $p.strangerMoments, "strangerMoments")
                        HairLine(inset: 16)
                        /* 微信「隐私」里那一行：朋友圈可见范围（最近三天 / 最近半年 / 全部）。
                           点一下弹选择；只对别人生效，自己永远看得见自己的全部。 */
                        Button { showRange = true } label: {
                            HStack(spacing: 10) {
                                Text(Tr("朋友圈可见范围")).font(pf(16)).foregroundColor(C.label)
                                Spacer(minLength: 8)
                                Text(rangeLabel).font(pf(15)).foregroundColor(C.subLabel)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(C.subLabel)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 50)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 8)

                    Text(Tr("添加我的方式")).font(pf(13)).foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22).padding(.top, 12)
                    GroupCard {
                        row(Tr("账号"), $p.addByWx, "addByWx")
                        HairLine(inset: 16)
                        row(Tr("手机号"), $p.addByPhone, "addByPhone")
                        HairLine(inset: 16)
                        row(Tr("群聊"), $p.addByGroup, "addByGroup")
                        HairLine(inset: 16)
                        row(Tr("二维码"), $p.addByQR, "addByQR")
                    }

                    Text(Tr("关掉之后，别人就不能用这个方式找到你、加你好友。"))
                        .font(pf(12)).foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22).padding(.top, 10)
                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { p = await API.shared.privacy() }
        .confirmationDialog(Tr("朋友圈可见范围"), isPresented: $showRange, titleVisibility: .visible) {
            Button(Tr("最近三天")) { setRange("3d") }
            Button(Tr("最近半年")) { setRange("6m") }
            Button(Tr("全部")) { setRange("all") }
            Button(Tr("取消"), role: .cancel) { }
        }
    }

    /// 当前范围显示成中文（微信那一行右边就是这三个说法之一）
    private var rangeLabel: String {
        switch p.momentsRange {
        case "3d": return Tr("最近三天")
        case "6m": return Tr("最近半年")
        default: return Tr("全部")
        }
    }

    private func setRange(_ v: String) {
        p.momentsRange = v
        Task { await API.shared.setPrivacyText("momentsRange", v) }
    }

    private func row(_ title: String, _ value: Binding<Bool>, _ key: String) -> some View {
        HStack(spacing: 10) {
            Text(title).font(pf(16)).foregroundColor(C.label)
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { value.wrappedValue },
                set: { v in
                    value.wrappedValue = v
                    Task { await API.shared.setPrivacy(key, v) }
                }
            ))
            .labelsHidden().tint(C.green)
        }
        .padding(.horizontal, 16).frame(height: 50)
    }
}

struct NotifyView: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var n = NotifySettings()
    @State private var muteOn = false
    @ObservedObject private var push = PushCenter.shared

    /// 系统那一层到底允不允许通知（微信「接收新消息通知」那一行显示的就是这个）
    private var sysText: String { push.authorized ? Tr("已开启") : Tr("已关闭") }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("新消息通知"), back: { dismiss() })
            ScrollView {
                VStack(spacing: 8) {
                    /* 微信那一行在最上面：点一下直接跳到 iOS 设置里的通知页 */
                    GroupCard {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Text(Tr("接收新消息通知")).font(pf(16)).foregroundColor(C.label)
                                Spacer(minLength: 8)
                                Text(sysText)
                                    .font(pf(15))
                                    .foregroundColor(push.authorized ? C.subLabel : C.red)
                                Chevron(size: 9, line: 1.6).padding(.trailing, 3)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 50)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 8)

                    if !push.authorized {
                        Text(Tr("系统通知还没开：点上面那行去 iOS 设置里打开「允许通知」，不然 App 在后台收不到提醒。"))
                            .font(pf(12.5))
                            .foregroundColor(C.subLabel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 22)
                    }

                    GroupCard {
                        row(Tr("App 内提醒"), $n.on, "on")
                        HairLine(inset: 16)
                        row(Tr("声音"), $n.sound, "sound")
                        HairLine(inset: 16)
                        row(Tr("振动"), $n.vibrate, "vibrate")
                        HairLine(inset: 16)
                        row(Tr("通知显示消息详情"), $n.showDetail, "showDetail")
                    }
                    .padding(.top, 8)

                    GroupCard {
                        HStack(spacing: 10) {
                            Text(Tr("免打扰")).font(pf(16)).foregroundColor(C.label)
                            Spacer(minLength: 8)
                            Toggle("", isOn: $muteOn).labelsHidden().tint(C.green)
                        }
                        .padding(.horizontal, 16).frame(height: 50)
                        if muteOn {
                            HairLine(inset: 16)
                            HStack(spacing: 10) {
                                DatePicker("", selection: Binding(
                                    get: { Self.time(n.muteStart, 22, 0) },
                                    set: { n.muteStart = Self.hhmm($0) }), displayedComponents: .hourAndMinute)
                                    .labelsHidden()
                                Text("—").foregroundColor(C.subLabel)
                                DatePicker("", selection: Binding(
                                    get: { Self.time(n.muteEnd, 7, 0) },
                                    set: { n.muteEnd = Self.hhmm($0) }), displayedComponents: .hourAndMinute)
                                    .labelsHidden()
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16).frame(height: 50)
                        }
                    }

                    Text(Tr("免打扰时段里收到消息不响不震，进 App 还是能看到小红点。"))
                        .font(pf(12)).foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22).padding(.top, 10)
                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task {
            n = await API.shared.notifySettings()
            muteOn = !(n.muteStart.isEmpty || n.muteEnd.isEmpty)
            if !muteOn { n.muteStart = ""; n.muteEnd = "" }
            PushCenter.shared.start()          // 顺手问一次系统权限，那一行显示的就是最新状态
        }
        .onChange(of: muteOn) { on in
            if on { n.muteStart = "22:00"; n.muteEnd = "07:00" }
            else { n.muteStart = ""; n.muteEnd = "" }
            Task { await API.shared.setNotify(["muteStart": n.muteStart, "muteEnd": n.muteEnd]) }
        }
    }

    private func row(_ title: String, _ value: Binding<Bool>, _ key: String) -> some View {
        HStack(spacing: 10) {
            Text(title).font(pf(16)).foregroundColor(C.label)
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { value.wrappedValue },
                set: { v in
                    value.wrappedValue = v
                    Task { await API.shared.setNotify([key: v]) }
                }
            ))
            .labelsHidden().tint(C.green)
        }
        .padding(.horizontal, 16).frame(height: 50)
    }

    static func hhmm(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
    static func time(_ s: String, _ h: Int, _ m: Int) -> Date {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        if let d = f.date(from: s) { return d }
        var c = DateComponents(); c.hour = h; c.minute = m
        return Calendar.current.date(from: c) ?? Date()
    }
}

/* ---------------- 通用（外观 / 界面语言 / 聊天背景）---------------- */

struct GeneralView: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var showTheme = false
    @State private var showLang = false
    @State private var showBg = false
    @State private var showBgPick = false
    @State private var showStorage = false
    @State private var showHistory = false
    @State private var showVoice = false
    @ObservedObject private var voiceStore = VoiceChangerStore.shared

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("通用"), back: { dismiss() })
            ScrollView {
                VStack(spacing: 0) {
                    GroupCard {
                        /* 二级菜单一律**整页 push**（微信也是这样）：外观 / 语言 / 聊天背景 /
                           存储空间 / 聊天记录管理 / 语音变声 —— 落点都在「我」页那条
                           navigationDestination 上，不再是 sheet / 半屏。 */
                        link(Tr("外观"),
                             app.appearance == "dark" ? Tr("深色")
                                 : (app.appearance == "light" ? Tr("浅色") : Tr("跟随系统")),
                             key: "g.theme")
                        HairLine(inset: 16)
                        link(Tr("界面语言"), Lang.name, key: "g.lang")
                        HairLine(inset: 16)
                        link(Tr("聊天背景"),
                             (app.me?.chatBackground ?? "auto") == "auto" ? Tr("恢复默认") : Tr("自定义"),
                             key: "g.chatbg")
                        HairLine(inset: 16)
                        /* 微信「通用 → 存储空间」：看占用 + 清缓存 + 清某个会话的记录 */
                        link(Tr("存储空间"), "", key: "g.storage")
                        HairLine(inset: 16)
                        link(Tr("聊天记录管理"), "", key: "g.history")
                        HairLine(inset: 16)
                        /* 真人变声：发语音和打电话共用一个预设 */
                        link(Tr("语音变声"), voiceStore.current.name, key: "g.voice")
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
    }

    /// 和 row 长得一样，但点进去是下一个**整页**（用导航，不是 sheet）
    private func link(_ title: String, _ value: String, key: String) -> some View {
        NavigationLink(value: key) {
            HStack(spacing: 12) {
                Text(title).font(pf(17)).foregroundColor(C.label)
                Spacer(minLength: 8)
                Text(value).font(pf(15)).foregroundColor(C.subLabel)
                Chevron(size: 9, line: 1.6).padding(.trailing, 3)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ title: String, _ value: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                Text(title).font(pf(17)).foregroundColor(C.label)
                Spacer(minLength: 8)
                Text(value).font(pf(15)).foregroundColor(C.subLabel)
                Chevron(size: 9, line: 1.6).padding(.trailing, 3)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func setLang(_ code: String) {
        Lang.code = code
        app.show(code == "en" ? "Language switched to English" : "界面语言已切成中文")
        dismiss()
        /* 不在运行中重绘界面（重绘这条路试过两次都会闪退）：
           语言已经存下来了，重开 App 就是新语言。 */
    }

    private func changeBg(_ image: UIImage) {
        Task {
            if let url = try? await API.shared.uploadOriginal(image: image) {   // 聊天背景用原图
                await API.shared.changeBackground(url)
                app.me = try? await API.shared.me()
                app.show(Tr("聊天背景换好了"))
            }
        }
    }
}

/* ============================================================
   通用 → 外观（微信也是一整页三个选项，不是底下冒出来的半屏）
   ============================================================ */
struct AppearanceView: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    private let opts: [(String, String)] = [("auto", "跟随系统"), ("light", "浅色"), ("dark", "深色")]

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("外观"), back: { dismiss() })
            ScrollView {
                VStack(spacing: 0) {
                    GroupCard {
                        ForEach(opts.indices, id: \.self) { i in
                            if i > 0 { HairLine(inset: 16) }
                            Button { app.setAppearance(opts[i].0) } label: {
                                HStack(spacing: 12) {
                                    Text(Tr(opts[i].1)).font(pf(17)).foregroundColor(C.label)
                                    Spacer(minLength: 8)
                                    if app.appearance == opts[i].0 {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundColor(C.green)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .frame(height: 54)
                                .background(C.cardBg)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
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
    }
}

/* ============================================================
   通用 → 界面语言（同样整页两个选项）
   ============================================================ */
struct LanguageView: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    private let opts: [(String, String)] = [("zh", "简体中文"), ("en", "English")]

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("界面语言"), back: { dismiss() })
            ScrollView {
                VStack(spacing: 0) {
                    GroupCard {
                        ForEach(opts.indices, id: \.self) { i in
                            if i > 0 { HairLine(inset: 16) }
                            Button {
                                Lang.code = opts[i].0
                                app.show(opts[i].0 == "en" ? "Language switched to English"
                                                           : "界面语言已切成中文")
                            } label: {
                                HStack(spacing: 12) {
                                    Text(opts[i].1).font(pf(17)).foregroundColor(C.label)
                                    Spacer(minLength: 8)
                                    if Lang.code == opts[i].0 {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundColor(C.green)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .frame(height: 54)
                                .background(C.cardBg)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 8)
                    Text(Tr("换完语言把 App 从后台划掉重开，全部界面文字才是新语言。"))
                        .font(pf(12.5))
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

/* ---------------- 设置数据的模型 + 接口 ---------------- */

struct PrivacySettings {
    var needVerify = true
    var strangerMoments = false
    var addByWx = true
    var addByPhone = true
    var addByGroup = true
    var addByQR = true
    /// 朋友圈可见范围（微信那一行）：3d 最近三天 / 6m 最近半年 / all 全部
    var momentsRange = "all"
}

struct NotifySettings {
    var on = true
    var sound = true
    var vibrate = true
    var showDetail = true
    var muteStart = ""
    var muteEnd = ""
}
