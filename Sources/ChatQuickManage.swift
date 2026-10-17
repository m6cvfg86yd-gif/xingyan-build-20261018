import SwiftUI

/// 后台配的 "#RRGGBB" / "RRGGBB" → Color；空串或格式不对就返回 nil（调用方走默认色）。
/// ⚠ 不能往 Color 上加 `init?(hexString:)` —— Core.swift 里已经有一个**非可选**的
/// `init(hexString:fallback:)`，再加一个可选的会让全站的 `Color(hexString:)`
/// 全部被推成 `Color?`（B255 第一次打包就是这么挂的），所以这里用函数代替。
func optionalHexColor(_ s: String) -> Color? {
    var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.hasPrefix("#") { t.removeFirst() }
    guard t.count == 6, UInt32(t, radix: 16) != nil else { return nil }
    return Color(hexString: s)
}

/// 管理 →「聊天快捷」：用户要求的那两件事 ——
/// ① 输入框上面那排**快捷按钮**能管理（增删、排序、改名、开关）；
/// ② 输入框右边那个「＋」按钮能换**颜色 / 大小 / 图片**。
/// 存服务端（和「＋面板」同一个文件），App 回到前台自己就生效，不用重装。
struct ChatQuickAdminSection: View {
    @EnvironmentObject var app: AppState

    @State private var chips: [QuickChip] = []
    @State private var plus = PlusButtonCfg()
    @State private var loaded = false
    @State private var editing: QuickChip?
    @State private var editingIndex = -1
    @State private var msg = ""
    @State private var saving = false
    /// 「＋」按钮：颜色（#RRGGBB，空 = 跟主题走）和大小（0 = 默认）
    @State private var colorText = ""
    @State private var sizeText = "0"
    @State private var showPickPlusImage = false
    /// 发文件用苹果的「文件」App 挑（默认关 = 用我们自己那一页「我的文件」）
    @State private var filePickerSystem = UIConfig.num("filePickerSystem", 0) > 0

    /// 几个常用色，点一下就填上（不想记 #RRGGBB 的时候用）
    private let presetColors = ["", "#07C160", "#576B95", "#FA5151", "#FF9500", "#333333"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(Tr("聊天快捷按钮")).font(pf(13)).foregroundColor(C.subLabel)
                Spacer(minLength: 0)
                if saving { ProgressView().scaleEffect(0.7) }
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 6)

            VStack(spacing: 0) {
                /* ① 快捷按钮列表 */
                ForEach(Array(chips.enumerated()), id: \.element.id) { idx, c in
                    Button { editing = c; editingIndex = idx } label: {
                        HStack(spacing: 10) {
                            Text(c.label).font(pf(16))
                                .foregroundColor(c.enabled ? C.label : C.subLabel)
                            Text(actionName(c.action)).font(pf(12.5)).foregroundColor(C.subLabel)
                            Spacer(minLength: 6)
                            Text(c.enabled ? Tr("显示中") : Tr("已隐藏"))
                                .font(pf(12.5))
                                .foregroundColor(c.enabled ? C.green : C.subLabel)
                            Image(systemName: "chevron.right").font(.system(size: 12))
                                .foregroundColor(C.arrow)
                        }
                        .padding(.horizontal, 16).frame(height: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    HairLine(inset: 16)
                }

                Button {
                    let c = QuickChip(id: "q" + String(Int(Date().timeIntervalSince1970)), label: Tr("新按钮"),
                                      action: "photo", enabled: true)
                    chips.append(c)
                    editing = c
                    editingIndex = chips.count - 1
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 16)).foregroundColor(C.green)
                        Text(Tr("添加一个快捷按钮")).font(pf(15)).foregroundColor(C.green)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16).frame(height: 50)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .background(C.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 12)

            /* ② 「＋」按钮的外观 */
            HStack {
                Text(Tr("「＋」按钮外观")).font(pf(13)).foregroundColor(C.subLabel)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)

            VStack(spacing: 0) {
                /* 颜色 */
                HStack(spacing: 10) {
                    Text(Tr("颜色")).font(pf(16)).foregroundColor(C.label)
                    Spacer(minLength: 6)
                    TextField(Tr("跟主题"), text: $colorText)
                        .font(pf(14))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 110)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Group {
                        if let c = optionalHexColor(colorText) {
                            Circle().fill(c)
                                .overlay(Circle().stroke(C.hairline, lineWidth: 0.5))
                        } else {
                            Circle().fill(Color.clear)
                        }
                    }
                    .frame(width: 22, height: 22)
                }
                .padding(.horizontal, 16).frame(height: 52)

                HStack(spacing: 10) {
                    ForEach(presetColors, id: \.self) { hex in
                        Button { colorText = hex } label: {
                            if hex.isEmpty {
                                Text(Tr("默认")).font(pf(12)).foregroundColor(C.subLabel)
                                    .frame(width: 40, height: 26)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(C.fieldBg))
                            } else {
                                Circle().fill(optionalHexColor(hex) ?? C.green)
                                    .frame(width: 26, height: 26)
                                    .overlay(Circle().stroke(colorText == hex ? C.label : Color.clear, lineWidth: 2))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.bottom, 12)

                HairLine(inset: 16)

                /* 大小 */
                HStack(spacing: 10) {
                    Text(Tr("大小")).font(pf(16)).foregroundColor(C.label)
                    Spacer(minLength: 6)
                    TextField(Tr("默认"), text: $sizeText)
                        .font(pf(14))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                    Text(Tr("pt（留空 = 默认）")).font(pf(12)).foregroundColor(C.subLabel)
                }
                .padding(.horizontal, 16).frame(height: 52)

                HairLine(inset: 16)

                /* 图片（自己上传一张，替换默认那个圆圈加号） */
                HStack(spacing: 10) {
                    Text(Tr("换成图片")).font(pf(16)).foregroundColor(C.label)
                    Spacer(minLength: 6)
                    if !plus.image.isEmpty {
                        RemoteImage(path: plus.image, mode: .fit, maxSide: 200)
                            .frame(width: 28, height: 28)
                        Button(Tr("清除")) { plus.image = "" }
                            .font(pf(13)).foregroundColor(C.red)
                    }
                    Button(Tr("从相册选")) { showPickPlusImage = true }
                        .font(pf(14)).foregroundColor(C.link)
                }
                .padding(.horizontal, 16).frame(height: 52)

                HairLine(inset: 16)

                Button { Task { await save() } } label: {
                    Text(saving ? Tr("保存中…") : Tr("保存"))
                        .font(pf(16, .medium))
                        .foregroundColor(C.green)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .background(C.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 12)

            /* 发文件用哪一套：默认**我们自己的**「我的文件」页；打开这个开关才用苹果的文件 App */
            HStack {
                Text(Tr("发文件")).font(pf(13)).foregroundColor(C.subLabel)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Tr("用苹果的「文件」App 挑文件")).font(pf(16)).foregroundColor(C.label)
                        Text(Tr("关着的时候用我们自己的文件页（发过/收到过的文件都在里面，点一下直接发）"))
                            .font(pf(12)).foregroundColor(C.subLabel)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    Toggle("", isOn: Binding(
                        get: { filePickerSystem },
                        set: { v in
                            filePickerSystem = v
                            Task {
                                let ok = await API.shared.opsSetUIKey("filePickerSystem", v ? 1 : 0)
                                if ok {
                                    let cfg = await API.shared.uiConfig()
                                    UIConfig.apply(cfg.ui)
                                }
                                msg = ok ? (v ? Tr("发文件改用苹果的文件 App 了")
                                              : Tr("发文件已改回我们自己的文件页")) : Tr("保存失败")
                            }
                        }))
                        .labelsHidden().tint(C.green)
                }
                .padding(.horizontal, 16).frame(minHeight: 62)
            }
            .background(C.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 12)

            if !msg.isEmpty {
                Text(msg).font(pf(12.5)).foregroundColor(C.subLabel)
                    .padding(.horizontal, 16).padding(.top, 8)
            }
        }
        .task { await load() }
        .sheet(item: $editing) { c in
            editorSheet(c)
        }
        .sheet(isPresented: $showPickPlusImage) {
            MediaPicker(onImage: { img in
                showPickPlusImage = false
                Task {
                    if let path = try? await API.shared.upload(image: img) {
                        plus.image = path
                        msg = Tr("图片选好了，点保存生效")
                    } else {
                        msg = Tr("图片上传失败，再试一次")
                    }
                }
            }, onVideo: { _ in }, onLive: { _, _ in }, maxImages: 1)
        }
    }

    /// 改一个按钮：名字 / 动作 / 显示开关 / 上移下移 / 删除
    @ViewBuilder
    private func editorSheet(_ c: QuickChip) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                NavBar(title: Tr("快捷按钮"), back: { editing = nil }) {
                    Button { editing = nil } label: {
                        Text(Tr("完成")).font(pf(16, .medium)).foregroundColor(C.green)
                            .frame(height: L.navH).padding(.trailing, 16)
                    }
                }
                ScrollView {
                    VStack(spacing: 12) {
                        VStack(spacing: 0) {
                            HStack(spacing: 10) {
                                Text(Tr("按钮名字")).font(pf(16)).foregroundColor(C.label)
                                Spacer(minLength: 6)
                                TextField(Tr("最多 8 个字"), text: Binding(
                                    get: { currentLabel(c) },
                                    set: { setLabel(c, $0) }))
                                    .font(pf(15))
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 150)
                            }
                            .padding(.horizontal, 16).frame(height: 52)

                            HairLine(inset: 16)

                            HStack(spacing: 10) {
                                Text(Tr("点了做什么")).font(pf(16)).foregroundColor(C.label)
                                Spacer(minLength: 6)
                                Picker("", selection: Binding(
                                    get: { currentAction(c) },
                                    set: { setAction(c, $0) })) {
                                    ForEach(QuickChip.actions, id: \.self) { a in
                                        Text(actionName(a)).tag(a)
                                    }
                                }
                                .pickerStyle(.menu)
                                .tint(C.link)
                            }
                            .padding(.horizontal, 16).frame(height: 52)

                            HairLine(inset: 16)

                            HStack(spacing: 10) {
                                Text(Tr("在聊天里显示")).font(pf(16)).foregroundColor(C.label)
                                Spacer(minLength: 6)
                                Toggle("", isOn: Binding(
                                    get: { currentEnabled(c) },
                                    set: { setEnabled(c, $0) }))
                                    .labelsHidden().tint(C.green)
                            }
                            .padding(.horizontal, 16).frame(height: 52)
                        }
                        .background(C.cardBg)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.horizontal, 12)

                        VStack(spacing: 0) {
                            Button { move(c, -1) } label: {
                                Text(Tr("上移")).font(pf(16)).foregroundColor(C.label)
                                    .frame(maxWidth: .infinity).frame(height: 50)
                            }
                            .buttonStyle(.plain)
                            HairLine(inset: 16)
                            Button { move(c, 1) } label: {
                                Text(Tr("下移")).font(pf(16)).foregroundColor(C.label)
                                    .frame(maxWidth: .infinity).frame(height: 50)
                            }
                            .buttonStyle(.plain)
                        }
                        .background(C.cardBg)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.horizontal, 12)

                        Button {
                            chips.removeAll { $0.id == c.id }
                            editing = nil
                            msg = Tr("删掉了，记得点保存")
                        } label: {
                            Text(Tr("删除这个按钮")).font(pf(16)).foregroundColor(C.red)
                                .frame(maxWidth: .infinity).frame(height: 50)
                                .background(C.cardBg)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .padding(.horizontal, 12)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 12)
                }
            }
            .background(C.pageBg.ignoresSafeArea())
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            /* 2026-10-16：快捷按钮编辑器补左滑返回 */
            .swipeBack { editing = nil }
        }
    }

    /* ---------- 编辑时用的小工具（列表里那一份是值拷贝，改完要写回数组） ---------- */

    private func idx(_ c: QuickChip) -> Int? { chips.firstIndex { $0.id == c.id } }
    private func currentLabel(_ c: QuickChip) -> String { idx(c).map { chips[$0].label } ?? c.label }
    private func currentAction(_ c: QuickChip) -> String { idx(c).map { chips[$0].action } ?? c.action }
    private func currentEnabled(_ c: QuickChip) -> Bool { idx(c).map { chips[$0].enabled } ?? c.enabled }

    private func setLabel(_ c: QuickChip, _ v: String) {
        guard let i = idx(c) else { return }
        chips[i].label = String(v.prefix(8))
    }
    private func setAction(_ c: QuickChip, _ v: String) {
        guard let i = idx(c) else { return }
        chips[i].action = v
    }
    private func setEnabled(_ c: QuickChip, _ v: Bool) {
        guard let i = idx(c) else { return }
        chips[i].enabled = v
    }
    private func move(_ c: QuickChip, _ d: Int) {
        guard let i = idx(c) else { return }
        let j = i + d
        guard j >= 0, j < chips.count else { return }
        chips.swapAt(i, j)
    }

    private func actionName(_ a: String) -> String {
        QuickChip.actionNames[a] ?? Tr("未设置")
    }

    private func load() async {
        guard !loaded else { return }
        loaded = true
        let c = await API.shared.plusConfigSafe()
        chips = c.quick.isEmpty ? QuickChip.defaults : c.quick
        plus = c.plus
        colorText = plus.color
        sizeText = plus.size > 0 ? String(Int(plus.size)) : ""
    }

    private func save() async {
        saving = true
        defer { saving = false }
        var cfg = plus
        cfg.color = colorText.trimmingCharacters(in: .whitespacesAndNewlines)
        cfg.size = Double(sizeText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        do {
            try await API.shared.saveChatQuick(quick: chips, plus: cfg)
            plus = cfg
            /* 本机立刻按新配置走（不用等回到前台） */
            app.quickChips = chips
            app.plusButton = cfg
            msg = Tr("已保存，聊天里立刻生效")
        } catch {
            msg = (error as? APIError)?.errorDescription ?? Tr("保存失败，再试一次")
        }
    }
}
