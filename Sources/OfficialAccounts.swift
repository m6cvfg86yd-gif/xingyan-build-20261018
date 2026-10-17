import SwiftUI

/* ============================================================
   公众号（我们自己的，照微信那套）
     · 通讯录 → 公众号：所有号 + 关注状态
     · 号主页：头像 / 名字 / 简介 + 订阅按钮 + 历史文章
     · 文章页：大标题、封面、作者时间、正文（# 小标题、图片行）
     · 会话里收到的是图文卡片（kind = oa），点开就是文章页
   版式按"高级"来：大留白、细分隔线、克制的配色、正文行距 1.75
   ============================================================ */

struct OAAccount: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var avatar: String?
    var bio: String?
    var type: String?
    var following: Bool?
    var articleCount: Int?
    var lastAt: String?

    var isService: Bool { (type ?? "") == "service" }
    var typeLabel: String { isService ? "服务号" : "订阅号" }
    var avatarPath: String { avatar ?? "" }
    var about: String { bio ?? "" }
    var count: Int { articleCount ?? 0 }
    var followed: Bool { following ?? false }
}

struct OAArticle: Decodable, Identifiable, Hashable {
    var id: String
    var title: String
    var summary: String?
    var cover: String?
    var author: String?
    var content: String?
    var createdAt: String?
    var reads: Int?
    /// 原文链接（有的话右上角「⋯」能打开）
    var originalUrl: String?

    var coverPath: String { cover ?? "" }
    var text: String { content ?? "" }
    var readCount: Int { reads ?? 0 }
}

struct OAAccountPage: Decodable {
    var account: OAAccount?
    var articles: [OAArticle]?
}

struct OAArticlePage: Decodable {
    var article: OAArticle?
    var account: OAAccount?
}

/* ============================================================
   通讯录 → 公众号
   ============================================================ */

struct OfficialAccountsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var accounts: [OAAccount] = []
    @State private var loading = true
    @State private var openAccountId = ""
    @State private var showAccount = false

    private var followed: [OAAccount] { accounts.filter { $0.followed } }
    private var others: [OAAccount] { accounts.filter { !$0.followed } }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("公众号"), back: { dismiss() })
            ScrollView {
                LazyVStack(spacing: 0) {
                    if loading && accounts.isEmpty {
                        ProgressView().padding(.top, 60)
                    } else if accounts.isEmpty {
                        Text(Tr("还没有公众号")).font(pf(15)).foregroundColor(C.subLabel)
                            .frame(maxWidth: .infinity).padding(.vertical, 50)
                    } else {
                        if !followed.isEmpty {
                            sectionHead(Tr("我关注的"))
                            ForEach(followed) { a in row(a) }
                        }
                        if !others.isEmpty {
                            sectionHead(Tr("全部公众号"))
                            ForEach(others) { a in row(a) }
                        }
                    }
                    Spacer().frame(height: 30)
                }
            }
            .refreshable { await load() }
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { await load() }
        .navigationDestination(isPresented: $showAccount) {
            OfficialAccountPage(accountId: openAccountId).environmentObject(app)
        }
    }

    private func sectionHead(_ t: String) -> some View {
        Text(t)
            .font(pf(13))
            .foregroundColor(C.subLabel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 7)
    }

    private func row(_ a: OAAccount) -> some View {
        Button { openAccountId = a.id; showAccount = true } label: {
            HStack(spacing: 12) {
                Avatar(path: a.avatarPath, size: 46, radius: 10, circle: false)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(C.hairline, lineWidth: 0.5)
                    )
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(a.name).font(pf(16, .medium)).foregroundColor(C.label).lineLimit(1)
                        typeChip(a)
                    }
                    Text(a.about.isEmpty ? Tr("还没有简介") : a.about)
                        .font(pf(13)).foregroundColor(C.subLabel).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(C.subLabel)
            }
            .padding(.horizontal, 18)
            .frame(height: 72)
            .background(C.cardBg)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { HairLine(inset: 76) }
    }

    /// 服务号 / 订阅号 那个小标（服务号是深色实心，订阅号是描边，一眼能分开）
    private func typeChip(_ a: OAAccount) -> some View {
        Text(a.typeLabel)
            .font(pf(10.5, .medium))
            .foregroundColor(a.isService ? .white : C.subLabel)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .fill(a.isService ? Color(hex: 0x2C7BE5) : C.hairline)
            )
    }

    private func load() async {
        if let list = try? await API.shared.oaList() {
            accounts = list
            loading = false
        }
        loading = false
    }
}

/* ============================================================
   某个号的主页：头像 + 名字 + 简介 + 订阅按钮 + 历史文章
   ============================================================ */

struct OfficialAccountPage: View {
    let accountId: String

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var account: OAAccount?
    @State private var articles: [OAArticle] = []
    @State private var busy = false
    @State private var openArticleId = ""
    @State private var showArticle = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: account?.name ?? Tr("公众号"), back: { dismiss() })
            ScrollView {
                LazyVStack(spacing: 0) {
                    header
                    if articles.isEmpty {
                        Text(Tr("还没有发过文章")).font(pf(14)).foregroundColor(C.subLabel)
                            .frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else {
                        Text(Tr("历史文章"))
                            .font(pf(13)).foregroundColor(C.subLabel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18).padding(.top, 20).padding(.bottom, 6)
                        ForEach(articles) { a in articleRow(a) }
                    }
                    Spacer().frame(height: 30)
                }
            }
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { await load() }
        .navigationDestination(isPresented: $showArticle) {
            ArticleView(articleId: openArticleId).environmentObject(app)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Avatar(path: account?.avatarPath ?? "", size: 62, radius: 14, circle: false)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(C.hairline, lineWidth: 0.5)
                    )
                VStack(alignment: .leading, spacing: 6) {
                    Text(account?.name ?? "").font(pf(19, .semibold)).foregroundColor(C.label)
                    HStack(spacing: 6) {
                        if let a = account {
                            Text(a.typeLabel)
                                .font(pf(11, .medium))
                                .foregroundColor(a.isService ? .white : C.subLabel)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(a.isService ? Color(hex: 0x2C7BE5) : C.hairline))
                            Text("· \(a.count) 篇文章").font(pf(12)).foregroundColor(C.subLabel)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            if let bio = account?.about, !bio.isEmpty {
                Text(bio)
                    .font(pf(14))
                    .foregroundColor(C.subLabel)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
            }

            Button {
                Task { await toggleFollow() }
            } label: {
                Text(account?.followed == true ? Tr("已订阅") : Tr("订阅"))
                    .font(pf(15, .medium))
                    .foregroundColor(account?.followed == true ? C.subLabel : .white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(account?.followed == true ? C.fieldBg : C.green)
                    )
            }
            .buttonStyle(.plain)
            .disabled(busy || account == nil)
            .padding(.horizontal, 20)
            .padding(.top, 16)

            HairLine().padding(.top, 20)
        }
        .background(C.cardBg)
    }

    private func articleRow(_ a: OAArticle) -> some View {
        Button { openArticleId = a.id; showArticle = true } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(a.title)
                        .font(pf(16.5))
                        .foregroundColor(C.label)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(articleMeta(a))
                        .font(pf(12))
                        .foregroundColor(C.time)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !a.coverPath.isEmpty {
                    RemoteImage(path: a.coverPath, maxSide: 600)
                        .frame(width: 96, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(C.cardBg)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { HairLine(inset: 18) }
    }

    private func articleMeta(_ a: OAArticle) -> String {
        var parts: [String] = []
        if !(a.author ?? "").isEmpty { parts.append(a.author ?? "") }
        let d = TimeFmt.list(a.createdAt)
        if !d.isEmpty { parts.append(d) }
        if a.readCount > 0 { parts.append("\(a.readCount) 阅读") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        if let page = try? await API.shared.oaAccount(id: accountId) {
            account = page.account
            articles = page.articles ?? []
        }
    }

    private func toggleFollow() async {
        guard let a = account else { return }
        busy = true
        let want = !a.followed
        _ = try? await API.shared.oaFollow(accountId: a.id, follow: want)
        account?.following = want
        busy = false
        await app.loadChats()
        app.show(want ? Tr("已订阅，文章会推到会话里") : Tr("已取消订阅"))
    }
}

/* ============================================================
   文章页（高级版排版）
   ============================================================ */

struct ArticleView: View {
    let articleId: String

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var article: OAArticle?
    @State private var account: OAAccount?
    @State private var busy = false
    @State private var web: WebURL?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(account?.name ?? Tr("文章"))
                    .font(pf(16, .semibold)).foregroundColor(C.label).lineLimit(1)
                HStack(spacing: 0) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundColor(C.label)
                            .frame(width: 44, height: L.navH)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                    Button { if let s = article?.originalUrl, !s.isEmpty, let u = URL(string: s) { web = WebURL(url: u) } } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(article?.originalUrl?.isEmpty == false ? C.label : C.subLabel)
                            .frame(width: 44, height: L.navH)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: L.navH)
            .background(C.cardBg)
            .overlay(alignment: .bottom) { HairLine() }

            ScrollView {
                if let a = article {
                    VStack(alignment: .leading, spacing: 0) {
                        if !a.coverPath.isEmpty {
                            RemoteImage(path: a.coverPath, maxSide: 1600)
                                .frame(height: 190)
                                .clipped()
                                .padding(.bottom, 18)
                        }
                        Text(a.title)
                            .font(pf(23, .semibold))
                            .foregroundColor(C.label)
                            .lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 20)

                        HStack(spacing: 8) {
                            Avatar(path: account?.avatarPath ?? "", size: 26, radius: 7, circle: false)
                            Text(account?.name ?? "").font(pf(13)).foregroundColor(C.link)
                            if !(a.author ?? "").isEmpty, a.author != account?.name {
                                Text(a.author ?? "").font(pf(12.5)).foregroundColor(C.subLabel)
                            }
                            Spacer(minLength: 0)
                            Text(TimeFmt.list(a.createdAt)).font(pf(12)).foregroundColor(C.time)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 14)

                        HairLine().padding(.top, 14).padding(.bottom, 4)

                        ArticleBody(text: a.text)
                            .padding(.horizontal, 20)
                            .padding(.top, 10)

                        if a.readCount > 0 {
                            Text("\(a.readCount) 阅读")
                                .font(pf(12)).foregroundColor(C.time)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 22)
                        }
                        Spacer().frame(height: 26)
                    }
                } else {
                    ProgressView().padding(.top, 80)
                }
            }
            .background(C.cardBg)

            /* 底部：作者信息 + 订阅按钮（微信文章底下也是这一条） */
            if let acc = account {
                HStack(spacing: 12) {
                    Avatar(path: acc.avatarPath, size: 34, radius: 9, circle: false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(acc.name).font(pf(14, .medium)).foregroundColor(C.label)
                        Text(acc.typeLabel).font(pf(11)).foregroundColor(C.subLabel)
                    }
                    Spacer(minLength: 8)
                    Button {
                        Task { await toggleFollow(acc) }
                    } label: {
                        Text(acc.followed ? Tr("已订阅") : Tr("订阅"))
                            .font(pf(14, .medium))
                            .foregroundColor(acc.followed ? C.subLabel : .white)
                            .padding(.horizontal, 16)
                            .frame(height: 32)
                            .background(Capsule().fill(acc.followed ? C.fieldBg : C.green))
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(C.cardBg)
                .overlay(alignment: .top) { HairLine() }
            }
        }
        .background(C.cardBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { await load() }
        .sheet(item: $web) { w in SafariSheet(url: w.url).ignoresSafeArea() }
    }

    private func toggleFollow(_ acc: OAAccount) async {
        busy = true
        let want = !acc.followed
        _ = try? await API.shared.oaFollow(accountId: acc.id, follow: want)
        account?.following = want
        busy = false
        await app.loadChats()
    }

    private func load() async {
        if let page = try? await API.shared.oaArticle(id: articleId) {
            article = page.article
            account = page.account
        }
    }
}

/// 正文渲染：空行分段、`# ` 小标题、单独一行是图片地址就画图（简单但够用）
private struct ArticleBody: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .heading(let t):
                    Text(t)
                        .font(pf(18, .semibold))
                        .foregroundColor(C.label)
                        .padding(.top, 20)
                        .padding(.bottom, 8)
                        .fixedSize(horizontal: false, vertical: true)
                case .image(let p):
                    RemoteImage(path: p, maxSide: 1400)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(.vertical, 12)
                case .para(let t):
                    Text(t)
                        .font(pf(16))
                        .foregroundColor(C.label)
                        .lineSpacing(7)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 14)
                }
            }
        }
    }

    private enum Block { case heading(String), para(String), image(String) }

    private var blocks: [Block] {
        text.components(separatedBy: "\n").reduce(into: [Block]()) { out, raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return }
            if line.hasPrefix("#") {
                out.append(.heading(String(line.drop(while: { $0 == "#" || $0 == " " }))))
            } else if line.hasPrefix("/uploads/") || line.hasPrefix("http") {
                out.append(.image(line))
            } else if case .para(let prev)? = out.last {
                out[out.count - 1] = .para(prev + "\n" + line)   // 连着的行并成一段
            } else {
                out.append(.para(line))
            }
        }
    }
}

/* ============================================================
   会话里的图文卡片（kind = oa）：左边封面，右边标题 + 摘要 + 来源
   ============================================================ */

struct OAArticleCard: View {
    let json: String
    var onTap: () -> Void

    private var o: [String: Any] {
        guard let d = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return obj
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    let cover = (o["cover"] as? String) ?? ""
                    if !cover.isEmpty {
                        RemoteImage(path: cover, maxSide: 700)
                            .frame(width: 84, height: 62)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text((o["title"] as? String) ?? "")
                            .font(pf(15.5, .medium))
                            .foregroundColor(C.label)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 6) {
                    Avatar(path: (o["accountAvatar"] as? String) ?? "", size: 16, radius: 4, circle: false)
                    Text((o["accountName"] as? String) ?? Tr("公众号"))
                        .font(pf(11.5)).foregroundColor(C.time).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(Tr("文章")).font(pf(11)).foregroundColor(C.time)
                }
                .padding(.top, 10)
            }
            .padding(11)
            .frame(width: 246, alignment: .leading)
            .background { CardGlassBox(radius: 7) }
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(C.hairline, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}
