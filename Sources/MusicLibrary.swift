import SwiftUI

/* ============================================================
   我的音乐（2026-10-15 听一听对齐 QQ音乐）

   「听一听」页顶上那三个入口（我喜欢 / 我的歌单 / 最近播放）就是这一页的东西：
     · 我喜欢   = **复用服务器上的点赞**（track.likes 里有我 = 我喜欢），本机不另存一份
     · 我的歌单 = 本机数据（谁在哪个歌单里放了哪些歌），能新建/改名/加歌/删歌
     · 最近播放 = 本机记最近 100 首（一放歌就记一条）
   落盘位置：Documents/dd_music.json（读写都在 MusicLibrary 里，别的页面不碰文件）。

   ⚠ 这一页只读曲库 + 只写本机文件，不动 StreamPlay / 本地留底 / 迷你球 / 锁屏。
   ============================================================ */

/// 最近播放的一条（存歌 id + 一份快照：歌被后台删了也还能看能播）
struct MusicRecent: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var artist: String?
    var cover: String?
    var url: String
    var at: Double

    var asTrack: MusicTrack {
        MusicTrack(id: id, title: title, artist: artist, cover: cover, url: url, at: nil)
    }
}

/// 一个歌单（只存歌 id，歌的信息永远以曲库为准）
struct MusicPlaylist: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var songs: [String]
    var at: Double
}

/// 听一听顶上的三个入口
enum MusicMineKind: String, CaseIterable, Identifiable {
    case likes
    case playlists
    case recents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .likes: return "我喜欢"
        case .playlists: return "我的歌单"
        case .recents: return "最近播放"
        }
    }

    var icon: String {
        switch self {
        case .likes: return "heart.fill"
        case .playlists: return "music.note.list"
        case .recents: return "clock.arrow.circlepath"
        }
    }
}

@MainActor
final class MusicLibrary: ObservableObject {
    static let shared = MusicLibrary()

    @Published private(set) var recents: [MusicRecent] = []
    @Published private(set) var playlists: [MusicPlaylist] = []

    private struct Disk: Codable {
        var recents: [MusicRecent]?
        var playlists: [MusicPlaylist]?
    }

    private var file: URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return nil }
        return docs.appendingPathComponent("dd_music.json")
    }

    init() { load() }

    private func load() {
        guard let f = file, let d = try? Data(contentsOf: f),
              let j = try? JSONDecoder().decode(Disk.self, from: d) else { return }
        recents = j.recents ?? []
        playlists = j.playlists ?? []
    }

    private func save() {
        guard let f = file else { return }
        let j = Disk(recents: recents, playlists: playlists)
        guard let d = try? JSONEncoder().encode(j) else { return }
        try? d.write(to: f, options: .atomic)
    }

    /* ---------------------------------------------------------- 最近播放 */

    /// 放一首歌就记一条（同一首只留最新那一次，永远排在最前面）
    func markPlayed(_ t: MusicTrack) {
        guard !t.id.isEmpty, !t.title.isEmpty else { return }
        recents.removeAll { $0.id == t.id }
        recents.insert(MusicRecent(id: t.id, title: t.title, artist: t.artist,
                                   cover: t.cover, url: t.url,
                                   at: Date().timeIntervalSince1970 * 1000), at: 0)
        if recents.count > 100 { recents = Array(recents.prefix(100)) }
        save()
    }

    func clearRecents() {
        recents = []
        save()
    }

    /* ---------------------------------------------------------- 我的歌单 */

    @discardableResult
    func createPlaylist(name: String) -> MusicPlaylist {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let pl = MusicPlaylist(id: "pl_" + UUID().uuidString.prefix(8).lowercased(),
                               name: n.isEmpty ? "新建歌单" : n,
                               songs: [],
                               at: Date().timeIntervalSince1970 * 1000)
        playlists.insert(pl, at: 0)
        save()
        return pl
    }

    func renamePlaylist(_ id: String, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].name = n
        save()
    }

    func removePlaylist(_ id: String) {
        playlists.removeAll { $0.id == id }
        save()
    }

    func playlist(_ id: String) -> MusicPlaylist? {
        playlists.first { $0.id == id }
    }

    func songs(in listId: String) -> [String] {
        playlist(listId)?.songs ?? []
    }

    func has(_ trackId: String, in listId: String) -> Bool {
        songs(in: listId).contains(trackId)
    }

    func add(_ trackId: String, to listId: String) {
        guard let i = playlists.firstIndex(where: { $0.id == listId }) else { return }
        guard !playlists[i].songs.contains(trackId) else { return }
        playlists[i].songs.append(trackId)
        save()
    }

    func addAll(_ trackIds: [String], to listId: String) {
        guard let i = playlists.firstIndex(where: { $0.id == listId }) else { return }
        var changed = false
        for id in trackIds where !playlists[i].songs.contains(id) {
            playlists[i].songs.append(id)
            changed = true
        }
        if changed { save() }
    }

    func remove(_ trackId: String, from listId: String) {
        guard let i = playlists.firstIndex(where: { $0.id == listId }) else { return }
        playlists[i].songs.removeAll { $0 == trackId }
        save()
    }
}

/* ---------------------------------------------------------- 小零件 */

/// 空状态（三个「我的音乐」页共用）
struct MusicEmptyState: View {
    let icon: String
    let title: String
    var hint: String = ""

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundColor(C.subLabel.opacity(0.85))
            Text(title).font(pf(15)).foregroundColor(C.label)
            if !hint.isEmpty {
                Text(hint).font(pf(12.5)).foregroundColor(C.subLabel)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 34)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 72)
    }
}

/// 一行歌（三个页面共用）：点一下 = 播放/暂停，并把**这一页的列表**塞成播放队列
struct MusicSongRow: View {
    let track: MusicTrack
    var queue: [MusicTrack] = []
    /// 右边附加的按钮（取消喜欢 / 从歌单移出 / 加入歌单）
    var trailing: AnyView = AnyView(EmptyView())
    @ObservedObject private var player = MusicPlayer.shared

    private var playing: Bool { player.isPlaying(track.id) }

    var body: some View {
        /* ⚠ 右边那几颗小按钮（取消喜欢 / 移出歌单）放在**外面**，别塞进 Button 的 label 里：
           塞进去的话点小按钮会变成点整行（去播放），按钮就废了。 */
        HStack(spacing: 0) {
            Button {
                MusicPlayer.shared.setQueue(queue.isEmpty ? [track] : queue)
                MusicPlayer.shared.toggle(track)
            } label: {
                HStack(spacing: 12) {
                    MusicCover(path: track.cover ?? "", size: 52, radius: 10)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title).font(pf(15.5, .medium)).foregroundColor(C.label).lineLimit(1)
                        Text(track.artistText).font(pf(12.5)).foregroundColor(C.subLabel).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    ZStack {
                        Circle().fill(playing ? C.green : C.green.opacity(0.12))
                        if player.loadingId == track.id {
                            ProgressView().tint(playing ? .white : C.green).scaleEffect(0.6)
                        } else {
                            Image(systemName: playing ? "pause.fill" : "play.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(playing ? .white : C.green)
                        }
                    }
                    .frame(width: 32, height: 32)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            trailing
        }
        .padding(.horizontal, 14)
        .frame(height: 72)
    }
}

/// 一列歌（我喜欢 / 最近播放 / 歌单详情 / 选歌）
struct MusicSongList: View {
    let tracks: [MusicTrack]
    var accessory: (MusicTrack) -> AnyView = { _ in AnyView(EmptyView()) }

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                    if i > 0 { HairLine(inset: 78) }
                    MusicSongRow(track: t, queue: tracks, trailing: accessory(t))
                }
                Color.clear.frame(height: 26)
            }
        }
    }
}

/* ---------------------------------------------------------- 入口条（挂在听一听顶上） */

/// 「我喜欢 / 我的歌单 / 最近播放」三个入口
struct MusicMineBar: View {
    var onOpen: (MusicMineKind) -> Void

    var body: some View {
        HStack(spacing: 9) {
            ForEach(MusicMineKind.allCases) { k in
                Button { onOpen(k) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: k.icon)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundColor(C.green)
                        Text(Tr(k.title)).font(pf(13.5, .medium)).foregroundColor(C.label).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(C.cardBg))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(C.hairline, lineWidth: 0.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }
}

/* ---------------------------------------------------------- 三个页面 */

/// 三个入口点进来的那一页（自己带一层 NavigationStack 的调用方在这里面 push）
struct MusicMinePage: View {
    let kind: MusicMineKind

    var body: some View {
        switch kind {
        case .likes: MusicLikesPage()
        case .playlists: MusicPlaylistsPage()
        case .recents: MusicRecentsPage()
        }
    }
}

/// 我喜欢（复用服务器上的点赞，不另外存一份）
struct MusicLikesPage: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var tracks: [MusicTrack] = []
    @State private var loading = true
    @State private var addFor: MusicTrack? = nil

    private var myId: String { app.me?.id ?? "" }
    private var liked: [MusicTrack] {
        guard !myId.isEmpty else { return [] }
        return tracks.filter { ($0.likes ?? []).contains(myId) }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("我喜欢"), back: { dismiss() })

            if loading {
                HStack(spacing: 10) { ProgressView(); Text(Tr("正在加载…")).font(pf(15)).foregroundColor(C.subLabel) }
                    .frame(maxWidth: .infinity).frame(height: 90)
                Spacer(minLength: 0)
            } else if liked.isEmpty {
                MusicEmptyState(icon: "heart", title: Tr("还没有喜欢的歌"),
                                hint: Tr("在播放页点一下「赞」，喜欢过的歌都会出现在这里"))
                Spacer(minLength: 0)
            } else {
                MusicSongList(tracks: liked) { t in unlikeView(t) }
            }
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .sheet(item: $addFor) { t in AddToPlaylistSheet(track: t) }
        .task {
            tracks = await API.shared.musicTracks()
            loading = false
        }
    }

    /// 取消喜欢 + 加入歌单（QQ音乐那一列歌右边的小按钮）
    private func unlikeView(_ t: MusicTrack) -> AnyView {
        AnyView(
            HStack(spacing: 0) {
                Button { addFor = t } label: {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 17)).foregroundColor(C.subLabel)
                        .frame(width: 34, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { Task { await unlike(t) } } label: {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 17)).foregroundColor(Color(hex: 0xFF5A5A))
                        .frame(width: 34, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        )
    }

    private func unlike(_ t: MusicTrack) async {
        guard let r = await API.shared.musicLike(t.id) else { return }
        MusicPlayer.shared.applyLike(id: t.id, myId: myId, liked: r.liked, count: r.count)
        MusicSheet.shared.applyLike(id: t.id, myId: myId, liked: r.liked, count: r.count)
        tracks = await API.shared.musicTracks()
    }
}

/// 最近播放（本机记录）
struct MusicRecentsPage: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lib = MusicLibrary.shared
    @State private var addFor: MusicTrack? = nil
    @State private var confirmClear = false

    private var list: [MusicTrack] { lib.recents.map { $0.asTrack } }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("最近播放"), back: { dismiss() }) {
                if !lib.recents.isEmpty {
                    Button { confirmClear = true } label: {
                        Text(Tr("清空")).font(pf(15)).foregroundColor(C.subLabel)
                            .frame(height: 40).padding(.horizontal, 10).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if list.isEmpty {
                MusicEmptyState(icon: "clock.arrow.circlepath", title: Tr("还没有播放记录"),
                                hint: Tr("去「听一听」里点一首歌，这里就会记下来"))
                Spacer(minLength: 0)
            } else {
                MusicSongList(tracks: list) { t in addView(t) }
            }
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .sheet(item: $addFor) { t in AddToPlaylistSheet(track: t) }
        .alert(Tr("清空最近播放？"), isPresented: $confirmClear) {
            Button(Tr("取消"), role: .cancel) { }
            Button(Tr("清空"), role: .destructive) { lib.clearRecents() }
        }
    }

    private func addView(_ t: MusicTrack) -> AnyView {
        AnyView(
            Button { addFor = t } label: {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 17)).foregroundColor(C.subLabel)
                    .frame(width: 34, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        )
    }
}

/// 我的歌单（新建 / 改名 / 删歌单 / 点进去看歌）
struct MusicPlaylistsPage: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lib = MusicLibrary.shared
    /* ⚠ 一个弹窗把「新建 / 改名 / 删除」三件事都办了：
       SwiftUI 在同一层同时挂 3 个 alert，行为不稳（可能只弹最后一个）。 */
    enum Ask: Equatable { case none, new, rename, del }
    @State private var ask: Ask = .none
    @State private var renameFor: MusicPlaylist? = nil
    @State private var name = ""
    @State private var openId = ""
    @State private var showOpen = false
    @State private var confirmDel: MusicPlaylist? = nil

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("我的歌单"), back: { dismiss() }) {
                Button { name = ""; ask = .new } label: {
                    Text(Tr("新建")).font(pf(15, .medium)).foregroundColor(C.green)
                        .frame(height: 40).padding(.horizontal, 10).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if lib.playlists.isEmpty {
                MusicEmptyState(icon: "music.note.list", title: Tr("还没有歌单"),
                                hint: Tr("点右上角「新建」建一个，再往里加歌"))
                Spacer(minLength: 0)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(lib.playlists.enumerated()), id: \.element.id) { i, pl in
                            if i > 0 { HairLine(inset: 74) }
                            row(pl)
                        }
                        Color.clear.frame(height: 26)
                    }
                }
            }
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .navigationDestination(isPresented: $showOpen) { MusicPlaylistPage(listId: openId) }
        .alert(askTitle, isPresented: Binding(
            get: { ask != .none },
            set: { if !$0 { ask = .none } }
        )) {
            if ask == .new || ask == .rename {
                TextField(Tr("歌单名字"), text: $name)
            }
            Button(Tr("取消"), role: .cancel) { name = ""; ask = .none }
            if ask == .new {
                Button(Tr("创建")) {
                    let pl = lib.createPlaylist(name: name)
                    name = ""
                    ask = .none
                    openId = pl.id
                    showOpen = true
                }
            } else if ask == .rename {
                Button(Tr("保存")) {
                    if let pl = renameFor { lib.renamePlaylist(pl.id, to: name) }
                    name = ""
                    ask = .none
                }
            } else if ask == .del {
                Button(Tr("删除"), role: .destructive) {
                    if let pl = confirmDel { lib.removePlaylist(pl.id) }
                    ask = .none
                }
            }
        } message: {
            if ask == .del {
                Text(Tr("歌单里的歌不会被删掉，只是从这个歌单里移出去"))
            }
        }
    }

    private var askTitle: String {
        switch ask {
        case .new:    return Tr("新建歌单")
        case .rename: return Tr("重命名歌单")
        case .del:    return Tr("删除这个歌单？")
        case .none:   return ""
        }
    }

    private func row(_ pl: MusicPlaylist) -> some View {
        /* 「⋯」菜单放在 Button **外面**：塞进 label 里点它会变成点整行 */
        HStack(spacing: 0) {
            Button {
                openId = pl.id
                showOpen = true
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LinearGradient(colors: [Color(hex: 0xB98CFF), Color(hex: 0x7A45D6)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                        Image(systemName: "music.note.list")
                            .font(.system(size: 20, weight: .semibold)).foregroundColor(.white.opacity(0.95))
                    }
                    .frame(width: 52, height: 52)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(pl.name).font(pf(15.5, .medium)).foregroundColor(C.label).lineLimit(1)
                        Text("\(pl.songs.count) " + Tr("首")).font(pf(12.5)).foregroundColor(C.subLabel)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(C.subLabel.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button(Tr("重命名")) { name = pl.name; renameFor = pl; ask = .rename }
                Button(Tr("删除歌单"), role: .destructive) { confirmDel = pl; ask = .del }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold)).foregroundColor(C.subLabel)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .padding(.trailing, 6)
        }
        .padding(.horizontal, 14)
        .frame(height: 74)
    }
}

/// 一个歌单里的歌（加歌 / 移出 / 改名 / 删除 / 播放全部）
struct MusicPlaylistPage: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lib = MusicLibrary.shared
    let listId: String
    @State private var all: [MusicTrack] = []
    @State private var showPick = false
    @State private var rename = false
    @State private var name = ""
    @State private var confirmDel = false
    @State private var addFor: MusicTrack? = nil

    private var pl: MusicPlaylist? { lib.playlist(listId) }

    private var songs: [MusicTrack] {
        let ids = lib.songs(in: listId)
        return ids.compactMap { id in all.first { $0.id == id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: pl?.name ?? Tr("歌单"), back: { dismiss() }) {
                Menu {
                    Button(Tr("重命名")) { name = pl?.name ?? ""; rename = true }
                    Button(Tr("删除歌单"), role: .destructive) { confirmDel = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold)).foregroundColor(C.label)
                        .frame(width: 40, height: 40).contentShape(Rectangle())
                }
            }

            head

            if songs.isEmpty && !lib.songs(in: listId).isEmpty {
                /* 曲库还在拉：先转个圈，别急着说"这个歌单还没有歌" */
                HStack(spacing: 10) { ProgressView(); Text(Tr("正在加载…")).font(pf(15)).foregroundColor(C.subLabel) }
                    .frame(maxWidth: .infinity).frame(height: 90)
                Spacer(minLength: 0)
            } else if songs.isEmpty {
                MusicEmptyState(icon: "music.note", title: Tr("这个歌单还没有歌"),
                                hint: Tr("点上面「加入歌曲」，从曲库里挑几首"))
                Spacer(minLength: 0)
            } else {
                MusicSongList(tracks: songs) { t in accessory(t) }
            }
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .sheet(item: $addFor) { t in AddToPlaylistSheet(track: t) }
        .navigationDestination(isPresented: $showPick) { MusicPickPage(listId: listId) }
        .alert(Tr("重命名歌单"), isPresented: $rename) {
            TextField(Tr("歌单名字"), text: $name)
            Button(Tr("取消"), role: .cancel) { }
            Button(Tr("保存")) { lib.renamePlaylist(listId, to: name) }
        }
        .alert(Tr("删除这个歌单？"), isPresented: $confirmDel) {
            Button(Tr("取消"), role: .cancel) { }
            Button(Tr("删除"), role: .destructive) {
                lib.removePlaylist(listId)
                dismiss()
            }
        } message: {
            Text(Tr("歌单里的歌不会被删掉，只是从这个歌单里移出去"))
        }
        .task {
            all = await API.shared.musicTracks()
        }
    }

    /// 封面 + 名字 + 「播放全部 / 加入歌曲」
    private var head: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0xB98CFF), Color(hex: 0x7A45D6)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                MusicCover(path: songs.first?.cover ?? "", size: 62, radius: 10)
            }
            .frame(width: 62, height: 62)

            VStack(alignment: .leading, spacing: 6) {
                Text(pl?.name ?? "").font(pf(17, .semibold)).foregroundColor(C.label).lineLimit(1)
                Text("\(lib.songs(in: listId).count) " + Tr("首")).font(pf(12.5)).foregroundColor(C.subLabel)
                HStack(spacing: 8) {
                    Button {
                        guard let first = songs.first else { return }
                        MusicPlayer.shared.setQueue(songs)
                        MusicPlayer.shared.play(first)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill").font(.system(size: 11, weight: .bold))
                            Text(Tr("播放全部")).font(pf(12.5, .medium))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(Capsule().fill(C.green))
                    }
                    .buttonStyle(.plain)
                    .disabled(songs.isEmpty)

                    Button { showPick = true } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                            Text(Tr("加入歌曲")).font(pf(12.5, .medium))
                        }
                        .foregroundColor(C.green)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(Capsule().fill(C.green.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private func accessory(_ t: MusicTrack) -> AnyView {
        AnyView(
            HStack(spacing: 0) {
                Button { addFor = t } label: {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 17)).foregroundColor(C.subLabel)
                        .frame(width: 34, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { lib.remove(t.id, from: listId) } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 17)).foregroundColor(C.subLabel)
                        .frame(width: 34, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        )
    }
}

/// 从曲库里挑歌加进歌单（点一下勾上/取消，勾了就立刻写进去）
struct MusicPickPage: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lib = MusicLibrary.shared
    let listId: String
    @State private var tracks: [MusicTrack] = []
    @State private var query = ""
    @State private var loading = true

    private var list: [MusicTrack] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return tracks }
        return tracks.filter { $0.title.localizedCaseInsensitiveContains(q)
            || ($0.artist ?? "").localizedCaseInsensitiveContains(q)
            || $0.categoryText.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("加入歌曲"), back: { dismiss() }) {
                Button { dismiss() } label: {
                    Text(Tr("完成")).font(pf(15, .medium)).foregroundColor(C.green)
                        .frame(height: 40).padding(.horizontal, 10).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 14.5)).foregroundColor(C.searchIcon)
                TextField(Tr("搜索歌名 / 歌手"), text: $query).font(pf(15))
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15)).foregroundColor(C.searchIcon2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(C.searchBg))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(C.hairline, lineWidth: 0.6))
            .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 6)

            if loading {
                HStack(spacing: 10) { ProgressView(); Text(Tr("正在加载…")).font(pf(15)).foregroundColor(C.subLabel) }
                    .frame(maxWidth: .infinity).frame(height: 90)
                Spacer(minLength: 0)
            } else if list.isEmpty {
                MusicEmptyState(icon: "magnifyingglass", title: Tr("没找到这首歌"))
                Spacer(minLength: 0)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, t in
                            if i > 0 { HairLine(inset: 78) }
                            row(t)
                        }
                        Color.clear.frame(height: 26)
                    }
                }
            }
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task {
            tracks = await API.shared.musicTracks()
            loading = false
        }
    }

    private func row(_ t: MusicTrack) -> some View {
        let on = lib.has(t.id, in: listId)
        return Button {
            if on { lib.remove(t.id, from: listId) } else { lib.add(t.id, to: listId) }
        } label: {
            HStack(spacing: 12) {
                MusicCover(path: t.cover ?? "", size: 46, radius: 9)
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.title).font(pf(15, .medium)).foregroundColor(C.label).lineLimit(1)
                    Text(t.artistText).font(pf(12.5)).foregroundColor(C.subLabel).lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21))
                    .foregroundColor(on ? C.green : C.subLabel.opacity(0.7))
                    .padding(.trailing, 2)
            }
            .padding(.horizontal, 14)
            .frame(height: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 把一首歌加进某个歌单（列表里没有歌单就顺手新建一个）
struct AddToPlaylistSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lib = MusicLibrary.shared
    let track: MusicTrack
    @State private var showNew = false
    @State private var name = ""

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("加入歌单"), back: { dismiss() }) {
                Button { name = ""; showNew = true } label: {
                    Text(Tr("新建")).font(pf(15, .medium)).foregroundColor(C.green)
                        .frame(height: 40).padding(.horizontal, 10).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Text(track.title).font(pf(12.5)).foregroundColor(C.subLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, 8)

            if lib.playlists.isEmpty {
                MusicEmptyState(icon: "music.note.list", title: Tr("还没有歌单"),
                                hint: Tr("点右上角「新建」建一个"))
                Spacer(minLength: 0)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(lib.playlists.enumerated()), id: \.element.id) { i, pl in
                            if i > 0 { HairLine(inset: 16) }
                            Button {
                                lib.add(track.id, to: pl.id)
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    Text(pl.name).font(pf(15.5)).foregroundColor(C.label).lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text("\(pl.songs.count) " + Tr("首")).font(pf(12.5)).foregroundColor(C.subLabel)
                                    if lib.has(track.id, in: pl.id) {
                                        Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(C.green)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .frame(height: 56)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        Color.clear.frame(height: 20)
                    }
                }
            }
        }
        .background(C.pageBg.ignoresSafeArea())
        /* 2026-10-16：加入歌单页补左滑返回 */
        .swipeBack { dismiss() }
        .alert(Tr("新建歌单"), isPresented: $showNew) {
            TextField(Tr("歌单名字"), text: $name)
            Button(Tr("取消"), role: .cancel) { name = "" }
            Button(Tr("创建")) {
                let pl = lib.createPlaylist(name: name)
                lib.add(track.id, to: pl.id)
                name = ""
                dismiss()
            }
        }
    }
}
