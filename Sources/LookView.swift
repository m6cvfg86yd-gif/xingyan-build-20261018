import SwiftUI

/* ============================================================
   看一看（和微信一样：一屏内容流）
   分四段，有内容才显示，全空也不会是一片白：
     ① 朋友在看      —— 视频号里朋友看过的（有朋友头像）
     ② 朋友点赞的     —— 朋友点过赞的动态
     ③ 大家都在看     —— 站内热度最高的动态
     ④ 朋友最近发的   —— 好友最近发的动态
   ============================================================ */

struct LookAroundData: Decodable {
    struct Friend: Decodable, Hashable { var id: String?; var name: String?; var avatar: String? }
    struct Video: Decodable, Hashable, Identifiable {
        var id: String
        var title: String?
        var cover: String?
        var author: String?
        var createdAt: String?
        var dur: Double?
        var likes: Int?
        var watched: Int?
        var friendsCount: Int?
        var friends: [Friend]?
    }
    struct Post: Decodable, Hashable, Identifiable {
        var id: String
        var author: String?
        var authorId: String?
        var content: String?
        var images: [String]?
        var createdAt: String?
        var likeCount: Int?
        var commentCount: Int?
        var whoLiked: [Friend]?
    }
    var videos: [Video]?
    var hot: [Video]?
    var moments: [Post]?
    var hotMoments: [Post]?
    var friendRecent: [Post]?
}

struct LookView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var data: LookAroundData?
    @State private var loading = true
    @State private var tab = 0            // 0 朋友在看 / 1 精选

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("看一看"), back: { dismiss() })
            Picker("", selection: $tab) {
                Text(Tr("朋友在看")).tag(0)
                Text(Tr("精选")).tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 0) {
                    if loading {
                        ProgressView().padding(.top, 60)
                    } else {
                        content
                    }
                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { await load() }
    }

    private var friendVideos: [LookAroundData.Video] {
        tab == 0 ? (data?.videos ?? []) : (data?.hot ?? [])
    }

    @ViewBuilder private var content: some View {
        let vids = friendVideos
        let liked = data?.moments ?? []
        let hotPosts = data?.hotMoments ?? []
        let recent = data?.friendRecent ?? []
        if vids.isEmpty && liked.isEmpty && hotPosts.isEmpty && recent.isEmpty {
            VStack(spacing: 10) {
                SVGIcon(markup: I.look, size: 44, color: C.subLabel)
                Text(Tr("暂时没有可看的内容")).font(pf(15)).foregroundColor(C.subLabel)
                Text(Tr("朋友看了什么、点赞了什么，会出现在这里")).font(pf(12.5)).foregroundColor(C.subLabel)
            }
            .frame(maxWidth: .infinity).padding(.top, 70)
        }
        if !vids.isEmpty {
            sectionTitle(tab == 0 ? Tr("朋友在看") : Tr("精选"))
            ForEach(vids) { v in videoCard(v) }
        }
        if tab == 0 && !liked.isEmpty {
            sectionTitle(Tr("朋友点赞的"))
            ForEach(liked) { p in postCard(p, friends: p.whoLiked ?? []) }
        }
        if tab == 1 && !hotPosts.isEmpty {
            sectionTitle(Tr("大家都在看"))
            ForEach(hotPosts) { p in postCard(p, friends: []) }
        }
        if tab == 0 && !recent.isEmpty {
            sectionTitle(Tr("朋友最近发的"))
            ForEach(recent) { p in postCard(p, friends: []) }
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        HStack {
            Text(t).font(pf(13)).foregroundColor(C.subLabel)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
    }

    private func videoCard(_ v: LookAroundData.Video) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Array((v.friends ?? []).prefix(3).enumerated()), id: \.offset) { _, f in
                    Avatar(path: f.avatar ?? "", size: 20, radius: 10)
                }
                Text((v.friendsCount ?? 0) > 0
                     ? Tr("\((v.friendsCount ?? 0)) 位朋友在看")
                     : Tr("\((v.watched ?? 0)) 人看过"))
                    .font(pf(12.5)).foregroundColor(C.subLabel)
                Spacer(minLength: 0)
            }
            Text(v.title ?? "").font(pf(15.5, .medium)).foregroundColor(C.label).lineLimit(2)
            if let cover = v.cover, !cover.isEmpty {
                RemoteImage(path: cover, mode: .fill, maxSide: 900)
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            HStack(spacing: 12) {
                Text(v.author ?? "").font(pf(12.5)).foregroundColor(C.subLabel)
                Spacer(minLength: 0)
                Text("♡ \((v.likes ?? 0))").font(pf(12.5)).foregroundColor(C.subLabel)
            }
        }
        .padding(14)
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func postCard(_ p: LookAroundData.Post, friends: [LookAroundData.Friend]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !friends.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(friends.prefix(3).enumerated()), id: \.offset) { _, f in
                        Avatar(path: f.avatar ?? "", size: 20, radius: 10)
                    }
                    Text(friends.compactMap { $0.name }.joined(separator: "、") + Tr(" 在看"))
                        .font(pf(12.5)).foregroundColor(C.subLabel)
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 8) {
                Avatar(path: "", size: 30, radius: 15)
                Text(p.author ?? "").font(pf(14, .medium)).foregroundColor(C.label)
                Spacer(minLength: 0)
                Text(fmtShort(p.createdAt)).font(pf(12)).foregroundColor(C.subLabel)
            }
            if let c = p.content, !c.isEmpty {
                Text(c).font(pf(15)).foregroundColor(C.label).lineLimit(3)
            }
            if let imgs = p.images, !imgs.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(imgs.prefix(3).enumerated()), id: \.offset) { _, s in
                        RemoteImage(path: s, mode: .fill, maxSide: 600)
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 14) {
                Text("♡ \(p.likeCount ?? 0)").font(pf(12.5)).foregroundColor(C.subLabel)
                Text("💬 \(p.commentCount ?? 0)").font(pf(12.5)).foregroundColor(C.subLabel)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func fmtShort(_ s: String?) -> String {
        guard let s = s, s.count >= 16 else { return "" }
        let i = s.index(s.startIndex, offsetBy: 10)
        return String(s[s.index(s.startIndex, offsetBy: 5)..<i])
    }

    private func load() async {
        loading = true
        data = try? await API.shared.lookAround()
        loading = false
    }
}
