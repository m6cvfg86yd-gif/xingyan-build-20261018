import SwiftUI

/* ============================================================
   个人信息（重做的高级的版）
   · 顶部一张深色金边卡：大头像（金圈、右下角小相机）、昵称 + 等级图标、星言号 + 二维码
   · 下面三张圆角卡片：资料（昵称/性别/地区/生日/签名）、联系方式（手机号）、来电铃声
   · 右上「保存」做成绿色渐变胶囊
   逻辑和旧版一模一样（点保存提交、头像先裁再传），只是界面换了。
   ============================================================ */
struct ProfileEditView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var growth = GrowthStore.shared

    @State private var nickname = ""
    @ObservedObject private var ring = Ringtone.shared
    @State private var showRingtone = false
    @State private var bio = ""
    @State private var region = ""
    @State private var gender = "male"
    @State private var phone = ""
    @State private var birthday = ""
    @State private var showBirthday = false
    @State private var showRegion = false
    /// 性别选一下（微信那样：点"性别"那一行弹出来选）
    @State private var showGender = false
    @State private var showPhone = false
    @State private var showPhoto = false
    @State private var busy = false
    @State private var cropImage: UIImage?
    /// 拍一拍后缀（微信：我 → 个人资料 → 拍一拍 →「朋友拍了拍我的＿＿」）
    @State private var patText = ""
    @State private var showMyQR = false
    /// 改星言号（2026-10-16 用户：注册不设、随机给；一年能改一次）
    @State private var showUsername = false
    /// 服务器那份资料**填过一次**就不再覆盖用户正在改的内容
    /// （用户报的「换了地区和生日不立马显示」：从「选地区 / 选生日」子页返回时
    ///  onAppear 又跑了一遍，拿**还没更新的** app.me 把刚选好的值顶回旧值）
    @State private var filledProfile = false

    private let gold = Color(hex: 0xF0C24B)

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("个人信息"), back: { dismiss() }) {
                Button { save() } label: {
                    Text(busy ? Tr("保存中…") : Tr("保存"))
                        .font(pf(14.5, .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 15)
                        .frame(height: 32)
                        .background(
                            Capsule().fill(busy
                                ? AnyShapeStyle(Color.dyn(0xEDEDED, 0x2C2C2E))
                                : AnyShapeStyle(LinearGradient(colors: [C.green, C.green.opacity(0.78)],
                                                               startPoint: .topLeading, endPoint: .bottomTrailing)))
                        )
                        .padding(.trailing, 14)
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }

            ScrollView(showsIndicators: false) {
                /* 和微信同款：**就一张列表**从头到尾 ——
                   头像 / 昵称 / 性别 / 地区 / 生日 / 拍一拍 / 个性签名 / 手机号 / 来电铃声。
                   以前是「大头像卡 + 资料卡 + 联系方式卡 + 铃声卡 + 一行说明」，
                   看着啰嗦，现在合成一张，行和行之间就是一条细线。 */
                VStack(spacing: 0) {
                    avatarRow
                    divider
                    field(Tr("昵称"), $nickname)
                    divider
                    /* 星言号：微信那样 —— 注册时系统随机给一个，这里一年能改一次（服务端拦） */
                    Button { showUsername = true } label: {
                        linkLabel(Tr("星言号"),
                                  (app.me?.username?.isEmpty == false) ? (app.me?.username ?? "—") : "—")
                    }.buttonStyle(.plain)
                    divider
                    tapRow(Tr("性别"), gender == "female" ? Tr("女") : Tr("男")) { showGender = true }
                    divider
                    /* 地区 / 生日 / 手机号 / 来电铃声 / 二维码：**整页 push**（不再是半屏 sheet）。
                       ⚠ 这里**不能**用 `NavigationLink { 目标 }`（destination 版）：
                       外层「我」页那条栈是 NavigationPath + navigationDestination(for: String)，
                       两种写法混在一个栈里会让后面的 value 版链接全失效
                       （用户反馈的「设置里面的页面进不去」就是这个）。
                       全站统一用 navigationDestination(isPresented:)（见下面那几条）。 */
                    Button { showRegion = true } label: {
                        linkLabel(Tr("地区"), region.isEmpty ? Tr("未设置") : region)
                    }.buttonStyle(.plain)
                    divider
                    Button { showBirthday = true } label: {
                        linkLabel(Tr("生日"), birthday.isEmpty ? Tr("未设置") : birthday)
                    }.buttonStyle(.plain)
                    divider
                    patRow
                    divider
                    field(Tr("个性签名"), $bio)
                    divider
                    Button { showPhone = true } label: {
                        linkLabel(Tr("手机号"), phone.isEmpty ? Tr("未绑定") : maskPhone(phone))
                    }.buttonStyle(.plain)
                    divider
                    Button { showRingtone = true } label: {
                        linkLabel(Tr("来电铃声"), ring.currentName)
                    }.buttonStyle(.plain)
                }
                /* 用户要求：**关掉玻璃** —— 就一块实色卡片（跟会话页一个底色），
                   不画磨砂、不画亮边。想找回玻璃：把下面这行换成
                   `.background { CardGlassBox(radius: 14) }` 即可。 */
                .background(C.cardBg)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 30)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .onAppear { fillFromMe() }
        /* app.me 晚到（进页面时才拉回来）：补填一次 */
        .onChange(of: app.me?.id) { _ in fillFromMe() }
        .sheet(isPresented: $showPhoto) { PhotoPicker { image in cropImage = image } }
        .sheet(isPresented: Binding(get: { cropImage != nil },
                                    set: { if !$0 { cropImage = nil } })) {
            if let img = cropImage {
                AvatarCropSheet(image: img) { cropped in
                    changeAvatar(cropped)
                    cropImage = nil
                }
            }
        }
        /* 地区 / 生日 / 手机号 / 来电铃声 / 二维码：整页 push（和全站一样用 isPresented 版），
           不再是 sheet，也不跟外层的 value 版链接混用。 */
        .navigationDestination(isPresented: $showRegion) {
            RegionPickerSheet { r in region = r }
        }
        .navigationDestination(isPresented: $showBirthday) {
            BirthdayPickerSheet(birthday: $birthday)
        }
        .navigationDestination(isPresented: $showPhone) {
            PhoneChangeSheet().environmentObject(app)
        }
        .navigationDestination(isPresented: $showRingtone) {
            RingtonePicker()
        }
        .navigationDestination(isPresented: $showMyQR) {
            MyQRView()
        }
        .navigationDestination(isPresented: $showUsername) {
            UsernameChangeSheet().environmentObject(app)
        }
        /* 性别：微信那样点一行弹出来选（不是行里的分段控件） */
        .confirmationDialog(Tr("性别"), isPresented: $showGender, titleVisibility: .visible) {
            Button(Tr("男")) { gender = "male"; saveNow(["gender": "male"]) }
            Button(Tr("女")) { gender = "female"; saveNow(["gender": "female"]) }
            Button(Tr("取消"), role: .cancel) { }
        }
        /* 地区 / 生日选完**立刻生效**（不用再回去按右上角那个保存）——
           用户反馈的「设置了地区和生日都没显示生效」就是这个：
           以前选完只是改了本地那行字，不点保存什么都没存 */
        .onChange(of: region) { v in
            if v != (app.me?.region ?? "") { saveNow(["region": v]) }
        }
        .onChange(of: birthday) { v in
            if v != (app.me?.birthday ?? "") { saveNow(["birthday": v]) }
        }
    }

    /// 把服务器那份资料填进页面（只在还没填过 / app.me 刚拉回来时填一次）
    private func fillFromMe() {
        guard let me = app.me, !filledProfile else { return }
        filledProfile = true
        nickname = me.nickname ?? ""
        bio = me.bio ?? ""
        region = me.region ?? ""
        gender = me.gender == "female" ? "female" : "male"
        phone = me.phone ?? ""
        birthday = me.birthday ?? ""
        patText = me.patText ?? ""
    }

    /// 选完就存（地区 / 生日 / 性别）：存完立刻把 app.me 刷一遍，页面上那行字跟着变
    private func saveNow(_ fields: [String: Any]) {
        Task {
            do {
                try await API.shared.updateMeChecked(fields)
                if let me = try? await API.shared.me() {
                    app.me = me
                    /* 服务器那份回来了：把页面上这几行**跟着对齐** ——
                       以前只刷 app.me，页面上留的还是刚才那个字（或者被
                       onAppear 顶回旧值），看着就像「没生效」 */
                    filledProfile = true
                    if let v = me.region { region = v }
                    if let v = me.birthday { birthday = v }
                    if let v = me.gender { gender = v == "female" ? "female" : "male" }
                    nickname = me.nickname ?? nickname
                    bio = me.bio ?? bio
                    patText = me.patText ?? patText
                    if let v = me.phone { phone = v }
                }
            } catch {
                app.show(error.localizedDescription)
            }
        }
    }

    /* ---------------------------------------------------------- 顶部：头像 + 昵称 + 星言号 */

    private var headerCard: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Button { showPhoto = true } label: {
                    Avatar(path: app.me?.avatarPath ?? "", size: 84, radius: 42, circle: true, level: growth.shownLevel)
                        .overlay(Circle().stroke(gold.opacity(0.9), lineWidth: 1.6))
                        .shadow(color: Color.black.opacity(0.35), radius: 10, y: 4)
                }
                .buttonStyle(.plain)
                Button { showPhoto = true } label: {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 27, height: 27)
                        .background(Circle().fill(LinearGradient(colors: [C.green, C.green.opacity(0.78)],
                                                                 startPoint: .topLeading, endPoint: .bottomTrailing)))
                        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.2))
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 6) {
                Text(app.me?.name ?? "")
                    .font(pf(19, .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if growth.shownLevel > 0 {
                    QQLevelBadge(level: growth.shownLevel, size: 14, maxIcons: 3).fixedSize()
                }
            }
            HStack(spacing: 10) {
                Text(Tr("星言号") + "：" + (app.me?.username ?? "-"))
                    .font(pf(13))
                    .foregroundColor(.white.opacity(0.62))
                    .lineLimit(1)
                /* 二维码：整页 push（同样用 isPresented 版，别用 destination 版） */
                Button { showMyQR = true } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "qrcode").font(.system(size: 11, weight: .semibold))
                        Text(Tr("二维码")).font(pf(12))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.16)))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 16)
        .background(
            ZStack {
                LinearGradient(colors: [Color(hex: 0x1C2130), Color(hex: 0x2B2233), Color(hex: 0x14111A)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [gold.opacity(0.22), Color.clear],
                               center: .topTrailing, startRadius: 2, endRadius: 220)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    /* ---------------------------------------------------------- 资料 */

    private var infoCard: some View {
        VStack(spacing: 0) {
            field(Tr("昵称"), $nickname)
            HStack(spacing: 8) {
                Text(Tr("最多 16 个字符；不能用 < > \" ' / \\ 等符号，不能冒用官方或客服"))
                    .font(pf(11.5))
                    .foregroundColor(C.subLabel)
                Spacer(minLength: 0)
                Text("\(nickname.count)/16")
                    .font(pf(11.5))
                    .foregroundColor(nickname.count > 16 ? C.red : C.subLabel)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            divider
            /* 微信的格局：性别也是**一行**（左边"性别"、右边值、右箭头），点开再选 ——
               不是嵌在行里的分段控件。 */
            tapRow(Tr("性别"), gender == "female" ? Tr("女") : Tr("男")) { showGender = true }
            divider
            tapRow(Tr("地区"), region.isEmpty ? Tr("未设置") : region) { showRegion = true }
            divider
            tapRow(Tr("生日"), birthday.isEmpty ? Tr("未设置") : birthday) { showBirthday = true }
            divider
            field(Tr("个性签名"), $bio)
            divider
            /* 拍一拍：微信那一句「朋友拍了拍我的 ＿＿」——
               **就在这一页改**，不弹层、不给输入框（和昵称、签名一个样式）。 */
            HStack(spacing: 8) {
                Text(Tr("拍一拍"))
                    .font(pf(16)).foregroundColor(C.label)
                    .frame(width: 70, alignment: .leading)
                /* 2026-10-17 用户：「朋友拍了拍我的字靠后去 / 没有和其他字对齐」——
                   以前这一行把「朋友拍了拍我的」直接跟在标签后面（落在中间），
                   可上下几行（性别/地区/生日/星言号）的值全是**靠右**的，看着就散。
                   现在先 Spacer 把它顶到右边，和后缀一起贴着右边排 —— 整页一个竖列。 */
                Spacer(minLength: 8)
                Text(Tr("朋友拍了拍我的"))
                    .font(pf(15)).foregroundColor(C.subLabel).fixedSize()
                TextField(Tr("填一个后缀"), text: $patText)
                    .font(pf(16)).foregroundColor(C.label)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 120)
                    .onChange(of: patText) { v in
                        if v.count > 10 { patText = String(v.prefix(10)) }   // 最多 10 个字
                    }
            }
            .padding(.horizontal, 14)
            .frame(height: 56)
            HStack(spacing: 8) {
                Text(Tr("最多 10 个字；留空就是「拍了拍我」"))
                    .font(pf(11.5)).foregroundColor(C.subLabel)
                Spacer(minLength: 0)
                Text("\(patText.count)/10")
                    .font(pf(11.5)).foregroundColor(patText.count >= 10 ? C.red : C.subLabel)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .background { CardGlassBox(radius: 14) }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(C.hairline, lineWidth: 0.6))
    }

    private var contactCard: some View {
        VStack(spacing: 0) {
            Button { showPhone = true } label: {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(LinearGradient(colors: [C.green, C.green.opacity(0.78)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 30, height: 30)
                        Image(systemName: "iphone")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    Text(Tr("手机号")).font(pf(16)).foregroundColor(C.label)
                    Spacer(minLength: 8)
                    Text(phone.isEmpty ? Tr("未绑定") : maskPhone(phone))
                        .font(pf(15))
                        .foregroundColor(C.subLabel)
                    Chevron(size: 8, line: 1.5)
                }
                .padding(.horizontal, 14)
                .frame(height: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background { CardGlassBox(radius: 14) }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(C.hairline, lineWidth: 0.6))
    }

    private var ringCard: some View {
        Button { showRingtone = true } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: [Color(hex: 0xB98CFF), Color(hex: 0x7A45D6)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 30, height: 30)
                    Image(systemName: "music.note")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(Tr("来电铃声")).font(pf(16)).foregroundColor(C.label)
                    Text(ring.currentName).font(pf(12)).foregroundColor(C.subLabel)
                }
                Spacer(minLength: 0)
                Chevron(size: 8, line: 1.5)
            }
            .padding(.horizontal, 14)
            .frame(height: 60)
            .background { CardGlassBox(radius: 14) }
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(C.hairline, lineWidth: 0.6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /* ---------------------------------------------------------- 零件 */

    /* ---------------------------------------------------------- 微信同款那几行 */

    /// 头像那一行（微信：左边「头像」，右边一个小头像 + ›）—— 点一下换头像
    private var avatarRow: some View {
        Button { showPhoto = true } label: {
            HStack(spacing: 12) {
                Text(Tr("头像")).font(pf(16)).foregroundColor(C.label)
                Spacer(minLength: 8)
                Avatar(path: app.me?.avatarPath ?? "", size: 48, radius: 6,
                       circle: false, level: growth.shownLevel)
                Chevron(size: 8, line: 1.5)
            }
            .padding(.horizontal, 14)
            .frame(height: 72)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 拍一拍那一行：微信那句「朋友拍了拍我的 ＿＿」，**在本页直接改**（不弹层）
    private var patRow: some View {
        HStack(spacing: 8) {
            Text(Tr("拍一拍")).font(pf(16)).foregroundColor(C.label)
                .frame(width: 70, alignment: .leading)
            Text(Tr("朋友拍了拍我的")).font(pf(15)).foregroundColor(C.subLabel).fixedSize()
            TextField(Tr("后缀"), text: $patText)
                .font(pf(16)).foregroundColor(C.label)
                .onChange(of: patText) { v in
                    if v.count > 10 { patText = String(v.prefix(10)) }   // 最多 10 个字
                }
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
    }

    private var phoneRow: some View {
        Button { showPhone = true } label: {
            HStack(spacing: 12) {
                Text(Tr("手机号")).font(pf(16)).foregroundColor(C.label)
                Spacer(minLength: 8)
                Text(phone.isEmpty ? Tr("未绑定") : maskPhone(phone))
                    .font(pf(15)).foregroundColor(C.subLabel)
                Chevron(size: 8, line: 1.5)
            }
            .padding(.horizontal, 14)
            .frame(height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var ringRow: some View {
        Button { showRingtone = true } label: {
            HStack(spacing: 12) {
                Text(Tr("来电铃声")).font(pf(16)).foregroundColor(C.label)
                Spacer(minLength: 8)
                Text(ring.currentName).font(pf(15)).foregroundColor(C.subLabel).lineLimit(1)
                Chevron(size: 8, line: 1.5)
            }
            .padding(.horizontal, 14)
            .frame(height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var divider: some View { HairLine(inset: 14) }

    private func field(_ title: String, _ text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(title).font(pf(16)).foregroundColor(C.label).frame(width: 70, alignment: .leading)
            TextField("", text: text)
                .font(pf(16))
                .foregroundColor(C.label)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
    }

    private func tapRow(_ title: String, _ value: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                Text(title).font(pf(16)).foregroundColor(C.label)
                Spacer(minLength: 8)
                Text(value).font(pf(15)).foregroundColor(C.subLabel).lineLimit(1)
                Chevron(size: 8, line: 1.5)
            }
            .padding(.horizontal, 14)
            .frame(height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// NavigationLink 用的那一行（长得和 tapRow 一样，但点进去是下一个整页）
    private func linkLabel(_ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(title).font(pf(16)).foregroundColor(C.label)
            Spacer(minLength: 8)
            Text(value).font(pf(15)).foregroundColor(C.subLabel).lineLimit(1)
            Chevron(size: 8, line: 1.5)
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .contentShape(Rectangle())
    }

    /* ---------------------------------------------------------- 干活（和旧版一致） */

    private func changeAvatar(_ image: UIImage) {
        busy = true
        Task {
            if let url = try? await API.shared.upload(image: image) {
                await API.shared.updateMe(["avatar": url])
                app.me = try? await API.shared.me()
                app.show(Tr("头像换好了"))
            } else {
                app.show(Tr("头像上传失败，再试一次"))
            }
            busy = false
        }
    }

    private func save() {
        busy = true
        Task {
            var fields: [String: Any] = [
                "nickname": nickname,
                "bio": bio,
                "region": region,
                "gender": gender,
                "birthday": birthday,
                /* 拍一拍后缀：在资料页里直接改，保存时一起提交 */
                "patText": patText
            ]
            if !phone.isEmpty && phone != (app.me?.phone ?? "") { fields["phone"] = phone }
            do {
                try await API.shared.updateMeChecked(fields)
            } catch {
                /* 服务器说不行（昵称不合格 / 手机号一年只能改一次…）—— 直接说出来，
                   别再吞掉然后提示"已保存" */
                busy = false
                app.show(error.localizedDescription)
                return
            }
            app.me = try? await API.shared.me()
            await app.loadContacts()
            busy = false
            app.show(Tr("已保存"))
            dismiss()
        }
    }
}

/* ============================================================
   改「星言号」（2026-10-16 用户：「注册不要星言号设置，按微信那样给随机的」+
   「然后可以 1 年改一次」）

   · 注册时不再让用户填，服务端随机给一个（xy 开头 10 位）
   · 这里改：**一年只能改一次**，规则由服务端兜（`PATCH /api/me` 的 username 那条），
     改早了服务端会把「下次可改：XXXX年X月X日」原话带回来，这里直接显示
   ============================================================ */
struct UsernameChangeSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var busy = false
    @State private var err = ""

    /// 下一次能改的时间（服务端给的 usernameUpdatedAt + 365 天）
    private var nextChangeText: String {
        guard let s = app.me?.usernameUpdatedAt, !s.isEmpty else { return "" }
        var t = ISO8601DateFormatter().date(from: s)
        if t == nil {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
            t = f.date(from: s)
        }
        guard let t else { return "" }
        let can = t.addingTimeInterval(365 * 24 * 60 * 60)
        if can <= Date() { return "" }          // 已经能改了
        let f = DateFormatter()
        f.dateFormat = "yyyy年M月d日"
        return "下次可改：" + f.string(from: can)
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("星言号"), back: { dismiss() }) {
                Button { save() } label: {
                    Text(busy ? Tr("保存中…") : Tr("保存"))
                        .font(pf(15, .medium))
                        .foregroundColor(name.isEmpty || busy ? C.subLabel : C.green)
                        .frame(height: L.navH)
                        .padding(.trailing, 16)
                }
                .buttonStyle(.plain)
                .disabled(name.isEmpty || busy)
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Text(Tr("星言号")).font(pf(16)).foregroundColor(C.label)
                        TextField("", text: $name)
                            .font(pf(16))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .multilineTextAlignment(.trailing)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 54)
                    HairLine(inset: 16)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Tr("3-24 位字母、数字或下划线；一年只能改一次。"))
                            .font(pf(12.5)).foregroundColor(C.subLabel)
                        if !nextChangeText.isEmpty {
                            Text(nextChangeText).font(pf(12.5)).foregroundColor(C.subLabel)
                        }
                        if !err.isEmpty {
                            Text(err).font(pf(12.5)).foregroundColor(C.red)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
                .background(C.cardBg)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 14)
                .padding(.top, 12)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .onAppear { name = app.me?.username ?? "" }
    }

    private func save() {
        let want = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard want != (app.me?.username ?? "") else { dismiss(); return }
        busy = true
        err = ""
        Task {
            do {
                try await API.shared.updateMeChecked(["username": want])
                app.me = try? await API.shared.me()
                busy = false
                app.show(Tr("星言号已更新"))
                dismiss()
            } catch {
                busy = false
                err = (error as? LocalizedError)?.errorDescription ?? "改不了，稍后再试"
            }
        }
    }
}


