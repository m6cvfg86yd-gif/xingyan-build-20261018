import SwiftUI

/* ============================================================ 个人信息 */

/* 旧的个人信息页（灰底列表那版）：已经被 ProfileEditNew.swift 里的新版替换，
   留着是因为这里的 field / save / changeAvatar 逻辑还能对照，界面上不再用它。 */
struct ProfileEditViewOld: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

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
    @State private var showPhone = false
    @State private var showPhoto = false
    @State private var busy = false
    @State private var cropImage: UIImage?
    @State private var showMyQR = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("个人信息"), back: { dismiss() }) {
                Button {
                    save()
                } label: {
                    Text(busy ? "保存中…" : "保存")
                        .font(pf(17))
                        .foregroundColor(C.green)
                        .frame(height: L.navH)
                        .padding(.trailing, 16)
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                VStack(spacing: 0) {
                    GroupCard {
                        Button {
                            showPhoto = true
                        } label: {
                            HStack(spacing: 12) {
                                Text(Tr("头像")).font(pf(17)).foregroundColor(C.label)
                                Spacer()
                                Avatar(path: app.me?.avatarPath ?? "", size: 56, radius: 6)
                                Chevron(size: 9, line: 1.6).padding(.trailing, 3)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 72)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        HairLine(inset: 16)
                        field("昵称", $nickname)
                        /* 昵称规范（和微信一致）：≤16 个字符、不能用 < > " ' / \ 这类符号、不能冒用官方/客服 */
                        HStack(spacing: 8) {
                            Text(Tr("最多 16 个字符；不能用 < > \" ' / \\ 等符号，不能冒用官方或客服"))
                                .font(pf(12)).foregroundColor(C.subLabel)
                            Spacer(minLength: 0)
                            Text("\(nickname.count)/16")
                                .font(pf(12)).foregroundColor(nickname.count > 16 ? C.red : C.subLabel)
                        }
                        .padding(.horizontal, 16).padding(.bottom, 10)
                        HairLine(inset: 16)
                        /* 星言号（只读）+ 我的二维码：和微信一样排在这一屏最上面 */
                        HStack(spacing: 12) {
                            Text(Tr("星言号")).font(pf(17)).foregroundColor(C.label)
                                .frame(width: 76, alignment: .leading)
                            Text(app.me?.username ?? "-")
                                .font(pf(17))
                                .foregroundColor(C.subLabel)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 56)
                    }

                    Rectangle().fill(C.pageBg).frame(height: 8)

                    GroupCard {
                        HStack(spacing: 12) {
                            Text(Tr("性别")).font(pf(17)).foregroundColor(C.label)
                            Spacer()
                            Picker("", selection: $gender) {
                                Text(Tr("男")).tag("male")
                                Text(Tr("女")).tag("female")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 140)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 56)
                        HairLine(inset: 16)
                        /* 地区：和微信一样点开是两个滚轮（省 / 市），不再让人手打 */
                        Button {
                            showRegion = true
                        } label: {
                            HStack(spacing: 12) {
                                Text(Tr("地区")).font(pf(17)).foregroundColor(C.label)
                                Spacer()
                                Text(region.isEmpty ? Tr("未设置") : region)
                                    .font(pf(15)).foregroundColor(C.subLabel)
                                Chevron(size: 9, line: 1.6).padding(.trailing, 3)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 56)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        HairLine(inset: 16)
                        /* 生日（对应功能清单里的「生日」）：点一下弹出日期选择 */
                        Button {
                            showBirthday = true
                        } label: {
                            HStack(spacing: 12) {
                                Text(Tr("生日")).font(pf(17)).foregroundColor(C.label)
                                Spacer()
                                Text(birthday.isEmpty ? "未设置" : birthday)
                                    .font(pf(15))
                                    .foregroundColor(C.subLabel)
                                Chevron(size: 9, line: 1.6).padding(.trailing, 3)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 56)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        HairLine(inset: 16)
                        field("个性签名", $bio)
                    }

                    Rectangle().fill(C.pageBg).frame(height: 8)

                    GroupCard {
                        /* 手机号在个人信息里只看不改、中间打码（微信也是「138****8888」），
                           改号去「设置 → 账号与安全」 */
                        Button {
                            showPhone = true
                        } label: {
                            HStack(spacing: 12) {
                                Text(Tr("手机号"))
                                    .font(pf(17)).foregroundColor(C.label)
                                    .frame(width: 76, alignment: .leading)
                                Spacer(minLength: 0)
                                Text(phone.isEmpty ? Tr("未绑定") : maskPhone(phone))
                                    .font(pf(17)).foregroundColor(C.subLabel)
                                Chevron(size: 9, line: 1.6).padding(.trailing, 3)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 56)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    GroupCard {
                        Button {
                            showRingtone = true
                        } label: {
                            HStack(spacing: 12) {
                                Text(Tr("来电铃声")).font(pf(17)).foregroundColor(C.label)
                                Spacer()
                                Text(ring.currentName)
                                    .font(pf(15))
                                    .foregroundColor(C.subLabel)
                                Chevron(size: 9, line: 1.6).padding(.trailing, 3)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 56)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    Text(Tr("手机号一年只能改一次；头像、昵称、地区、签名想改就改。"))
                        .font(pf(12.5))
                        .foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.top, 10)

                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .onAppear {
            nickname = app.me?.nickname ?? ""
            bio = app.me?.bio ?? ""
            region = app.me?.region ?? ""
            gender = app.me?.gender == "female" ? "female" : "male"
            phone = app.me?.phone ?? ""
            birthday = app.me?.birthday ?? ""
        }
        .sheet(isPresented: $showPhoto) {
            /* 先裁成正方形再上传（对应功能清单里的「头像裁剪」） */
            PhotoPicker { image in cropImage = image }
        }
        .sheet(isPresented: Binding(get: { cropImage != nil },
                                    set: { if !$0 { cropImage = nil } })) {
            if let img = cropImage {
                AvatarCropSheet(image: img) { cropped in
                    changeAvatar(cropped)
                    cropImage = nil
                }
            }
        }
        .sheet(isPresented: $showRingtone) {
            RingtonePicker()
        }
        .sheet(isPresented: $showBirthday) {
            BirthdayPickerSheet(birthday: $birthday)
        }
        .sheet(isPresented: $showRegion) {
            RegionPickerSheet { r in region = r }
        }
        .sheet(isPresented: $showPhone) {
            PhoneChangeSheet().environmentObject(app)
        }
        .sheet(isPresented: $showMyQR) { MyQRView() }
        /* 地区 / 生日选完立刻生效（不用再按保存）—— 见 ProfileEditNew 里同一段说明 */
        .onChange(of: region) { v in
            if v != (app.me?.region ?? "") { saveNow(["region": v]) }
        }
        .onChange(of: birthday) { v in
            if v != (app.me?.birthday ?? "") { saveNow(["birthday": v]) }
        }
    }

    private func field(_ title: String, _ text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(title).font(pf(17)).foregroundColor(C.label).frame(width: 76, alignment: .leading)
            TextField("", text: text)
                .font(pf(17))
                .foregroundColor(C.label)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    private func changeAvatar(_ image: UIImage) {
        busy = true
        Task {
            if let url = try? await API.shared.upload(image: image) {
                await API.shared.updateMe(["avatar": url])
                app.me = try? await API.shared.me()
                app.show(Tr("头像换好了"))
            }
            busy = false
        }
    }

    /// 选完就存（地区 / 生日）：存完把 app.me 刷一遍，页面那行字跟着变
    private func saveNow(_ fields: [String: Any]) {
        Task {
            do {
                try await API.shared.updateMeChecked(fields)
                app.me = try? await API.shared.me()
            } catch {
                app.show(error.localizedDescription)
            }
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
                "birthday": birthday
            ]
            if !phone.isEmpty && phone != (app.me?.phone ?? "") { fields["phone"] = phone }
            do {
                try await API.shared.updateMeChecked(fields)
            } catch {
                /* 服务器的报错别再吞掉（吞掉就会变成"保存了但没生效"） */
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

/* ============================================================ 新的朋友（照微信那套）
   微信这一页的样子：
     · 顶上一个搜索框（搜的是申请记录）
     · 第一行「添加朋友」，点进去是添加朋友页
     · 好友申请：头像 + 昵称 + 对方写的那句验证消息（「我是XXX」）+ 接受 / 拒绝
     · 已添加：刚通过的那几个人留着显示「已添加」（服务器留 3 天）
     · 我添加的：我发出去的申请，右边「等待验证」
   验证消息是服务器 friendships.json 里的 note 字段，通过 /api/contacts 带回来。*/

struct NewFriendsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var realtime = Realtime.shared

    @State private var incoming: [User] = []
    @State private var outgoing: [User] = []
    @State private var added: [User] = []
    @State private var loading = true
    @State private var keyword = ""
    @State private var busy: Set<String> = []

    private func hit(_ u: User) -> Bool {
        if keyword.isEmpty { return true }
        return u.name.contains(keyword)
            || (u.username ?? "").contains(keyword)
            || (u.requestMessage ?? "").contains(keyword)
    }
    private var shownIncoming: [User] { incoming.filter(hit) }
    private var shownOutgoing: [User] { outgoing.filter(hit) }
    private var shownAdded: [User] { added.filter(hit) }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("新的朋友"), back: { dismiss() })
            SearchBoxCenter(text: $keyword).padding(L.searchPad)
                .background(C.pageBg)

            ScrollView {
                LazyVStack(spacing: 0) {
                    NavigationLink(value: "addFriend") { addFriendRow }
                        .buttonStyle(MenuPressStyle())

                    if loading && incoming.isEmpty && outgoing.isEmpty && added.isEmpty {
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .frame(height: 76).background(C.cardBg)
                    } else if !loading && shownIncoming.isEmpty && shownOutgoing.isEmpty && shownAdded.isEmpty {
                        Text(Tr("还没有好友申请"))
                            .font(pf(15))
                            .foregroundColor(C.subLabel)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 36)
                            .background(C.cardBg)
                    }

                    if !shownIncoming.isEmpty {
                        sectionHeader(Tr("好友申请"))
                        ForEach(shownIncoming) { user in
                            VStack(spacing: 0) {
                                HairLine(inset: 68)
                                requestRow(user)
                            }
                            .background(C.cardBg)
                        }
                    }
                    if !shownAdded.isEmpty {
                        sectionHeader(Tr("已添加"))
                        ForEach(shownAdded) { user in
                            VStack(spacing: 0) {
                                HairLine(inset: 68)
                                doneRow(user)
                            }
                            .background(C.cardBg)
                        }
                    }
                    if !shownOutgoing.isEmpty {
                        sectionHeader(Tr("我添加的"))
                        ForEach(shownOutgoing) { user in
                            VStack(spacing: 0) {
                                HairLine(inset: 68)
                                waitingRow(user)
                            }
                            .background(C.cardBg)
                        }
                    }
                }
                .padding(.bottom, 30)
            }
            .refreshable { await load() }
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task {
            await load()
            /* 1 秒对一次账：对方同意/拒绝以后，这一页自己就变（不用退出去再进来） */
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                await load()
            }
        }
        /* 对方通过我的申请 / 又有人加我 → 这一页自己刷新，不用手动下拉 */
        .onChange(of: realtime.event) { ev in
            if ev.type == "friend" {
                /* 服务端 accepted 推送里带着对方资料：先乐观把「我添加的」移走、
                   插进「已添加」。这样即使随后那次对账网络慢，当前页也立刻正确。 */
                if ev.action == "accepted", let user = ev.user {
                    outgoing.removeAll { $0.id == user.id }
                    added.removeAll { $0.id == user.id }
                    added.insert(user, at: 0)
                }
                Task { await load() }
            }
        }
    }

    /* ---------------------------------------------------------- 行 */

    private var addFriendRow: some View {
        HStack(spacing: L.ctGap) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(hex: 0x4C93DD))
                Image(systemName: "person.badge.plus").font(.system(size: 18)).foregroundColor(.white)
            }
            .frame(width: L.ctIcon, height: L.ctIcon)
            Text(Tr("添加朋友")).font(pf(L.ctNameSize)).foregroundColor(C.label)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 13)).foregroundColor(C.subLabel)
        }
        .padding(.leading, L.ctPadL)
        .padding(.trailing, 16)
        .frame(height: L.ctRowH)
        .background(C.cardBg)
        .contentShape(Rectangle())
    }

    private func sectionHeader(_ t: String) -> some View {
        HStack(spacing: 0) {
            Text(t).font(pf(13)).foregroundColor(C.subLabel)
            Spacer(minLength: 0)
        }
        .padding(.leading, 16)
        .frame(height: 30)
        .background(C.pageBg)
    }

    private func requestRow(_ user: User) -> some View {
        HStack(spacing: L.ctGap) {
            Avatar(path: user.avatarPath, size: L.ctAvatar, radius: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(user.name).font(pf(L.ctNameSize)).foregroundColor(C.label).lineLimit(1)
                Text(noteOf(user)).font(pf(13)).foregroundColor(C.subLabel).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { respond(user, true) } label: {
                Text(Tr("接受"))
                    .font(pf(14, .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 13)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(C.green))
            }
            .buttonStyle(MenuPressStyle())
            .disabled(busy.contains(user.id))

            Button { respond(user, false) } label: {
                Text(Tr("拒绝")).font(pf(14)).foregroundColor(C.subLabel)
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
            .disabled(busy.contains(user.id))
        }
        .padding(.leading, L.ctPadL)
        .padding(.trailing, 16)
        .frame(height: 68)
        .contentShape(Rectangle())
    }

    private func doneRow(_ user: User) -> some View {
        HStack(spacing: L.ctGap) {
            Avatar(path: user.avatarPath, size: L.ctAvatar, radius: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(user.name).font(pf(L.ctNameSize)).foregroundColor(C.label).lineLimit(1)
                Text(noteOf(user)).font(pf(13)).foregroundColor(C.subLabel).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Tr("已添加")).font(pf(14)).foregroundColor(C.subLabel)
        }
        .padding(.leading, L.ctPadL)
        .padding(.trailing, 16)
        .frame(height: 68)
        .contentShape(Rectangle())
    }

    private func waitingRow(_ user: User) -> some View {
        HStack(spacing: L.ctGap) {
            Avatar(path: user.avatarPath, size: L.ctAvatar, radius: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(user.name).font(pf(L.ctNameSize)).foregroundColor(C.label).lineLimit(1)
                let n = (user.requestMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !n.isEmpty {
                    Text(n).font(pf(13)).foregroundColor(C.subLabel).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(Tr("等待验证")).font(pf(14)).foregroundColor(C.subLabel)
        }
        .padding(.leading, L.ctPadL)
        .padding(.trailing, 16)
        .frame(height: 68)
        .contentShape(Rectangle())
    }

    private func noteOf(_ user: User) -> String {
        let n = (user.requestMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? Tr("请求加你为好友") : n
    }

    /* ---------------------------------------------------------- 干活 */

    private func load() async {
        if let d = try? await API.shared.friendRequests() {
            incoming = d.incoming
            outgoing = d.outgoing
            added = d.added
            app.contacts = d.friends
            app.friendRequests = d.incoming.count
        }
        loading = false
    }

    private func respond(_ user: User, _ accept: Bool) {
        /* ⚠ 2026-10-12 用户「新的朋友接受了不会在当页刷新」：
           以前这里写的是 `guard let id = user.requestId, …` —— 只要服务器那条没带
           requestId（老数据 / 字段缺失），这一下就**直接 return**：行不动、也没请求服务器，
           看着就是"点了接受没反应"。现在两种都能走：有 requestId 用 requestId，
           没有就用 userId（服务器的 /api/friends/respond 两个都收）。 */
        guard !busy.contains(user.id) else { return }
        /* 微信的手感：手指一松这一行就动，不等服务器。
           以前是「等接口回来 → 再把整份通讯录重拉一遍」才动，
           手机上就是点了没反应（那个 558KB 的通讯录要下好一会儿）。 */
        let backup = incoming
        busy.insert(user.id)
        incoming.removeAll { $0.id == user.id }
        if accept { added.insert(user, at: 0) }
        app.friendRequests = incoming.count
        Task {
            let res: (ok: Bool, pending: Int?) = (user.requestId ?? "").isEmpty
                ? await API.shared.respondFriend(userId: user.id, accept: accept)
                : await API.shared.respondFriend(requestId: user.requestId ?? "", accept: accept)
            busy.remove(user.id)
            guard res.ok else {
                /* 没成功（断网 / 服务端不认这条申请）：把这一行放回去，再对一次账 */
                incoming = backup
                app.friendRequests = incoming.count
                app.show(Tr("网络不太好，再试一次"))
                await load()
                return
            }
            if let n = res.pending { app.friendRequests = n }
            app.show(accept ? Tr("已添加到通讯录") : Tr("已拒绝"))
            /* 通讯录 / 会话在后台慢慢同步，不挡这一下点击 */
            await app.loadContacts()
            await app.loadChats()
            /* 这一页自己也对一次账：服务器那边的「好友申请 / 已添加 / 我添加的」三份列表
               才是真源，拉回来行状态就不会停在旧样子（拉失败也不影响刚才那一下乐观更新） */
            await load()
        }
    }
}

/* ============================================================ 添加朋友（照微信那套）
   微信「添加朋友」页：
     · 顶上一个搜索框：输入微信号 / 手机号，右边一个「搜索」
     · 搜出来的人是一张卡片：头像 + 昵称 + 微信号，右边按钮随关系变：
         none → 「添加到通讯录」   requested → 「等待验证」
         incoming → 「接受」       friend → 「已添加」
     · 点「添加到通讯录」弹出申请页：头像昵称 + 验证消息（默认「我是XXX」）+ 发送
     · 下面还有「扫一扫」「我的二维码」两行（微信也有） */

struct AddFriendView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var realtime = Realtime.shared

    @State private var keyword = ""
    @State private var results: [User] = []
    @State private var searching = false
    @State private var searched = false
    @State private var errorText: String?
    @State private var target: User?
    @State private var sentTo: Set<String> = []
    @State private var showScan = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("添加朋友"), back: { dismiss() })

            ScrollView {
                VStack(spacing: 0) {
                    searchRow
                        .padding(L.searchPad)

                    if let errorText = errorText {
                        Text(errorText)
                            .font(pf(14))
                            .foregroundColor(C.subLabel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    }

                    if searching {
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .frame(height: 76).background(C.cardBg)
                    } else if searched && results.isEmpty {
                        Text(Tr("未找到相关用户"))
                            .font(pf(15))
                            .foregroundColor(C.subLabel)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                            .background(C.cardBg)
                    }

                    if !results.isEmpty {
                        Text(Tr("搜索结果"))
                            .font(pf(13)).foregroundColor(C.subLabel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 16)
                            .frame(height: 30)
                            .background(C.pageBg)
                        ForEach(results) { u in
                            VStack(spacing: 0) {
                                HairLine(inset: 72)
                                resultRow(u)
                            }
                            .background(C.cardBg)
                        }
                    }

                    /* 微信这一页下面那两行 */
                    VStack(spacing: 0) {
                        HairLine(inset: 56)
                        otherRow(icon: "qrcode.viewfinder", title: Tr("扫一扫")) { showScan = true }
                        HairLine(inset: 56)
                        NavigationLink(value: "myQR") {
                            otherRowLabel(icon: "qrcode", title: Tr("我的二维码"))
                        }
                        .buttonStyle(MenuPressStyle())
                    }
                    .background(C.cardBg)
                    .padding(.top, 24)
                }
                .padding(.bottom, 30)
            }
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .fullScreenCover(isPresented: $showScan) {
            ScannerView { text in handleScanned(text, app: app) }
        }
        .sheet(item: $target) { u in
            FriendApplySheet(user: u) {
                sentTo.insert(u.id)
                Task { await app.loadContacts() }
            }
            .environmentObject(app)
        }
        .onChange(of: realtime.event) { ev in
            if ev.type == "friend" && !results.isEmpty { search() }
        }
    }

    /* ---------------------------------------------------------- 搜索框 */

    private var searchRow: some View {
        HStack(spacing: 8) {
            SVGIcon(markup: I.searchSmall, size: 16, color: C.searchIcon)
            TextField(Tr("星言号/手机号"), text: $keyword)
                .font(pf(16))
                .foregroundColor(C.label)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .submitLabel(.search)
                .onSubmit { search() }
            if !keyword.isEmpty {
                Button {
                    keyword = ""
                    results = []
                    searched = false
                    errorText = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(C.searchIcon)
                }
                .buttonStyle(.plain)
            }
            Button { search() } label: {
                Text(searching ? Tr("搜索中…") : Tr("搜索"))
                    .font(pf(15, .medium))
                    .foregroundColor(keyword.isEmpty ? C.subLabel : .white)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(keyword.isEmpty ? Color.clear : C.green))
            }
            .buttonStyle(.plain)
            .disabled(keyword.isEmpty || searching)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(C.searchBg))
    }

    /* ---------------------------------------------------------- 结果卡片 */

    private func resultRow(_ u: User) -> some View {
        HStack(spacing: L.ctGap) {
            Avatar(path: u.avatarPath, size: 52, radius: 7)
            VStack(alignment: .leading, spacing: 4) {
                Text(u.name).font(pf(17)).foregroundColor(C.label).lineLimit(1)
                if let un = u.username, !un.isEmpty {
                    Text(Tr("星言号") + "：" + un)
                        .font(pf(13)).foregroundColor(C.subLabel).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            resultAction(u)
        }
        .padding(.horizontal, 16)
        .frame(height: 76)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func resultAction(_ u: User) -> some View {
        let rel = u.relation ?? "none"
        if sentTo.contains(u.id) || rel == "requested" {
            Text(Tr("等待验证")).font(pf(14)).foregroundColor(C.subLabel)
        } else if rel == "friend" || rel == "self" {
            Text(Tr("已添加")).font(pf(14)).foregroundColor(C.subLabel)
        } else if rel == "incoming" {
            Button { accept(u) } label: {
                greenChip(Tr("接受"))
            }
            .buttonStyle(MenuPressStyle())
        } else {
            Button { openApply(u) } label: {
                greenChip(Tr("添加到通讯录"))
            }
            .buttonStyle(MenuPressStyle())
        }
    }

    private func greenChip(_ t: String) -> some View {
        Text(t)
            .font(pf(14, .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(C.green))
    }

    /* ---------------------------------------------------------- 下面两行 */

    private func otherRow(icon: String, title: String, tap: @escaping () -> Void) -> some View {
        Button(action: tap) { otherRowLabel(icon: icon, title: title) }
            .buttonStyle(MenuPressStyle())
    }

    private func otherRowLabel(icon: String, title: String) -> some View {
        HStack(spacing: L.ctGap) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(hex: 0x4C93DD))
                Image(systemName: icon).font(.system(size: 17)).foregroundColor(.white)
            }
            .frame(width: L.ctIcon, height: L.ctIcon)
            Text(title).font(pf(L.ctNameSize)).foregroundColor(C.label)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 13)).foregroundColor(C.subLabel)
        }
        .padding(.leading, L.ctPadL)
        .padding(.trailing, 16)
        .frame(height: L.ctRowH)
        .background(C.cardBg)
        .contentShape(Rectangle())
    }

    /* ---------------------------------------------------------- 干活 */

    private func search() {
        let q = keyword.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        errorText = nil
        Task {
            do {
                let list = try await API.shared.searchUsers(q)
                results = list
                searched = true
            } catch {
                results = []
                searched = true
                errorText = (error as? APIError)?.errorDescription ?? Tr("未找到相关用户")
            }
            searching = false
        }
    }

    private func openApply(_ u: User) {
        target = u
    }

    private func accept(_ u: User) {
        Task {
            /* 直接按 userId 同意：以前要先拉一遍整份通讯录才找得到 requestId，白等一个来回 */
            let res = await API.shared.respondFriend(userId: u.id, accept: true)
            guard res.ok else {
                app.show(Tr("到「通讯录 → 新的朋友」里同意"))
                return
            }
            if let n = res.pending { app.friendRequests = n }
            app.show(Tr("已添加到通讯录"))
            await app.loadContacts()
            search()
        }
    }
}

/* ============================================================ 申请加好友（验证消息）
   微信那个「发送添加朋友申请」页：上面是被加的人（头像/昵称/星言号），
   下面一行验证消息，默认填「我是XXX」，右上角「发送」。
   添加朋友页和名片页上的「添加到通讯录」都弹这一页。 */

struct FriendApplySheet: View {
    let user: User
    var onSent: () -> Void = {}

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var note = ""
    @State private var sending = false

    private var trimmed: String { note.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("发送添加朋友申请"), back: { dismiss() }) {
                Button { send() } label: {
                    Text(sending ? Tr("发送中…") : Tr("发送"))
                        .font(pf(17))
                        .foregroundColor(trimmed.isEmpty ? C.subLabel : C.green)
                        .frame(height: L.navH)
                        .padding(.trailing, 16)
                }
                .buttonStyle(.plain)
                .disabled(sending || trimmed.isEmpty)
            }

            VStack(spacing: 0) {
                HStack(spacing: L.ctGap) {
                    Avatar(path: user.avatarPath, size: 52, radius: 7)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(user.name).font(pf(17)).foregroundColor(C.label)
                        if let un = user.username, !un.isEmpty {
                            Text(Tr("星言号") + "：" + un).font(pf(13)).foregroundColor(C.subLabel)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .frame(height: 76)
                .background(C.cardBg)

                HStack(spacing: 12) {
                    Text(Tr("验证消息")).font(pf(15)).foregroundColor(C.subLabel)
                    TextField(Tr("验证消息"), text: $note)
                        .font(pf(16))
                        .foregroundColor(C.label)
                    if !note.isEmpty {
                        Button { note = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15)).foregroundColor(C.searchIcon)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(C.cardBg)
                .padding(.top, 12)
            }
            Spacer()
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .onAppear {
            if note.isEmpty { note = defaultNote() }
        }
    }

    private func defaultNote() -> String {
        let me = (app.me?.name ?? "").trimmingCharacters(in: .whitespaces)
        let u = (app.me?.username ?? "").trimmingCharacters(in: .whitespaces)
        let who = me.isEmpty ? u : me
        return who.isEmpty ? Tr("我是") : Tr("我是") + who
    }

    private func send() {
        sending = true
        Task {
            do {
                if let un = user.username, !un.isEmpty {
                    try await API.shared.addFriend(username: un, note: trimmed)
                } else {
                    try await API.shared.addFriend(userId: user.id, note: trimmed)
                }
                app.show(Tr("好友申请已发出"))
                onSent()
                dismiss()
            } catch {
                app.show((error as? APIError)?.errorDescription ?? Tr("发送失败"))
            }
            sending = false
        }
    }
}

/* ============================================================ 设置备注和标签（微信那一页）
   备注名（设了以后通讯录、会话标题都显示它）+ 标签（多个，用顿号分开）。
   标签是「我这个好友」的属性，存服务器 data/friendmeta.json。 */

struct FriendRemarkSheet: View {
    let user: User
    var meta: API.FriendMeta?
    var onSaved: () async -> Void

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var remark = ""
    @State private var tags = ""
    @State private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("设置备注和标签"), back: { dismiss() }) {
                Button { save() } label: {
                    Text(saving ? Tr("保存中…") : Tr("完成"))
                        .font(pf(17))
                        .foregroundColor(C.green)
                        .frame(height: L.navH)
                        .padding(.trailing, 16)
                }
                .buttonStyle(.plain)
                .disabled(saving)
            }

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(Tr("备注名")).font(pf(16)).foregroundColor(C.label)
                        .frame(width: 76, alignment: .leading)
                    TextField(Tr("填写备注名"), text: $remark)
                        .font(pf(16)).foregroundColor(C.label)
                    if !remark.isEmpty {
                        Button { remark = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15)).foregroundColor(C.searchIcon)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(C.cardBg)

                HairLine(inset: 16)
                HStack(spacing: 12) {
                    Text(Tr("标签")).font(pf(16)).foregroundColor(C.label)
                        .frame(width: 76, alignment: .leading)
                    TextField(Tr("多个标签用顿号隔开"), text: $tags)
                        .font(pf(16)).foregroundColor(C.label)
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(C.cardBg)
            }
            .padding(.top, 12)

            Text(Tr("备注名只你自己看得见：设了以后通讯录和会话列表都显示备注。"))
                .font(pf(12.5))
                .foregroundColor(C.subLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 12)
            Spacer()
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .onAppear {
            remark = meta?.remark ?? ""
            tags = (meta?.tags ?? []).joined(separator: "、")
        }
    }

    private func save() {
        saving = true
        let list = tags.split(whereSeparator: { "、,，;； ".contains($0) })
            .map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        Task {
            await API.shared.setFriendMeta(userId: user.id,
                                           remark: remark.trimmingCharacters(in: .whitespaces),
                                           tags: list)
            await app.loadContacts()
            await onSaved()
            saving = false
            dismiss()
            app.show(Tr("已保存"))
        }
    }
}

/* ============================================================ 朋友权限（微信那一页）
   聊天 / 看他（她）的朋友圈 / 不让他（她）看我 / 加入黑名单 */

struct FriendPermSheet: View {
    let user: User
    var meta: API.FriendMeta?
    var onSaved: () async -> Void

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var noMoments = false
    @State private var hideMine = false
    @State private var blocked = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("朋友权限"), back: { dismiss() })

            VStack(spacing: 0) {
                toggleRow(Tr("聊天"), true, locked: true)
                HairLine(inset: 16)
                toggleRow(Tr("不看他的朋友圈"), noMoments) { noMoments = $0; save() }
                HairLine(inset: 16)
                toggleRow(Tr("不让他看我的朋友圈"), hideMine) { hideMine = $0; save() }
                HairLine(inset: 16)
                toggleRow(Tr("加入黑名单"), blocked) { blocked = $0; save() }
            }
            .padding(.top, 12)
            .background(C.cardBg)

            Text(Tr("拉黑以后他发不了消息给你，也看不到你的朋友圈；聊天里你会看到「消息已发出，但被对方拒收了」。"))
                .font(pf(12.5))
                .foregroundColor(C.subLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 12)
            Spacer()
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .onAppear {
            noMoments = meta?.noMoments == true
            hideMine = meta?.hideMyMoments == true
            blocked = meta?.block == true
        }
    }

    private func toggleRow(_ title: String, _ on: Bool, locked: Bool = false,
                           set: @escaping (Bool) -> Void = { _ in }) -> some View {
        HStack(spacing: 10) {
            Text(title).font(pf(16)).foregroundColor(C.label)
            Spacer(minLength: 8)
            if locked {
                Text(Tr("已开启")).font(pf(14)).foregroundColor(C.subLabel)
            } else {
                Toggle("", isOn: Binding(get: { on }, set: { set($0) }))
                    .labelsHidden()
                    .tint(C.green)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private func save() {
        Task {
            await API.shared.setFriendMeta(userId: user.id, block: blocked,
                                           noMoments: noMoments, hideMyMoments: hideMine)
            await onSaved()
            app.show(Tr("已保存"))
        }
    }
}

/* ============================================================ 发起群聊 */

struct GroupCreateView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    var onCreated: (Chat) -> Void

    @State private var name = ""
    @State private var picked: Set<String> = []
    @State private var busy = false
    /// 面对面建群（微信：这个入口就在「发起群聊」页最上面）
    @State private var showFace = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("发起群聊"), back: { dismiss() }) {
                Button {
                    create()
                } label: {
                    Text(busy ? "创建中…" : "完成")
                        .font(pf(17))
                        .foregroundColor(picked.isEmpty ? C.subLabel : C.green)
                        .frame(height: L.navH)
                        .padding(.trailing, 16)
                }
                .buttonStyle(.plain)
            }

            /* 微信的「发起群聊」页最上面这一条就是**面对面建群**：
               大家输入同一个 4 位数字，3 分钟内进同一个群。 */
            Button { showFace = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "person.3.sequence.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(C.green)
                        .frame(width: 26)
                    Text(Tr("面对面建群")).font(pf(16)).foregroundColor(C.label)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(C.subLabel)
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(C.cardBg)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)

            HStack(spacing: 8) {
                TextField("群名称", text: $name)
                    .font(pf(16))
                    .foregroundColor(C.label)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(C.searchBg)
            .padding(12)

            List {
                ForEach(app.contacts) { user in
                    Button {
                        if picked.contains(user.id) { picked.remove(user.id) }
                        else { picked.insert(user.id) }
                    } label: {
                        HStack(spacing: 12) {
                            Avatar(path: user.avatarPath, size: 40, radius: 6)
                            Text(user.name).font(pf(17)).foregroundColor(C.label)
                            Spacer()
                            Image(systemName: picked.contains(user.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(picked.contains(user.id) ? C.green : C.subLabel)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 56)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(C.cardBg)
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 0)
            .scrollContentBackground(.hidden)
            .background(C.cardBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()

        /* 面对面建群：进群之后把那个群交给外层（和"建完群直接进去"同一条路） */
        .sheet(isPresented: $showFace) {
            FaceGroupView { chat in onCreated(chat) }
                .environmentObject(app)
        }
    }

    private func create() {
        let groupName = name.trimmingCharacters(in: .whitespaces)
        if groupName.isEmpty { app.show(Tr("先填个群名称")); return }
        if picked.isEmpty { app.show(Tr("至少选一个好友")); return }
        busy = true
        Task {
            do {
                if let chat = try await API.shared.createGroup(name: groupName, memberIds: Array(picked)) {
                    await app.loadChats()
                    onCreated(chat)
                    dismiss()
                    app.show(Tr("群建好了"))
                }
            } catch {
                app.show((error as? APIError)?.errorDescription ?? "创建失败")
            }
            busy = false
        }
    }
}

/* ============================================================
   面对面建群（微信那套）

   和身边的朋友**输入同样的四个数字**，就进同一个群聊；
   数字 3 分钟内有效，每进来一个人有效期重新计时。
   这串数字就是"密码" —— 服务端只认 4 位数字（接口：POST /api/chats/face）。
   ============================================================ */
struct FaceGroupView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    /// 进群/建群成功后把那个群交回外层（外层负责打开聊天页）
    var onJoined: (Chat) -> Void

    @State private var digits = ""
    @State private var busy = false
    @State private var tip = ""

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("面对面建群"), back: { dismiss() }) { EmptyView() }

            VStack(spacing: 8) {
                Text(Tr("和身边的朋友输入同样的四个数字，进入同一个群聊"))
                    .font(pf(14))
                    .foregroundColor(C.subLabel)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                Text(Tr("数字 3 分钟内有效"))
                    .font(pf(12))
                    .foregroundColor(C.subLabel.opacity(0.75))

                /* 四个格子：输入到第几个就亮第几个 */
                HStack(spacing: 10) {
                    ForEach(0..<4, id: \.self) { i in
                        let on = digits.count > i
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(C.searchBg)
                            .frame(width: 46, height: 56)
                            .overlay(
                                Text(on ? String(Array(digits)[i]) : "")
                                    .font(pf(24, .semibold))
                                    .foregroundColor(C.label)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(digits.count == i ? C.green : Color.clear, lineWidth: 1.6)
                            )
                    }
                }
                .padding(.top, 10)

                if !tip.isEmpty {
                    Text(tip).font(pf(13)).foregroundColor(C.red)
                }

                Button { enter() } label: {
                    Text(busy ? Tr("进入中…") : Tr("进入群聊"))
                        .font(pf(17, .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(digits.count == 4 ? C.green : C.green.opacity(0.35)))
                }
                .buttonStyle(.plain)
                .disabled(digits.count != 4 || busy)
                .padding(.horizontal, 24)
                .padding(.top, 6)
            }
            .padding(.top, 24)

            Spacer(minLength: 10)
            keypad
            Color.clear.frame(height: L.safeBottom)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
    }

    /* 微信那种数字键盘：1-9 一行三个，最后一行是（空）0 ⌫ */
    private var keypad: some View {
        VStack(spacing: 1) {
            ForEach(0..<4, id: \.self) { r in
                HStack(spacing: 1) {
                    ForEach(0..<3, id: \.self) { c in
                        let i = r * 3 + c
                        let label = i == 9 ? "" : (i == 10 ? "0" : (i == 11 ? "⌫" : String(i + 1)))
                        key(label)
                    }
                }
            }
        }
        .background(C.hairline)
    }

    @ViewBuilder
    private func key(_ k: String) -> some View {
        if k.isEmpty {
            Color.clear.frame(maxWidth: .infinity).frame(height: 56).background(C.cardBg)
        } else {
            Button {
                if k == "⌫" {
                    if !digits.isEmpty { digits.removeLast() }
                    return
                }
                guard digits.count < 4 else { return }
                digits += k
                /* 满 4 位直接进（微信也是这样，不用再点一下） */
                if digits.count == 4 { enter() }
            } label: {
                Text(k)
                    .font(pf(k == "⌫" ? 20 : 24))
                    .foregroundColor(C.label)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(C.cardBg)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func enter() {
        guard digits.count == 4, !busy else { return }
        busy = true
        tip = ""
        Task {
            do {
                guard let chat = try await API.shared.faceGroup(code: digits) else {
                    tip = Tr("没进去，再试一次")
                    digits = ""
                    busy = false
                    return
                }
                await app.loadChats()
                onJoined(chat)
                dismiss()
            } catch {
                tip = (error as? APIError)?.errorDescription ?? Tr("没进去，再试一次")
                digits = ""
            }
            busy = false
        }
    }
}

/* ============================================================ 服务（照微信参考图重做）
   尺寸全部对着参考图量出来的数字（iPhone @3x，420×912pt）：
     · 卡片左右各内缩 8、卡与卡之间空 8、圆角 7
     · 绿卡：高 144，底色 #2AAE67；左右两半居中（图标 28 / 名字 18 / 小字 12 白 50%）
     · 白卡：分类标题行 48（灰 14）+ 每行格子 92 + 底部 20
     · 格子：4 列均分，图标 28、图标下 18.5、文字 13（黑）
   内容全部来自后台「服务页」模块（GET /api/service），拉不到就用内置那套兜底；
   钱包那一半显示零钱余额，账单列表接在所有分类下面（原来的功能没丢）。 */

struct ServiceView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var realtime = Realtime.shared
    /// 小星的档位：关掉小星（顶栏不画那颗眼睛）之后，这一页补一个「AI 助手」入口
    @ObservedObject private var eyes = EyesStore.shared

    @State private var cfg: ServiceConfig?
    @State private var bills: [BillItem] = []
    @State private var loading = true
    @State private var rechargeAmount = ""
    @State private var showRecharge = false
    @State private var showMore = false
    @State private var showWallet = false
    /// 服务页上的「客服中心」：进真正的客服中心页
    @State private var showServiceSupport = false
    @State private var showBillsPage = false
    /// 「收付款」那一页（付款码 + 收款码）
    @State private var showPayCode = false
    @State private var detailChat: Chat?
    @State private var detailInfo: TransferInfo?
    /// 「AI 助手」：整页打开小星自己的对话页
    @State private var botChat: Chat? = nil

    struct BillItem: Identifiable {
        let id: String
        let title: String
        let amount: Double
        let date: String
        let status: String
        var chat: Chat? = nil
        var info: TransferInfo? = nil
    }

    /// 一格（四列网格里的一个）
    private struct Cell: Identifiable {
        let id: String
        let label: String
        let color: Color
        let svg: String
        let action: String
    }

    /// 一张白卡 = 一个分类
    private struct Group: Identifiable {
        let id: String
        let title: String
        let cells: [Cell]
        var style: ServiceGroupStyle? = nil
    }

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 0), count: 4)

    /// 样式（绿卡背景 / 图标大小 / 字体）：后台「服务页 → 样式」里配，取不到就用参考图那套默认值
    private var st: ServiceStyle { cfg?.style ?? ServiceStyle() }

    /// 底部账单卡 + 右上角「⋯」菜单的文案：后台「服务页 → 底部」里配（留空 = 下面这些默认值）
    private var bt: ServiceBottom { cfg?.bottom ?? ServiceBottom() }

    /// 分类：后台配的优先，没有就用内置那套（内容和参考图一致）
    private var groups: [Group] {
        var out: [Group] = []
        if let list = cfg?.groups, !list.isEmpty {
            out = list.compactMap { g in
                let cells = (g.items ?? []).filter { $0.enabled != false }.map { it in
                    Cell(id: it.id,
                         label: it.label,
                         color: Color(hexString: it.color ?? "#1180E0", fallback: 0x1180E0),
                         svg: SvcIcon.markup(it.icon, it.svg),
                         action: it.action ?? "soon")
                }
                return cells.isEmpty ? nil : Group(id: g.id, title: g.title, cells: cells, style: g.style)
            }
        } else {
            out = ServiceFallback.groups.map { pair in
                Group(id: pair.0, title: pair.0, cells: pair.1.map { row in
                    Cell(id: row.0, label: row.0,
                         color: Color(hexString: row.2, fallback: 0x1180E0),
                         svg: SvcIcon.markup(row.1, nil), action: "soon")
                })
            }
        }
        /* 「AI 助手」入口**一直挂在这一页**（用户要求把会话页顶栏那颗眼睛删掉之后，
           这里是进 AI 助手最顺的一条路：我 → 服务 → AI 助手）。 */
        if let last = out.last {
            let ai = Cell(id: "ai.assistant",
                          label: Tr("AI 助手"),
                          color: C.green,
                          svg: #"<svg data-key="svc.ai" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3.4l1.9 5.1 5.1 1.9-5.1 1.9-1.9 5.1-1.9-5.1L5 10.4l5.1-1.9z"/><path d="M18.6 16.4l.8 2 2 .8-2 .8-.8 2-.8-2-2-.8 2-.8z"/></svg>"#,
                          action: "ai")
            out[out.count - 1] = Group(id: last.id, title: last.title,
                                       cells: last.cells + [ai], style: last.style)
        }
        return out
    }

    private var balanceText: String { "¥" + moneyFmt(app.me?.balance ?? 0) }
    /// 绿卡右边的零钱：后台开了「金额打星号」就显示 ¥****
    private var walletSubText: String { (st.maskAmount ?? true) ? "¥****" : balanceText }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: cfg?.title ?? "服务", back: { dismiss() }) {
                Button { showMore = true } label: {
                    WeChatDots()
                        .frame(width: 44, height: L.navH)
                }
                .buttonStyle(.plain)
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    if cfg?.card?.enabled != false { greenCard.padding(.top, 13) }
                    ForEach(Array(groups.enumerated()), id: \.element.id) { idx, g in
                        groupCard(g).padding(.top, topGap(idx))
                    }
                    billsCard.padding(.top, 8)
                    Color.clear.frame(height: 24)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .navigationDestination(isPresented: $showWallet) { WalletView() }
        .sheet(isPresented: $showServiceSupport) { SupportView().environmentObject(app) }
        .navigationDestination(isPresented: $showBillsPage) { BillsView() }
        .navigationDestination(isPresented: $showPayCode) { PayCodePage() }
        /* 小星关掉之后那一格「AI 助手」：整页打开小星对话页 */
        .fullScreenCover(item: $botChat) { c in
            BotChatView(chat: c).environmentObject(app)
        }
        .confirmationDialog(Tr("服务"), isPresented: $showMore, titleVisibility: .hidden) {
            Button(Tr(bt.moreRefresh ?? "刷新账单")) { Task { await loadBills() } }
            Button(Tr(bt.moreRecharge ?? "充值")) { rechargeAmount = ""; showRecharge = true }
            Button(Tr(bt.moreCancel ?? "取消"), role: .cancel) { }
        }
        .sheet(isPresented: Binding(
            get: { detailInfo != nil },
            set: { if !$0 { detailInfo = nil; detailChat = nil } }
        )) {
            if let c = detailChat, let i = detailInfo {
                BillDetailView(chat: c, info: i)
            }
        }
        .alert("充值", isPresented: $showRecharge) {
            TextField("金额", text: $rechargeAmount).keyboardType(.decimalPad)
            Button(Tr("充值")) { doRecharge() }
            Button(Tr("取消"), role: .cancel) { }
        }
        .task {
            await loadConfig()
            await loadBills()
            /* 小星的档位：关掉了才在最后一张卡里补「AI 助手」那一格 */
            if !eyes.loaded { await eyes.refresh() }
        }
        // 有转账 / 余额变动 → 账单立刻刷新
        .onChange(of: realtime.event) { ev in
            if ev.type == "transfer" || ev.type == "balance" { Task { await loadBills() } }
            if ev.type == "ui" { Task { await loadConfig() } }
        }
    }

    /* ---------------------------------------------------------- 绿卡：收付款 / 钱包 */

    private var greenCard: some View {
        let c = cfg?.card
        /* 2026-10-17：默认色从微信绿换成品牌色（后台配了 bg 还是以配置为准） */
        let bg = Color(hexString: c?.bg ?? "#E02F24", fallback: 0xE02F24)
        let s = st
        return ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(bg)
            /* 一层斜向高光：看着像玻璃面（浅色从左上压下来、右下收一点暗） */
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [Color.white.opacity(0.18), Color.clear, Color.black.opacity(0.07)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            /* 后台填了背景图就用图，没填就只用底色 */
            if let img = s.cardImage, !img.isEmpty {
                RemoteImage(path: img)
                    .frame(maxWidth: .infinity)
                    .frame(height: s.cardHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            HStack(alignment: .top, spacing: 0) {
                halfView(c?.left, label: "收付款", icon: "svc.pay", action: "pay", sub: "")
                /* 两半中间一条细白线（微信那张卡也是分开的两块） */
                Rectangle().fill(Color.white.opacity(0.18))
                    .frame(width: 0.7, height: 46)
                    .padding(.top, 6)
                halfView(c?.right, label: "钱包", icon: "svc.wallet", action: "wallet", sub: walletSubText)
            }
            .padding(.horizontal, 25)
            .padding(.top, 33)
        }
        .frame(height: s.cardHeight)
        .padding(.horizontal, 8)
        .shadow(color: Color.black.opacity(0.12), radius: 12, y: 6)
    }

    private func halfView(_ h: ServiceHalf?, label fallbackLabel: String,
                          icon fallbackIcon: String, action fallbackAction: String, sub fallbackSub: String) -> some View {
        let rawLabel = h?.label ?? ""
        let label = rawLabel.isEmpty ? fallbackLabel : rawLabel
        let rawSub = h?.sub ?? ""
        let sub = rawSub.isEmpty ? fallbackSub : rawSub
        let s = st
        return Button {
            run(h?.action ?? fallbackAction, label)
        } label: {
            VStack(spacing: 0) {
                SVGIcon(markup: SvcIcon.markup(h?.icon ?? fallbackIcon, h?.svg), size: s.icon, color: s.cardText)
                    .frame(width: s.icon, height: s.icon)
                Text(label)
                    .font(pf(s.cardNameSize))
                    .foregroundColor(s.cardText)
                    .padding(.top, 17)
                if !sub.isEmpty {
                    MoneyLabel(text: sub, size: s.cardSubSizeV, curSize: s.curFontSize,
                               color: s.cardText.opacity(s.cardSubOpacityV))
                        .padding(.top, 10)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    /* ---------------------------------------------------------- 白卡：分类标题 + 四列格子 */

    private func groupCard(_ g: Group) -> some View {
        let s = st
        /* 版块自己的「上 / 下」在 topGap() 里处理（块与块之间的空隙）；
           标题行高、每行高、行间距、留白都是参考图那套固定值。左右固定 8pt。 */
        return VStack(spacing: 0) {
            Text(g.title)
                .font(pf(s.titleSize))
                .foregroundColor(s.titleColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 16.7)
                .frame(height: s.titleHeight)

            LazyVGrid(columns: cols, spacing: 0) {
                ForEach(g.cells) { c in
                    Button {
                        run(c.action, c.label)
                    } label: {
                        VStack(spacing: 0) {
                            /* 图标加一层淡淡的同色圆角底：比光秃秃一个图标更精致，
                               而且不改尺寸（底比图标大 14pt，下面的文字往上收一点，总高度基本没变） */
                            ZStack {
                                RoundedRectangle(cornerRadius: (s.icon + 14) * 0.29, style: .continuous)
                                    .fill(LinearGradient(colors: [c.color.opacity(0.18), c.color.opacity(0.07)],
                                                         startPoint: .topLeading,
                                                         endPoint: .bottomTrailing))
                                    .frame(width: s.icon + 14, height: s.icon + 14)
                                SVGIcon(markup: c.svg, size: s.icon, color: c.color)
                                    .frame(width: s.icon, height: s.icon)
                            }
                            Text(c.label)
                                .font(pf(s.textSize))
                                .foregroundColor(s.gridText)
                                .lineLimit(1)
                                .padding(.top, 10)
                        }
                        .padding(.top, 14)
                        .frame(maxWidth: .infinity)
                        .frame(height: s.cellHeight, alignment: .top)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 20)
        }
        .background { CardGlassBox(radius: 16) }
        .padding(.horizontal, 8)
        .shadow(color: Color.black.opacity(0.055), radius: 9, y: 3)
    }

    /// 版块之间的空隙 = 上一块的「块下间距」+ 这一块的「块上间距」
    /// （默认：上一块 8、这一块 0 → 和参考图一样空 8pt；后台怎么调都不会挨在一起）
    private func topGap(_ idx: Int) -> CGFloat {
        guard idx > 0 else { return 8 }
        let prev = groups[idx - 1].style?.gapBottom ?? 8
        let cur = groups[idx].style?.gapTop ?? 0
        return CGFloat(max(8, prev + cur))
    }

    /* ---------------------------------------------------------- 账单（原来那一套，接在下面） */

    private var billsCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(Tr(bt.billTitle ?? "账单"))
                    .font(pf(14))
                    .foregroundColor(Color.dyn(0x7A7A7A, 0x8A8A8A))
                Spacer(minLength: 0)
                Text(balanceText)
                    .font(pf(13))
                    .foregroundColor(C.subLabel)
                /* 后台「隐藏开关」：billsShow = 0 → 这一颗「全部账单」整个不画 */
                if UIConfig.num("billsShow", 1) > 0 {
                    Button { showBillsPage = true } label: {
                        Text(Tr(bt.billAll ?? "全部账单"))
                            .font(pf(13))
                            .foregroundColor(C.green)
                            .padding(.leading, 14)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    rechargeAmount = ""
                    showRecharge = true
                } label: {
                    Text(Tr(bt.billRecharge ?? "充值"))
                        .font(pf(13))
                        .foregroundColor(C.green)
                        .padding(.leading, 14)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16.7)
            .frame(height: 48)

            if loading {
                ProgressView().padding(.vertical, 26)
            } else if bills.isEmpty {
                Text(Tr(bt.billEmpty ?? "还没有账单项"))
                    .font(pf(14))
                    .foregroundColor(C.subLabel)
                    .padding(.vertical, 26)
            } else {
                ForEach(bills) { bill in
                    Button {
                        if let chat = bill.chat, let info = bill.info {
                            detailChat = chat
                            detailInfo = info
                        }
                    } label: {
                        VStack(spacing: 0) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(bill.title).font(pf(16)).foregroundColor(C.label)
                                    Text(bill.date).font(pf(12.5)).foregroundColor(C.subLabel)
                                }
                                Spacer(minLength: 0)
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text("¥\(moneyFmt(bill.amount))")
                                        .font(pfMoney(16))
                                        .foregroundColor(C.label)
                                    Text(bill.status).font(pf(12.5)).foregroundColor(C.subLabel)
                                }
                                Chevron(size: 9, line: 1.6)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 66)
                            HairLine(inset: 16)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background { CardGlassBox(radius: 16) }
        .padding(.horizontal, 8)
        .padding(.bottom, 20)
    }

    /* ---------------------------------------------------------- 动作 */

    private func run(_ action: String, _ label: String) {
        switch action {
        case "wallet":
            showWallet = true          // 进「钱包」页（照参考图做的那一页）
        case "pay":
            showPayCode = true          // 收付款（付款码 + 收款码）
        case "ai":
            openAI()                    // 小星关掉之后，这一格进 AI 助手
        default:
            /* 名字兜底：这几页都做好了，后台动作写成 soon 也能点进去 */
            if label.contains("客服") { showServiceSupport = true }
            else if label.contains("经营") { showWallet = true }
            else { app.show(soonTip(label)) }
        }
    }

    /// 「XX 还没接后端」这句提示：后台「服务页 → 底部 → 未接提示」能改，{label} 换成格子的名字
    private func soonTip(_ label: String) -> String {
        Tr((bt.soonTip ?? "「{label}」还没接后端，先把页面做出来").replacingOccurrences(of: "{label}", with: label))
    }

    private func loadConfig() async {
        if let got = try? await API.shared.serviceConfig() {
            cfg = got
        }
    }

    /// 「AI 助手」：整页打开小星自己的对话页（和会话页顶栏那颗眼睛点开的是同一页）
    private func openAI() {
        if let bot = app.chats.first(where: { $0.botRank == 0 }) { botChat = bot; return }
        Task {
            await app.loadChats()
            if let b = app.chats.first(where: { $0.botRank == 0 }) { botChat = b }
            else { app.show(Tr("AI 助手还没准备好，稍后再试")) }
        }
    }

    private func doRecharge() {
        guard let amount = Double(rechargeAmount), amount > 0 else {
            app.show(Tr("金额不对"))
            return
        }
        Task {
            if let balance = try? await API.shared.recharge(amount) {
                app.me = try? await API.shared.me()
                app.show("充值成功，余额 ¥\(moneyFmt(balance))")
            } else {
                app.show(Tr("充值失败"))
            }
        }
    }

    private func loadBills() async {
        loading = true
        var found: [BillItem] = []
        for chat in app.chats.prefix(14) {
            guard let result = try? await API.shared.messages(chatId: chat.id, limit: 40) else { continue }
            for m in result.messages where m.kindName == "transfer" {
                guard let data = m.body.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let mine = (o["fromId"] as? String) == app.me?.id
                let amount = (o["amount"] as? Double) ?? 0
                let status = (o["status"] as? String) ?? "pending"
                let state = status == "received" ? "已收款" :
                            (status == "refunded" ? "已退回" : "待收款")
                found.append(BillItem(id: (o["id"] as? String) ?? m.id,
                                      title: mine ? "转账给 \(chat.name)" : "\(chat.name) 转账给你",
                                      amount: amount,
                                      date: TimeFmt.bill(o["createdAt"] as? String ?? m.createdAt),
                                      status: state,
                                      chat: chat,
                                      info: TransferInfo(json: m.body)))
            }
        }
        bills = found.sorted { $0.date > $1.date }
        loading = false
    }
}


