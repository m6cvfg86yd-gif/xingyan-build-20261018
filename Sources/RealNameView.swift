import SwiftUI

/* ============================================================
   实名认证（我 → 设置 → 实名认证）
   填姓名 + 身份证号，服务端校验：18 位（最后一位可能是 X）、
   生日合法、校验位对、一人一证（和「自助解封」用同一张证）。
   认证过就不能自己改，要改找管理员。实名 +30 分安全分。
   ============================================================ */
struct RealNameView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var info: API.RealNameInfo?
    @State private var name = ""
    @State private var idCard = ""
    @State private var busy = false
    @State private var error = ""
    /// 人脸核身那一页（微信：实名之前先刷脸）
    @State private var showFace = false
    /// 这一轮是不是已经核过脸了（核过就直接提交）
    @State private var faceOK = false
    @FocusState private var focus: Field?

    private enum Field: Hashable { case name, id }

    private var sheetBg: Color { scheme == .dark ? Color(hex: 0x1C1C1E) : .white }
    /* 页面底色统一走后台的 pageBg（暗色下就是会话页每行那个 #141419） */
    private var pageBg: Color { C.pageBg }
    private var ink: Color { scheme == .dark ? Color(hex: 0xEDEDED) : Color(hex: 0x1A1A1A) }
    private var gray: Color { scheme == .dark ? Color(hex: 0x8E8E93) : Color(hex: 0x737373) }
    private var line: Color { scheme == .dark ? Color(white: 1, opacity: 0.09) : Color(hex: 0xE6E6E6) }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("实名认证"), back: { dismiss() })

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 10)

                    if let i = info, i.verified {
                        verifiedCard(i)
                    } else {
                        formCard
                    }

                    Color.clear.frame(height: 10)
                    noteCard
                    Color.clear.frame(height: 26)
                }
            }
            .background(pageBg)
        }
        .background(pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task {
            info = await API.shared.realNameStatus()
            if let i = info, !i.verified { name = app.me?.name ?? "" }
        }
    }

    /* ---------------------------------------------------- 已经实名了 */
    private func verifiedCard(_ i: API.RealNameInfo) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 40))
                    .foregroundColor(Color(hexString: "#19A47A"))
                Text(Tr("已实名认证"))
                    .font(pf(17, .medium))
                    .foregroundColor(ink)
            }
            .padding(.vertical, 22)

            HairLine(inset: 16)
            row(Tr("姓名"), i.realName)
            HairLine(inset: 16)
            row(Tr("身份证号"), i.idMask)
            if !i.at.isEmpty {
                HairLine(inset: 16)
                row(Tr("认证时间"), i.at.prefix(10).description)
            }
            /* 已经实名过的人也要能用「人脸核身」那一页（用户反馈：实名过了就看不到了）。
               点一下进刷脸页（正对屏幕 → 眨眨眼 → 摇摇头），试一次/重新录一次都行；
               这里不再重复提交实名，只记一条结果。 */
            HairLine(inset: 16)
            Button { showFace = true } label: {
                HStack(spacing: 12) {
                    Text(Tr("人脸核身")).font(pf(16)).foregroundColor(C.label)
                    Spacer(minLength: 8)
                    Text(faceOK ? Tr("已通过") : Tr("去验证"))
                        .font(pf(14)).foregroundColor(C.subLabel)
                    Chevron(size: 9, line: 1.6)
                }
                .padding(.horizontal, 16).frame(height: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(sheetBg)
    }

    /* ---------------------------------------------------- 还没实名：填表 */
    private var formCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(Tr("姓名"))
                    .font(pf(16))
                    .foregroundColor(ink)
                    .frame(width: 72, alignment: .leading)
                TextField(Tr("请填写真实姓名"), text: $name)
                    .font(pf(16))
                    .foregroundColor(ink)
                    .focused($focus, equals: .name)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .background(sheetBg)

            HairLine(inset: 16)

            HStack(spacing: 10) {
                Text(Tr("身份证号"))
                    .font(pf(16))
                    .foregroundColor(ink)
                    .frame(width: 72, alignment: .leading)
                TextField(Tr("18 位身份证号"), text: $idCard)
                    .font(pf(16))
                    .foregroundColor(ink)
                    .focused($focus, equals: .id)
                    .keyboardType(.asciiCapable)
                    .autocorrectionDisabled()
                    .autocapitalization(.allCharacters)
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .background(sheetBg)

            if !error.isEmpty {
                Text(error)
                    .font(pf(13))
                    .foregroundColor(Color(hexString: "#FA5151"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(sheetBg)
            }

            Button {
                /* 微信的规矩：提交实名之前先刷一次脸（人脸核身）。
                   这里是真的开摄像头做活体（正对屏幕 → 眨眨眼 → 摇摇头），过了才允许提交。
                   管理页有开关（ui.json 的 realnameFace）：判定不准的时候可以关掉，
                   关掉后直接提交，不挡用户。 */
                if UIConfig.num("realnameFace", 1) > 0 {
                    showFace = true
                } else {
                    faceOK = true
                    submit()
                }
            } label: {
                Text(busy ? Tr("提交中…")
                          : ((faceOK || UIConfig.num("realnameFace", 1) <= 0)
                             ? Tr("提交认证") : Tr("开始人脸验证")))
                    .font(pf(17, .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(canSubmit ? C.green : Color.dyn(0xC8C8C8, 0x4A4A4A)))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit || busy)
            .padding(16)
            .background(sheetBg)
            .sheet(isPresented: $showFace) {
                /* 两页流程（照微信）：先准备页说明，点「开始识别」才进摄像头那页 */
                FaceVerifyFlowView { ok in
                    showFace = false
                    if ok {
                        faceOK = true
                        DiagLog.shared.note("实名认证：人脸核身通过")
                        /* 2026-10-15 用户：「人脸给后台做个比对口」「不要让 ai 图像过，要真实对比」——
                           核身这一帧 + 姓名/身份证号一起传上去，后台**人工比对**（通过 / 驳回），
                           结论写在用户身上（安全分那页看得到）。 */
                        let shot = FaceLiveness.shared.shot ?? ""
                        let n = name, ic = idCard
                        Task {
                            /* 顺手和账号头像比一下（Apple 原生特征指纹，只在手机上算）：
                               给后台一个人工比对的参考分 */
                            var dist: Double? = nil
                            if !shot.isEmpty, let av = app.me?.avatarPath, !av.isEmpty,
                               let u = API.shared.assetURL(av), let d = try? await API.shared.assetData(u) {
                                dist = await FaceMatch.distance(shot: shot, avatar: d)
                            }
                            let up = await API.shared.faceSubmit(image: shot, name: n, idCard: ic, dist: dist)
                            if up {
                                app.show(Tr("已传后台做人脸比对；结果在「我 → 设置 → 安全分」里看"))
                            }
                        }
                        /* 还没实名的：核身过了就提交；已实名的：只提示一下（不重复提交） */
                        if info?.verified == true {
                            app.show(Tr("人脸核身通过 ✅"))
                        } else {
                            submit()
                        }
                    } else {
                        app.show(Tr("人脸验证没通过，可以重来一次"))
                    }
                }
                .environmentObject(app)
            }
        }
    }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && idCard.count >= 15
    }

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Tr("为什么要实名"))
                .font(pf(15, .medium))
                .foregroundColor(ink)
            bullet(Tr("实名后安全分的「身份特质」加 30 分"))
            bullet(Tr("转账、收付款更可信；被封号也能用这张身份证自助解封"))
            bullet(Tr("身份证号只在本机服务器上存密文，界面只显示前 6 位和后 4 位"))
            bullet(Tr("一张身份证只能绑一个账号，认证后不能自己改"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(sheetBg)
    }

    private func bullet(_ t: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(C.green).frame(width: 5, height: 5).padding(.top, 6)
            Text(t).font(pf(13.5)).foregroundColor(gray)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(pf(16)).foregroundColor(ink)
            Spacer(minLength: 0)
            Text(v).font(pf(16)).foregroundColor(gray)
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
    }

    private func submit() {
        error = ""
        focus = nil
        busy = true
        Task {
            do {
                let r = try await API.shared.submitRealName(name: name.trimmingCharacters(in: .whitespaces),
                                                            idCard: idCard.trimmingCharacters(in: .whitespaces))
                info = r
                app.me = try? await API.shared.me()
                app.show(Tr("实名认证通过 ✅"))
            } catch {
                self.error = (error as? APIError)?.errorDescription ?? "认证失败，检查一下再试"
            }
            busy = false
        }
    }
}
